#define _GNU_SOURCE
#include "CLinuxSandbox.h"
#include "WorkerFilter.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/capability.h>
#include <linux/landlock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#ifndef LANDLOCK_ACCESS_FS_IOCTL_DEV
#define LANDLOCK_ACCESS_FS_IOCTL_DEV (1ULL << 15)
#endif
#ifndef LANDLOCK_RESTRICT_SELF_TSYNC
#define LANDLOCK_RESTRICT_SELF_TSYNC (1U << 3)
#endif
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_int installed;
static const uint64_t read_access = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;

static int grant(int rules, int fd, uint64_t access) {
    struct stat st;
    if (fstat(fd, &st) < 0) return 0;
    if (!S_ISDIR(st.st_mode)) access &= ~LANDLOCK_ACCESS_FS_READ_DIR;
    struct landlock_path_beneath_attr path = {.parent_fd = fd, .allowed_access = access};
    return syscall(SYS_landlock_add_rule, rules, LANDLOCK_RULE_PATH_BENEATH, &path, 0) == 0;
}

static int allow_path(int rules, const char *path, uint64_t access) {
    int fd = open(path, O_PATH | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT;
    int ok = grant(rules, fd, access);
    close(fd);
    return ok;
}

static int virtual_pcm(int rules, const char *path, unsigned device, uint64_t access) {
    int fd = open(path, O_PATH | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return errno == ENOENT;
    struct stat st;
    int ok = !fstat(fd, &st) && S_ISCHR(st.st_mode) && st.st_rdev == makedev(1, device) && grant(rules, fd, access);
    close(fd);
    return ok;
}

static int audio(int rules) {
    // ALSA's standard null PCM uses these character devices for silent input and output.
    if (!virtual_pcm(rules, "/dev/null", 3, LANDLOCK_ACCESS_FS_WRITE_FILE) ||
        !virtual_pcm(rules, "/dev/full", 7, LANDLOCK_ACCESS_FS_READ_FILE)) return 0;
    DIR *dir = opendir("/dev/snd");
    if (!dir) return errno == ENOENT;
    int ok = grant(rules, dirfd(dir), LANDLOCK_ACCESS_FS_READ_DIR);
    struct dirent *ent;
    while (ok && (ent = readdir(dir))) {
        unsigned card, device; char direction, trailing;
        int pcm = sscanf(ent->d_name, "pcmC%uD%u%c%c", &card, &device, &direction, &trailing) == 3 &&
                  (direction == 'p' || direction == 'c');
        int control = sscanf(ent->d_name, "controlC%u%c", &card, &trailing) == 1;
        if (!pcm && !control) continue;
        int fd = openat(dirfd(dir), ent->d_name, O_PATH | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0 && errno == ENOENT) continue;
        struct stat st;
        ok = fd >= 0 && fstat(fd, &st) == 0 && S_ISCHR(st.st_mode) && major(st.st_rdev) == 116 &&
             grant(rules, fd, LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_IOCTL_DEV |
                   (pcm ? LANDLOCK_ACCESS_FS_WRITE_FILE : 0));
        if (fd >= 0) close(fd);
    }
    closedir(dir);
    return ok;
}
static int restrict_files(enum WorkerRole role) {
    if (syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION) < 8) return 0;
    // No filesystem writes (except PCM I/O), execution or TCP listening.
    // Scope signals and abstract Unix sockets to this Landlock domain.
    struct { uint64_t fs, net, scope; } policy = {(LANDLOCK_ACCESS_FS_IOCTL_DEV << 1) - 1, 1, 3};
    int rules = syscall(SYS_landlock_create_ruleset, &policy, sizeof(policy), 0);
    if (rules < 0) return 0;
    const char *system[] = {"/usr/lib", "/lib", "/lib64", "/usr/share/locale", "/etc/ld.so.cache",
        "/etc/localtime", "/proc/cpuinfo", "/sys/devices/system/cpu", "/dev/urandom", "/dev/random"};
    const char *resolver[] = {"/etc/resolv.conf", "/etc/hosts", "/etc/nsswitch.conf", "/etc/host.conf",
        "/etc/gai.conf", "/etc/services"};
    const char *media[] = {"/etc/ssl/certs", "/usr/share/ca-certificates", "/usr/share/p11-kit",
        "/etc/alsa", "/usr/share/alsa", "/proc/asound", "/usr/share/glib-2.0", "/etc/gnutls",
        "/etc/passwd", "/etc/group", "/etc/machine-id"};
    int ok = 1;
    for (size_t i = 0; ok && i < sizeof(system)/sizeof(system[0]); ++i)
        ok = allow_path(rules, system[i], read_access);
    if (role == CallingBroker) {
        for (size_t i = 0; ok && i < sizeof(resolver)/sizeof(resolver[0]); ++i)
            ok = allow_path(rules, resolver[i], read_access);
    } else {
        for (size_t i = 0; ok && i < sizeof(media)/sizeof(media[0]); ++i)
            ok = allow_path(rules, media[i], read_access);
        if (ok) ok = audio(rules);
    }
    if (ok) ok = syscall(SYS_landlock_restrict_self, rules, LANDLOCK_RESTRICT_SELF_TSYNC) == 0;
    close(rules);
    return ok;
}
static int denied_operations(enum WorkerRole role) {
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd >= 0) { close(fd); return 0; }
    if (errno != EACCES) return 0;
    int families[] = {AF_UNIX, AF_INET};
    int count = role == CallingWorker ? 2 : 1;
    for (int i = 0; i < count; ++i) {
        fd = socket(families[i], SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (fd >= 0) { close(fd); return 0; }
        if (errno != EPERM) return 0;
    }
    return prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 1;
}

static int install(enum WorkerRole role) {
    pthread_mutex_lock(&lock);
    if (!atomic_load(&installed)) {
        struct __user_cap_header_struct h = {.version = _LINUX_CAPABILITY_VERSION_3};
        struct __user_cap_data_struct caps[2] = {0};
        if (geteuid() && geteuid() == getuid() && !syscall(SYS_capget, &h, caps) &&
            !caps[0].permitted && !caps[1].permitted &&
            !prctl(PR_SET_DUMPABLE, 0) && !prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) &&
            restrict_files(role) && serein_install_worker_filter(role) && denied_operations(role)) atomic_store(&installed, role);
    }
    pthread_mutex_unlock(&lock);
    return atomic_load(&installed) == (int)role;
}
int serein_confine_call_worker(void) { return install(CallingWorker); }
int serein_confine_call_broker(void) { return install(CallingBroker); }
int serein_is_call_worker_confined(void) { return atomic_load(&installed) == CallingWorker; }

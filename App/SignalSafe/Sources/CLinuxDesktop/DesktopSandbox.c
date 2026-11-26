// The Docker app runs as an unprivileged user with a private data and runtime
// directory. Install kernel restrictions before constructing the session or UI.
#define _GNU_SOURCE
#include "CLinuxDesktop.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/landlock.h>
#include <pthread.h>
#include <sched.h>
#include <seccomp.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

// Stable kernel UAPI constants added after Ubuntu 24.04's build headers.
#ifndef LANDLOCK_ACCESS_FS_IOCTL_DEV
#define LANDLOCK_ACCESS_FS_IOCTL_DEV (1ULL << 15)
#endif
#ifndef LANDLOCK_RESTRICT_SELF_TSYNC
#define LANDLOCK_RESTRICT_SELF_TSYNC (1U << 3)
#endif

static _Atomic int confined;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static const uint64_t readable = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;
static const uint64_t writable = LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_TRUNCATE |
    LANDLOCK_ACCESS_FS_REMOVE_DIR | LANDLOCK_ACCESS_FS_REMOVE_FILE | LANDLOCK_ACCESS_FS_MAKE_DIR |
    LANDLOCK_ACCESS_FS_MAKE_REG | LANDLOCK_ACCESS_FS_MAKE_SOCK | LANDLOCK_ACCESS_FS_MAKE_SYM | LANDLOCK_ACCESS_FS_REFER;

static int permit(int ruleset, const char *path, uint64_t access, int private_dir) {
    int fd = open(path, O_PATH | O_CLOEXEC | (private_dir ? O_NOFOLLOW : 0));
    if (fd == -1) return !private_dir && errno == ENOENT;
    struct stat info;
    int ok = fstat(fd, &info) == 0;
    if (private_dir)
        ok = ok && S_ISDIR(info.st_mode) && (info.st_mode & 077) == 0 && info.st_uid == geteuid();
    if (ok) {
        if (!S_ISDIR(info.st_mode))
            access &= LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_IOCTL_DEV;
        struct landlock_path_beneath_attr rule = {.parent_fd = fd, .allowed_access = access};
        ok = syscall(SYS_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH, &rule, 0) == 0;
    }
    close(fd);
    return ok;
}

static int restrict_files(void) {
    if (syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION) < 8) return 0;
    // ABI 8 provides all-thread enforcement. Handle all filesystem access bits
    // through IOCTL_DEV, TCP bind, and signals sent outside the app's domain.
    struct { uint64_t fs, net, scope; } rules = {(LANDLOCK_ACCESS_FS_IOCTL_DEV << 1) - 1, 1, 2};
    int fd = (int)syscall(SYS_landlock_create_ruleset, &rules, sizeof(rules), 0);
    if (fd < 0) return 0;
    const char *public_files[] = {
        "/opt/serein", "/usr", "/lib", "/lib64", "/etc/ld.so.cache", "/etc/localtime", "/etc/fonts",
        "/etc/ssl", "/etc/pki", "/etc/resolv.conf", "/etc/hosts", "/etc/host.conf", "/etc/gai.conf",
        "/etc/nsswitch.conf", "/etc/passwd", "/etc/group", "/etc/machine-id", "/etc/os-release",
        "/var/cache/fontconfig", "/tmp/.X11-unix", "/sys/devices/system/cpu",
        "/proc/self/maps", "/proc/self/status", "/proc/self/task", "/proc/cpuinfo", "/proc/meminfo",
        "/dev/urandom", "/dev/random"
    };
    int ok = permit(fd, "/var/lib/serein", readable | writable, 1)
        && permit(fd, "/run/serein", readable | writable, 1)
        && permit(fd, "/dev/null", LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_WRITE_FILE, 0);
    for (size_t i = 0; ok && i < sizeof(public_files) / sizeof(public_files[0]); ++i)
        ok = permit(fd, public_files[i], readable, 0);
    if (ok) ok = syscall(SYS_landlock_restrict_self, fd, LANDLOCK_RESTRICT_SELF_TSYNC) == 0;
    close(fd);
    return ok;
}

static int restrict_processes(void) {
    scmp_filter_ctx f = seccomp_init(SCMP_ACT_ALLOW);
    if (!f) return 0;
    int ok = seccomp_attr_set(f, SCMP_FLTATR_CTL_TSYNC, 1) == 0;
    const char *denied[] = {"fork", "vfork", "execve", "execveat", "ptrace", "process_vm_readv", "process_vm_writev",
                            "pidfd_getfd", "setsid", "setns", "unshare", "listen", "io_uring_setup"};
    for (size_t i = 0; ok && i < sizeof(denied) / sizeof(denied[0]); ++i) {
        int nr = seccomp_syscall_resolve_name(denied[i]);
        if (nr != __NR_SCMP_ERROR) ok = seccomp_rule_add(f, SCMP_ACT_ERRNO(EPERM), nr, 0) == 0;
    }
    ok = ok && seccomp_rule_add(f, SCMP_ACT_ERRNO(EPERM), SCMP_SYS(clone), 1,
                                SCMP_A0(SCMP_CMP_MASKED_EQ, CLONE_THREAD, 0)) == 0;
    ok = ok && seccomp_rule_add(f, SCMP_ACT_ERRNO(ENOSYS), SCMP_SYS(clone3), 0) == 0;
    if (ok) ok = seccomp_load(f) == 0;
    seccomp_release(f);
    return ok;
}

static int unprivileged(void) {
    if (geteuid() == 0 || getuid() != geteuid()) return 0;
    FILE *status = fopen("/proc/self/status", "re");
    if (!status) return 0;
    char line[256];
    unsigned long long permitted = ~0ULL;
    while (fgets(line, sizeof(line), status))
        if (sscanf(line, "CapPrm: %llx", &permitted) == 1) break;
    fclose(status);
    return permitted == 0;
}

static void install(void) {
    if (unprivileged() && prctl(PR_SET_DUMPABLE, 0) == 0 && prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0
        && restrict_files() && restrict_processes()) confined = 1;
}

int serein_desktop_confine(void) { pthread_once(&once, install); return confined; }
int serein_desktop_is_confined(void) { return confined; }

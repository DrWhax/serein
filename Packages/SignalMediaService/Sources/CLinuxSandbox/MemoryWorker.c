#define _GNU_SOURCE
#include "CLinuxSandbox.h"
#include "WorkerFilter.h"
#include <netinet/in.h>
#include <linux/netlink.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/sched.h>
#include <pthread.h>
#include <seccomp.h>
#include <stdatomic.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <termios.h>
#include <sound/asound.h>
#include <unistd.h>

static atomic_int installed;
static pthread_mutex_t install_lock = PTHREAD_MUTEX_INITIALIZER;

static int allow_runtime(scmp_filter_ctx filter) {
    // Memory, clocks, thread scheduling, notification queues, and I/O on
    // inherited descriptors. A decoder or HTML parser opens no paths or sockets.
    const char *const names[] = {
        "read", "write", "readv", "writev", "close", "close_range", "fstat", "lseek",
        "dup", "dup2", "dup3", "pipe", "pipe2", "poll", "ppoll", "select", "pselect6",
        "epoll_create", "epoll_create1", "epoll_ctl", "epoll_wait", "epoll_pwait", "epoll_pwait2",
        "eventfd", "eventfd2", "timerfd_create", "timerfd_settime", "timerfd_gettime",
        "recvfrom", "recvmsg", "recvmmsg", "shutdown",
        "getsockopt", "getsockname", "getpeername",
        "brk", "mmap", "mremap", "munmap", "mprotect", "madvise", "mincore", "getrandom",
        "clock_gettime", "clock_getres", "clock_nanosleep", "gettimeofday", "nanosleep", "times",
        "getpid", "gettid", "getppid", "getuid", "geteuid", "getgid", "getegid",
        "getcpu", "sched_yield", "sched_getaffinity", "sched_getparam", "sched_getscheduler",
        "getpriority", "getrlimit", "getrusage", "sysinfo", "uname",
        "futex", "futex_waitv", "rseq", "set_tid_address", "set_robust_list", "get_robust_list",
        "rt_sigaction", "rt_sigprocmask", "rt_sigreturn", "rt_sigtimedwait", "rt_sigsuspend", "rt_sigpending", "signalfd4", "sigaltstack",
        "restart_syscall", "exit", "exit_group"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        const int nr = seccomp_syscall_resolve_name(names[i]);
        if (nr != __NR_SCMP_ERROR && seccomp_rule_add(filter, SCMP_ACT_ALLOW, nr, 0) < 0) return 0;
    }
    return 1;
}

static int allow_name(scmp_filter_ctx f, const char *name) {
    int nr = seccomp_syscall_resolve_name(name);
    return nr == __NR_SCMP_ERROR || seccomp_rule_add(f, SCMP_ACT_ALLOW, nr, 0) == 0;
}

int serein_install_worker_filter(enum WorkerRole role) {
    scmp_filter_ctx filter = seccomp_init(SCMP_ACT_ERRNO(EPERM));
    if (!filter) return 0;
    int ok = seccomp_attr_set(filter, SCMP_FLTATR_CTL_TSYNC, 1) == 0 && allow_runtime(filter);
    if (role == CallingWorker) {
        ok = ok && allow_name(filter, "wait4");  // Reap the socket broker that predates confinement.
        const int commands[] = {F_GETFD, F_SETFD, F_GETFL, F_DUPFD, F_DUPFD_CLOEXEC};
        for (size_t i = 0; ok && i < sizeof(commands)/sizeof(commands[0]); ++i)
            ok = seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(fcntl), 1, SCMP_A1(SCMP_CMP_EQ, commands[i], 0)) == 0;
        ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(fcntl), 2,
            SCMP_A1(SCMP_CMP_EQ, F_SETFL, 0), SCMP_A2(SCMP_CMP_MASKED_EQ, O_ASYNC, 0)) == 0;
    } else ok = ok && allow_name(filter, "fcntl");
    if (role != CallingWorker)
        ok = ok && allow_name(filter, "sendmsg") && allow_name(filter, "sendmmsg") && allow_name(filter, "setsockopt");
    if (role != MemoryWorker) {
        const char *names[] = {"open", "openat", "stat", "statx", "newfstatat", "lstat", "access", "faccessat",
            "faccessat2", "readlink", "readlinkat", "getdents64", "getcwd", "pread64", "getgroups", "fstatfs"};
        for (size_t i = 0; ok && i < sizeof(names)/sizeof(names[0]); ++i) ok = allow_name(filter, names[i]);
    }
    if (role == CallingBroker) {
        ok = ok && allow_name(filter, "bind") && allow_name(filter, "connect") && allow_name(filter, "sendto");
        const int families[] = {AF_INET, AF_INET6};
        for (size_t i = 0; ok && i < 2; ++i)
            for (int t = 0; ok && t < 2; ++t)
                ok = seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(socket), 2,
                    SCMP_A0(SCMP_CMP_EQ, families[i], 0), SCMP_A1(SCMP_CMP_MASKED_EQ, 15, t ? SOCK_STREAM : SOCK_DGRAM)) == 0;
        ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(socket), 2,
            SCMP_A0(SCMP_CMP_EQ, AF_NETLINK, 0), SCMP_A2(SCMP_CMP_EQ, NETLINK_ROUTE, 0)) == 0;
    }
    if (role == CallingWorker) {
        // Optional DER trust roots are held in a private non-executable memory file.
        ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(memfd_create), 1,
            SCMP_A1(SCMP_CMP_EQ, 0x0009U, 0)) == 0;  // MFD_CLOEXEC | MFD_NOEXEC_SEAL
        // Landlock additionally restricts device ioctl to the individual ALSA nodes.
        // Allow PCM commands and control enumeration, never console or network ioctls.
        ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(ioctl), 1,
            SCMP_A1(SCMP_CMP_MASKED_EQ, 0xffffffff0000ff00ULL, 'A' << 8)) == 0;
        const unsigned long controls[] = {SNDRV_CTL_IOCTL_PVERSION, SNDRV_CTL_IOCTL_CARD_INFO,
            SNDRV_CTL_IOCTL_PCM_NEXT_DEVICE, SNDRV_CTL_IOCTL_PCM_INFO,
            SNDRV_CTL_IOCTL_ELEM_LIST, SNDRV_CTL_IOCTL_ELEM_INFO, SNDRV_CTL_IOCTL_ELEM_READ};
        for (size_t i = 0; ok && i < sizeof(controls)/sizeof(controls[0]); ++i)
            ok = seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(ioctl), 1, SCMP_A1(SCMP_CMP_EQ, controls[i], 0)) == 0;
    }
    // clone3 passes flags indirectly. glibc retries with clone when it gets ENOSYS.
    ok = ok && seccomp_rule_add(filter, SCMP_ACT_ERRNO(ENOSYS), SCMP_SYS(clone3), 0) == 0;
    uint64_t thread_mask = CLONE_THREAD, required = CLONE_THREAD;
    if (role != MemoryWorker) {
        uint64_t allowed = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SYSVSEM |
            CLONE_SETTLS | CLONE_PARENT_SETTID | CLONE_CHILD_SETTID | CLONE_CHILD_CLEARTID;
        required |= CLONE_VM | CLONE_SIGHAND;
        thread_mask = ~allowed | required;
    }
    ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(clone), 1,
                                SCMP_A0(SCMP_CMP_MASKED_EQ, thread_mask, required)) == 0;
    ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(socketpair), 1, SCMP_A0(SCMP_CMP_EQ, AF_UNIX, 0)) == 0;
    // Connected local pairs also use send() for their payloads.
    if (role != CallingBroker) ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(sendto), 1, SCMP_A4(SCMP_CMP_EQ, 0, 0)) == 0;
    ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(tgkill), 1, SCMP_A0(SCMP_CMP_EQ, (unsigned)getpid(), 0)) == 0;
    const int operations[] = {PR_SET_NAME, PR_GET_NAME, PR_GET_NO_NEW_PRIVS, PR_GET_SECCOMP};
    for (size_t i = 0; ok && i < sizeof(operations) / sizeof(operations[0]); ++i)
        ok = seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(prctl), 1, SCMP_A0(SCMP_CMP_EQ, operations[i], 0)) == 0;
    ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(ioctl), 1, SCMP_A1(SCMP_CMP_EQ, FIONREAD, 0)) == 0;
    ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(ioctl), 1, SCMP_A1(SCMP_CMP_EQ, FIONBIO, 0)) == 0;
    ok = ok && prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0 && seccomp_load(filter) == 0;
    seccomp_release(filter);
    return ok;
}

int serein_confine_memory_worker(void) {
    pthread_mutex_lock(&install_lock);
    if (!atomic_load(&installed) && serein_install_worker_filter(MemoryWorker)) atomic_store(&installed, 1);
    pthread_mutex_unlock(&install_lock);
    return atomic_load(&installed);
}
int serein_is_memory_worker_confined(void) { return atomic_load(&installed); }

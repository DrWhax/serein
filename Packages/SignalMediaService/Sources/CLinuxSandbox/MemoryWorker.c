#define _GNU_SOURCE
#include "CLinuxSandbox.h"
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
#include <unistd.h>

static atomic_int installed;
static pthread_mutex_t install_lock = PTHREAD_MUTEX_INITIALIZER;

static int allow_runtime(scmp_filter_ctx filter) {
    // Memory, clocks, thread scheduling, notification queues, and I/O on
    // inherited descriptors. A decoder or HTML parser opens no paths or sockets.
    const char *const names[] = {
        "read", "write", "readv", "writev", "close", "close_range", "fstat", "lseek",
        "dup", "dup2", "dup3", "fcntl", "pipe", "pipe2", "poll", "ppoll", "select", "pselect6",
        "epoll_create", "epoll_create1", "epoll_ctl", "epoll_wait", "epoll_pwait", "epoll_pwait2",
        "eventfd", "eventfd2", "timerfd_create", "timerfd_settime", "timerfd_gettime",
        "recvfrom", "recvmsg", "recvmmsg", "sendmsg", "sendmmsg", "shutdown",
        "getsockopt", "setsockopt", "getsockname", "getpeername",
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

static int install_filter(void) {
    scmp_filter_ctx filter = seccomp_init(SCMP_ACT_ERRNO(EPERM));
    if (!filter) return 0;
    int ok = seccomp_attr_set(filter, SCMP_FLTATR_CTL_TSYNC, 1) == 0 && allow_runtime(filter);
    // clone3 passes flags indirectly. glibc retries with clone when it gets ENOSYS.
    ok = ok && seccomp_rule_add(filter, SCMP_ACT_ERRNO(ENOSYS), SCMP_SYS(clone3), 0) == 0;
    ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(clone), 1,
                                SCMP_A0(SCMP_CMP_MASKED_EQ, CLONE_THREAD, CLONE_THREAD)) == 0;
    ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(socketpair), 1, SCMP_A0(SCMP_CMP_EQ, AF_UNIX, 0)) == 0;
    // Connected local pairs also use send() for their payloads.
    ok = ok && seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(sendto), 1, SCMP_A4(SCMP_CMP_EQ, 0, 0)) == 0;
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
    if (!atomic_load(&installed) && install_filter()) atomic_store(&installed, 1);
    pthread_mutex_unlock(&install_lock);
    return atomic_load(&installed);
}
int serein_is_memory_worker_confined(void) { return atomic_load(&installed); }

#define _GNU_SOURCE
#include "CLinuxLandlock.h"
#include <errno.h>
#include <linux/landlock.h>
#include <sys/single_threaded.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef LANDLOCK_RESTRICT_SELF_TSYNC
#define LANDLOCK_RESTRICT_SELF_TSYNC (1U << 3)
#endif

int serein_landlock_restrict_all(int ruleset) {
    long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 6) {
        if (abi >= 0) errno = EOPNOTSUPP;
        return 0;
    }
    if (abi >= 8)
        return syscall(SYS_landlock_restrict_self, ruleset, LANDLOCK_RESTRICT_SELF_TSYNC) == 0;

    // glibc only reports true while the process is known to have a single thread.
    // Threads subsequently started by the desktop or worker inherit this domain.
    if (!__libc_single_threaded) {
        errno = EBUSY;
        return 0;
    }
    return syscall(SYS_landlock_restrict_self, ruleset, 0) == 0;
}

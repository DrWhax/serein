// Build with DesktopSandbox.c, CLinuxLandlock, and -lseccomp. Run as the app user in an
// isolated Docker container with private /var/lib/serein and /run/serein.
#include "CLinuxDesktop.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <linux/landlock.h>
#include <sys/syscall.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

static pthread_barrier_t start;
static int sibling_denied;

static int denied_open(void) {
    int fd = open("/tmp/serein-desktop-check-public.txt", O_RDONLY);
    if (fd >= 0) { close(fd); return 0; }
    return errno == EACCES || errno == EPERM;
}

static void *existing_thread(void *unused) {
    (void)unused;
    pthread_barrier_wait(&start);
    sibling_denied = denied_open();
    return NULL;
}

int main(void) {
    int readable = open("/tmp/serein-desktop-check-public.txt", O_RDONLY);
    if (readable < 0) return 1;
    close(readable);
    long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 6) return 2;
    if (abi < 8) {
        // A late install must fail closed with another thread already running.
        pid_t pid = fork();
        if (pid < 0) return 2;
        if (!pid) {
            pthread_t thread;
            if (pthread_barrier_init(&start, NULL, 2) || pthread_create(&thread, NULL, existing_thread, NULL)) _exit(2);
            _exit(serein_desktop_confine() ? 1 : 0);
        }
        int status;
        if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) || WEXITSTATUS(status)) return 2;
    }
    pthread_t sibling;
    if (pthread_barrier_init(&start, NULL, 2)) return 2;
    if (abi >= 8 && pthread_create(&sibling, NULL, existing_thread, NULL)) return 2;
    if (!serein_desktop_confine() || !serein_desktop_is_confined()) {
        perror("could not apply desktop confinement");
        return 3;
    }
    if (abi < 8 && pthread_create(&sibling, NULL, existing_thread, NULL)) return 2;
    pthread_barrier_wait(&start);
    pthread_join(sibling, NULL);
    if (!sibling_denied || !denied_open()) return 4;
    int data = open("/var/lib/serein/desktop-check.data", O_CREAT | O_RDWR | O_TRUNC, 0600);
    if (data < 0 || write(data, "ok", 2) != 2) return 5;
    close(data);
    if (unlink("/var/lib/serein/desktop-check.data") != 0) return 6;
    pid_t child = fork();
    if (child == 0) _exit(0);
    if (child > 0) { waitpid(child, NULL, 0); return 7; }
    if (errno != EPERM) return 8;
    printf("PASS: ABI %ld, both threads confined, app data writable, other files and process creation denied\n", abi);
    return 0;
}

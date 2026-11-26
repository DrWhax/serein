// Check the actual kernel policy on threads created before and after installation.
#define _GNU_SOURCE
#include "CLinuxSandbox.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static pthread_barrier_t ready;
static int ordinary_operations_are_denied(void) {
    if (open("/etc/hosts", O_RDONLY) >= 0 || errno != EPERM) return 0;
    if (open("/tmp/serein-sandbox-probe", O_CREAT | O_EXCL | O_WRONLY, 0600) >= 0 || errno != EPERM) return 0;
    if (socket(AF_INET, SOCK_STREAM, 0) >= 0 || errno != EPERM) return 0;
    if (socket(AF_UNIX, SOCK_STREAM, 0) >= 0 || errno != EPERM) return 0;
    return prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 1;
}
static void *check_existing(void *result) {
    pthread_barrier_wait(&ready);
    *(int *)result = ordinary_operations_are_denied();
    return NULL;
}
static void *check_new(void *result) {
    *(int *)result = ordinary_operations_are_denied();
    return NULL;
}
int main(void) {
    int initial = open("/etc/hosts", O_RDONLY), before = 0, after = 0;
    if (initial < 0) return 1;
    close(initial);
    if (pthread_barrier_init(&ready, NULL, 2)) return 1;
    pthread_t first, second;
    if (pthread_create(&first, NULL, check_existing, &before) || !serein_confine_memory_worker()) return 1;
    pthread_barrier_wait(&ready);
    if (pthread_join(first, NULL) || !before || pthread_create(&second, NULL, check_new, &after) ||
        pthread_join(second, NULL) || !after || !ordinary_operations_are_denied()) return 1;
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) return 1;
    char byte = 0;
    if (write(pair[0], "s", 1) != 1 || read(pair[1], &byte, 1) != 1 || byte != 's') return 1;
    pid_t child = fork();
    if (child == 0) _exit(1);
    if (child > 0) { waitpid(child, NULL, 0); return 1; }
    if (errno != EPERM || !serein_is_memory_worker_confined()) return 1;
    execl("/usr/bin/false", "false", NULL);
    if (errno != EPERM) return 1;
    puts("Kernel denied file access, new sockets, exec and fork. Existing and new threads retained local IPC.");
    return 0;
}

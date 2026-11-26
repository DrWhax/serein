#define _GNU_SOURCE
#include "CLinuxServiceSocket.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int connected_unix_socket(int fd, int type) {
    struct sockaddr_un peer;
    socklen_t addr_len = sizeof(peer), type_len = sizeof(type);
    int actual;
    return getpeername(fd, (struct sockaddr *)&peer, &addr_len) == 0 &&
        peer.sun_family == AF_UNIX &&
        getsockopt(fd, SOL_SOCKET, SO_TYPE, &actual, &type_len) == 0 && actual == type;
}

/* Route slots are reserved by the Linux launcher. A spawned parser child must
 * never inherit its parent's authority to open sessions with other services. */
__attribute__((constructor)) static void protect_inherited_routes(void) {
    for (int fd = 160; fd < 176; ++fd) {
        if (connected_unix_socket(fd, SOCK_SEQPACKET))
            fcntl(fd, F_SETFD, FD_CLOEXEC);
    }
}

int serein_duplicate_route(int route) {
    if (!connected_unix_socket(route, SOCK_SEQPACKET)) return -1;
    return fcntl(route, F_DUPFD_CLOEXEC, 3);
}

int serein_open_channel(int route, int stream, uint64_t high, uint64_t low) {
    int pair[2];
    if (socketpair(AF_UNIX, (stream ? SOCK_STREAM : SOCK_SEQPACKET) | SOCK_CLOEXEC, 0, pair) < 0)
        return -1;
    uint64_t token[] = {high, low};
    struct iovec data = { token, sizeof(token) };
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
    struct msghdr message = { .msg_iov = &data, .msg_iovlen = 1,
        .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes) };
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &pair[1], sizeof(int));
    ssize_t sent;
    do { sent = sendmsg(route, &message, MSG_NOSIGNAL | MSG_DONTWAIT); }
    while (sent < 0 && errno == EINTR);
    close(pair[1]);
    if (sent == sizeof(token)) return pair[0];
    close(pair[0]);
    return -1;
}

int serein_accept_channel(int route, int stream, uint64_t high, uint64_t low) {
    uint64_t token[2] = {0};
    struct iovec data = { token, sizeof(token) };
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control;
    for (;;) {
        struct msghdr message = { .msg_iov = &data, .msg_iovlen = 1,
            .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes) };
        ssize_t bytes = recvmsg(route, &message, MSG_CMSG_CLOEXEC);
        if (bytes < 0 && errno == EINTR) continue;
        if (bytes < 0) return -1;
        int accepted = -1;
        int valid = bytes == sizeof(token) && !(message.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) &&
            token[0] == high && token[1] == low;
        for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header;
             header = CMSG_NXTHDR(&message, header)) {
            if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) {
                valid = 0;
                continue;
            }
            size_t count = (header->cmsg_len - CMSG_LEN(0)) / sizeof(int);
            for (size_t i = 0; i < count; ++i) {
                int fd;
                memcpy(&fd, CMSG_DATA(header) + i * sizeof(int), sizeof(fd));
                if (accepted < 0) accepted = fd;
                else { close(fd); valid = 0; }
            }
        }
        if (accepted < 0) {
            if (bytes == 0) return -1;
            continue;
        }
        if (valid && connected_unix_socket(accepted, stream ? SOCK_STREAM : SOCK_SEQPACKET)) return accepted;
        close(accepted);
    }
}

void serein_interrupt_channel(int fd) { shutdown(fd, SHUT_RDWR); }

int serein_block_pipe_signal(void) {
    sigset_t mask, old;
    sigemptyset(&mask);
    sigaddset(&mask, SIGPIPE);
    if (pthread_sigmask(SIG_BLOCK, &mask, &old) != 0) return -1;
    if (sigismember(&old, SIGPIPE)) return 1;
    sigset_t pending;
    if (sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE)) return 2;
    return 0;
}

void serein_restore_pipe_signal(int state, int failed) {
    if (state < 0 || state == 1) return;
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGPIPE);
    if (failed && state == 0) {
        struct timespec now = {0};
        while (sigtimedwait(&mask, NULL, &now) < 0 && errno == EINTR) {}
    }
    pthread_sigmask(SIG_UNBLOCK, &mask, NULL);
}

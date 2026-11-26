#ifndef SEREIN_LINUX_SERVICE_SOCKET_H
#define SEREIN_LINUX_SERVICE_SOCKET_H
#include <stdint.h>

/* The supervisor provisions a connected AF_UNIX/SOCK_SEQPACKET descriptor for
 * each allowed edge, before switching identity and applying the service sandbox.
 * The kernel transfers descriptors only across these inherited capabilities. */
int serein_open_channel(int route, int stream, uint64_t high, uint64_t low);
int serein_accept_channel(int route, int stream, uint64_t high, uint64_t low);
int serein_duplicate_route(int route);
void serein_interrupt_channel(int fd);

/* Save and restore SIGPIPE on the writing thread, including any pre-existing
 * pending signal, so writing to a dead peer reports EPIPE to Swift. */
int serein_block_pipe_signal(void);
void serein_restore_pipe_signal(int state, int failed);
#endif

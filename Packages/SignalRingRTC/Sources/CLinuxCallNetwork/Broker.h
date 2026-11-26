#pragma once
#include <gio/gio.h>
#include <stdint.h>
enum CallSocketOperation { CallUDP = 1, CallTCP, CallListen, CallInterfaces };
struct CallSocketRequest {
    uint32_t op;
    uint16_t port, local_port;
    uint8_t family, reuse;
    char source[46], host[256];
};
int call_broker_active(void);
int call_broker_socket(const struct CallSocketRequest *req, GCancellable *cancel);
int call_broker_interfaces(uint8_t *result, size_t capacity);
int call_broker_listen(int reuse, GCancellable *cancel, int *lease_fd);
int call_net_local_interfaces(uint8_t *result, size_t capacity);

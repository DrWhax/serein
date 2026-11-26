#pragma once
#include <ptrcheck.h>
#include <stdint.h>
#include <stddef.h>

uint64_t call_net_new(void);
void call_net_cancel(uint64_t id);
void call_net_release(uint64_t id);
enum CallNetMode { CallDatagram, CallStream, CallTLS };
// family is 0, 4, or 6. The TLS identity can differ from the numeric dial target.
int call_net_connect(uint64_t id, const uint8_t * __counted_by(n) host __attribute__((noescape)), size_t n,
    uint16_t port, int family, uint16_t local_port, int reuse, enum CallNetMode mode,
    const uint8_t * __counted_by(m) identity __attribute__((noescape)), size_t m,
    const uint8_t * __counted_by(k) root_der __attribute__((noescape)), size_t k);
int call_net_listen(uint64_t id, int reuse);
struct CallNetPeer { uint64_t id; int count; uint16_t port; int ip_size; };
struct CallNetPeer call_net_accept(uint64_t listener, uint8_t * __counted_by(n) packet __attribute__((noescape)), size_t n,
    uint8_t * __counted_by(k) ip __attribute__((noescape)), size_t k);
struct CallNetAddress { uint16_t port; int ip_size; };
struct CallNetAddress call_net_local(uint64_t id, uint8_t * __counted_by(n) ip __attribute__((noescape)), size_t n);
int call_net_read(uint64_t id, uint8_t * __counted_by(n) bytes __attribute__((noescape)), size_t n);
int call_net_write(uint64_t id, const uint8_t * __counted_by(n) bytes __attribute__((noescape)), size_t n);

int call_net_parse_ip(const uint8_t * __counted_by(n) text __attribute__((noescape)), size_t n,
    uint8_t * __counted_by(k) bytes __attribute__((noescape)), size_t k);
int call_net_format_ip(const uint8_t * __counted_by(n) ip __attribute__((noescape)), size_t n,
    uint8_t * __counted_by(k) text __attribute__((noescape)), size_t k);
int call_net_interfaces(uint8_t * __counted_by(n) result __attribute__((noescape)), size_t n);

int call_net_start_broker(void);
int call_net_serve_broker(void);

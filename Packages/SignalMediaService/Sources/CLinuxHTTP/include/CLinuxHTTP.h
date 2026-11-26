#pragma once
#include <ptrcheck.h>
#include <stddef.h>
#include <stdint.h>

enum SereinHTTPError { SereinHTTPOK, SereinHTTPInvalid, SereinHTTPTLS, SereinHTTPTimeout, SereinHTTPCancelled, SereinHTTPNetwork };
uint64_t serein_http_new(const uint8_t * __counted_by(url_size) url __attribute__((noescape)), size_t url_size,
                         const uint8_t * __counted_by(method_size) method __attribute__((noescape)), size_t method_size, unsigned timeout_seconds);
void serein_http_release(uint64_t id);
void serein_http_cancel(uint64_t id);
enum SereinHTTPError serein_http_add_root(uint64_t id, const uint8_t * __counted_by(size) der __attribute__((noescape)), size_t size);
enum SereinHTTPError serein_http_add_header(uint64_t id, const uint8_t * __counted_by(name_size) name __attribute__((noescape)), size_t name_size,
                                            const uint8_t * __counted_by(value_size) value __attribute__((noescape)), size_t value_size);
enum SereinHTTPError serein_http_set_body(uint64_t id, const uint8_t * __counted_by(size) bytes __attribute__((noescape)), size_t size);
struct SereinHTTPResponse { enum SereinHTTPError error; int status; size_t headers_size; };
struct SereinHTTPResponse serein_http_send(uint64_t id);
enum SereinHTTPError serein_http_headers(uint64_t id, uint8_t * __counted_by(size) bytes __attribute__((noescape)), size_t size);
struct SereinHTTPRead { enum SereinHTTPError error; size_t count; };
struct SereinHTTPRead serein_http_read(uint64_t id, uint8_t * __counted_by(size) bytes __attribute__((noescape)), size_t size);

enum SereinHTTPError serein_http_set_proxy(uint64_t id, const uint8_t * __counted_by(size) uri __attribute__((noescape)), size_t size);
size_t serein_http_peers_size(uint64_t id);
enum SereinHTTPError serein_http_peers(uint64_t id, uint8_t * __counted_by(size) bytes __attribute__((noescape)), size_t size);
int serein_parse_ip(const uint8_t * __counted_by(size) text __attribute__((noescape)), size_t size,
                    uint8_t * __counted_by(capacity) out __attribute__((noescape)), size_t capacity);

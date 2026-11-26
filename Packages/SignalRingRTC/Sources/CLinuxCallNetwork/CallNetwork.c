#define _GNU_SOURCE
#include "CLinuxCallNetwork.h"
#include <gio/gio.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <sys/mman.h>
#include <unistd.h>

typedef struct {
    GCancellable *cancel;
    GSocket *socket;
    GIOStream *stream;
    int anchor_fd;
} CallSocket;

static GMutex lock;
static GHashTable *sockets;
static uint64_t next_id;

static void destroy(void *value) {
    CallSocket *s = value;
    g_clear_object(&s->stream);
    g_clear_object(&s->socket);
    g_clear_object(&s->cancel);
    if (s->anchor_fd >= 0) close(s->anchor_fd);
}
static void unref(CallSocket *s) { g_atomic_rc_box_release_full(s, destroy); }
G_DEFINE_AUTOPTR_CLEANUP_FUNC(CallSocket, unref)

static CallSocket *lookup(uint64_t id) {
    g_mutex_lock(&lock);
    CallSocket *s = sockets ? g_hash_table_lookup(sockets, &id) : NULL;
    if (s) g_atomic_rc_box_acquire(s);
    g_mutex_unlock(&lock);
    return s;
}
static uint64_t register_socket(GSocket *socket) {
    CallSocket *s = g_atomic_rc_box_new0(CallSocket);
    s->anchor_fd = -1;
    s->cancel = g_cancellable_new();
    s->socket = socket;
    g_mutex_lock(&lock);
    if (!sockets) sockets = g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free, (GDestroyNotify)unref);
    uint64_t id = ++next_id;
    g_hash_table_insert(sockets, g_memdup2(&id, sizeof(id)), s);
    g_mutex_unlock(&lock);
    return id;
}
uint64_t call_net_new(void) { return register_socket(NULL); }
void call_net_cancel(uint64_t id) {
    g_autoptr(CallSocket) s = lookup(id);
    if (s) g_cancellable_cancel(s->cancel);
}
void call_net_release(uint64_t id) {
    call_net_cancel(id);
    g_mutex_lock(&lock);
    if (sockets) g_hash_table_remove(sockets, &id);
    g_mutex_unlock(&lock);
}

static GSocket *datagram(GInetAddress *local, uint16_t port, int reuse) {
    GSocketFamily family = g_inet_address_get_family(local);
    g_autoptr(GSocket) socket = g_socket_new(family, G_SOCKET_TYPE_DATAGRAM, G_SOCKET_PROTOCOL_UDP, NULL);
    g_autoptr(GSocketAddress) address = g_inet_socket_address_new(local, port);
    if (!socket || !g_socket_bind(socket, address, reuse, NULL)) return NULL;
    return g_steal_pointer(&socket);
}

static int connect_udp(CallSocket *s, const char *host, uint16_t port, int family, uint16_t local_port, int reuse) {
    g_autoptr(GSocketConnectable) target = g_network_address_new(host, port);
    g_autoptr(GSocketAddressEnumerator) addresses = g_socket_connectable_enumerate(target);
    while (!g_cancellable_is_cancelled(s->cancel)) {
        g_autoptr(GSocketAddress) peer = g_socket_address_enumerator_next(addresses, s->cancel, NULL);
        if (!peer) break;
        GSocketFamily af = g_socket_address_get_family(peer);
        if ((family == 4 && af != G_SOCKET_FAMILY_IPV4) || (family == 6 && af != G_SOCKET_FAMILY_IPV6)) continue;
        g_autoptr(GInetAddress) any = g_inet_address_new_any(af);
        g_autoptr(GSocket) socket = datagram(any, local_port, reuse);
        if (socket && g_socket_connect(socket, peer, s->cancel, NULL)) {
            s->socket = g_steal_pointer(&socket);
            return 1;
        }
    }
    return 0;
}

// GTlsFileDatabase accepts PEM by path. Keep a private, anonymous memory file
// alive with the TLS session when an isolated test supplies its own trust root.
static gboolean set_anchor(CallSocket *s, GTlsConnection *tls, const uint8_t *der, size_t n) {
    if (!der || n > 1024 * 1024) return FALSE;
    g_autofree char *encoded = g_base64_encode(der, n);
    g_autoptr(GString) pem = g_string_new("-----BEGIN CERTIFICATE-----\n");
    for (size_t at = 0, len = strlen(encoded); at < len; at += 64) {
        g_string_append_len(pem, encoded + at, MIN(len - at, 64));
        g_string_append_c(pem, '\n');
    }
    g_string_append(pem, "-----END CERTIFICATE-----\n");
    g_autoptr(GTlsCertificate) cert = g_tls_certificate_new_from_pem(pem->str, pem->len, NULL);
    if (!cert) return FALSE;
    s->anchor_fd = memfd_create("serein-call-trust", MFD_CLOEXEC);
    if (s->anchor_fd < 0 || write(s->anchor_fd, pem->str, pem->len) != (ssize_t)pem->len) return FALSE;
    g_autofree char *path = g_strdup_printf("/proc/self/fd/%d", s->anchor_fd);
    g_autoptr(GTlsDatabase) db = g_tls_file_database_new(path, NULL);
    if (!db) return FALSE;
    g_tls_connection_set_database(tls, db);
    return TRUE;
}

int call_net_connect(uint64_t id, const uint8_t *name, size_t n, uint16_t port, int family, uint16_t local_port, int reuse,
                     enum CallNetMode mode, const uint8_t *identity, size_t m, const uint8_t *root, size_t k) {
    g_autoptr(CallSocket) s = lookup(id);
    if (!s || !port || !name || !n || n > 1024 || memchr(name, 0, n)) return 0;
    g_autofree char *host = g_strndup((const char *)name, n);
    if (mode == CallDatagram) return connect_udp(s, host, port, family, local_port, reuse);

    g_autoptr(GSocketClient) client = g_socket_client_new();
    g_socket_client_set_enable_proxy(client, FALSE);
    g_socket_client_set_timeout(client, 15);
    g_autoptr(GSocketConnectable) target = g_network_address_new(host, port);
    g_autoptr(GSocketConnection) connection = g_socket_client_connect(client, target, s->cancel, NULL);
    if (!connection) return 0;
    GSocket *socket = g_socket_connection_get_socket(connection);
    g_socket_set_option(socket, IPPROTO_TCP, TCP_NODELAY, 1, NULL);
    if (mode == CallTLS) {
        if (!m || !identity || m > 1024 || memchr(identity, 0, m)) return 0;
        g_autofree char *tls_name = g_strndup((const char *)identity, m);
        g_autoptr(GSocketConnectable) server = g_network_address_new(tls_name, port);
        g_autoptr(GIOStream) stream = g_tls_client_connection_new(G_IO_STREAM(connection), server, NULL);
        if (!stream || (k && !set_anchor(s, G_TLS_CONNECTION(stream), root, k))) return 0;
        // A separately anchored connection must never inherit a previous session's verification.
        GParamSpec *resume = g_object_class_find_property(G_OBJECT_GET_CLASS(stream), "session-resumption-enabled");
        if (!resume || !(resume->flags & G_PARAM_WRITABLE) || !(resume->flags & G_PARAM_READABLE) ||
            G_PARAM_SPEC_VALUE_TYPE(resume) != G_TYPE_BOOLEAN) return 0;
        gboolean enabled = TRUE;
        g_object_set(stream, "session-resumption-enabled", FALSE, NULL);
        g_object_get(stream, "session-resumption-enabled", &enabled, NULL);
        if (enabled || !g_tls_connection_handshake(G_TLS_CONNECTION(stream), s->cancel, NULL)) return 0;
        GTlsProtocolVersion version = g_tls_connection_get_protocol_version(G_TLS_CONNECTION(stream));
        if (version != G_TLS_PROTOCOL_VERSION_TLS_1_2 && version != G_TLS_PROTOCOL_VERSION_TLS_1_3) return 0;
        s->stream = g_steal_pointer(&stream);
    } else {
        s->stream = G_IO_STREAM(g_object_ref(connection));
    }
    s->socket = g_object_ref(socket);
    g_socket_set_timeout(socket, 0);
    return 1;
}

int call_net_listen(uint64_t id, int reuse) {
    g_autoptr(CallSocket) s = lookup(id);
    if (!s) return 0;
    const GSocketFamily families[] = {G_SOCKET_FAMILY_IPV6, G_SOCKET_FAMILY_IPV4};
    for (size_t i = 0; i < G_N_ELEMENTS(families); i++) {
        GSocketFamily family = families[i];
        g_autoptr(GSocket) socket = g_socket_new(family, G_SOCKET_TYPE_DATAGRAM, G_SOCKET_PROTOCOL_UDP, NULL);
        if (!socket) continue;
        if (family == G_SOCKET_FAMILY_IPV6 &&
            (!g_socket_set_option(socket, IPPROTO_IPV6, IPV6_V6ONLY, 0, NULL) ||
             !g_socket_set_option(socket, IPPROTO_IPV6, IPV6_RECVPKTINFO, 1, NULL))) continue;
        if (family == G_SOCKET_FAMILY_IPV4 && !g_socket_set_option(socket, IPPROTO_IP, IP_PKTINFO, 1, NULL)) continue;
        g_autoptr(GInetAddress) any = g_inet_address_new_any(family);
        g_autoptr(GSocketAddress) address = g_inet_socket_address_new(any, 0);
        if (!g_socket_bind(socket, address, reuse, NULL)) continue;
        s->socket = g_steal_pointer(&socket);
        return 1;
    }
    return 0;
}

static int pack_ip(GInetAddress *address, uint8_t *out, size_t cap) {
    size_t size = g_inet_address_get_native_size(address);
    const uint8_t *bytes = g_inet_address_to_bytes(address);
    static const uint8_t mapped[12] = {0,0,0,0,0,0,0,0,0,0,255,255};
    if (size == 16 && !memcmp(bytes, mapped, 12)) { bytes += 12; size = 4; }
    if (!out || size > cap) return 0;
    memcpy(out, bytes, size);
    return (int)size;
}

struct CallNetAddress call_net_local(uint64_t id, uint8_t *ip, size_t n) {
    g_autoptr(CallSocket) s = lookup(id);
    if (!s || !s->socket) return (struct CallNetAddress){0};
    g_autoptr(GSocketAddress) addr = g_socket_get_local_address(s->socket, NULL);
    if (!G_IS_INET_SOCKET_ADDRESS(addr)) return (struct CallNetAddress){0};
    GInetSocketAddress *inet = G_INET_SOCKET_ADDRESS(addr);
    return (struct CallNetAddress){g_inet_socket_address_get_port(inet),
        pack_ip(g_inet_socket_address_get_address(inet), ip, n)};
}

struct CallNetPeer call_net_accept(uint64_t id, uint8_t *packet, size_t n, uint8_t *ip, size_t k) {
    g_autoptr(CallSocket) s = lookup(id);
    if (!s || !s->socket || !packet || !n || !ip || k < 16) return (struct CallNetPeer){0};
    int fd = g_socket_get_fd(s->socket);
    while (g_socket_condition_wait(s->socket, G_IO_IN, s->cancel, NULL)) {
        struct sockaddr_storage remote;
        union { struct cmsghdr align; char bytes[128]; } control;
        struct iovec iov = {packet, n};
        struct msghdr msg = {.msg_name = &remote, .msg_namelen = sizeof(remote), .msg_iov = &iov,
            .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = sizeof(control.bytes)};
        ssize_t count = recvmsg(fd, &msg, MSG_DONTWAIT);
        if (count < 0) {
            if (errno == EINTR || errno == EAGAIN) continue;
            break;
        }
        if (!count || msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) continue;
        g_autoptr(GSocketAddress) native = g_socket_address_new_from_native(&remote, msg.msg_namelen);
        if (!G_IS_INET_SOCKET_ADDRESS(native)) continue;
        GInetSocketAddress *peer = G_INET_SOCKET_ADDRESS(native);
        int width = pack_ip(g_inet_socket_address_get_address(peer), ip, k);
        if (!width) continue;
        uint8_t local[16];
        int local_width = 0;
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
            if (c->cmsg_level == IPPROTO_IPV6 && c->cmsg_type == IPV6_PKTINFO) {
                const struct in6_pktinfo *info = (const void *)CMSG_DATA(c);
                g_autoptr(GInetAddress) addr = g_inet_address_new_from_bytes(info->ipi6_addr.s6_addr, G_SOCKET_FAMILY_IPV6);
                local_width = pack_ip(addr, local, sizeof(local));
            } else if (c->cmsg_level == IPPROTO_IP && c->cmsg_type == IP_PKTINFO) {
                const struct in_pktinfo *info = (const void *)CMSG_DATA(c);
                memcpy(local, &info->ipi_addr, 4);
                local_width = 4;
            }
        }
        if (local_width != width) continue;
        GSocketFamily family = width == 4 ? G_SOCKET_FAMILY_IPV4 : G_SOCKET_FAMILY_IPV6;
        g_autoptr(GInetAddress) local_ip = g_inet_address_new_from_bytes(local, family);
        g_autoptr(GSocketAddress) listener_addr = g_socket_get_local_address(s->socket, NULL);
        if (!listener_addr) break;
        g_autoptr(GSocket) child = datagram(local_ip, g_inet_socket_address_get_port(G_INET_SOCKET_ADDRESS(listener_addr)), TRUE);
        g_autoptr(GInetAddress) remote_ip = g_inet_address_new_from_bytes(ip, family);
        uint16_t port = g_inet_socket_address_get_port(peer);
        g_autoptr(GSocketAddress) endpoint = g_inet_socket_address_new(remote_ip, port);
        if (!child || !g_socket_connect(child, endpoint, s->cancel, NULL)) continue;
        return (struct CallNetPeer){register_socket(g_steal_pointer(&child)), (int)count, port, width};
    }
    return (struct CallNetPeer){0};
}

int call_net_read(uint64_t id, uint8_t *bytes, size_t n) {
    g_autoptr(CallSocket) s = lookup(id);
    if (!s || !s->socket || !bytes || !n || n > 65536) return -1;
    if (s->stream) return (int)g_input_stream_read(g_io_stream_get_input_stream(s->stream), bytes, n, s->cancel, NULL);
    return (int)g_socket_receive(s->socket, (char *)bytes, n, s->cancel, NULL);
}
int call_net_write(uint64_t id, const uint8_t *bytes, size_t n) {
    g_autoptr(CallSocket) s = lookup(id);
    if (!s || !s->socket || !bytes || n > 65536) return 0;
    if (s->stream) return g_output_stream_write_all(g_io_stream_get_output_stream(s->stream), bytes, n, NULL, s->cancel, NULL);
    return g_socket_send(s->socket, (const char *)bytes, n, s->cancel, NULL) == (gssize)n;
}

#include "CLinuxHTTP.h"
#include <libsoup/soup.h>
#include <glib/gstdio.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    SoupSession *session;
    SoupMessage *message;
    GCancellable *cancel;
    GInputStream *stream;
    GString *anchors, *headers;
    char *anchors_path;
    gboolean unsupported_tls_backend;
} Request;

static GMutex registry_lock;
static GHashTable *requests;
static uint64_t next_id;

static void destroy_request(void *ptr) {
    Request *r = ptr;
    g_clear_object(&r->stream);
    g_clear_object(&r->message);
    g_clear_object(&r->session);
    g_clear_object(&r->cancel);
    g_string_free(r->anchors, TRUE);
    g_string_free(r->headers, TRUE);
    if (r->anchors_path) { g_unlink(r->anchors_path); g_free(r->anchors_path); }
}
static void release_request(Request *r) { g_atomic_rc_box_release_full(r, destroy_request); }
G_DEFINE_AUTOPTR_CLEANUP_FUNC(Request, release_request)

static Request *lookup(uint64_t id) {
    g_mutex_lock(&registry_lock);
    Request *r = requests ? g_hash_table_lookup(requests, &id) : NULL;
    if (r) g_atomic_rc_box_acquire(r);
    g_mutex_unlock(&registry_lock);
    return r;
}
static char *string(const uint8_t *bytes, size_t size) {
    if ((!bytes && size) || (size && memchr(bytes, 0, size))) return NULL;
    return size ? g_strndup((const char *)bytes, size) : g_strdup("");
}
static gboolean token(const char *s) {
    if (!s || !*s) return FALSE;
    for (; *s; ++s) if (!g_ascii_isalnum(*s) && !strchr("!#$%&'*+-.^_`|~", *s)) return FALSE;
    return TRUE;
}
static void configure_connection(SoupMessage *message, GSocketClientEvent event, GIOStream *stream, void *data) {
    if (event != G_SOCKET_CLIENT_TLS_HANDSHAKING) return;
    Request *r = data;
    // Each request selects its own trust database. A cached TLS session for the
    // same hostname may have authenticated against a different database.
    GParamSpec *setting = g_object_class_find_property(G_OBJECT_GET_CLASS(stream), "session-resumption-enabled");
    if (!setting || !(setting->flags & G_PARAM_WRITABLE) || !(setting->flags & G_PARAM_READABLE) ||
        G_PARAM_SPEC_VALUE_TYPE(setting) != G_TYPE_BOOLEAN) {
        r->unsupported_tls_backend = TRUE;
        g_cancellable_cancel(r->cancel);
        return;
    }
    gboolean enabled = TRUE;
    g_object_set(stream, "session-resumption-enabled", FALSE, NULL);
    g_object_get(stream, "session-resumption-enabled", &enabled, NULL);
    if (enabled) {
        r->unsupported_tls_backend = TRUE;
        g_cancellable_cancel(r->cancel);
    }
}
uint64_t serein_http_new(const uint8_t * __counted_by(url_size) url __attribute__((noescape)), size_t url_size,
                         const uint8_t * __counted_by(method_size) method __attribute__((noescape)), size_t method_size) {
    g_autofree char *address = string(url, url_size), *verb = string(method, method_size);
    if (!address || !token(verb)) return 0;
    g_autoptr(GUri) uri = g_uri_parse(address, G_URI_FLAGS_ENCODED, NULL);
    if (!uri || g_ascii_strcasecmp(g_uri_get_scheme(uri), "https") || !g_uri_get_host(uri)) return 0;
    g_autoptr(SoupMessage) message = soup_message_new_from_uri(verb, uri);
    if (!message) return 0;
    Request *r = g_atomic_rc_box_new0(Request);
    r->session = soup_session_new();
    soup_session_set_timeout(r->session, 30);
    r->message = g_steal_pointer(&message);
    soup_message_add_flags(r->message, SOUP_MESSAGE_NO_REDIRECT);
    r->cancel = g_cancellable_new();
    g_signal_connect(r->message, "network-event", G_CALLBACK(configure_connection), r);
    r->anchors = g_string_new(NULL);
    r->headers = g_string_new(NULL);
    g_mutex_lock(&registry_lock);
    if (!requests) requests = g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free, NULL);
    uint64_t *key = g_new(uint64_t, 1);
    do { ++next_id; } while (!next_id || g_hash_table_contains(requests, &next_id));
    const uint64_t id = *key = next_id;
    g_hash_table_insert(requests, key, r);
    g_mutex_unlock(&registry_lock);
    return id;
}
void serein_http_cancel(uint64_t id) {
    g_autoptr(Request) r = lookup(id);
    if (r) g_cancellable_cancel(r->cancel);
}
void serein_http_release(uint64_t id) {
    void *key = NULL, *value = NULL;
    g_mutex_lock(&registry_lock);
    if (requests) g_hash_table_steal_extended(requests, &id, &key, &value);
    g_mutex_unlock(&registry_lock);
    g_free(key);
    if (value) release_request(value);
}
enum SereinHTTPError serein_http_add_root(uint64_t id, const uint8_t * __counted_by(size) der __attribute__((noescape)), size_t size) {
    g_autoptr(Request) r = lookup(id);
    if (!r || !der || !size) return SereinHTTPTLS;
    g_autofree char *encoded = g_base64_encode(der, size);
    g_autoptr(GString) pem = g_string_new("-----BEGIN CERTIFICATE-----\n");
    for (size_t i = 0, n = strlen(encoded); i < n; i += 64) {
        g_string_append_len(pem, encoded + i, MIN(n - i, 64));
        g_string_append_c(pem, '\n');
    }
    g_string_append(pem, "-----END CERTIFICATE-----\n");
    g_autoptr(GTlsCertificate) certificate = g_tls_certificate_new_from_pem(pem->str, pem->len, NULL);
    if (!certificate) return SereinHTTPTLS;
    g_string_append_len(r->anchors, pem->str, pem->len);
    return SereinHTTPOK;
}
enum SereinHTTPError serein_http_add_header(uint64_t id, const uint8_t * __counted_by(name_size) name __attribute__((noescape)), size_t name_size,
                                            const uint8_t * __counted_by(value_size) value __attribute__((noescape)), size_t value_size) {
    g_autoptr(Request) r = lookup(id);
    g_autofree char *field = string(name, name_size), *text = string(value, value_size);
    if (!r || !token(field) || !text || strpbrk(text, "\r\n")) return SereinHTTPInvalid;
    soup_message_headers_replace(soup_message_get_request_headers(r->message), field, text);
    return SereinHTTPOK;
}
enum SereinHTTPError serein_http_set_body(uint64_t id, const uint8_t * __counted_by(size) bytes __attribute__((noescape)), size_t size) {
    g_autoptr(Request) r = lookup(id);
    if (!r || (!bytes && size)) return SereinHTTPInvalid;
    g_autoptr(GBytes) body = g_bytes_new(bytes, size);
    soup_message_set_request_body_from_bytes(r->message, NULL, body);
    return SereinHTTPOK;
}
static enum SereinHTTPError failure(GError *error) {
    if (error && error->domain == G_TLS_ERROR) return SereinHTTPTLS;
    if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) return SereinHTTPCancelled;
    if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT)) return SereinHTTPTimeout;
    return SereinHTTPNetwork;
}
static gboolean configure_roots(Request *r) {
    // GTlsFileDatabase replaces the session's system database. Keep its public
    // anchors alive until the session closes, including on lazy-loading backends.
    int fd = g_file_open_tmp("serein-ca-XXXXXX", &r->anchors_path, NULL);
    if (fd < 0) return FALSE;
    size_t offset = 0;
    while (offset < r->anchors->len) {
        ssize_t count = write(fd, r->anchors->str + offset, r->anchors->len - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        offset += (size_t)count;
    }
    if (close(fd) || offset != r->anchors->len) return FALSE;
    g_autoptr(GTlsDatabase) db = g_tls_file_database_new(r->anchors_path, NULL);
    if (!db) return FALSE;
    soup_session_set_tls_database(r->session, db);
    return TRUE;
}
struct SereinHTTPResponse serein_http_send(uint64_t id) {
    g_autoptr(Request) r = lookup(id);
    if (!r || r->stream) return (struct SereinHTTPResponse){SereinHTTPInvalid};
    if (r->anchors->len && !configure_roots(r)) return (struct SereinHTTPResponse){SereinHTTPTLS};
    g_autoptr(GError) error = NULL;
    r->stream = soup_session_send(r->session, r->message, r->cancel, &error);
    if (r->unsupported_tls_backend) return (struct SereinHTTPResponse){SereinHTTPTLS};
    if (!r->stream) return (struct SereinHTTPResponse){failure(error)};
    SoupMessageHeadersIter iter;
    const char *name, *value;
    soup_message_headers_iter_init(&iter, soup_message_get_response_headers(r->message));
    while (soup_message_headers_iter_next(&iter, &name, &value)) {
        g_string_append_printf(r->headers, "%s: %s\n", name, value);
        if (r->headers->len > 128 * 1024) return (struct SereinHTTPResponse){SereinHTTPInvalid};
    }
    return (struct SereinHTTPResponse){SereinHTTPOK, soup_message_get_status(r->message), r->headers->len};
}
enum SereinHTTPError serein_http_headers(uint64_t id, uint8_t * __counted_by(size) bytes __attribute__((noescape)), size_t size) {
    g_autoptr(Request) r = lookup(id);
    if (!r || r->headers->len != size || (size && !bytes)) return SereinHTTPInvalid;
    if (size) memcpy(bytes, r->headers->str, size);
    return SereinHTTPOK;
}
struct SereinHTTPRead serein_http_read(uint64_t id, uint8_t * __counted_by(size) bytes __attribute__((noescape)), size_t size) {
    g_autoptr(Request) r = lookup(id);
    if (!r || !r->stream || !bytes || !size) return (struct SereinHTTPRead){SereinHTTPInvalid};
    g_autoptr(GError) error = NULL;
    const gssize count = g_input_stream_read(r->stream, bytes, size, r->cancel, &error);
    if (count < 0) return (struct SereinHTTPRead){failure(error)};
    return (struct SereinHTTPRead){SereinHTTPOK, (size_t)count};
}

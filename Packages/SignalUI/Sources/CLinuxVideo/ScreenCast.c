#include "CaptureInternal.h"
#include <libportal/portal.h>
#include <unistd.h>

typedef struct {
    GMutex lock;
    GCancellable *cancel;
    SereinShareStatus status;
    int fd;
    gboolean is_screen;
    uint32_t node;
} Share;

typedef struct {
    Share *share;
    GMainLoop *loop;
    XdpSession *session;
    gboolean starting;
} Request;

static void free_share(gpointer data) {
    Share *share = data;
    if (share->fd >= 0) close(share->fd);
    g_object_unref(share->cancel);
    g_mutex_clear(&share->lock);
}

static void set_status(Share *share, SereinShareStatus status) {
    g_mutex_lock(&share->lock);
    share->status = status;
    g_mutex_unlock(&share->lock);
}

static void request_failed(Request *request, GError *error) {
    g_debug("ScreenCast request failed: %s", error ? error->message : "invalid stream response");
    set_status(request->share, g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED) ? SereinShareCancelled : SereinShareFailed);
    g_main_loop_quit(request->loop);
}

static void revoked(XdpSession *session, gpointer data) {
    Request *request = data;
    set_status(request->share, SereinShareClosed);
    if (!request->starting) g_main_loop_quit(request->loop);
}

static void selected(GObject *object, GAsyncResult *result, gpointer data) {
    Request *request = data;
    g_autoptr(GError) error = NULL;
    request->starting = FALSE;
    if (!xdp_session_start_finish(request->session, result, &error)) { request_failed(request, error); return; }
    GVariant *streams = xdp_session_get_streams(request->session);
    if (!streams || g_variant_n_children(streams) != 1) { request_failed(request, NULL); return; }
    g_autoptr(GVariant) entry = g_variant_get_child_value(streams, 0);
    uint32_t node;
    g_variant_get_child(entry, 0, "u", &node);
    if (node == UINT32_MAX || xdp_session_get_session_state(request->session) != XDP_SESSION_ACTIVE) {
        request_failed(request, NULL);
        return;
    }
    g_autoptr(GVariant) properties = g_variant_get_child_value(entry, 1);
    uint32_t source_type = 0;
    g_variant_lookup(properties, "source_type", "u", &source_type);
    int fd = xdp_session_open_pipewire_remote(request->session);
    if (fd < 0) { request_failed(request, NULL); return; }
    g_mutex_lock(&request->share->lock);
    request->share->node = node;
    request->share->is_screen = source_type == XDP_OUTPUT_MONITOR;
    request->share->fd = fd;
    request->share->status = SereinShareGranted;
    g_mutex_unlock(&request->share->lock);
}

static void created(GObject *object, GAsyncResult *result, gpointer data) {
    Request *request = data;
    g_autoptr(GError) error = NULL;
    request->session = xdp_portal_create_screencast_session_finish(XDP_PORTAL(object), result, &error);
    if (!request->session) { request_failed(request, error); return; }
    g_signal_connect(request->session, "closed", G_CALLBACK(revoked), request);
    xdp_session_start(request->session, NULL, request->share->cancel, selected, request);
}

static gboolean check_cancel(gpointer data) {
    Request *request = data;
    if (!request->starting && g_cancellable_is_cancelled(request->share->cancel)) {
        set_status(request->share, SereinShareCancelled);
        g_main_loop_quit(request->loop);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static gpointer run_request(gpointer data) {
    Share *share = data;
    g_autoptr(GMainContext) context = g_main_context_new();
    g_main_context_push_thread_default(context);
    g_autoptr(GMainLoop) loop = g_main_loop_new(context, FALSE);
    g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SESSION, share->cancel, NULL);
    if (bus) {
        g_autoptr(XdpPortal) portal = xdp_portal_new();
        Request request = { .share = share, .loop = loop, .starting = TRUE };
        g_autoptr(GSource) timer = g_timeout_source_new(50);
        g_source_set_callback(timer, check_cancel, &request, NULL);
        g_source_attach(timer, context);
        xdp_portal_create_screencast_session(portal, XDP_OUTPUT_MONITOR | XDP_OUTPUT_WINDOW, XDP_SCREENCAST_FLAG_NONE,
            XDP_CURSOR_MODE_EMBEDDED, XDP_PERSIST_MODE_NONE, NULL, share->cancel, created, &request);
        g_main_loop_run(loop);
        g_source_destroy(timer);
        if (request.session) {
            g_signal_handlers_disconnect_by_data(request.session, &request);
            xdp_session_close(request.session);
            g_object_unref(request.session);
        }
    } else {
        set_status(share, g_cancellable_is_cancelled(share->cancel) ? SereinShareCancelled : SereinShareFailed);
    }
    g_main_context_pop_thread_default(context);
    g_atomic_rc_box_release_full(share, free_share);
    return NULL;
}

uint64_t serein_share_request(void) {
    Share *share = g_atomic_rc_box_new0(Share);
    g_mutex_init(&share->lock);
    share->fd = -1;
    share->cancel = g_cancellable_new();
    GThread *worker = g_thread_try_new("serein-screencast", run_request, g_atomic_rc_box_acquire(share), NULL);
    if (worker) g_thread_unref(worker);
    else {
        set_status(share, SereinShareFailed);
        g_atomic_rc_box_release_full(share, free_share);
    }
    return (uintptr_t)share;
}

SereinShareStatus serein_share_status(uint64_t request) {
    Share *share = (Share *)(uintptr_t)request;
    if (!share) return SereinShareFailed;
    g_mutex_lock(&share->lock);
    SereinShareStatus status = share->status;
    g_mutex_unlock(&share->lock);
    return status;
}

int serein_share_is_screen(uint64_t request) {
    Share *share = (Share *)(uintptr_t)request;
    if (!share) return 0;
    g_mutex_lock(&share->lock);
    int screen = share->is_screen;
    g_mutex_unlock(&share->lock);
    return screen;
}

SereinCameraOpen serein_share_open(uint64_t request, int max_width, int max_height, int fps) {
    Share *share = (Share *)(uintptr_t)request;
    if (!share) return (SereinCameraOpen){ .error = 1 };
    g_mutex_lock(&share->lock);
    int fd = -1;
    uint32_t node = share->node;
    if (share->status == SereinShareGranted) { fd = share->fd; share->fd = -1; }
    g_mutex_unlock(&share->lock);
    return serein_capture_from_remote(fd, NULL, node, max_width, max_height, fps);
}

void serein_share_cancel(uint64_t request) {
    if (request) g_cancellable_cancel(((Share *)(uintptr_t)request)->cancel);
}
void serein_share_release(uint64_t request) {
    if (!request) return;
    serein_share_cancel(request);
    g_atomic_rc_box_release_full((Share *)(uintptr_t)request, free_share);
}

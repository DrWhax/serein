#include "CLinuxVideo.h"
#include <libportal/portal.h>
#include <unistd.h>

static GMutex bus_lock;
static GDBusConnection *camera_bus;

// Authorization and later remote requests use the same D-Bus sender.
static GDBusConnection *session_bus(void) {
    g_mutex_lock(&bus_lock);
    if (camera_bus && g_dbus_connection_is_closed(camera_bus)) g_clear_object(&camera_bus);
    if (!camera_bus) camera_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    GDBusConnection *bus = camera_bus ? g_object_ref(camera_bus) : NULL;
    g_mutex_unlock(&bus_lock);
    return bus;
}

int serein_camera_remote(void) {
    g_autoptr(GDBusConnection) bus = session_bus();
    if (!bus) return -1;
    g_autoptr(GUnixFDList) descriptors = NULL;
    g_autoptr(GVariant) reply = g_dbus_connection_call_with_unix_fd_list_sync(bus, "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Camera", "OpenPipeWireRemote",
        g_variant_new("(a{sv})", NULL), G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE, 2000, NULL, &descriptors, NULL, NULL);
    int index = -1;
    if (reply) g_variant_get(reply, "(h)", &index);
    return index >= 0 && descriptors ? g_unix_fd_list_get(descriptors, index, NULL) : -1;
}

int serein_camera_authorized(void) {
    int fd = serein_camera_remote();
    if (fd < 0) return 0;
    close(fd);
    return 1;
}

typedef struct { GMainLoop *loop; gboolean granted; } Permission;
static void permission_ready(GObject *source, GAsyncResult *result, gpointer data) {
    Permission *permission = data;
    permission->granted = xdp_portal_access_camera_finish(XDP_PORTAL(source), result, NULL);
    g_main_loop_quit(permission->loop);
}

static gboolean cancel_permission(gpointer data) {
    g_cancellable_cancel(data);
    return G_SOURCE_REMOVE;
}

int serein_camera_request(void) {
    g_autoptr(GDBusConnection) bus = session_bus();
    if (!bus) return 0;
    g_autoptr(GMainContext) context = g_main_context_new();
    g_main_context_push_thread_default(context);
    g_autoptr(GMainLoop) loop = g_main_loop_new(context, FALSE);
    g_autoptr(XdpPortal) portal = xdp_portal_new();
    g_autoptr(GCancellable) cancel = g_cancellable_new();
    g_autoptr(GSource) timeout = g_timeout_source_new_seconds(120);
    g_source_set_callback(timeout, cancel_permission, cancel, NULL);
    g_source_attach(timeout, context);
    Permission permission = { .loop = loop };
    xdp_portal_access_camera(portal, NULL, XDP_CAMERA_FLAG_NONE, cancel, permission_ready, &permission);
    g_main_loop_run(loop);
    g_source_destroy(timeout);
    g_main_context_pop_thread_default(context);
    return permission.granted;
}

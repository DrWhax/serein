#include "CLinuxDesktop.h"
#include <fcntl.h>
#include <gio/gio.h>
#include <string.h>
#include <unistd.h>

static GMutex bus_lock;
static GDBusConnection *portal_bus;

// A portal request belongs to the client connection until the desktop finishes
// handling it. Keep the connection after the initial reply containing its handle.
static GDBusConnection *session_bus(void) {
    g_mutex_lock(&bus_lock);
    if (portal_bus && g_dbus_connection_is_closed(portal_bus)) g_clear_object(&portal_bus);
    if (!portal_bus) portal_bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    GDBusConnection *bus = portal_bus ? g_object_ref(portal_bus) : NULL;
    g_mutex_unlock(&bus_lock);
    return bus;
}

static int request(const char *method, GVariant *arguments, GUnixFDList *fds) {
    g_autoptr(GVariant) params = g_variant_ref_sink(arguments);
    g_autoptr(GDBusConnection) bus = session_bus();
    if (!bus) return 0;
    g_autoptr(GVariant) reply = g_dbus_connection_call_with_unix_fd_list_sync(bus,
        "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.OpenURI",
        method, params, G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, 5000, fds, NULL, NULL, NULL);
    return reply != NULL;
}

int serein_portal_open(const uint8_t *uri, size_t size) {
    if (!size || memchr(uri, 0, size)) return 0;
    g_autofree char *copy = g_strndup((const char *)uri, size);
    return request("OpenURI", g_variant_new("(ssa{sv})", "", copy, NULL), NULL);
}

int serein_portal_reveal(const uint8_t *path, size_t size) {
    if (!size || path[0] != '/' || memchr(path, 0, size)) return 0;
    g_autofree char *copy = g_strndup((const char *)path, size);
    int fd = open(copy, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY);
    if (fd == -1) return 0;
    g_autoptr(GUnixFDList) fds = g_unix_fd_list_new();
    int index = g_unix_fd_list_append(fds, fd, NULL);
    close(fd);
    if (index == -1) return 0;
    return request("OpenDirectory", g_variant_new("(sha{sv})", "", index, NULL), fds);
}

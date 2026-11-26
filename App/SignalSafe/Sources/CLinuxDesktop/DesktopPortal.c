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

int serein_authenticate_owner(void) {
    g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, NULL);
    if (!bus) return 0;
    const char *name = g_dbus_connection_get_unique_name(bus);
    if (!name) return 0;
    GVariantBuilder identity;
    g_variant_builder_init(&identity, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&identity, "{sv}", "name", g_variant_new_string(name));
    g_autoptr(GVariant) reply = g_dbus_connection_call_sync(bus, "org.freedesktop.PolicyKit1",
        "/org/freedesktop/PolicyKit1/Authority", "org.freedesktop.PolicyKit1.Authority", "CheckAuthorization",
        g_variant_new("((sa{sv})sa{ss}us)", "system-bus-name", &identity, "org.signalsafe.SignalSafe.authenticate",
                      NULL, 1u, ""), G_VARIANT_TYPE("((bba{ss}))"), G_DBUS_CALL_FLAGS_NONE, G_MAXINT, NULL, NULL);
    if (!reply) return 0;
    g_autoptr(GVariant) result = g_variant_get_child_value(reply, 0);
    gboolean authorized;
    g_variant_get_child(result, 0, "b", &authorized);
    return authorized;
}

void serein_desktop_badge(int64_t count) {
    g_autoptr(GDBusConnection) bus = session_bus();
    if (!bus) return;
    GVariantBuilder props;
    g_variant_builder_init(&props, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&props, "{sv}", "count", g_variant_new_int64(MAX(count, 0)));
    g_variant_builder_add(&props, "{sv}", "count-visible", g_variant_new_boolean(count > 0));
    g_dbus_connection_emit_signal(bus, NULL, "/org/signalsafe/SignalSafe", "com.canonical.Unity.LauncherEntry",
        "Update", g_variant_new("(sa{sv})", "application://org.signalsafe.SignalSafe.desktop", &props), NULL);
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

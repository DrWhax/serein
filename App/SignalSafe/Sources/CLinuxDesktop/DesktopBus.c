#include "CLinuxDesktop.h"
#include <gio/gio.h>

// The bus connection is part of the inhibitor lease. Dropping the last
// reference would release the inhibition as soon as Inhibit returns.
static GMutex lock;
static GDBusConnection *connection;
static unsigned leases;

static GVariant *call(const char *method, GVariant *arguments, const GVariantType *reply) {
    return g_dbus_connection_call_sync(connection, "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
        "org.freedesktop.ScreenSaver", method, arguments, reply, G_DBUS_CALL_FLAGS_NONE, 1500, NULL, NULL);
}

uint64_t serein_display_inhibit(void) {
    g_mutex_lock(&lock);
    if (!connection) connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    GVariant *result = connection ? call("Inhibit", g_variant_new("(ss)", "Serein", "Signal call in progress"),
                                         G_VARIANT_TYPE("(u)")) : NULL;
    uint64_t handle = 0;
    if (result) {
        uint32_t cookie;
        g_variant_get(result, "(u)", &cookie);
        g_variant_unref(result);
        handle = (uint64_t)cookie + 1;
        ++leases;
    } else if (!leases) g_clear_object(&connection);
    g_mutex_unlock(&lock);
    return handle;
}

void serein_display_uninhibit(uint64_t handle) {
    g_mutex_lock(&lock);
    if (connection && leases && handle) {
        GVariant *reply = call("UnInhibit", g_variant_new("(u)", (uint32_t)(handle - 1)), G_VARIANT_TYPE("()"));
        if (reply) g_variant_unref(reply);
        if (--leases == 0) g_clear_object(&connection);
    }
    g_mutex_unlock(&lock);
}

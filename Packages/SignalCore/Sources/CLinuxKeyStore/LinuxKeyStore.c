#include "CLinuxKeyStore.h"
#include <libsecret/secret.h>
#include <errno.h>
#include <string.h>
#include <sys/random.h>

static const SecretSchema schema = {
    "org.signalsafe.DatabaseKey", SECRET_SCHEMA_NONE,
    {{"service", SECRET_SCHEMA_ATTRIBUTE_STRING}, {"account", SECRET_SCHEMA_ATTRIBUTE_STRING}, {NULL, 0}}
};
static const char lock_name[] = "org.signalsafe.DatabaseKeyStoreLock";
static GMutex local_lock;

// Cooperating Serein processes must finish the first key creation before any
// other lookup. Disconnecting from D-Bus releases the name if a process dies.
static enum SereinKeyStatus acquire(GDBusConnection *bus) {
    const gint64 deadline = g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND;
    do {
        g_autoptr(GVariant) result = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", "RequestName", g_variant_new("(su)", lock_name, 4u /* DO_NOT_QUEUE */),
            G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, NULL);
        if (!result) return SereinKeyUnavailable;
        guint32 status;
        g_variant_get(result, "(u)", &status);
        if (status == 1) return SereinKeyOK;
        if (status != 3) return SereinKeyUnavailable;
        g_usleep(10000);
    } while (g_get_monotonic_time() < deadline);
    return SereinKeyBusy;
}

static enum SereinKeyStatus perform(GHashTable *attributes, uint8_t *key, int remove_key) {
    g_autoptr(GError) error = NULL;
    g_autoptr(SecretService) service = secret_service_get_sync(SECRET_SERVICE_OPEN_SESSION, NULL, &error);
    if (!service) return SereinKeyUnavailable;
    GList *items = secret_service_search_sync(service, &schema, attributes,
        SECRET_SEARCH_ALL | SECRET_SEARCH_UNLOCK | SECRET_SEARCH_LOAD_SECRETS, NULL, &error);
    enum SereinKeyStatus status = SereinKeyUnavailable;
    if (error) goto done;
    // A locked, malformed or duplicated entry must never be replaced with a new key.
    if (items && items->next) { status = SereinKeyCorrupt; goto done; }
    if (items) {
        SecretItem *item = SECRET_ITEM(items->data);
        if (secret_item_get_locked(item)) goto done;
        if (remove_key) {
            if (secret_item_delete_sync(item, NULL, &error)) status = SereinKeyOK;
        } else {
            g_autoptr(SecretValue) value = secret_item_get_secret(item);
            if (!value) goto done;
            gsize length;
            const gchar *bytes = secret_value_get(value, &length);
            if (!bytes || length != 32) { status = SereinKeyCorrupt; goto done; }
            memcpy(key, bytes, 32);
            status = SereinKeyOK;
        }
    } else if (remove_key) {
        status = SereinKeyOK;
    } else {
        size_t filled = 0;
        while (filled < 32) {
            const ssize_t n = getrandom(key + filled, 32 - filled, 0);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) goto done;
            filled += (size_t)n;
        }
        g_autoptr(SecretValue) value = secret_value_new((const gchar *) key, 32, "application/octet-stream");
        if (secret_service_store_sync(service, &schema, attributes, SECRET_COLLECTION_DEFAULT,
                                      "Serein database key", value, NULL, &error)) status = SereinKeyOK;
    }
done:
    g_list_free_full(items, g_object_unref);
    if (status != SereinKeyOK) explicit_bzero(key, 32);
    return status;
}

enum SereinKeyStatus serein_database_key(
    const uint8_t * __counted_by(service_size) service __attribute__((noescape)), size_t service_size,
    const uint8_t * __counted_by(account_size) account __attribute__((noescape)), size_t account_size,
    uint8_t * __counted_by(key_size) key __attribute__((noescape)), size_t key_size, int remove_key) {
    if (!service || !account || !key || key_size != 32 || !service_size || service_size > 4096 ||
        !account_size || account_size > 4096 || !g_utf8_validate((const char *)service, service_size, NULL) ||
        !g_utf8_validate((const char *)account, account_size, NULL)) return SereinKeyInvalid;
    g_autoptr(GHashTable) attributes = g_hash_table_new_full(g_str_hash, g_str_equal, NULL, g_free);
    g_hash_table_insert(attributes, "service", g_strndup((const char *)service, service_size));
    g_hash_table_insert(attributes, "account", g_strndup((const char *)account, account_size));
    g_autoptr(GDBusConnection) bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!bus) return SereinKeyUnavailable;
    g_mutex_lock(&local_lock);
    enum SereinKeyStatus status = acquire(bus);
    if (status == SereinKeyOK) {
        status = perform(attributes, key, remove_key);
        g_autoptr(GVariant) released = g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", "ReleaseName", g_variant_new("(s)", lock_name),
            G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, 5000, NULL, NULL);
    }
    g_mutex_unlock(&local_lock);
    return status;
}

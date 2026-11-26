#include "CaptureInternal.h"
#include <glib.h>
#include <pipewire/pipewire.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    uint8_t *output;
    size_t capacity, used;
    int sequence;
    gboolean done, failed;
} Devices;

static void node_added(void *data, uint32_t id, uint32_t permissions, const char *type,
                       uint32_t version, const struct spa_dict *properties) {
    Devices *devices = data;
    if (strcmp(type, PW_TYPE_INTERFACE_Node) || !properties) return;
    const char *kind = spa_dict_lookup(properties, PW_KEY_MEDIA_CLASS);
    const char *name = spa_dict_lookup(properties, PW_KEY_NODE_NAME);
    if (!kind || strcmp(kind, "Video/Source") || !name || !*name) return;
    const char *label = spa_dict_lookup(properties, PW_KEY_NODE_DESCRIPTION);
    if (!label || !*label) label = spa_dict_lookup(properties, PW_KEY_NODE_NICK);
    if (!label || !*label) label = name;
    size_t name_size = strnlen(name, 4096), label_size = strnlen(label, 4096);
    size_t needed = name_size + label_size + 2;
    if (name_size == 4096 || label_size == 4096 || needed > devices->capacity - devices->used) return;
    memcpy(devices->output + devices->used, name, name_size + 1);
    memcpy(devices->output + devices->used + name_size + 1, label, label_size + 1);
    devices->used += needed;
}

static void synced(void *data, uint32_t id, int sequence) {
    Devices *devices = data;
    if (id == PW_ID_CORE && sequence == devices->sequence) devices->done = TRUE;
}

static void disconnected(void *data, uint32_t id, int sequence, int result, const char *message) {
    if (id == PW_ID_CORE) ((Devices *)data)->failed = TRUE;
}

size_t serein_camera_devices(uint8_t *output, size_t capacity) {
    if (!output || !capacity) return 0;
    int fd = serein_camera_remote();
    if (fd < 0) return 0;
    pw_init(NULL, NULL);
    struct pw_main_loop *main = pw_main_loop_new(NULL);
    if (!main) { close(fd); return 0; }
    struct pw_loop *loop = pw_main_loop_get_loop(main);
    struct pw_context *context = pw_context_new(loop, NULL, 0);
    struct pw_core *core = context ? pw_context_connect_fd(context, fd, NULL, 0) : NULL;
    if (!context) close(fd);
    struct pw_registry *registry = core ? pw_core_get_registry(core, PW_VERSION_REGISTRY, 0) : NULL;
    Devices devices = { .output = output, .capacity = capacity };
    if (registry) {
        static const struct pw_registry_events nodes = { PW_VERSION_REGISTRY_EVENTS, .global = node_added };
        static const struct pw_core_events events = { PW_VERSION_CORE_EVENTS, .done = synced, .error = disconnected };
        struct spa_hook node_listener, core_listener;
        pw_registry_add_listener(registry, &node_listener, &nodes, &devices);
        pw_core_add_listener(core, &core_listener, &events, &devices);
        devices.sequence = pw_core_sync(core, PW_ID_CORE, 0);
        gint64 deadline = g_get_monotonic_time() + G_TIME_SPAN_SECOND;
        pw_loop_enter(loop);
        while (!devices.done && !devices.failed) {
            gint64 remaining = deadline - g_get_monotonic_time();
            if (remaining <= 0 || pw_loop_iterate(loop, (int)((remaining + 999) / 1000)) < 0) break;
        }
        pw_loop_leave(loop);
        spa_hook_remove(&core_listener);
        spa_hook_remove(&node_listener);
        pw_proxy_destroy((struct pw_proxy *)registry);
    }
    if (core) pw_core_disconnect(core);
    if (context) pw_context_destroy(context);
    pw_main_loop_destroy(main);
    pw_deinit();
    return devices.done && !devices.failed ? devices.used : 0;
}

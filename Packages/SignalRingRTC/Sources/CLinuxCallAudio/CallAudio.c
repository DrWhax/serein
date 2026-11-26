#include "CLinuxCallAudio.h"
#include <alsa/asoundlib.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { rate = 48000, max_queue = 17280, max_packet = 5760 };
typedef struct Stream {
    uint64_t id;
    snd_pcm_t *device;
    int capture;
    int16_t packet[960];
    size_t filled;
    int64_t packet_start;
    struct Stream *next;
} Stream;
static Stream *streams;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t next_id;

// The capture timestamp and the echo reference use the same 48 kHz monotonic clock.
int64_t serein_audio_host_frame(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * rate + (int64_t)t.tv_nsec * rate / 1000000000;
}
static Stream *lookup(uint64_t id) {
    for (Stream *s = streams; s; s = s->next) if (s->id == id) return s;
    return NULL;
}

uint64_t serein_call_pcm_open(const uint8_t *name, size_t size, int capture) {
    if (size > 4096 || (size && (!name || memchr(name, 0, size)))) return 0;
    char *device_name = size ? strndup((const char *)name, size) : strdup("default");
    if (!device_name) return 0;
    snd_pcm_t *pcm = NULL;
    int ret = snd_pcm_open(&pcm, device_name, capture ? SND_PCM_STREAM_CAPTURE : SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK);
    free(device_name);
    if (ret < 0) return 0;
    if (snd_pcm_set_params(pcm, SND_PCM_FORMAT_S16, SND_PCM_ACCESS_RW_INTERLEAVED, 1, rate, 1,
                           capture ? 100000 : 400000) < 0) goto failed;
    if (capture && snd_pcm_start(pcm) < 0) goto failed;
    if (!capture) {
        snd_pcm_sw_params_t *sw;
        snd_pcm_sw_params_alloca(&sw);
        if (snd_pcm_sw_params_current(pcm, sw) < 0 || snd_pcm_sw_params_set_start_threshold(pcm, sw, 1) < 0 ||
            snd_pcm_sw_params(pcm, sw) < 0) goto failed;
    }
    Stream *s = calloc(1, sizeof(*s));
    if (!s) goto failed;
    s->device = pcm;
    s->capture = capture;
    pthread_mutex_lock(&lock);
    uint64_t id = s->id = ++next_id;
    s->next = streams;
    streams = s;
    pthread_mutex_unlock(&lock);
    return id;
failed:
    snd_pcm_close(pcm);
    return 0;
}

void serein_call_pcm_close(uint64_t id) {
    pthread_mutex_lock(&lock);
    Stream **link = &streams;
    while (*link && (*link)->id != id) link = &(*link)->next;
    Stream *s = *link;
    if (s) *link = s->next;
    pthread_mutex_unlock(&lock);
    if (s) { snd_pcm_drop(s->device); snd_pcm_close(s->device); free(s); }
}

static int reset(snd_pcm_t *pcm) {
    if (snd_pcm_drop(pcm) < 0 && snd_pcm_state(pcm) != SND_PCM_STATE_SETUP) return -1;
    return snd_pcm_prepare(pcm) < 0 ? -1 : 0;
}
struct SereinPlayout serein_call_pcm_play(uint64_t id, const int16_t *samples, size_t count,
                                         int64_t first_frame, int flush, int muted) {
    struct SereinPlayout result = {.status = -1};
    if (!samples || count < 120 || count > max_packet || count % 120) return result;
    pthread_mutex_lock(&lock);
    Stream *s = lookup(id);
    if (!s || s->capture || (flush && reset(s->device) < 0)) goto done;
    snd_pcm_sframes_t avail, delay;
    int rc = snd_pcm_avail_delay(s->device, &avail, &delay);
    if (rc < 0) {
        result.status = snd_pcm_recover(s->device, rc, 1) < 0 ? -1 : 0;
        goto done;
    }
    int64_t now = serein_audio_host_frame();
    if (delay < 0) delay = 0;
    if (delay > max_queue || first_frame > now + max_queue) { result.status = reset(s->device); goto done; }
    int64_t pad = first_frame > now + delay ? first_frame - now - delay : 0;
    size_t total = (size_t)pad + count;
    if ((int64_t)total > avail || total + (size_t)delay > max_queue) { result.status = reset(s->device); goto done; }
    int16_t block[max_queue];
    memset(block, 0, (muted ? total : (size_t)pad) * sizeof(*block));
    if (!muted) memcpy(block + pad, samples, count * sizeof(*block));
    snd_pcm_sframes_t written = snd_pcm_writei(s->device, block, total);
    if (written == (snd_pcm_sframes_t)total) {
        result.status = 1;
        result.first_frame = now + delay + pad;
    } else {
        result.status = reset(s->device);
    }
done:
    pthread_mutex_unlock(&lock);
    return result;
}

struct SereinCapture serein_call_pcm_read(uint64_t id, int16_t *samples, size_t count) {
    struct SereinCapture result = {.status = -1};
    if (!samples || count != 960) return result;
    pthread_mutex_lock(&lock);
    Stream *s = lookup(id);
    if (!s || !s->capture) goto done;
    snd_pcm_sframes_t avail = 0, delay = 0;
    int rc = snd_pcm_avail_delay(s->device, &avail, &delay);
    if (rc >= 0 && avail == 0) { result.status = 0; goto done; }
    if (rc >= 0) {
        if (!s->filled) s->packet_start = serein_audio_host_frame() - (delay > 0 ? delay : avail);
        rc = (int)snd_pcm_readi(s->device, s->packet + s->filled, count - s->filled);
    }
    if (rc < 0) {
        if (rc == -EAGAIN || rc == -EINTR) result.status = 0;
        else if (snd_pcm_recover(s->device, rc, 1) == 0) {
            s->filled = 0;
            result.status = snd_pcm_state(s->device) == SND_PCM_STATE_PREPARED && snd_pcm_start(s->device) < 0 ? -1 : 0;
        }
        goto done;
    }
    s->filled += (size_t)rc;
    result.status = 0;
    if (s->filled == count) {
        memcpy(samples, s->packet, sizeof(s->packet));
        result.status = 1;
        result.first_frame = s->packet_start;
        s->filled = 0;
    }
done:
    pthread_mutex_unlock(&lock);
    return result;
}

int serein_call_pcm_routes(int capture, uint8_t *output, size_t size) {
    void **hints = NULL;
    if (snd_device_name_hint(-1, "pcm", &hints) < 0) return -1;
    size_t used = 0;
    for (void **hint = hints; *hint; ++hint) {
        char *direction = snd_device_name_get_hint(*hint, "IOID");
        int matches = !direction || strcmp(direction, capture ? "Input" : "Output") == 0;
        free(direction);
        if (!matches) continue;
        char *name = snd_device_name_get_hint(*hint, "NAME");
        char *label = snd_device_name_get_hint(*hint, "DESC");
        if (name && *name) {
            const char *description = label && *label ? label : name;
            size_t a = strlen(name) + 1, b = strlen(description) + 1;
            if (a > 1048576 || b > 1048576 || used + a + b > 1048576) {
                free(name); free(label); snd_device_name_free_hint(hints); return -1;
            }
            if (used + a + b <= size) {
                memcpy(output + used, name, a);
                memcpy(output + used + a, description, b);
            }
            used += a + b;
        }
        free(name); free(label);
    }
    snd_device_name_free_hint(hints);
    return (int)used;
}

#include "CLinuxMicrophone.h"
#include <alsa/asoundlib.h>
#include <errno.h>
#include <pthread.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static snd_pcm_t *microphone;
static uint64_t generation;

uint64_t serein_microphone_open(void) {
    pthread_mutex_lock(&lock);
    uint64_t result = 0;
    if (!microphone) {
        snd_pcm_t *pcm = NULL;
        if (snd_pcm_open(&pcm, "default", SND_PCM_STREAM_CAPTURE, SND_PCM_NONBLOCK) >= 0) {
            if (snd_pcm_set_params(pcm, SND_PCM_FORMAT_FLOAT, SND_PCM_ACCESS_RW_INTERLEAVED,
                                   1, 48000, 1, 100000) >= 0) {
                microphone = pcm;
                if (++generation == 0) ++generation;
                result = generation;
            } else {
                snd_pcm_close(pcm);
            }
        }
    }
    pthread_mutex_unlock(&lock);
    return result;
}

int serein_microphone_read(uint64_t handle, float *output, size_t count) {
    if (count == 0 || count > 4096) return -1;
    pthread_mutex_lock(&lock);
    int frames = -1;
    if (microphone && handle == generation) {
        frames = (int)snd_pcm_readi(microphone, output, count);
        if (frames == -EAGAIN || frames == -EINTR) frames = 0;
        else if (frames == -EPIPE && snd_pcm_prepare(microphone) >= 0) frames = 0;
    }
    pthread_mutex_unlock(&lock);
    return frames;
}

void serein_microphone_close(uint64_t handle) {
    pthread_mutex_lock(&lock);
    if (microphone && handle == generation) {
        snd_pcm_drop(microphone);
        snd_pcm_close(microphone);
        microphone = NULL;
    }
    pthread_mutex_unlock(&lock);
}

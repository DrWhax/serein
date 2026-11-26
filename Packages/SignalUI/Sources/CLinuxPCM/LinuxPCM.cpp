#include "CLinuxPCM.h"
#include <alsa/asoundlib.h>
#include <soundtouch/SoundTouch.h>
#include <algorithm>
#include <cmath>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace {
// All entry points are synchronous and nonblocking. The client polls while
// audio is playing, allowing pause and seek to discard a partially written block.
struct Stream {
    snd_pcm_t *device = nullptr;
    soundtouch::SoundTouch stretch;
    int channels;
    double tempo;
    std::vector<float> buffer;
    std::vector<float> silence;
    size_t consumed = 0;
    int64_t written = 0;
    bool finished = false;

    Stream(int channels, double tempo) : channels(channels), tempo(tempo) {}
    ~Stream() {
        if (device) {
            snd_pcm_drop(device);
            snd_pcm_close(device);
        }
    }

    // 1 needs more source data, 0 has queued output, 2 has played the last frame.
    int pump(bool muted) {
        if (consumed == buffer.size()) {
            consumed = 0;
            buffer.resize(1024 * channels);
            const auto frames = stretch.receiveSamples(buffer.data(), 1024);
            buffer.resize(frames * channels);
            if (buffer.empty()) {
                if (!finished) return 1;
                const int status = snd_pcm_drain(device);
                return status == -EAGAIN ? 0 : status < 0 ? status : 2;
            }
        }
        const size_t remaining = buffer.size() - consumed;
        if (muted) silence.resize(remaining, 0.0f);
        const auto n = snd_pcm_writei(device, muted ? silence.data() : buffer.data() + consumed, remaining / channels);
        if (n == -EAGAIN || n == -EINTR) return 0;
        if (n < 0) return snd_pcm_recover(device, static_cast<int>(n), 1);
        written += n;
        consumed += static_cast<size_t>(n) * channels;
        return n > 0 ? 3 : 0;
    }
};

std::mutex guard;
std::unordered_map<uint64_t, std::unique_ptr<Stream>> streams;
uint64_t nextID = 1;
}

uint64_t serein_pcm_open(int sample_rate, int channels, double tempo) {
    if (sample_rate < 8000 || sample_rate > 192000 || (channels != 1 && channels != 2) ||
        !std::isfinite(tempo) || tempo < 1.0 / 32 || tempo > 32) return 0;
    try {
        auto stream = std::make_unique<Stream>(channels, tempo);
        stream->stretch.setSampleRate(sample_rate);
        stream->stretch.setChannels(channels);
        stream->stretch.setTempo(tempo);
        if (snd_pcm_open(&stream->device, "default", SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK) < 0 ||
            snd_pcm_set_params(stream->device, SND_PCM_FORMAT_FLOAT_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
                               channels, sample_rate, 1, 60000) < 0) return 0;
        std::lock_guard<std::mutex> lock(guard);
        const auto id = nextID++;
        streams.emplace(id, std::move(stream));
        return id;
    } catch (...) { return 0; }
}

void serein_pcm_close(uint64_t id) {
    std::lock_guard<std::mutex> lock(guard);
    streams.erase(id);
}

int serein_pcm_append(uint64_t id, const float * __counted_by(count) samples __attribute__((noescape)), size_t count) {
    std::lock_guard<std::mutex> lock(guard);
    auto i = streams.find(id);
    if (i == streams.end() || !samples || count == 0 || count > 8192) return -EINVAL;
    auto &s = *i->second;
    if (s.finished || count % s.channels || s.stretch.numSamples() != 0 || s.consumed != s.buffer.size()) return -EINVAL;
    try {
        // Unity tempo must preserve the source samples exactly and start immediately.
        if (s.tempo == 1.0) {
            s.consumed = 0;
            s.buffer.assign(samples, samples + count);
        } else {
            s.stretch.putSamples(samples, count / s.channels);
        }
        return 0;
    } catch (...) { return -EIO; }
}

int serein_pcm_finish(uint64_t id) {
    std::lock_guard<std::mutex> lock(guard);
    auto i = streams.find(id);
    if (i == streams.end()) return -EINVAL;
    auto &s = *i->second;
    try {
        if (!s.finished && s.tempo != 1.0) s.stretch.flush();
        s.finished = true;
        return 0;
    } catch (...) { return -EIO; }
}

int serein_pcm_pump(uint64_t id, int muted) {
    std::lock_guard<std::mutex> lock(guard);
    auto i = streams.find(id);
    if (i == streams.end()) return -EINVAL;
    try { return i->second->pump(muted != 0); }
    catch (...) { return -EIO; }
}

int64_t serein_pcm_played(uint64_t id) {
    std::lock_guard<std::mutex> lock(guard);
    auto i = streams.find(id);
    if (i == streams.end()) return 0;
    auto &s = *i->second;
    snd_pcm_sframes_t delay = 0;
    if (snd_pcm_delay(s.device, &delay) < 0) return 0;
    return static_cast<int64_t>(std::max<int64_t>(0, s.written - std::max<snd_pcm_sframes_t>(0, delay)) * s.tempo);
}

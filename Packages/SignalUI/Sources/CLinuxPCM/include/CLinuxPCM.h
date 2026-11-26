#pragma once
#include <stdint.h>
#include <stddef.h>
#include <ptrcheck.h>

#ifdef __cplusplus
extern "C" {
#endif
uint64_t serein_pcm_open(int sample_rate, int channels, double tempo);
void serein_pcm_close(uint64_t stream);
// Copy a bounded, interleaved block from the caller before returning.
int serein_pcm_append(uint64_t stream, const float * __counted_by(count) samples __attribute__((noescape)), size_t count);
int serein_pcm_finish(uint64_t stream);
int serein_pcm_pump(uint64_t stream, int muted);
int64_t serein_pcm_played(uint64_t stream);
#ifdef __cplusplus
}
#endif

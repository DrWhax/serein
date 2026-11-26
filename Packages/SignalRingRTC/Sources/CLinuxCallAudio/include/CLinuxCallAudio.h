#pragma once
#include <ptrcheck.h>
#include <stddef.h>
#include <stdint.h>

int64_t serein_audio_host_frame(void);
uint64_t serein_call_pcm_open(const uint8_t * __counted_by(size) name __attribute__((noescape)), size_t size, int capture);
void serein_call_pcm_close(uint64_t id);
struct SereinPlayout { int status; int64_t first_frame; };
// status 1 means the samples were queued, 0 requests a timeline reset, -1 is a device failure.
struct SereinPlayout serein_call_pcm_play(uint64_t id, const int16_t * __counted_by(count) samples __attribute__((noescape)),
                                         size_t count, int64_t first_frame, int flush, int muted);

struct SereinCapture { int status; int64_t first_frame; };
// Reads one 20 ms call packet; 0 means that a complete packet is not ready.
struct SereinCapture serein_call_pcm_read(uint64_t id, int16_t * __counted_by(count) samples __attribute__((noescape)), size_t count);
// Writes pairs of zero-terminated device IDs and labels, or returns the required size.
int serein_call_pcm_routes(int capture, uint8_t * __counted_by(size) output __attribute__((noescape)), size_t size);

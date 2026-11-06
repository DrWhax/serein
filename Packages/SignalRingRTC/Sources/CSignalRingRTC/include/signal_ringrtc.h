// SignalSafe's C ABI over ringrtc (Packages/SignalRingRTC/rust). Every buffer is a
// (pointer, length) pair annotated so that Swift imports it as Span / MutableSpan: the
// Swift side calls this without `unsafe`. See rust/src/lib.rs.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <ptrcheck.h>
#include <lifetimebound.h>

typedef struct { int32_t status; uint64_t length; } SrrResult;
typedef struct { int32_t status; uint32_t width; uint32_t height; } SrrFrame;

uint64_t srr_endpoint_create(const uint8_t * __counted_by(field_trials_len) __noescape field_trials, size_t field_trials_len);
void srr_endpoint_destroy(uint64_t endpoint);
SrrResult srr_command(uint64_t endpoint, const uint8_t * __counted_by(command_len) __noescape command, size_t command_len,
                      uint8_t * __counted_by(out_cap) __noescape out, size_t out_cap);
SrrResult srr_take_pending(uint64_t endpoint, uint8_t * __counted_by(out_cap) __noescape out, size_t out_cap);
SrrResult srr_wait_events(uint64_t endpoint, uint32_t timeout_ms, uint8_t * __counted_by(out_cap) __noescape out, size_t out_cap);
int32_t srr_send_video_frame(uint64_t endpoint, uint32_t width, uint32_t height, int32_t pixel_format,
                             const uint8_t * __counted_by(data_len) __noescape data, size_t data_len);
SrrFrame srr_receive_video_frame(uint64_t endpoint, uint32_t demux_id, uint32_t max_width, uint32_t max_height,
                                 uint8_t * __counted_by(rgba_cap) __noescape rgba, size_t rgba_cap);

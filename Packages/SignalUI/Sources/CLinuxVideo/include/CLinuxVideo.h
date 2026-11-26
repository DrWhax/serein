#pragma once
#include <stddef.h>
#include <stdint.h>
#include <ptrcheck.h>

int serein_camera_authorized(void);
int serein_camera_request(void);
// Pairs of NUL-terminated UTF-8 node names and display names from the authorized remote.
size_t serein_camera_devices(uint8_t * __counted_by(capacity) output __attribute__((noescape)), size_t capacity);

typedef struct { uint64_t handle; int error; } SereinCameraOpen;
typedef struct { int width, height, status; } SereinCaptureFrame;
SereinCameraOpen serein_camera_open(const uint8_t * __counted_by(length) device __attribute__((noescape)), size_t length,
                                    int max_width, int max_height, int fps);
SereinCaptureFrame serein_capture_read(uint64_t handle, uint8_t * __counted_by(capacity) bytes __attribute__((noescape)), size_t capacity);
void serein_capture_close(uint64_t handle);

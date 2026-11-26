#pragma once
#include <stddef.h>
#include <stdint.h>
#include <ptrcheck.h>

// The recorder service owns one capture stream. Handles distinguish successive
// recordings so late work from a previous session cannot stop or read a new one.
uint64_t serein_microphone_open(void);
int serein_microphone_read(uint64_t handle, float * __counted_by(count) output __attribute__((noescape)), size_t count);
void serein_microphone_close(uint64_t handle);

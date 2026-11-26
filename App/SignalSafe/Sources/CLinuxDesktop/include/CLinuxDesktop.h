#pragma once
#include <stdint.h>
#include <ptrcheck.h>
#include <stddef.h>

int serein_desktop_confine(void);
int serein_desktop_is_confined(void);
void serein_desktop_badge(int64_t count);
int serein_authenticate_owner(void);
int serein_open_dropped_document(const uint8_t * __counted_by(size) path __attribute__((noescape)), size_t size, int64_t limit);
uint64_t serein_network_signature(void);
int64_t serein_suspended_milliseconds(void);
uint64_t serein_display_inhibit(void);
void serein_display_uninhibit(uint64_t handle);

int serein_portal_open(const uint8_t * __counted_by(size) uri __attribute__((noescape)), size_t size);
int serein_portal_reveal(const uint8_t * __counted_by(size) path __attribute__((noescape)), size_t size);

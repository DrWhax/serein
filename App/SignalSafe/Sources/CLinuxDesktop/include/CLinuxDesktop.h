#pragma once
#include <stdint.h>

int serein_desktop_confine(void);
int serein_desktop_is_confined(void);
uint64_t serein_display_inhibit(void);
void serein_display_uninhibit(uint64_t handle);

#include <ptrcheck.h>
#include <stddef.h>
int serein_portal_open(const uint8_t * __counted_by(size) uri __attribute__((noescape)), size_t size);
int serein_portal_reveal(const uint8_t * __counted_by(size) path __attribute__((noescape)), size_t size);

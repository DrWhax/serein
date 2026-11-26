#pragma once
#include <stdint.h>

int serein_desktop_confine(void);
int serein_desktop_is_confined(void);
uint64_t serein_display_inhibit(void);
void serein_display_uninhibit(uint64_t handle);

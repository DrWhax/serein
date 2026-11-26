#pragma once
#include "CLinuxVideo.h"

int serein_camera_remote(void);
// Consumes the portal file descriptor, including on failure.
SereinCameraOpen serein_capture_from_remote(int fd, const char *node, int max_width, int max_height, int fps);

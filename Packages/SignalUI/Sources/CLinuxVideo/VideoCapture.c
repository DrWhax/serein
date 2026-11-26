#include "CaptureInternal.h"
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    GstElement *pipeline;
    GstAppSink *sink;
    int fd, width, height;
} Capture;

void serein_capture_close(uint64_t handle) {
    Capture *capture = (Capture *)(uintptr_t)handle;
    if (!capture) return;
    if (capture->pipeline) gst_element_set_state(capture->pipeline, GST_STATE_NULL);
    if (capture->sink) gst_object_unref(capture->sink);
    if (capture->pipeline) gst_object_unref(capture->pipeline);
    close(capture->fd);
    g_free(capture);
}

SereinCameraOpen serein_capture_from_remote(int fd, const char *node, uint32_t node_id, int max_width, int max_height, int fps) {
    if (fd < 0) return (SereinCameraOpen){ .error = 1 };
    // The desktop cannot launch a plugin scanner after confinement.
    gst_registry_fork_set_enabled(FALSE);
    if (max_width < 2 || max_width > 8192 || max_height < 2 || max_height > 8192 ||
        fps < 1 || fps > 120 || !gst_init_check(NULL, NULL, NULL)) {
        close(fd);
        return (SereinCameraOpen){ .error = 3 };
    }
    Capture *capture = g_new0(Capture, 1);
    capture->fd = fd;
    capture->width = max_width;
    capture->height = max_height;
    uint64_t handle = (uintptr_t)capture;
    // Accept raw camera pixels only. The PipeWire source duplicates the portal fd when it connects.
    g_autoptr(GError) error = NULL;
    g_autoptr(GstElement) source = NULL, rate = NULL;
    capture->pipeline = gst_parse_launch("pipewiresrc name=source ! video/x-raw,width=(int)[2,8192],height=(int)[2,8192] ! "
        "videoconvert ! videoscale ! videorate name=rate drop-only=true ! appsink name=sink max-buffers=1 drop=true sync=false", &error);
    if (error || !capture->pipeline) goto failed;
    source = gst_bin_get_by_name(GST_BIN(capture->pipeline), "source");
    rate = gst_bin_get_by_name(GST_BIN(capture->pipeline), "rate");
    capture->sink = GST_APP_SINK(gst_bin_get_by_name(GST_BIN(capture->pipeline), "sink"));
    if (!source || !rate || !capture->sink) goto failed;
    g_object_set(source, "fd", fd, NULL);
    if (node_id == UINT32_MAX) {
        g_object_set(source, "target-object", node, NULL);
    } else {
        // ScreenCast identifies the selected node by its PipeWire registry id.
        // target-object accepts serials and names. The path property accepts registry ids.
        g_autofree char *id = g_strdup_printf("%u", node_id);
        g_object_set(source, "path", id, "keepalive-time", 1000, NULL);
    }
    g_object_set(rate, "max-rate", fps, NULL);
    GstCaps *caps = gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING, "NV12", NULL);
    GstStructure *output = gst_caps_get_structure(caps, 0);
    if (max_width == 2) gst_structure_set(output, "width", G_TYPE_INT, 2, NULL);
    else gst_structure_set(output, "width", GST_TYPE_INT_RANGE, 2, max_width, NULL);
    if (max_height == 2) gst_structure_set(output, "height", G_TYPE_INT, 2, NULL);
    else gst_structure_set(output, "height", GST_TYPE_INT_RANGE, 2, max_height, NULL);
    gst_app_sink_set_caps(capture->sink, caps);
    gst_caps_unref(caps);
    GstStateChangeReturn state = gst_element_set_state(capture->pipeline, GST_STATE_PLAYING);
    if (state == GST_STATE_CHANGE_FAILURE) goto failed;
    state = gst_element_get_state(capture->pipeline, NULL, NULL, 3 * GST_SECOND);
    if (state == GST_STATE_CHANGE_FAILURE || state == GST_STATE_CHANGE_ASYNC) goto failed;
    return (SereinCameraOpen){ .handle = handle };
failed:
    serein_capture_close(handle);
    return (SereinCameraOpen){ .error = 3 };
}

SereinCameraOpen serein_camera_open(const uint8_t *device, size_t length, int max_width, int max_height, int fps) {
    if (length > 4095 || (length && (!device || memchr(device, 0, length)))) return (SereinCameraOpen){ .error = 2 };
    g_autofree char *name = length ? g_strndup((const char *)device, length) : NULL;
    return serein_capture_from_remote(serein_camera_remote(), name, UINT32_MAX, max_width, max_height, fps);
}

SereinCaptureFrame serein_capture_read(uint64_t handle, uint8_t *bytes, size_t capacity) {
    Capture *capture = (Capture *)(uintptr_t)handle;
    if (!capture || !bytes) return (SereinCaptureFrame){ .status = -1 };
    g_autoptr(GstSample) sample = gst_app_sink_try_pull_sample(capture->sink, 0);
    if (!sample) {
        g_autoptr(GstBus) bus = gst_element_get_bus(capture->pipeline);
        g_autoptr(GstMessage) ended = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR | GST_MESSAGE_EOS);
        return (SereinCaptureFrame){ .status = ended || gst_app_sink_is_eos(capture->sink) ? -1 : 0 };
    }
    GstVideoInfo info;
    if (!gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) || GST_VIDEO_INFO_FORMAT(&info) != GST_VIDEO_FORMAT_NV12 ||
        info.width < 2 || info.height < 2 || info.width > capture->width || info.height > capture->height) {
        return (SereinCaptureFrame){ .status = -1 };
    }
    int width = info.width & ~1, height = info.height & ~1;
    if ((size_t)width * height * 3 / 2 > capacity) return (SereinCaptureFrame){ .status = -1 };
    GstVideoFrame frame;
    if (!gst_video_frame_map(&frame, &info, gst_sample_get_buffer(sample), GST_MAP_READ)) return (SereinCaptureFrame){ .status = -1 };
    size_t offset = 0;
    for (unsigned plane = 0; plane < 2; ++plane) {
        const uint8_t *data = GST_VIDEO_FRAME_PLANE_DATA(&frame, plane);
        int stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, plane), rows = plane ? height / 2 : height;
        if (!data || stride < width) { gst_video_frame_unmap(&frame); return (SereinCaptureFrame){ .status = -1 }; }
        size_t needed = (size_t)(rows - 1) * stride + width;
        gboolean mapped = FALSE;
        for (unsigned i = 0; i < GST_VIDEO_MAX_PLANES; ++i) {
            uintptr_t start = (uintptr_t)frame.map[i].data, plane_start = (uintptr_t)data;
            if (start && plane_start >= start && needed <= frame.map[i].size &&
                plane_start - start <= frame.map[i].size - needed) { mapped = TRUE; break; }
        }
        if (!mapped) { gst_video_frame_unmap(&frame); return (SereinCaptureFrame){ .status = -1 }; }
        for (int row = 0; row < rows; ++row) {
            memcpy(bytes + offset, data + (size_t)row * stride, width);
            offset += width;
        }
    }
    gst_video_frame_unmap(&frame);
    return (SereinCaptureFrame){ width, height, 1 };
}

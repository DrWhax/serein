// PixelImage: draws an RGBA8 (straight alpha) pixel buffer passed as shader data, filtering as
// Chromium paints an <img>: downscaling samples mip level floor(log2(scale)) bilinearly
// (Skia's medium quality, which cc uses for downscales), upscaling uses the Mitchell cubic
// (Skia's high quality), and an exact pixel-aligned 1:1 mapping copies pixels. The result is
// premultiplied for SwiftUI.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static half4 texel(device const uchar *d, int count, int w, int h, int x, int y) {
    x = clamp(x, 0, w - 1);
    y = clamp(y, 0, h - 1);
    int i = (y * w + x) * 4;
    if (i < 0 || i + 3 >= count) return half4(0);
    half a = half(d[i + 3]) / 255.0h;
    return half4(half3(d[i], d[i + 1], d[i + 2]) / 255.0h * a, a);
}

/// Texel (x, y) of mip level `level` (each level halves the previous, rounding down, at
/// least 1): the area average of the source pixels it covers (the 2×2 box for even sizes).
static float4 mipTexel(device const uchar *d, int count, int w, int h, int level, int x, int y) {
    if (level == 0) return float4(texel(d, count, w, h, x, y));
    int lw = max(1, w >> level), lh = max(1, h >> level);
    x = clamp(x, 0, lw - 1);
    y = clamp(y, 0, lh - 1);
    float kx = float(w) / float(lw), ky = float(h) / float(lh);
    float x0 = float(x) * kx, x1 = x0 + kx, y0 = float(y) * ky, y1 = y0 + ky;
    float4 sum = 0;
    float total = 0;
    int ix1 = min(int(ceil(x1)), int(floor(x0)) + 64), iy1 = min(int(ceil(y1)), int(floor(y0)) + 64);
    for (int sy = int(floor(y0)); sy < iy1; sy++) {
        float cy = min(y1, float(sy + 1)) - max(y0, float(sy));
        for (int sx = int(floor(x0)); sx < ix1; sx++) {
            float c = (min(x1, float(sx + 1)) - max(x0, float(sx))) * cy;
            sum += float4(texel(d, count, w, h, sx, sy)) * c;
            total += c;
        }
    }
    return total > 0 ? sum / total : float4(0);
}

/// Mitchell–Netravali cubic (B = C = 1/3), Skia's high-quality upsampling filter.
static float mitchell(float x) {
    x = abs(x);
    const float B = 1.0 / 3.0, C = 1.0 / 3.0;
    if (x < 1) return ((12 - 9 * B - 6 * C) * x * x * x + (-18 + 12 * B + 6 * C) * x * x + (6 - 2 * B)) / 6;
    if (x < 2) return ((-B - 6 * C) * x * x * x + (6 * B + 30 * C) * x * x + (-12 * B - 48 * C) * x + (8 * B + 24 * C)) / 6;
    return 0;
}

[[ stitchable ]] half4 pixelImage(float2 position, device const uchar *data, int count,
                                  float sw, float sh, float ox, float oy, float dw, float dh, float scale) {
    int w = int(sw), h = int(sh);
    float2 p = position - float2(ox, oy);
    if (p.x < 0 || p.y < 0 || p.x > dw || p.y > dh || w <= 0 || h <= 0) return half4(0);
    float kx = sw / dw, ky = sh / dh;          // source pixels per point
    float fx = kx / scale, fy = ky / scale;    // footprint of one device pixel, in source pixels
    // One source pixel per device pixel, on the grid: drawn as is (Skia skips filtering for
    // an integer translation; the Mitchell cubic would soften it).
    float2 s0 = p * float2(kx, ky) - 0.5;
    if (abs(fx - 1.0) < 1e-4 && abs(fy - 1.0) < 1e-4 && abs(s0.x - round(s0.x)) < 1e-3 && abs(s0.y - round(s0.y)) < 1e-3) {
        return texel(data, count, w, h, int(round(s0.x)), int(round(s0.y)));
    }
    if (fx <= 1.0 && fy <= 1.0) {
        float2 s = p * float2(kx, ky) - 0.5;
        int bx = int(floor(s.x)), by = int(floor(s.y));
        float tx = s.x - floor(s.x), ty = s.y - floor(s.y);
        float4 sum = 0;
        for (int j = -1; j <= 2; j++) {
            float wy = mitchell(float(j) - ty);
            for (int i = -1; i <= 2; i++) {
                sum += float4(texel(data, count, w, h, bx + i, by + j)) * (mitchell(float(i) - tx) * wy);
            }
        }
        return half4(clamp(sum, 0.0, 1.0));
    }
    // Downscale: the level is chosen by the lesser reduction (fx, fy are source pixels per
    // device pixel), then sampled bilinearly with its texel centres.
    int level = clamp(int(floor(log2(max(min(fx, fy), 1.0)))), 0, 6);
    int lw = max(1, w >> level), lh = max(1, h >> level);
    float2 s = p * scale * float2(float(lw) / (dw * scale), float(lh) / (dh * scale)) - 0.5;
    int bx = int(floor(s.x)), by = int(floor(s.y));
    float tx = s.x - floor(s.x), ty = s.y - floor(s.y);
    float4 sum = mix(mix(mipTexel(data, count, w, h, level, bx, by), mipTexel(data, count, w, h, level, bx + 1, by), tx),
                     mix(mipTexel(data, count, w, h, level, bx, by + 1), mipTexel(data, count, w, h, level, bx + 1, by + 1), tx), ty);
    return half4(clamp(sum, 0.0, 1.0));
}

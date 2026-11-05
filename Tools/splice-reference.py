#!/usr/bin/env python3
"""Cut a horizontal band out of a Storybook reference capture (png + json).

Used where a story mixes in rows for features SignalSafe leaves out (payments, donations):
the band of those rows is removed and the rest is kept, so the remaining rows can still be
compared pixel for pixel.

  Tools/splice-reference.py <in-base> <out-base> <top> <bottom> [<left> <right>]

<in-base> / <out-base> are paths without ".png" / ".json"; <top> and <bottom> are CSS pixels
in page coordinates (as in the capture's .dom.json rects), the band [top, bottom) is removed.
With <left> <right>, only that column is cut (a sidebar next to other content): the column
below the band moves up, the image keeps its size, and the freed strip at the bottom of the
column is filled with the column's last row.
"""
import json, sys
from PIL import Image

src, dst, top, bottom = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
info = json.load(open(src + ".json"))
scale, (ox, oy) = info["scale"], info["offset"]
y0, y1 = round((top - oy) * scale), round((bottom - oy) * scale)
img = Image.open(src + ".png")
w, h = img.size
if len(sys.argv) > 6:
    x0, x1 = round((float(sys.argv[5]) - ox) * scale), round((float(sys.argv[6]) - ox) * scale)
    out = img.copy()
    out.paste(img.crop((x0, y1, x1, h)), (x0, y0))
    last = img.crop((x0, h - 1, x1, h))
    for y in range(h - (y1 - y0), h):
        out.paste(last, (x0, y))
    out.save(dst + ".png")
    info["id"] = dst.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    json.dump(info, open(dst + ".json", "w"), indent=1)
    print(dst, out.size, "column", x0, x1)
    sys.exit(0)
out = Image.new(img.mode, (w, h - (y1 - y0)))
out.paste(img.crop((0, 0, w, y0)), (0, 0))
out.paste(img.crop((0, y1, w, h)), (0, y0))
out.save(dst + ".png")
info["id"] = dst.rsplit("/", 1)[-1].rsplit(".", 1)[0]
info["height"] = round(info["height"] - (bottom - top))
json.dump(info, open(dst + ".json", "w"), indent=1)
print(dst, out.size, info["height"])

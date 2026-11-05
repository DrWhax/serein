#!/usr/bin/env python3 -I
"""Generate reference decodes for SignalCodecs conformance tests.

Runs the *reference* implementations once on a developer machine and stores their
results under Packages/SignalCodecs/Tests/DifferentialTests/Resources, so the Swift
tests never need these tools:

  bmp   BMP Suite 2.8 (public domain images) + its reference PNGs, mapping from bmpsuite.html
  ico   Pillow (largest entry, RGBA PNG)
  xbm   Pillow, inverted to X11 semantics (1 = black foreground), PNG
  jpeg  libjpeg-turbo djpeg -dct int (default fancy upsampling): MD5 of the RGB output
  webp  dwebp -pam: MD5 of the RGBA output (also libwebp-test-data's own md5 list)
  blurhash  woltapp/blurhash C reference encoder/decoder

Usage: Tools/gen-codec-references.py <corpora-dir> <step>...
"""
import json, os, re, shutil, subprocess, sys, hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "Packages/SignalCodecs/Tests/DifferentialTests/Resources")

def step_bmp(corpora):
    src = os.path.join(corpora, "bmpsuite/bmpsuite-2.8")
    dst = os.path.join(RES, "BMPSuite")
    shutil.rmtree(dst, ignore_errors=True)
    for d in ("g", "q", "b", "html"):
        shutil.copytree(os.path.join(src, d), os.path.join(dst, d),
                        ignore=shutil.ignore_patterns("*.html", "*.css") if d == "html" else None)
    html = open(os.path.join(src, "html/bmpsuite.html")).read()
    mapping = {}
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", html, re.S):
        imgs = re.findall(r'src="([^"]+)"', row)
        if imgs and imgs[-1].startswith("../") and imgs[-1].endswith(".bmp"):
            mapping[imgs[-1][3:]] = imgs[:-1]
    json.dump(mapping, open(os.path.join(dst, "references.json"), "w"), indent=1, sort_keys=True)
    open(os.path.join(dst, "SOURCE.md"), "w").write(
        "BMP Suite 2.8 by Jason Summers, https://entropymine.com/jason/bmpsuite/.\n"
        "The image files are in the public domain (see the suite's readme). references.json maps\n"
        "each BMP to its acceptable reference renderings in html/, taken from bmpsuite.html.\n")
    print("bmp:", len(mapping), "files")

def step_pillow(corpora):
    from PIL import Image, ImageOps
    out = os.path.join(RES, "References/Pillow")
    os.makedirs(out, exist_ok=True)
    pil = os.path.join(RES, "Pillow")
    n = 0
    for name in sorted(os.listdir(pil)):
        path = os.path.join(pil, name)
        if name.endswith((".ico", ".cur")):
            try:
                im = Image.open(path)
                im.load()
            except Exception as e:
                print("  pillow rejects", name, e); continue
            im.convert("RGBA").save(os.path.join(out, name + ".png"))
            n += 1
        elif name.endswith(".xbm"):
            im = Image.open(path).convert("L")
            ImageOps.invert(im).convert("RGBA").save(os.path.join(out, name + ".png"))  # X11: 1 = black
            n += 1
    print("pillow references:", n)

def step_jpeg(corpora):
    out = os.path.join(RES, "References")
    refs = {}
    jpeg_dir = os.path.join(RES, "JPEG")
    for name in sorted(os.listdir(jpeg_dir)):
        if not name.lower().endswith((".jpg", ".jpeg")):
            continue
        # JSIMD_FORCENONE: libjpeg-turbo's C code paths, its reference semantics. The NEON IDCT
        # differs from C only when corrupt data drives coefficients out of range.
        p = subprocess.run(["djpeg", "-dct", "int", "-ppm", os.path.join(jpeg_dir, name)], capture_output=True,
                           env=dict(os.environ, JSIMD_FORCENONE="1"))
        if p.returncode not in (0, 2) or not p.stdout.startswith((b"P6", b"P5")):  # 2 = warnings
            refs[name] = None
            continue
        # Strip the PNM header: magic, width, height, maxval, then one whitespace byte.
        m = re.match(rb"(P[56])\s+(\d+)\s+(\d+)\s+(\d+)\s", p.stdout)
        body = p.stdout[m.end():]
        w, h = int(m.group(2)), int(m.group(3))
        if m.group(1) == b"P5":  # grayscale -> RGB, as our decoder outputs RGBA
            body = bytes(v for g in body for v in (g, g, g))
        refs[name] = {"width": w, "height": h, "rgbMD5": hashlib.md5(body).hexdigest()}
    json.dump(refs, open(os.path.join(out, "djpeg.json"), "w"), indent=1, sort_keys=True)
    print("jpeg:", len(refs), "files,", sum(1 for v in refs.values() if v is None), "rejected by djpeg")

def step_webp(corpora):
    out = os.path.join(RES, "References")
    refs = {}
    d = os.path.join(RES, "WebP")
    for name in sorted(os.listdir(d)):
        if not name.endswith(".webp"):
            continue
        tmp = os.path.join(out, "_tmp.pam")
        p = subprocess.run(["dwebp", os.path.join(d, name), "-pam", "-o", tmp], capture_output=True)
        if p.returncode != 0:
            refs[name] = None
            continue
        data = open(tmp, "rb").read()
        os.remove(tmp)
        hdr_end = data.index(b"ENDHDR\n") + 7
        hdr = data[:hdr_end].decode()
        w = int(re.search(r"WIDTH (\d+)", hdr).group(1)); h = int(re.search(r"HEIGHT (\d+)", hdr).group(1))
        refs[name] = {"width": w, "height": h, "rgbaMD5": hashlib.md5(data[hdr_end:]).hexdigest()}
    json.dump(refs, open(os.path.join(out, "dwebp.json"), "w"), indent=1, sort_keys=True)
    print("webp:", len(refs), "files,", sum(1 for v in refs.values() if v is None), "rejected by dwebp")

BLURHASH_HARNESS = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "encode.h"
#include "decode.h"
int main(int argc, char **argv) {
    if (argc == 6 && !strcmp(argv[1], "encode")) {
        int w = atoi(argv[2]), h = atoi(argv[3]), xc = atoi(argv[4]), yc = atoi(argv[5]);
        unsigned char *rgb = malloc((size_t)w * h * 3);
        if (fread(rgb, 1, (size_t)w * h * 3, stdin) != (size_t)w * h * 3) return 2;
        const char *hash = blurHashForPixels(xc, yc, w, h, rgb, (size_t)w * 3);
        if (!hash) return 3;
        puts(hash);
        return 0;
    }
    if (argc == 6 && !strcmp(argv[1], "decode")) {
        int w = atoi(argv[3]), h = atoi(argv[4]), punch = atoi(argv[5]);
        unsigned char *px = decode(argv[2], w, h, punch, 4);
        if (!px) return 4;
        fwrite(px, 1, (size_t)w * h * 4, stdout);
        return 0;
    }
    return 1;
}
"""

def step_blurhash(corpora):
    from PIL import Image
    src = os.path.join(corpora, "blurhash/C")
    build = os.path.join(corpora, "blurhash-build")
    os.makedirs(build, exist_ok=True)
    open(os.path.join(build, "harness.c"), "w").write(BLURHASH_HARNESS)
    exe = os.path.join(build, "bh")
    # No FMA contraction: plain IEEE float/double semantics, which the Swift port mirrors.
    subprocess.run(["clang", "-O2", "-ffp-contract=off", "-I", src, "-o", exe,
                    os.path.join(build, "harness.c"), os.path.join(src, "encode.c"), os.path.join(src, "decode.c"), "-lm"], check=True)
    images = [("PngSuite/" + n) for n in sorted(os.listdir(os.path.join(RES, "PngSuite")))
              if n.endswith(".png") and not n.startswith(("x", "g")) and "16" not in n[4:8]]
    images += ["Pillow/" + n for n in ("hopper.gif", "chi.gif", "iss634.gif")]
    refs = {"encode": [], "decode": []}
    for rel in images:
        im = Image.open(os.path.join(RES, rel))
        im.seek(0)
        im = im.convert("RGB")
        w, h = im.size
        for xc, yc in ((4, 3), (1, 1), (9, 9), (5, 2)):
            p = subprocess.run([exe, "encode", str(w), str(h), str(xc), str(yc)], input=im.tobytes(), capture_output=True, check=True)
            refs["encode"].append({"image": rel, "x": xc, "y": yc, "hash": p.stdout.decode().strip()})
    hashes = sorted({e["hash"] for e in refs["encode"]}) + ["LEHV6nWB2yk8pyo0adR*.7kCMdnj", "L6PZfSi_.AyE_3t7t7R**0o#DgR4"]
    for hsh in hashes:
        for w, h, punch in ((32, 32, 1), (20, 13, 3), (7, 9, 1)):
            p = subprocess.run([exe, "decode", hsh, str(w), str(h), str(punch)], capture_output=True, check=True)
            refs["decode"].append({"hash": hsh, "width": w, "height": h, "punch": punch, "rgbaMD5": hashlib.md5(p.stdout).hexdigest()})
    json.dump(refs, open(os.path.join(RES, "References/blurhash.json"), "w"), indent=1)
    print("blurhash:", len(refs["encode"]), "encodes,", len(refs["decode"]), "decodes")

def step_jpegcorpus(corpora):
    from PIL import Image
    dst = os.path.join(RES, "JPEG")
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(dst)
    ljt = os.path.join(corpora, "ljt/testimages")
    for n in ("testorig.jpg", "testimgint.jpg", "testimgari.jpg", "monkey12.jpg"):
        shutil.copy(os.path.join(ljt, n), os.path.join(dst, "ljt_" + n))
    shutil.copy(os.path.join(ljt, "LICENSE.txt"), os.path.join(dst, "LICENSE-libjpeg-turbo-testimages.txt"))
    exif = os.path.join(corpora, "exif")
    for n in sorted(os.listdir(exif)):
        if n.endswith(".jpg"):
            shutil.copy(os.path.join(exif, n), os.path.join(dst, "exif_" + n))
    shutil.copy(os.path.join(exif, "LICENSE"), os.path.join(dst, "LICENSE-exif-orientation-examples.txt"))
    pil = os.path.join(corpora, "pillow/Tests/images")
    for n in sorted(os.listdir(pil)):
        if n.lower().endswith((".jpg", ".jpeg")) and n != "xmp_test.jpg":
            shutil.copy(os.path.join(pil, n), os.path.join(dst, "pillow_" + n))
    # Variants generated by libjpeg-turbo's cjpeg from public sources.
    src = os.path.join(ljt, "testorig.ppm")
    odd = os.path.join(corpora, "odd.ppm")
    Image.open(os.path.join(pil, "flower.jpg")).convert("RGB").crop((3, 5, 100, 66)).save(odd)   # 97x61
    variants = {
        "s1x1": ["-sample", "1x1"], "s2x1": ["-sample", "2x1"], "s1x2": ["-sample", "1x2"], "s2x2": ["-sample", "2x2"],
        "s4x1": ["-sample", "4x1"], "s1x4": ["-sample", "1x4"], "s4x2": ["-sample", "4x2"], "s3x2": ["-sample", "3x2"],
        "gray": ["-grayscale"], "prog": ["-progressive"], "prog1x1": ["-progressive", "-sample", "1x1"],
        "restart1": ["-restart", "1"], "restart7B": ["-restart", "7B"], "progrestart": ["-progressive", "-restart", "3B"],
        "opt": ["-optimize"], "q100": ["-quality", "100"], "q5": ["-quality", "5"], "rgb": ["-rgb"], "arith": ["-arithmetic"],
        "baselineq1": ["-quality", "1", "-baseline"],
    }
    n = 0
    for base, path in (("testorig", src), ("odd97x61", odd)):
        for name, args in variants.items():
            out = os.path.join(dst, f"cjpeg_{base}_{name}.jpg")
            subprocess.run(["cjpeg"] + args + ["-outfile", out, path], check=True)
            n += 1
    os.remove(odd)
    open(os.path.join(dst, "SOURCE.md"), "w").write(
        "ljt_*: libjpeg-turbo testimages (IJG/BSD licence, LICENSE-libjpeg-turbo-testimages.txt).\n"
        "exif_*: https://github.com/recurser/exif-orientation-examples (MIT, LICENSE-exif-orientation-examples.txt).\n"
        "pillow_*: Pillow Tests/images (MIT-CMU).\n"
        "cjpeg_*: generated by libjpeg-turbo 3.2.1 cjpeg from ljt testorig.ppm and a 97x61 crop of pillow flower.jpg\n"
        "(see Tools/gen-codec-references.py step jpegcorpus).\n")
    print("jpeg corpus:", len(os.listdir(dst)), "files,", n, "generated")

def step_cjpeg(corpora):
    from PIL import Image
    dst = os.path.join(RES, "JPEGEncode")
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(dst)
    inputs = {}
    inputs["testorig"] = Image.open(os.path.join(corpora, "ljt/testimages/testorig.ppm")).convert("RGB")
    inputs["flower97x61"] = Image.open(os.path.join(corpora, "pillow/Tests/images/flower.jpg")).convert("RGB").crop((3, 5, 100, 66))
    inputs["hopper"] = Image.open(os.path.join(corpora, "pillow/Tests/images/hopper.gif")).convert("RGB")
    for n in ("basn2c08", "s01n3p01", "s02n3p01", "s03n3p01", "s05n3p02", "s07n3p02", "s09n3p02", "s32n3p04",
              "s33n3p04", "s34n3p04", "s35n3p04", "s38n3p04", "s39n3p04", "s40n3p04"):
        inputs[n] = Image.open(os.path.join(RES, "PngSuite", n + ".png")).convert("RGB")
    grey = {"basn0g08": Image.open(os.path.join(RES, "PngSuite/basn0g08.png")).convert("L"),
            "testorig-grey": inputs["testorig"].convert("L")}
    refs = []
    tmp = os.path.join(corpora, "cjpeg-in.pnm")
    for name, im in list(inputs.items()) + list(grey.items()):
        im.convert("RGBA").save(os.path.join(dst, name + ".png"))
        im.save(tmp)
        modes = [("yuv444", ["-sample", "1x1"]), ("yuv420", ["-sample", "2x2"])] if im.mode == "RGB" else [("grayscale", [])]
        for q in (1, 10, 50, 75, 90, 100):
            for mode, args in modes:
                p = subprocess.run(["cjpeg", "-baseline", "-quality", str(q), "-dct", "int"] + args + [tmp], capture_output=True,
                                   env=dict(os.environ, JSIMD_FORCENONE="1"), check=True)
                refs.append({"image": name, "quality": q, "sampling": mode, "md5": hashlib.md5(p.stdout).hexdigest(), "size": len(p.stdout)})
    os.remove(tmp)
    json.dump(refs, open(os.path.join(RES, "References/cjpeg.json"), "w"), indent=1)
    open(os.path.join(dst, "SOURCE.md"), "w").write(
        "Encoder inputs derived from public corpora (libjpeg-turbo testorig, Pillow flower/hopper, PngSuite),\n"
        "stored as lossless PNG. References/cjpeg.json holds MD5s of libjpeg-turbo 3.2.1 cjpeg output.\n")
    print("cjpeg:", len(refs), "references")

def step_webpcorpus(corpora):
    dst = os.path.join(RES, "WebP")
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(dst)
    td = os.path.join(corpora, "webp")
    for n in sorted(os.listdir(td)):
        if n.endswith(".webp"):
            shutil.copy(os.path.join(td, n), os.path.join(dst, n))
    shutil.copy(os.path.join(td, "lossless_vec_list.txt"), dst)
    for n in ("hopper.webp", "hopper_lossless.webp", "flower.webp", "flower2.webp", "transparent.webp", "iss634.webp",
              "anim_frame1.webp", "anim_frame2.webp"):
        shutil.copy(os.path.join(corpora, "pillow/Tests/images", n), os.path.join(dst, "pillow_" + n))
    gifs = [os.path.join(RES, "GIFTestSuite", g) for g in ("animation.gif", "dispose-none.gif", "dispose-keep.gif",
            "dispose-restore-background.gif", "dispose-restore-previous.gif", "animation-multi-image.gif", "transparent.gif",
            "loop-once.gif", "high-color.gif")]
    gifs += [os.path.join(RES, "Pillow", g) for g in ("dispose_bgnd.gif", "dispose_prev.gif", "dispose_none.gif",
             "transparent_dispose.gif", "iss634.gif", "chi.gif")]
    n = 0
    for g in gifs:
        base = os.path.splitext(os.path.basename(g))[0]
        for mode, args in (("lossless", []), ("lossy", ["-lossy", "-q", "60"]), ("mixed", ["-mixed"])):
            out = os.path.join(dst, f"gif2webp_{base}_{mode}.webp")
            if subprocess.run(["gif2webp", "-quiet"] + args + [g, "-o", out]).returncode == 0:
                n += 1
    open(os.path.join(dst, "SOURCE.md"), "w").write(
        "Plain names: libwebp-test-data (https://chromium.googlesource.com/webm/libwebp-test-data, BSD, WebM project).\n"
        "pillow_*: Pillow Tests/images (MIT-CMU).\n"
        "gif2webp_*: produced by libwebp 1.6.0 gif2webp from the GIF corpus in ../GIFTestSuite and ../Pillow.\n")
    print("webp corpus:", len([f for f in os.listdir(dst) if f.endswith(".webp")]), "files,", n, "generated")

def step_webpanim(corpora):
    from PIL import Image
    refs = {}
    d = os.path.join(RES, "WebP")
    for name in sorted(os.listdir(d)):
        if not name.endswith(".webp"):
            continue
        im = Image.open(os.path.join(d, name))
        if not getattr(im, "is_animated", False):
            continue
        frames = []
        for i in range(im.n_frames):
            im.seek(i)
            im.load()
            # Native mode: Pillow reads canvases of files without the VP8X alpha flag as RGBX,
            # so only RGB is meaningful there (alpha would be forced to 255 by convert()).
            frames.append({"md5": hashlib.md5(im.tobytes()).hexdigest(), "duration": im.info.get("duration")})
        refs[name] = {"width": im.size[0], "height": im.size[1], "loop": im.info.get("loop"), "mode": im.mode, "frames": frames}
    json.dump(refs, open(os.path.join(RES, "References/webp-anim.json"), "w"), indent=1, sort_keys=True)
    print("webp anim:", len(refs), "animated files")

STEPS = {"webpcorpus": step_webpcorpus, "webpanim": step_webpanim, "cjpeg": step_cjpeg, "jpegcorpus": step_jpegcorpus, "blurhash": step_blurhash, "bmp": step_bmp, "pillow": step_pillow, "jpeg": step_jpeg, "webp": step_webp}

if __name__ == "__main__":
    corpora = sys.argv[1]
    for s in sys.argv[2:]:
        STEPS[s](corpora)

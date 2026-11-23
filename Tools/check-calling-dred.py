#!/usr/bin/env python3
"""Exercise Swift DRED against the Opus encoder and decoder from RingRTC's pinned libwebrtc.a."""
import argparse
import array
import base64
import contextlib
import ctypes as c
import hashlib
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "vendor/ringrtc/out/release/obj/libwebrtc.a"
WEIGHTS_DIGEST = "sdfpdb/u3wiTfBr2s0gx1LJX6jii4tquyax/UBThTGWTEXyOCSKjYmYV+9tKQZcO+Q1B1ReoGSW3VbvzeMGKaQ=="
SAMPLES = 960
PCM = c.c_int16 * SAMPLES


def checked(result):
    if result < 0:
        raise RuntimeError(f"RingRTC's Opus library returned error {result}")
    return result


class NativeOpus:
    def __init__(self, work, weights):
        # Link only the codec objects pulled in by these public functions. The library
        # is opened by the QA process and never goes into Serein or its calling service.
        if not ARCHIVE.is_file():
            raise SystemExit(f"Missing pinned RingRTC build at {ARCHIVE}")
        lib = work / "ringrtc-opus.dylib"
        ptr, integer, sample, byte = c.c_void_p, c.c_int32, c.POINTER(c.c_int16), c.POINTER(c.c_ubyte)
        error = c.POINTER(integer)
        apis = {
            "opus_encoder_create": (ptr, [integer, integer, integer, error]),
            "opus_encoder_ctl": (integer, [ptr, integer]),
            "opus_encoder_destroy": (None, [ptr]),
            "opus_encode": (integer, [ptr, sample, integer, byte, integer]),
            "opus_decoder_create": (ptr, [integer, integer, error]),
            "opus_decoder_ctl": (integer, [ptr, integer]),
            "opus_decoder_destroy": (None, [ptr]),
            "opus_decode": (integer, [ptr, byte, integer, sample, integer, integer]),
            "opus_dred_decoder_create": (ptr, [error]),
            "opus_dred_decoder_ctl": (integer, [ptr, integer]),
            "opus_dred_decoder_destroy": (None, [ptr]),
            "opus_dred_alloc": (ptr, [error]),
            "opus_dred_free": (None, [ptr]),
            "opus_dred_parse": (integer, [ptr, ptr, byte, integer, integer, integer, error, integer]),
            "opus_decoder_dred_decode": (integer, [ptr, ptr, integer, sample, integer]),
        }
        # Chrome builds its static Opus symbols with hidden visibility. Forward the
        # public API through a test-only shim with exported names.
        names = {ptr: "void *", integer: "int", sample: "short *", byte: "unsigned char *", error: "int *", None: "void"}
        source = ["#include <stdarg.h>"]
        for name, (result, args) in apis.items():
            fields = ", ".join(names[t] + " a" + str(i) for i, t in enumerate(args))
            values = ", ".join("a" + str(i) for i in range(len(args)))
            if name.endswith("_ctl"):
                source += [f"extern int {name}({fields}, ...);", f"int test_{name}({fields}, ...) {{",
                           "va_list ap; va_start(ap,a1); int result;",
                           f"if (a1 == 4052) {{ void *p = va_arg(ap,void*); int n = va_arg(ap,int); result = {name}(a0,a1,p,n); }}",
                           f"else {{ int v = va_arg(ap,int); result = {name}(a0,a1,v); }}",
                           "va_end(ap); return result; }"]
            else:
                statement = "" if result is None else "return "
                source += [f"extern {names[result]} {name}({fields});",
                           f"{names[result]} test_{name}({fields}) {{ {statement}{name}({values}); }}"]
        shim = work / "ringrtc-opus.c"
        shim.write_text("\n".join(source))
        subprocess.run(["xcrun", "clang", "-dynamiclib", "-Wall", "-Werror", shim, ARCHIVE, "-o", lib], check=True)
        self.library = c.CDLL(str(lib))
        for name, (result, args) in apis.items():
            function = getattr(self.library, "test_" + name)
            function.restype, function.argtypes = result, args
            setattr(self.library, name, function)
        self.model = c.create_string_buffer(weights)
        self.size = len(weights)

    def load_model(self, name, handle):
        control = getattr(self.library, "opus_" + name + "_ctl")
        checked(control(handle, 4052, c.cast(self.model, c.c_void_p), c.c_int(self.size)))

    @contextlib.contextmanager
    def handle(self, name):
        create = "dred_alloc" if name == "dred" else name + "_create"
        destroy = "dred_free" if name == "dred" else name + "_destroy"
        args = {"encoder": [48000, 1, 2048], "decoder": [48000, 1]}.get(name, [])
        error = c.c_int()
        handle = getattr(self.library, "opus_" + create)(*args, c.byref(error))
        checked(error.value)
        if not handle:
            raise RuntimeError("Unable to create native " + name)
        try:
            if name != "dred":
                self.load_model(name, handle)
            yield handle
        finally:
            getattr(self.library, "opus_" + destroy)(handle)

    def encode(self, pcm):
        packets = []
        with self.handle("encoder") as encoder:
            # 48 kb/s VOIP, ten percent loss, up to 400 ms of DRED history.
            for code, value in [(4002, 48000), (4014, 10), (4050, 40)]:
                checked(self.library.opus_encoder_ctl(encoder, code, c.c_int(value)))
            output = (c.c_ubyte * 1275)()
            for start in range(0, len(pcm), SAMPLES*2):
                frame = PCM.from_buffer_copy(pcm[start:start + SAMPLES*2])
                length = checked(self.library.opus_encode(encoder, frame, SAMPLES, output, len(output)))
                packets.append(bytes(output[:length]))
        return packets

    def loss_reference(self, packets, pcm, work):
        # Select a sustained voiced 60 ms span using only source PCM and DRED
        # coverage. Warm the reference decoder exactly through the preceding packet.
        samples = array.array("h", pcm)
        best, best_level = None, 0
        end = c.c_int()
        with self.handle("dred_decoder") as reader, self.handle("dred") as dred:
            for start in range(10, len(packets)-3):
                data = packets[start+3]
                buf = (c.c_ubyte * len(data)).from_buffer_copy(data)
                span = checked(self.library.opus_dred_parse(reader, dred, buf, len(buf), 3*SAMPLES, 48000, c.byref(end), 1))
                if span < 3*SAMPLES or end.value > SAMPLES: continue
                level = min(sum(x*x for x in samples[i*SAMPLES:(i+1)*SAMPLES]) for i in range(start,start+3))
                if level > best_level:
                    best, best_level = start, level
            if best is None:
                raise ValueError("Native stream contains no voiced 60 ms DRED coverage")
            data = packets[best+3]
            buf = (c.c_ubyte * len(data)).from_buffer_copy(data)
            checked(self.library.opus_dred_parse(reader, dred, buf, len(buf), 3*SAMPLES, 48000, c.byref(end), 0))
            reference = []
            with self.handle("decoder") as receiver:
                for packet in packets[:best]:
                    raw = (c.c_ubyte * len(packet)).from_buffer_copy(packet)
                    checked(self.library.opus_decode(receiver, raw, len(raw), PCM(), SAMPLES, 0))
                for missing in (3, 2, 1):
                    out = PCM()
                    if checked(self.library.opus_decoder_dred_decode(receiver, dred, missing*SAMPLES, out, SAMPLES)) != SAMPLES:
                        raise ValueError("Native reference produced an incomplete DRED frame")
                    reference.extend(out)
            (work / "loss-index.txt").write_text(str(best) + "\n")
            (work / "native-recovery.pcm").write_bytes(array.array("h", reference).tobytes())

    def verify(self, packets, pcm, work):
        audio, plc, reference = [], [], []
        total_dred = 0
        with self.handle("decoder") as receiver, self.handle("decoder") as baseline, \
             self.handle("dred_decoder") as reader, self.handle("dred") as dred:
            blocks = [PCM.from_buffer_copy(pcm[i:i+2*SAMPLES]) for i in range(0, len(pcm), 2*SAMPLES)]
            for index, data in enumerate(packets):
                buf = (c.c_ubyte * len(data)).from_buffer_copy(data)
                end = c.c_int()
                duration = checked(self.library.opus_dred_parse(reader, dred, buf, len(buf), 3*SAMPLES,
                                                               48000, c.byref(end), 0))
                if duration: total_dred += 1
                # Drop three consecutive packets per 12. Decoders are warmed by identical
                # primary audio before each gap. Only its following packet may repair the loss.
                pos = index % 12
                if index >= 12 and 5 <= pos <= 7: continue
                if index >= 12 and pos == 8:
                    for missing in (3, 2, 1):
                        offset = missing*SAMPLES
                        dst, fallback = PCM(), PCM()
                        got = checked(self.library.opus_decode(baseline, None, 0, fallback, SAMPLES, 0))
                        if duration >= offset and offset >= end.value:
                            n = checked(self.library.opus_decoder_dred_decode(receiver, dred, offset, dst, SAMPLES))
                            audio.extend(dst)
                            plc.extend(fallback)
                            reference.extend(blocks[index-missing])
                        else:
                            n = checked(self.library.opus_decode(receiver, None, 0, dst, SAMPLES, 0))
                        if got != SAMPLES or n != SAMPLES:
                            raise ValueError("Incomplete native recovery frame")
                for decoder in (receiver, baseline):
                    if checked(self.library.opus_decode(decoder, buf, len(buf), PCM(), SAMPLES, 0)) != SAMPLES:
                        raise ValueError("The Swift stream did not keep its 20 ms packet clock")
        if len(audio) < 12*SAMPLES:
            raise ValueError(f"Only {len(audio)//SAMPLES} missing frames were covered by native DRED")
        energy = lambda x: math.sqrt(sum(a*a for a in x)/len(x))
        difference = energy([a-b for a,b in zip(audio, plc)])
        # Per-frame speech energy retains timing across FARGAN's free-running excitation.
        def envelope(samples):
            return [math.log1p(energy(samples[i:i+SAMPLES])) for i in range(0, len(samples), SAMPLES)]
        a, b = envelope(audio), envelope(reference)
        a = [v-sum(a)/len(a) for v in a]
        b = [v-sum(b)/len(b) for v in b]
        denom = math.sqrt(sum(v*v for v in a)*sum(v*v for v in b))
        similarity = sum(x*y for x,y in zip(a,b))/denom if denom else 0
        print(f"Native parsed {total_dred}/{len(packets)} DRED packets, recovered {len(audio)//SAMPLES} dropped "
              f"frames, RMS {energy(audio):.1f}, difference from PLC {difference:.1f}, "
              f"speech-envelope correlation {similarity:.3f}", flush=True)
        if energy(audio) < 100 or difference < 25 or similarity < 0.35:
            raise ValueError("Native DRED recovery failed the speech signal checks")
        with wave.open(str(work / "native-recovered.wav"), "wb") as wav:
            wav.setparams((1, 2, 48000, 0, "NONE", "not compressed"))
            wav.writeframes(array.array("h", audio).tobytes())


def read_frames(path):
    frames, index = [], 0
    contents = path.read_bytes()
    while index < len(contents):
        if index + 2 > len(contents):
            raise ValueError("Truncated packet length")
        length = struct.unpack_from(">H", contents, index)[0]
        index += 2
        if not 1 <= length <= 65507 or index + length > len(contents):
            raise ValueError("Invalid packet length")
        frames.append(contents[index:index+length])
        index += length
    return frames


def run(work, args):
    if not args.weights:
        raise SystemExit("Set SEREIN_DRED_WEIGHTS or use --weights with the locally cached Signal DRED model.")
    weights = args.weights.read_bytes()
    if base64.b64encode(hashlib.sha512(weights).digest()).decode() != WEIGHTS_DIGEST:
        raise ValueError("The supplied model does not match Serein's pinned Signal SHA-512")
    work.mkdir(parents=True, exist_ok=True)
    native = NativeOpus(work, weights)
    pcm_path = work / "input.pcm"
    if not pcm_path.exists():
        subprocess.run(["say", "-r", "162", "-o", work / "phrase.aiff",
                        "The blue boat crossed the quiet lake. Seven bright birds flew home before dark. "
                        "Then four boats left the dock."], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@48000", "-c", "1",
                        work / "phrase.aiff", work / "phrase.wav"], check=True)
        with wave.open(str(work / "phrase.wav")) as wav:
            if (wav.getframerate(), wav.getsampwidth(), wav.getnchannels()) != (48000, 2, 1):
                raise ValueError("Expected mono 48 kHz 16-bit PCM")
            raw = wav.readframes(wav.getnframes())
        pcm_path.write_bytes(raw + bytes(-len(raw) % (SAMPLES*2)))
    pcm = pcm_path.read_bytes()
    if len(pcm) % (SAMPLES*2) or not 48_000*2 <= len(pcm) <= 48_000*60:
        raise ValueError("Expected 1–30 seconds of 20 ms mono PCM frames")
    packets = native.encode(pcm)
    (work / "native.frames").write_bytes(b"".join(struct.pack(">H", len(p))+p for p in packets))
    native.loss_reference(packets, pcm, work)
    print(f"Prepared {len(packets)} native 20 ms packets in {work}", flush=True)
    if args.generate_only: return
    swift_path = work / "swift.frames"
    swift_path.unlink(missing_ok=True)
    env = dict(os.environ, SEREIN_DRED_FIXTURE=str(work), SEREIN_DRED_WEIGHTS=str(args.weights.resolve()))
    subprocess.run(["swift", "test", "--package-path", ROOT / "Packages/SignalRingRTC", "-c", "release",
                    "--enable-testable-imports", "--filter", "DREDInteropTests"], env=env, check=True)
    output = read_frames(swift_path)
    if len(output) != len(packets):
        raise ValueError(f"Swift wrote {len(output)} packets for {len(packets)} input frames")
    native.verify(output, pcm, work)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", type=Path, default=os.getenv("SEREIN_DRED_WEIGHTS"))
    parser.add_argument("--fixture", type=Path, help="retain generated audio and packet files in this directory")
    parser.add_argument("--generate-only", action="store_true", help="prepare input.pcm and native.frames for debugging")
    args = parser.parse_args()
    if args.fixture:
        run(args.fixture.resolve(), args)
    else:
        with tempfile.TemporaryDirectory(prefix="serein-dred-") as directory:
            run(Path(directory), args)

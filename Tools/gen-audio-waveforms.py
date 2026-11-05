#!/usr/bin/env python3
# Test fixture: the waveforms Signal Desktop computes for its audio fixtures
# (VoiceNotesPlaybackContext doComputeWaveform + util/waveformBuilder.std.ts), for SignalUI's
# MessageAudio snapshot tests until the Swift MP3 decoder lands (plan Phase 5). Decodes with
# ffmpeg (a dev tool, test data only) at 44.1 kHz, as the capture's AudioContext does (its bars match to 0.02px).
#   python3 Tools/gen-audio-waveforms.py
import json, math, os, struct, subprocess

ROOT = os.path.join(os.path.dirname(__file__), '..')
FIXTURES = os.path.join(ROOT, 'Signal-Desktop', 'fixtures')
OUT = os.path.join(ROOT, 'Packages', 'SignalUI', 'Tests', 'SignalUITests', 'Fixtures', 'audio-waveforms.json')
FILES = ['incompetech-com-Agnus-Dei-X.mp3', 'long-audio.mp3']
MAX_AUDIO_DURATION = 15 * 60
MAX_WAVEFORM_SIZE, HALF = 100, 50
RATE = os.environ.get('RATE', '44100')

def to_peak(mean_square):
    val = max(0.0, 10 * math.log10(mean_square) + 60) / 60 if mean_square > 0 else 0.0
    return round(val * 255)

def waveform(samples):
    wf = [0.0] * MAX_WAVEFORM_SIZE
    length = shift = 0
    for s in samples:
        index = length >> shift
        if index >= MAX_WAVEFORM_SIZE:
            for i in range(HALF):
                wf[i] = (wf[2 * i] + wf[2 * i + 1]) / 2
            for i in range(HALF, MAX_WAVEFORM_SIZE):
                wf[i] = 0.0
            shift += 1
            index = HALF
        wf[index] += s * s / (1 << shift)
        length += 1
    n = length >> shift
    last = length % (1 << shift)
    if last:
        wf[n] = wf[n] * (1 << shift) / last
        n += 1
    return [to_peak(wf[i]) for i in range(n)]

out = {}
for name in FILES:
    path = os.path.join(FIXTURES, name)
    duration = float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', path]))
    if duration > MAX_AUDIO_DURATION:
        out['/fixtures/' + name] = {'waveform': [], 'duration': duration}
        continue
    pcm = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', path, '-f', 'f32le', '-ar', RATE, '-'])
    samples = struct.unpack('<%df' % (len(pcm) // 4), pcm)   # interleaved channels, as upstream pushes them
    out['/fixtures/' + name] = {'waveform': waveform(samples), 'duration': duration}
    print(name, duration, len(out['/fixtures/' + name]['waveform']))
json.dump(out, open(OUT, 'w'), indent=1)

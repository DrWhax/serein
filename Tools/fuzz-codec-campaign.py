#!/usr/bin/env python3
"""Bounded deterministic codec campaign. Use an AddressSanitizer-built codec-fuzz.

Logs retain the exact seed/iteration before each HEVC/AV1 input. Replay with:
  codec-fuzz TARGET CORPUS --run SEED ITERATION
The RSS monitor is a host safety backstop, not an allocator limit.
"""
import argparse
import json
import math
import os
from pathlib import Path
import resource
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('target', choices=['hevc', 'av1', 'av1video'])
    parser.add_argument('corpus', type=Path)
    parser.add_argument('--iterations', type=int, default=20000)
    parser.add_argument('--seed', type=int, default=20261115)
    parser.add_argument('--seconds', type=float, default=600)
    parser.add_argument('--rss-mib', type=int, default=2048)
    parser.add_argument('--log', type=Path, required=True)
    args = parser.parse_args()
    if (not 0 < args.iterations < (1 << 63) or not math.isfinite(args.seconds)
            or args.seconds <= 0 or args.rss_mib <= 0 or not 0 <= args.seed < (1 << 64)):
        parser.error('use positive finite limits, an Int64 iteration count and a UInt64 seed')
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    env = dict(os.environ)
    env.setdefault('ASAN_OPTIONS', 'abort_on_error=1:detect_leaks=0')
    command = [str(args.binary.resolve()), args.target, str(args.corpus), str(args.iterations), str(args.seed)]
    started = time.monotonic()
    peak = 0
    reason = 'completed'
    with args.log.open('w') as output:
        child = subprocess.Popen(command, stdout=output, stderr=output, env=env)
        try:
            while child.poll() is None:
                # ps on macOS reports RSS in KiB. Sampling cannot catch transient peaks.
                metric = subprocess.run(['ps', '-o', 'rss=', '-p', str(child.pid)],
                                        capture_output=True, text=True)
                if metric.returncode and child.poll() is None:
                    raise RuntimeError('cannot monitor child RSS: ' + metric.stderr)
                peak = max(peak, int(metric.stdout.strip() or 0))
                if peak > args.rss_mib * 1024:
                    reason = 'memory limit'
                    break
                if time.monotonic() - started > args.seconds:
                    reason = 'time limit'
                    break
                time.sleep(0.1)
        finally:
            if child.poll() is None:
                child.kill()
            child.wait()
    if child.returncode != 0 and reason == 'completed':
        reason = 'process failed'
    summary = dict(command=command, exit=child.returncode, reason=reason,
                   sampled_peak_kib=peak, seconds=round(time.monotonic() - started, 2))
    args.log.with_suffix(args.log.suffix + '.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary))
    return 0 if child.returncode == 0 and reason == 'completed' else 1


if __name__ == '__main__':
    raise SystemExit(main())

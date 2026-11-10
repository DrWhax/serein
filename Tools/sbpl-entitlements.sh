#!/bin/sh
# Prints the entitlements plist for a process confined by a Seatbelt profile file: App Sandbox,
# the entitlements its `;!` lines name, and every rule of the file (one per line; blank lines
# and `;` comments skipped) in com.apple.security.temporary-exception.sbpl, XML-escaped.
#   ;! <key>               a boolean entitlement set to true (e.g. com.apple.security.network.client)
#   ;!+ <key> <value>      a string appended to an array entitlement
# Extra plist lines (e.g. the ad-hoc library-validation exception) can be given as $2.
set -eu
python3 -I - "$1" "${2:-}" <<'PY'
import sys
from xml.sax.saxutils import escape
sb, extra = sys.argv[1], sys.argv[2]
flags, arrays, rules = [], {}, []
for raw in open(sb, encoding="utf-8"):
    line = raw.strip()
    if line.startswith(";!+"):
        _, key, value = line.split(None, 2)
        arrays.setdefault(key, []).append(value)
    elif line.startswith(";!"):
        flags.append(line[2:].strip())
    elif line and not line.startswith(";"):
        rules.append(line)
out = ['<?xml version="1.0" encoding="UTF-8"?>',
       '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
       '<plist version="1.0">', '<dict>', '  <key>com.apple.security.app-sandbox</key><true/>']
for f in flags:
    out.append(f"  <key>{escape(f)}</key><true/>")
for k, vs in arrays.items():
    out.append(f"  <key>{escape(k)}</key>")
    out.append("  <array>" + "".join(f"<string>{escape(v)}</string>" for v in vs) + "</array>")
out.append("  <key>com.apple.security.temporary-exception.sbpl</key>")
out.append("  <array>")
out += [f"    <string>{escape(r)}</string>" for r in rules]
out.append("  </array>")
if extra:
    out.append(extra)
out += ["</dict>", "</plist>"]
print("\n".join(out))
PY

#!/bin/sh
# Prints the entitlements plist for a service confined by a Seatbelt profile file: App Sandbox
# plus every rule of the .sb file (one per line; blank lines and `;` comments skipped) in
# com.apple.security.temporary-exception.sbpl, XML-escaped.
set -eu
sb="$1"
cat <<HEAD
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.temporary-exception.sbpl</key>
  <array>
HEAD
grep -vE '^[[:space:]]*(;|$)' "$sb" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/^/    <string>/' -e 's/$/<\/string>/'
cat <<TAIL
  </array>
</dict>
</plist>
TAIL

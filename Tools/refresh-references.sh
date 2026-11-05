#!/bin/sh
# Replaces SignalUI's reference captures with fresh ones from .cache/storybook-refs (taken by
# `Tools/capture-storybook.mjs --all <ids>`), so every reference comes from the same capture
# environment, then re-cuts the stories whose out-of-scope rows are spliced out
# (Tools/splice-reference.py: the payment rows of the TimelineItem / Timeline stories).
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
refs="$root/Packages/SignalUI/Tests/SignalUITests/References"
cache="$root/.cache/storybook-refs"
n=0
for f in "$refs"/*.png; do
  base=$(basename "$f" .png)
  case "$base" in *-without-payments.*) continue;; esac
  if [ -f "$cache/$base.png" ] && [ -f "$cache/$base.json" ]; then
    cp "$cache/$base.png" "$cache/$base.json" "$refs/"
    n=$((n + 1))
  fi
done
echo "refreshed $n captures"
# Re-splice: payment rows are the timeline items id-15…id-19 (Timeline) / rows 30–33 (TimelineItem).
for t in light dark; do
  python3 "$root/Tools/splice-reference.py" "$cache/components-conversation-timelineitem--notification.$t" \
    "$refs/components-conversation-timelineitem--notification-without-payments.$t" 596 772 >/dev/null
  for s in oldest-and-newest without-newest-message last-seen target-index-to-top with-active-message-request \
           without-newest-message-active-message-request without-oldest-message; do
    set -- $(python3 -c "
import json
d=json.load(open('$cache/components-conversation-timeline--$s.$t.dom.json'))[0]
rows=[c for c in d['children'][0]['children'][-1]['children'][0]['children'] if c['cls']=='']
print(rows[15]['rect'][1], rows[19]['rect'][1]+rows[19]['rect'][3])")
    python3 "$root/Tools/splice-reference.py" "$cache/components-conversation-timeline--$s.$t" \
      "$refs/components-conversation-timeline--$s-without-payments.$t" "$1" "$2" >/dev/null
  done
done
echo "re-spliced the payment stories"

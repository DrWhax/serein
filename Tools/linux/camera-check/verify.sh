#!/bin/sh
# Needs a session bus, PipeWire, WirePlumber, GStreamer test tools and python3-gi.
# Pass the CameraProbe executable built for Linux.
set -eu
probe=$(realpath "${1:?pass the CameraProbe executable}")
test_dir=$(cd "$(dirname "$0")" && pwd)
runtime_dir=$(mktemp -d)
trap 'rm -rf "$runtime_dir"' EXIT
export XDG_RUNTIME_DIR="$runtime_dir"

dbus-run-session -- sh -eu -c '
    pipewire > "$XDG_RUNTIME_DIR/server.log" 2>&1 & server=$!
    wireplumber > "$XDG_RUNTIME_DIR/manager.log" 2>&1 & manager=$!
    camera=""
    cleanup() {
        if [ -n "$camera" ]; then kill "$camera" 2>/dev/null || :; fi
        kill "$manager" "$server" 2>/dev/null || :
        wait || :
    }
    trap cleanup EXIT
    i=0
    while [ ! -S "$XDG_RUNTIME_DIR/pipewire-0" ]; do
        i=$((i + 1))
        [ "$i" -lt 80 ] || { cat "$XDG_RUNTIME_DIR/server.log"; exit 1; }
        sleep .05
    done
    gst-launch-1.0 -q videotestsrc is-live=true pattern=red ! video/x-raw,format=RGB,width=64,height=48,framerate=10/1 ! \
        pipewiresink mode=provide stream-properties="props,media.class=Video/Source,node.name=serein-test-camera,node.description=SereinTestCamera" \
        > "$XDG_RUNTIME_DIR/camera.log" 2>&1 & camera=$!
    i=0
    until pw-cli ls Node | grep -q serein-test-camera; do
        i=$((i + 1))
        [ "$i" -lt 80 ] || { cat "$XDG_RUNTIME_DIR/camera.log"; exit 1; }
        sleep .05
    done
    /usr/bin/python3 "$1/portal.py" "$2"
' sh "$test_dir" "$probe"

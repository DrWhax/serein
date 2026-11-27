#!/bin/sh
# Compile the policy probe with the production confinement, network and audio code.
set -eu
root=$(cd "$(dirname "$0")/../../.." && pwd)
net="$root/Packages/SignalRingRTC/Sources/CLinuxCallNetwork"
audio="$root/Packages/SignalRingRTC/Sources/CLinuxCallAudio"
policy="$root/Packages/SignalMediaService/Sources/CLinuxSandbox"
landlock="$root/Packages/SignalMediaService/Sources/CLinuxLandlock"
exec clang -I"$landlock/include" "$landlock/Landlock.c" -std=gnu17 -Wall -Wextra -Werror -pthread -I"$net" -I"$net/include" -I"$audio/include" -I"$policy/include" \
    "$root/Tools/linux/calling-confinement/check.c" "$net/"*.c "$audio/CallAudio.c" "$policy/"*.c \
    $(pkg-config --cflags --libs gio-2.0 alsa libseccomp) -o "$1"

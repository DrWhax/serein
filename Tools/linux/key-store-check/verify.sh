#!/bin/sh
# Run in Ubuntu with libsecret-1-dev, dbus-daemon and gnome-keyring installed.
set -eu
repo=$(cd "$(dirname "$0")/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/KeyStoreCheck" "$work/data" "$work/runtime"
chmod 700 "$work/data" "$work/runtime"
cp "$repo/Tools/linux/key-store-check/Package.swift" "$work/"
cp "$repo/Tools/linux/key-store-check/Sources/KeyStoreCheck/main.swift" "$work/Sources/KeyStoreCheck/"
core="$repo/Packages/SignalCore/Sources"
ln -s "$core/CLibSecret" "$work/Sources/CLibSecret"
ln -s "$core/CLinuxKeyStore" "$work/Sources/CLinuxKeyStore"
ln -s "$core/SignalCore/Database/DatabaseKeyStore.swift" "$core/SignalCore/Database/SecretServiceKeyStore.swift" "$work/Sources/KeyStoreCheck/"
swift build --package-path "$work"
binary=$(swift build --package-path "$work" --show-bin-path)/KeyStoreCheck
# Only test fingerprints leave the private bus session. Each reader is a fresh
# process, and all first-use calls race against the same initially empty keyring.
export XDG_DATA_HOME="$work/data" XDG_RUNTIME_DIR="$work/runtime"
dbus-run-session -- bash -euo pipefail -c '
    printf "%s" "temporary integration-test password" | gnome-keyring-daemon --unlock --components=secrets >/dev/null
    binary=$1
    work=$2
    pids=()
    for index in 1 2 3 4 5 6; do
        ( "$binary" read concurrent | sha256sum > "$work/hash-$index" ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    test "$("$binary" read concurrent | wc -c)" -eq 32
    for index in 2 3 4 5 6; do cmp "$work/hash-1" "$work/hash-$index"; done
' bash "$binary" "$work"
# A fresh bus and keyring daemon must recover the same key from disk.
dbus-run-session -- bash -euo pipefail -c '
    printf "%s" "temporary integration-test password" | gnome-keyring-daemon --unlock --components=secrets >/dev/null
    binary=$1
    work=$2
    "$binary" read concurrent | sha256sum | cmp "$work/hash-1" -
    "$binary" delete concurrent
    "$binary" read concurrent | sha256sum > "$work/replaced"
    if cmp -s "$work/hash-1" "$work/replaced"; then exit 1; fi
    "$binary" delete concurrent
    "$binary" delete concurrent
' bash "$binary" "$work"
if DBUS_SESSION_BUS_ADDRESS="unix:path=$work/missing" "$binary" read missing > /dev/null; then
    echo "Created a key without a Secret Service" >&2
    exit 1
fi
echo "Concurrent creation, persisted lookup after restart, deletion, rotation and missing-service checks passed."

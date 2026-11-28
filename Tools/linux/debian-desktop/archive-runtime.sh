#!/bin/sh
# Run inside the Serein desktop image. Write only the runtime archive to stdout.
set -eu
cd /
case "$(uname -m)" in
    aarch64) triplet=aarch64-linux-gnu; loader='usr/lib/ld-linux-aarch64.so.1' ;;
    x86_64)  triplet=x86_64-linux-gnu;  loader='lib64 usr/lib64' ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
test -x opt/serein/bin/SignalSafe
test -x opt/serein/bin/SignalCallingService
test -f usr/local/lib/serein/workers/libdispatch.so
test -f usr/share/polkit-1/actions/org.signalsafe.SignalSafe.policy
root=$(mktemp -d)
# Every bind destination needs its parents on the read-only root, which bwrap cannot create.
mkdir -p "$root"/tmp/.X11-unix "$root"/proc "$root"/sys/devices/system/cpu "$root"/dev/shm \
    "$root"/run/serein "$root"/run/dbus "$root"/var/lib/serein "$root"/var/lib/dbus
# $loader is intentionally unquoted: it names one or two paths per architecture.
for path in bin lib $loader usr/bin/python3 usr/bin/python3.12 usr/lib/python3.12 \
    usr/lib/swift/linux/*.so* usr/local/lib/libsqlcipher.so* usr/local/lib/serein/workers \
    "usr/lib/$triplet" usr/share/alsa usr/share/ca-certificates usr/share/fontconfig \
    usr/share/fonts usr/share/glib-2.0/schemas usr/share/locale usr/share/qt6 usr/share/zoneinfo \
    usr/share/X11 usr/share/mime usr/share/doc usr/share/polkit-1/actions/org.signalsafe.SignalSafe.policy \
    etc/ssl/certs etc/fonts etc/alsa etc/ld.so.cache etc/ld.so.conf etc/ld.so.conf.d etc/hosts \
    etc/host.conf etc/services etc/gai.conf etc/nsswitch.conf etc/passwd etc/group etc/os-release \
    usr/lib/os-release var/cache/fontconfig opt/serein; do
    if [ -e "$path" ] || [ -L "$path" ]; then cp -a --parents "$path" "$root"; fi
done
find "$root/usr/lib/$triplet" -type f -name '*.a' -delete
find "$root/opt/serein/bin" -maxdepth 1 -type f -executable -exec strip --strip-debug {} +
# Bubblewrap needs regular mount points on the read-only filesystem.
touch "$root/etc/resolv.conf" "$root/etc/machine-id" "$root/etc/localtime" "$root/run/dbus/system_bus_socket"
ln -s /etc/machine-id "$root/var/lib/dbus/machine-id"
tar -C "$root" -czf - .

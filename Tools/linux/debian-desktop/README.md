# Run Serein on Debian 13 ARM64

This launcher runs the release binaries from the ARM64 Serein desktop image on Debian's stock kernel. The host supplies the X11 or XWayland display, session bus, Secret Service and desktop portal. Docker is only needed on the build machine.

Build the `serein-desktop` image using the [Linux build instructions](../README.md). From the Serein checkout on the build machine, export the shared libraries, workers and app resources.

```sh
docker run --rm -i --network none --user root --entrypoint /bin/sh serein-desktop \
    -s < Tools/linux/debian-desktop/archive-runtime.sh > serein-arm64.tar.gz
```

Copy the archive and this directory to the Debian machine. In a graphical session with an unlocked login keyring, run the following from the directory containing the launcher files. These commands assume the archive is in the same directory. Install into a fresh release directory on first setup.

```sh
sudo apt install bubblewrap gnome-keyring xdg-desktop-portal polkitd
release="$HOME/.local/share/serein-linux/releases/abi6-desktop"
install -d -m 0700 "$release/root"
tar --no-same-owner -xzf serein-arm64.tar.gz -C "$release/root"
install -m 0755 run-session launch "$release/"
install -D -m 0755 launch "$HOME/.local/bin/serein"
install -D -m 0644 serein.service "$HOME/.config/systemd/user/serein.service"
install -D -m 0644 org.signalsafe.SignalSafe.desktop \
    "$HOME/.local/share/applications/org.signalsafe.SignalSafe.desktop"
icon=hicolor/256x256/apps/org.signalsafe.SignalSafe.png
install -D -m 0644 "$release/root/opt/serein/share/icons/$icon" "$HOME/.local/share/icons/$icon"
sudo install -m 0644 "$release/root/usr/share/polkit-1/actions/org.signalsafe.SignalSafe.policy" \
    /usr/share/polkit-1/actions/
systemctl --user daemon-reload
"$HOME/.local/bin/serein"
```

Open **Serein** from the desktop menu or run `~/.local/bin/serein`. Both start the same user service. On first launch, scan the QR code from **Linked Devices** on your phone. The host login keyring holds the database key. The encrypted database lives under `~/.local/share/serein-linux/data` across launches.

To diagnose a problem, turn on tracing. It logs event kinds, counts and error kinds, never message content, names or numbers. The launcher clears the environment, so set the variable on the service, which `run-session` passes to the app:

```sh
systemctl --user edit serein.service     # add: [Service] Environment=SIGNALSAFE_TRACE=1
systemctl --user restart serein.service
journalctl --user -u serein.service -f
```

Remove the override with `systemctl --user revert serein.service` when done.

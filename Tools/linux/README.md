# Serein in Ubuntu Docker

The desktop and its seven socket-activated workers run as the unprivileged `serein` user. The application applies Landlock and seccomp before constructing its session. The minimum is Landlock ABI 6, available on Debian 13’s stock Linux 6.12 kernel. On ABI 6 and 7, the desktop, calling worker and calling socket broker apply their rules while single-threaded. Later threads inherit those rules. Startup fails if glibc cannot confirm single-threaded execution. ABI 8 and newer apply the same rules to all existing threads with `LANDLOCK_RESTRICT_SELF_TSYNC`.

## Build

Use sibling Serein and QtSwiftUI checkouts. Initialize Serein’s pinned vendor dependencies and apply the project patches first. Populate the upstream Signal-Desktop sound assets or supply the generated WAVs in `App/SignalSafe/Resources/Sounds`. Build the toolchain from the Serein root.

```sh
docker build -t serein-toolchain -f Tools/linux/Dockerfile vendor/libsignal
```

In that toolchain container, run `sh Tools/linux/build-desktop.sh /out` from the prepared Linux checkout. Mount a fresh output directory at `/out`. SwiftPM needs writable package and cache directories during compilation. The default build configuration is release. The output contains the executable, worker binaries, resource bundles, sounds, icon, license notices, supervisor and desktop policy.

```sh
docker build --target desktop -t serein-desktop -f Tools/linux/Desktop.Dockerfile /path/to/output
```

The entry point starts the service supervisor. For an interactive desktop, supply the display connection and the user's desktop D-Bus and Secret Service. File selection uses the desktop portal. Documents granted by the portal are expected under `/run/serein/doc`. Use a private home at `/var/lib/serein` and runtime directory at `/run/serein`, both mode 0700 and owned by the container user.

## Capture an isolated first launch

The capture target includes Xvfb, xdotool and Pillow. This command starts a disposable keyring, runs the normal supervisor, locates the application's X11 window by its executable path and saves that window. The command disables external networking, so the linking screen waits for its QR code.

```sh
docker build --target capture -t serein-capture -f Tools/linux/Desktop.Dockerfile /path/to/output
docker run --name serein-first-launch --network none --cap-drop ALL --security-opt no-new-privileges \
  --mount "type=bind,src=$PWD/Tools/linux/desktop-check/capture.py,dst=/tmp/capture.py,readonly" \
  --entrypoint dbus-run-session serein-capture -- xvfb-run -a -f /run/serein/Xauthority \
  python3 /tmp/capture.py /tmp/serein.png
docker cp serein-first-launch:/tmp/serein.png ./serein.png
```

Pass `--about` after the output path to exercise Help → About. The check captures the second window, sends Escape, and verifies the original window is still open on the same process. Pass `--shortcuts` to capture the keyboard shortcut guide opened by Ctrl+/ and verify that Escape dismisses it.

## Exercise a linked conversation

Prepare the local test server with `Tools/build-mock-server.sh`. The `conversation-check` target adds Node to the capture image. The server runs inside the same network namespace as Serein, using loopback and disposable accounts. The test checks that the phone receives the desktop composer's reply before capturing the conversation and General settings from the running release executable.

```sh
docker build --target conversation-check -t serein-conversation -f Tools/linux/Desktop.Dockerfile /path/to/output
docker run --name serein-linked-check --network none --cap-drop ALL --security-opt no-new-privileges \
  --mount "type=bind,src=$PWD/Tests/MockServer,dst=/fixture,readonly" \
  --mount "type=bind,src=$PWD/Tools/linux/desktop-check,dst=/checks,readonly" \
  --entrypoint dbus-run-session serein-conversation -- xvfb-run -a -f /run/serein/Xauthority \
  python3 /checks/conversation.py /fixture/harness.mjs /tmp/screens
docker cp serein-linked-check:/tmp/screens ./serein-linked-screens
```

<p align="center"><img src="Logo/Serein.png" width="128" alt="Serein logo"></p>

# Serein

A native Signal client for macOS. Built with SwiftUI, with every image and video format decoded in Swift inside a sandbox, and a focus on security.

> [!WARNING]
> **Serein is experimental software.** Do not rely on it for strong cryptography or security yet. No one has formally verified that its crypto code is implemented safely.

Serein is not affiliated with or endorsed by Signal Messenger LLC.

## What it is

- **Native app.** Built with SwiftUI and AppKit instead of Electron. The interface follows Signal Desktop's design closely.
- **Linked device only.** You link Serein to the Signal app on your phone with a QR code. Backups, payments and donations are not supported.
- **Swift media decoders.** Every image, audio and video format is decoded by memory-safe Swift code in `Packages/SignalCodecs`. Serein never uses ImageIO, VideoToolbox or AudioToolbox on untrusted data. Each format has a grammar-first parser written in the LangSec style. Supported formats:
  - images: PNG/APNG, JPEG, GIF, WebP and BMP/ICO;
  - video and audio: MP4, H.264, HEVC, AAC and MP3.
- **Sandboxed parsing.** Received media is decoded in `SignalMediaDecoder.xpc`, and link-preview HTML is parsed in `SignalLinkPreviewParser.xpc`. Both are XPC services with App Sandbox and their own Seatbelt profile. Neither has network or file access, and neither ever sees keys. Each service checks at startup that its profile is active, and exits if it isn't.
- **Signal's libraries for the protocol.** The protocol, networking and calling come from Signal's own Rust libraries ([libsignal](https://github.com/signalapp/libsignal) and [RingRTC](https://github.com/signalapp/ringrtc)). Serein does not reimplement them.

## Requirements

- macOS 27 on Apple silicon
- Xcode 27 (Swift 6.4)
- A Rust toolchain, to build libsignal and RingRTC

## Building

```sh
git submodule update --init
SIGNALSAFE_SIGN_IDENTITY=<codesign identity> Tools/build-app.sh
open App/SignalSafe/.build/Serein.app
```

Each package has its own tests:

```sh
(cd Packages/SignalCodecs && swift test)
(cd Packages/SignalCore && swift test)    # uses the mock server: Tools/build-mock-server.sh
(cd Packages/SignalUI && swift test)
Tools/lint-codecs.sh                      # memory-safety and isolation rules
Tools/check-sandbox-profile.sh            # the XPC services' Seatbelt profiles
```

## Layout

| Path | What it holds |
|---|---|
| `App/SignalSafe` | The app target |
| `Packages/SignalCodecs` | Media parsers, decoders and encoders (no Foundation, no `unsafe`) |
| `Packages/SignalMediaService` | The sandboxed XPC services and their XPC interface |
| `Packages/SignalCore` | Protocol stores, database (SQLCipher), messaging, groups, storage service, attachments, calling |
| `Packages/SignalUI` | The SwiftUI interface |
| `Packages/SignalI18n` | ICU MessageFormat runtime and the translated strings |
| `Packages/SignalRingRTC` | C ABI and Swift wrapper over RingRTC |
| `Tools` | Build scripts, generators and lint |
| `Signal-Desktop` | The upstream client, used as a read-only reference |

## License

Serein is licensed under the GNU Affero General Public License v3.0 (see [LICENSE](LICENSE)). Its interface and translations are ported from [Signal Desktop](https://github.com/signalapp/Signal-Desktop), which uses the same license.

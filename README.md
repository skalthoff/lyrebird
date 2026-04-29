# THIS IS A VIBE CODED PROJECT, WHILE I AM PUTTING REAL THOUGHT AND EFFORT INTO SOME ELEMENTS, it really shouldn't be used by people

# Jellify Desktop

Native desktop apps for [Jellyfin](https://jellyfin.org) — macOS first, Windows and Linux to follow. Not Electron, not a web wrapper. Each platform is rendered by its own native UI toolkit, sharing a Rust core for API, audio coordination, and storage.

<p align="center">
  <i>Status: macOS MVP playing music. Windows and Linux in planning.</i>
</p>

## Repo layout

```
core/       Rust library — Jellyfin API, queue, storage, stream URLs
macos/      SwiftUI + AVFoundation app (current focus)
windows/    WinUI 3 / C# app (planned)
linux/      GTK4 + libadwaita app (planned)
design/     Shared design tokens, fonts, icons, and prototype
examples/   Small Rust binaries exercising the core
```

## Architecture

Business logic lives in `core/` as a Rust library. Each platform links it:

- **macOS**: embedded as an `.xcframework`, consumed through [UniFFI](https://mozilla.github.io/uniffi-rs/)-generated Swift bindings. Audio playback uses `AVPlayer` directly, with the Rust core providing authenticated stream URLs. `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` integrations (planned) make the app a first-class participant in macOS media controls.
- **Windows** (bootstrap landed; pages in flight): WinUI 3 via Windows App SDK in C#, consuming the core through UniFFI .NET bindings (`uniffi-bindgen-cs`). `MediaPlayer` for audio, SMTC for transport integration. See `windows/README.md`.
- **Linux** (planned): GTK4 + libadwaita via `gtk-rs`, linking the core directly in-process. GStreamer for audio, MPRIS2 for transport.

## macOS — quick start

Requirements: macOS 14+, Rust (`brew install rust`), Xcode 15+.

```sh
cd macos
./Scripts/build-core.sh        # Builds the Rust core → Jellify.xcframework
swift build                     # Builds the SwiftUI app
./Scripts/make-bundle.sh        # Wraps the binary into Jellify.app
open build/Jellify.app
```

### Headless smoke test

Exercises login + playback without the UI. Useful in CI.

```sh
JELLYFIN_URL=https://your.server \
JELLYFIN_USER=you \
JELLYFIN_PASS=pw \
  ./.build/arm64-apple-macosx/debug/SmokeTest
```

## Core — tests

```sh
cargo test --workspace
```

## Design

The visual reference lives in `design/` — an HTML/CSS prototype produced in Claude Design. Every native implementation targets parity with it.

Tokens we track across platforms:

- **Palette (Purple preset, dark mode)**: bg `#0C0622`, surface `rgba(126,114,175,0.08)`, primary `#887BFF`, accent `#CC2F71`, teal `#57E9C9`.
- **Type**: Figtree (100 – 900), italic variants.
- **Themes**: purple, ocean, forest, sunset, peanut. Each ships dark + oled; purple additionally ships light.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Open issues for bugs and features; track milestones in [ROADMAP.md](ROADMAP.md).

## License

GPL-3.0-only. See [LICENSE](LICENSE).

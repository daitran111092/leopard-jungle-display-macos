# Architecture

This document covers how LJ Display gets its data, how a frame reaches the panel, and why each approach was chosen.
For building and using the app, see the [README](../README.md). Each source file also starts with a doc comment that
describes its details. When this document and the code disagree, the code is right.

## Overview

```
                 ┌──────────── LJSources ────────────┐
CoreAudio ──────▶│ AudioSource                       │
system_profiler ▶│ BluetoothSource                   │      ┌── LJCore ──┐
libproc / mach ─▶│ SystemSource                      ├─────▶│  AppStore  │◀── reduce(state, action)
perl + adapter ─▶│ NowPlayingSource                  │      │  (UiState) │        ▲
Carbon ─────────▶│ HotKeys ──────────────────────────┼──────┼────────────┼────────┘
                 └───────────────────────────────────┘      └─────┬──────┘   effects (.media) ─▶ MediaSendQueue
                                                                  │ onChange (only on real changes)    ─▶ NowPlayingSource.send
                                                                  ▼
             FrameLoop (60 Hz timer, main) ─ RootView ─ ImageRenderer ─ FrameEncoder ─ Panel ─ USBBulkPort ─▶ panel
```

`LJRuntime` (`Sources/LJApp/Runtime.swift`) does all of this wiring. Both the `.app` and `ljprobe stream` use it, so
the probe CLI runs exactly the same code as the app.

## Layers

| Target | Rule |
|---|---|
| `LJCore` | Pure logic with no UI and no OS frameworks beyond Foundation: protocol framing, the `Panel` session over an injectable `PortIO`, the reducer, parsers, formatting, the frame budget, config. Everything here is unit tested with fakes (`ManualClock`, fake ports). |
| `LJSources` | Everything that talks to macOS or USB. Each source emits `LJCore` types through an `onChange` callback on its own queue. |
| `LJUI` | SwiftUI views, which are pure functions of `(state, t, now)`, plus `AppStore`, the frame loop and the encoder. |
| `LJApp` | Wiring and lifecycle: connect / reconnect, sleep / wake, CLEAR on quit, log. |
| `LJDisplay` | The app shell: `NSApplication` with the `.accessory` policy, the menu bar, app-level effects. |

## Data sources

| Source | How | Why this way |
|---|---|---|
| Audio output (`AudioSource`) | CoreAudio property listeners on the default output device: name, transport, data source, volume, nominal sample rate, and the first stream's physical / virtual format. Listeners move to the new device when the default changes. | No polling. The speaker warning has to show within 1 s of a switch. |
| Bluetooth (`BluetoothSource`) | Runs `system_profiler SPBluetoothDataType -json` in a subprocess every 30 s, and again whenever the audio output changes. | IOBluetooth blocks on the Bluetooth TCC prompt in an unbundled CLI, and BLE devices (MX Master…) have no `BatteryPercent` in IORegistry. `system_profiler` reports main / left / right / case battery levels with no permission. |
| System (`SystemSource`) | Host CPU from `host_processor_info` tick deltas. Memory used as Activity Monitor computes it (app + wired + compressed, from `host_statistics64`). Per process: `proc_pid_rusage` CPU deltas and the physical footprint, grouped by the outermost `.app` (`Aggregate.swift`). | Matches what Activity Monitor shows. Processes the app may not inspect are skipped. |
| Now playing (`NowPlayingSource`) | `/usr/bin/perl` runs the vendored `mediaremote-adapter.pl`, which loads `MediaRemoteAdapter.framework` and streams line-delimited JSON (full state or diffs, parsed by `applyAdapterEvent`). Commands use the script's one-shot `send` / `seek`. | Since macOS 15.4, MediaRemote refuses unentitled processes, and `/usr/bin/perl` is entitled. A perl watchdog TERMs the stream if the app dies, and the stream restarts with backoff (1 s → 30 s). |
| Hot keys (`HotKeys`) | Carbon `RegisterEventHotKey`, F13–F19 plus Ctrl+Option fallbacks. | Global keys without Accessibility permission. The knob board sends F13–F19. |

## State and input

- **`AppStore`** is the single source of truth (`UiState`). It notifies observers only when the state actually
  changes (`Equatable`), so a source that repeats the same value never costs a frame.
- **`reduce`** (`LJCore/Reducer.swift`) is a pure function from (state, action) to (state, effects). Music actions
  are **optimistic**: a seek or a play / pause shows at once and holds for up to 1.5 s until the adapter confirms it
  (`MusicHold`). If the adapter never confirms, the state goes back to what the adapter reports.
- **`MediaSendQueue`** coalesces knob seeks into one per 250 ms and sends at most one command at a time (each send
  spawns perl), with a 3 s timeout.

## Rendering

`FrameLoop` runs a 60 Hz `DispatchSourceTimer` on the main queue. `FrameLoopCore` decides on each tick whether to draw:

| Rate | When |
|---|---|
| every tick | page slide (`.full`), or the state changed (`markDirty`), or the panel just (re)connected |
| 60 fps | music playing on the Music page (EQ bars, progress) |
| 20 fps | ambient only: speaker-warning stripes / flash, rail bars gliding |
| none | static: only the panel's keepalive goes out |

Animation time is wall clock, so a skipped tick never slows an animation. The static decor (gradients, graffiti wall,
"JINX", monkey) is drawn once per theme into a cached `CGImage`. Artwork is decoded once per distinct image
(`ArtworkCache`, LRU of 4).

A frame goes through these steps:

1. `RootView` (1920×462 landscape) is rendered by a reused `ImageRenderer`.
2. `FrameEncoder` draws it into a reused sRGB bitmap, rotates it 90° with `vImageRotate90_ARGB8888` (~0.1 ms, against
   ~3 ms for a rotated CGContext draw), then encodes a baseline 4:2:0 JPEG with **libjpeg-turbo**.
3. `FrameBudget` adapts the quality to keep each frame ≤ 300 KB at q ≤ 0.95 (about 11 ms over USB bulk, so 60 fps
   fits).

**Do not use ImageIO for panel frames.** The firmware hangs (stuck image, needs a power cycle) on ImageIO JPEGs,
probably because of their APP1 / APP13 metadata. libjpeg-turbo's plain JFIF output is safe. ImageIO is used only for
fixture PNGs and tests. A failed hardware encode skips the frame, and the panel keeps its last image.

## Panel session and transport

`Panel` (`LJCore/Panel.swift`) owns one session:

- **Handshake**: CLEAR, settle 0.3 s, `getInfo` (3 s deadline), enter live mode (`0x11`), then keepalive every
  1.5 s.
- **Writer**: one private serial queue writes brightness first, then control frames, then the latest image. A newer
  image replaces one not yet written, so the panel never falls behind.
- **Reader**: a reader queue drains and discards the panel's acks, so input never piles up. A read or write error
  ends the session.
- **Brightness**: the firmware ignores `0x03` while live. So the writer leaves live mode, sends brightness, re-enters
  live mode and repaints the last frame.

`PanelLink` (`LJApp`) connects off the main thread, one attempt at a time, with an 8 s watchdog. It reconnects after
an error, a replug or a wake. `PanelDiscovery` watches IOKit for vendor `0x33c3`.

**Transport: `USBBulkPort`, with `SerialPort` as a fallback.** The panel is a CDC-ACM device. Writing through the
macOS tty (`/dev/cu.usbmodem*`) splits each frame into ~1 KB USB transfers, and the panel sometimes corrupts those
(a tinted band at the end of the image). `USBBulkPort` claims the CDC data interface through IOUSBHost and sends
each frame as **one bulk OUT transfer**, as the vendor's Windows app does. This needs no root, as long as nothing holds
the tty open. If the interface can't be opened, `PanelLink` falls back to the tty.

## Lifecycle

- **Sleep**: before the Mac sleeps, the frame loop stops, the session closes and discovery stops. On wake,
  discovery restarts and the panel reconnects.
- **Quit / SIGTERM**: the CLEAR sequence (`FF D9 FF D9 00 00 00 00`) is written after any in-flight frame, then
  the port closes.
- **Pause streaming**: the timer is suspended, and the panel keeps showing the last frame.

## Testing

- `make test` runs Swift Testing across 4 targets. Hardware and OS calls sit behind injectable seams (`PortIO`,
  `PanelClock`, parser functions), so the protocol, reconnect, budget, reducer and frame-loop decisions are all
  tested without a panel.
- `make fixtures` renders fixed UI states (`Sources/LJUI/Fixtures.swift`) to PNG for visual review.
- `ljprobe` covers the hardware side: `panel --soak`, `stream`, and each source on its own.

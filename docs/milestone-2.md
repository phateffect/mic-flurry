# Milestone 2 foreground runtime

Milestone 2 is one foreground `micflurry` process. Ratatui calls a `LocalControlClient`; Bluetooth,
audio, recordings, keyboard events, and SQLite remain in `micflurry-core`. There is no daemon,
launchd job, Unix socket, application bundle, or custom driver IPC in this milestone.

```text
ATVV remote -> CoreBluetooth -> IMA ADPCM decoder -> streaming resampler
                                                        |-> Float32 WAV (optional)
                                                        `-> AUHAL -> MicFlurry_2_UID
Ratatui -> LocalControlClient -> in-process runtime
```

## Build and run

The repository pins Rust 1.91 through mise:

```bash
mise install
mise run rust-check
mise run micflurry
```

These tasks first export the pinned, unmodified `upstream/btleplug` submodule into
`.build/btleplug` and apply `patches/btleplug-macos-connected.patch`. Use the `mise` entry points
after a fresh clone instead of invoking Cargo before that generated dependency exists.

Useful diagnostic flags are passed after `--`:

```bash
mise run micflurry -- --no-audio
mise run micflurry -- --no-bluetooth
mise run micflurry -- --database /tmp/micflurry-test.db
mise run micflurry -- --drop-audio-notification 2
mise run micflurry -- --seize-hid
```

`--no-audio` keeps discovery, persistence, and the UI available without an installed driver.
`--no-bluetooth` is useful for local control and database testing. The one-based
`--drop-audio-notification` option deliberately skips one decoded notification per session so the
next `AUDIO_SYNC` gap and recovery can be characterized. `--seize-hid` is an explicit development
mode: it prevents macOS and other clients from receiving the attached remote's HID input, then
forwards recognized buttons as CGEvents. Normal runs observe HID values without seizing or
re-forwarding them.

The `mise run micflurry` development task appends structured runtime diagnostics to
`/tmp/micflurry-dev.log`. Set `MICFLURRY_LOG` to choose another file, or run the binary without that
variable to keep logs on stderr. Avoid running multiple TUI instances against the same remote when
interpreting protocol logs because CoreBluetooth can deliver the same notification to each process.

## Permissions and prerequisites

1. Build and install `MicFlurry.driver` using `INSTALL.md`. The runtime resolves the hidden output by
   its stable UID `MicFlurry_2_UID`; it does not select a similarly named default device.
2. Give the terminal used to start MicFlurry access in System Settings → Privacy & Security →
   Bluetooth. A future app bundle must instead include `NSBluetoothAlwaysUsageDescription`.
3. Give that terminal Accessibility access before using keyboard actions. MicFlurry posts ordinary
   CGEvent key presses and never changes the permission itself.
4. Give the terminal Input Monitoring access if macOS requires it for IOHID input callbacks.
   Exclusive `--seize-hid` mode can temporarily make the remote unavailable to the system; quit or
   release the device to close the exclusive IOHID handle.

At startup MicFlurry first uses the public `retrieveConnectedPeripheralsWithServices:` API to list
system-connected ATVV peripherals, including a remote connected through macOS before MicFlurry has
ever seen it. Users always pair and connect the remote in macOS Bluetooth Settings; MicFlurry never
scans or initiates system pairing. A non-exclusive IOHID monitor joins each CoreBluetooth UUID to the
HID manufacturer and VID/PID and reports every input usage/value to the TUI. The current supported
hardware fingerprint is `MIOM`, vendor ID `10007`,
product ID `12984`; its observed IOHID product name is `小米语音遥控器`. User-visible names are
display-only and may be renamed. The last successful UUID is persisted only to choose among multiple
supported, already-connected remotes. Releasing or quitting MicFlurry stops its notification task
without disconnecting a link macOS owned first.

## Controls

| Key | Action |
| --- | --- |
| `s` | refresh ATVV devices currently connected by macOS |
| Up / Down | select a device |
| Return | attach to the selected supported device and negotiate ATVV |
| `d` | close the ATVV stream and release MicFlurry's attachment |
| `r` | start or stop a mono Float32 WAV recording |
| `<` / `>` | decrease or increase input gain by 1 dB |
| Space | post play/pause (Space) through CGEvent |
| `[` / `]` | post previous/next (Left/Right Arrow) through CGEvent |
| `-` / `+` | post macOS volume down/up key codes through CGEvent |
| `m` | post the macOS mute key code through CGEvent |
| `q` | stop the foreground runtime and quit |

The UI displays refresh/attachment state, standard GATT Device Information, IOHID identity and input
history, CGEvent output history, ATT MTU, audio notification-size distribution, sync frame gaps, the
active or most recently completed session duration, source/output rates, persisted input gain,
decoded/dropped samples, input level, recording state, and the latest error. The duration resets on
`AUDIO_START`, advances while active, and freezes on `AUDIO_STOP` or disconnect.

## ATVV profile

The initial profile is Google Voice over BLE v1:

| Role | UUID | Operation |
| --- | --- | --- |
| service | `AB5E0001-5A21-4F05-BC7D-AF01F617B664` | discovery |
| host TX | `AB5E0002-5A21-4F05-BC7D-AF01F617B664` | write without response |
| audio | `AB5E0003-5A21-4F05-BC7D-AF01F617B664` | notify |
| control | `AB5E0004-5A21-4F05-BC7D-AF01F617B664` | notify |

After connection the host subscribes to audio and control and sends `GET_CAPS`. `START_SEARCH`
causes `MIC_OPEN`; an active stream is extended every ten seconds with its negotiated stream ID,
and release sends `MIC_CLOSE` for any stream. `AUDIO_START`, `AUDIO_STOP`, and
`AUDIO_SYNC` drive decoder state. Both 8 kHz and 16 kHz codecs are supported, including dynamic rate
changes. The decoder processes the high nibble first as required by ATVV and uses sync predictor and
step-index values after packet loss.

New databases default to +12 dB input gain because physical ATVV remotes commonly have low decoded
levels. The persisted gain is limited to -24 through +24 dB and is applied to both CoreAudio output
and Float32 WAV recordings.

## Persistent state

By default SQLite is stored at `~/Library/Application Support/MicFlurry/micflurry.db`. It owns:

- injection UID, output rate, input gain, recording directory, and automatic-recording setting;
- known-device identity and last-seen metadata;
- the most recently connected device UUID used for macOS restoration;
- recording path, device, rate, sample count, and timestamps;
- the schema version through SQLite `user_version`.

WAV files default to `~/Music/MicFlurry`. Clients use `ControlClient`; they do not access these
tables directly.

## Physical validation

The registered `MIOM`/`10007`/`12984` fingerprint has been validated with the installed driver. It
negotiated ATVV 1.00, 16 kHz ADPCM, interaction model 3 and a 120-byte audio frame; short sessions,
repeated sessions, WAV capture, visible `MicFlurry` input, release/reattach, and fresh-process restore
all passed. A held session stopped at 60 seconds in the remote firmware after five successful
`MIC_EXTEND` commands, and a new session began after release and another press. The runtime also
independently caps active sessions at 60 seconds and sends `MIC_CLOSE` with the negotiated stream ID.

Automated tests still do not emulate CoreBluetooth or a HAL render cycle. They now cover an injected
notification loss followed by decoder synchronization, a 16-to-8 kHz sync transition, frame-gap
accounting with wraparound, and host-owned cutoff state. The following physical coverage remains:

1. Exercise an 8 kHz remote/stream and a deliberate `AUDIO_SYNC` rate transition on hardware.
2. Capture the exposed ATT MTU and notification-size distribution, then use
   `--drop-audio-notification` before a real remote-generated sync point.
3. Exercise the host-owned cutoff against a supported device whose firmware would otherwise run
   beyond 60 seconds.
4. Repeat the lifecycle checks for every newly registered hardware fingerprint.

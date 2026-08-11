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

Useful diagnostic flags are passed after `--`:

```bash
mise run micflurry -- --no-audio
mise run micflurry -- --no-bluetooth
mise run micflurry -- --database /tmp/micflurry-test.db
```

`--no-audio` keeps discovery, persistence, and the UI available without an installed driver.
`--no-bluetooth` is useful for local control and database testing.

## Permissions and prerequisites

1. Build and install `MicFlurry.driver` using `INSTALL.md`. The runtime resolves the hidden output by
   its stable UID `MicFlurry_2_UID`; it does not select a similarly named default device.
2. Give the terminal used to start MicFlurry access in System Settings → Privacy & Security →
   Bluetooth. A future app bundle must instead include `NSBluetoothAlwaysUsageDescription`.
3. Give that terminal Accessibility access before using keyboard actions. MicFlurry posts ordinary
   CGEvent key presses and never changes the permission itself.

CoreBluetooth performs the system pairing exchange when connecting to protected characteristics.
The TUI calls this operation “pair/connect” because CoreBluetooth does not expose a separate pairing
method on macOS.

## Controls

| Key | Action |
| --- | --- |
| `s` | scan for BLE devices |
| Up / Down | select a device |
| Return | pair/connect and negotiate ATVV |
| `d` | close the ATVV stream and disconnect |
| `r` | start or stop a mono Float32 WAV recording |
| Space | post play/pause (Space) through CGEvent |
| `[` / `]` | post previous/next (Left/Right Arrow) through CGEvent |
| `-` / `+` | post macOS volume down/up key codes through CGEvent |
| `m` | post the macOS mute key code through CGEvent |
| `q` | stop the foreground runtime and quit |

The UI displays scan/pair/connection state, source and output rates, decoded and dropped samples,
the input level (limited to ten updates per second), recording state, and the latest error.

## ATVV profile

The initial profile is Google Voice over BLE v1:

| Role | UUID | Operation |
| --- | --- | --- |
| service | `AB5E0001-5A21-4F05-BC7D-AF01F617B664` | discovery |
| host TX | `AB5E0002-5A21-4F05-BC7D-AF01F617B664` | write without response |
| audio | `AB5E0003-5A21-4F05-BC7D-AF01F617B664` | notify |
| control | `AB5E0004-5A21-4F05-BC7D-AF01F617B664` | notify |

After connection the host subscribes to audio and control and sends `GET_CAPS`. `START_SEARCH`
causes `MIC_OPEN`; disconnect sends `MIC_CLOSE` for any stream. `AUDIO_START`, `AUDIO_STOP`, and
`AUDIO_SYNC` drive decoder state. Both 8 kHz and 16 kHz codecs are supported, including dynamic rate
changes. The decoder processes the high nibble first as required by ATVV and uses sync predictor and
step-index values after packet loss.

## Persistent state

By default SQLite is stored at `~/Library/Application Support/MicFlurry/micflurry.db`. It owns:

- injection UID, output rate, recording directory, and automatic-recording setting;
- known-device identity and last-seen metadata;
- recording path, device, rate, sample count, and timestamps;
- the schema version through SQLite `user_version`.

WAV files default to `~/Music/MicFlurry`. Clients use `ControlClient`; they do not access these
tables directly.

## Physical validation checklist

Automated tests do not emulate CoreBluetooth or a HAL render cycle. Before declaring device-level
validation complete, use an ATVV remote and verify:

1. The scan identifies the remote as ATVV and Return completes the macOS pairing prompt.
2. Assistant press produces `AUDIO_START`, a moving level meter, and no sustained dropped-sample
   increase.
3. A consumer recording from visible `MicFlurry` receives intelligible mono audio while the daemon
   writes only to hidden `MicFlurry Internal`.
4. Exercise both an 8 kHz and a 16 kHz remote/stream if available, including an `AUDIO_SYNC` rate
   transition.
5. Start and stop a recording; inspect its Float32 mono sample rate and confirm its SQLite metadata.
6. Exercise every CGEvent action after granting Accessibility access.
7. Disconnect, reconnect, restart the TUI, and confirm settings and known-device state persist.

# MicFlurry local control API v1

`micflurryd` exposes a local JSON-RPC 2.0 stream socket. The default endpoint is
`~/Library/Application Support/MicFlurry/run/control.sock`; development runs may override it with
`--socket PATH`. Its parent directory is owned by the current user with mode `0700`, and the socket
has mode `0600`. The daemon never listens on TCP and never sends PCM over this API.

Each frame is one UTF-8 JSON object followed by a newline. A frame may contain at most 65,535 bytes.
Method names carry the API major version; additive fields and events may be introduced within v1,
and clients must ignore values they do not understand.

## Requests

| Method | Params | Result |
| --- | --- | --- |
| `v1.status` | none | current status |
| `v1.settings` | none | current settings |
| `v1.set_settings` | partial settings object | persisted settings |
| `v1.refresh_devices` | none | `null` |
| `v1.connect` | `{ "device": "COREBLUETOOTH-UUID" }` | `null` |
| `v1.release` | none | `null` |
| `v1.start_recording` | none | `null` |
| `v1.stop_recording` | none | `null` |
| `v1.start_hid_capture` | none | `null` |
| `v1.stop_hid_capture` | none | `null` |

For example:

```json
{"jsonrpc":"2.0","id":1,"method":"v1.status"}
{"jsonrpc":"2.0","id":1,"result":{"attaching":false,"audio":{"active":false}}}
```

IDs may be integers or strings. The server accepts only requests with an ID for control operations;
it does not execute client notifications. Standard JSON-RPC errors use `-32700`, `-32600`,
`-32601`, and `-32602`; operation failures use `-32000`.

Settings fields are `injection_device_uid`, `output_rate_hz`, `input_gain_db`,
`recording_directory`, and `auto_record`. Output rates are limited to 8000, 16000, 44100, and 48000
Hz, and gain is limited to -24 through +24 dB. Changing the device UID or output rate atomically
opens the replacement AudioUnit before committing the setting and is rejected during recording.

`v1.start_hid_capture` always requests the built-in `rc003-v1` profile and the physical device ID
already correlated during BLE attachment. Public clients cannot provide a VID/PID, match dictionary,
IORegistry path, or arbitrary helper profile. Helper unavailability changes only HID status; it does
not release Bluetooth, stop audio, or stop recording. The method accepts no parameters (JSON `null`
is also accepted); a caller-supplied profile, VID/PID, IORegistry path, or other matching override is
rejected as invalid parameters rather than ignored.

## Events

Every connected client receives daemon notifications without a subscription request:

```json
{"jsonrpc":"2.0","method":"v1.event","params":{"type":"audio_started","rate_hz":16000}}
```

The current event types are `status`, `device_discovered`, `attaching`, `connected`, `disconnected`,
`audio_started`, `audio_level`, `audio_stopped`, `recording_started`, `recording_stopped`,
`hid_input`, `keyboard_output`, and `error`. Telemetry is aggregated by the daemon; audio samples are
never present. A client that accumulates more than 256 KiB of unsent output is disconnected without
affecting daemon work or other clients.

The machine-readable framing schema is [control-api-v1.schema.json](control-api-v1.schema.json).

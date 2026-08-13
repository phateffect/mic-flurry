# MicFlurry milestones

This document records the planned architecture and delivery sequence discussed on 2026-08-11 and
refined through 2026-08-13. It describes future work, not necessarily the behavior of the current
release. `README.md` and `AGENTS.md` remain authoritative for what is implemented today.

## Product boundary

MicFlurry has a required core and replaceable user interfaces:

```text
MicFlurry Core
├── MicFlurry.driver       virtual microphone and CoreAudio loopback
└── micflurryd             Bluetooth, audio, persistence, and control service

Optional clients
├── CLI / TUI              any language
├── tray / native app      any language
├── web UI                 any language
└── third-party clients    any language that can use a Unix socket
```

The driver and daemon form the complete Bluetooth microphone product. The driver can still be used
by itself as a conventional CoreAudio loopback device. The CLI, TUI, and tray are optional clients;
none of them owns the daemon, and closing a UI must not stop an active connection or recording.

A macOS `.app` is therefore not the whole product boundary. A future complete installer may carry
all components, but it installs the active HAL plug-in outside the app bundle:

```text
MicFlurry.pkg
├── /Library/Audio/Plug-Ins/HAL/MicFlurry.driver
└── /Applications/MicFlurry.app                     signed service host
    ├── per-user Swift micflurryd service
    ├── root Swift micflurry-hid-helper
    └── optional native UI
```

Headless operation of the driver and daemon must remain possible. The `.app` is the modern
ServiceManagement host and does not imply that a native UI must run or even be shipped. TUI, CLI,
web, and native UI packaging may be offered separately once maintaining multiple artifacts is
useful.

## Runtime architecture

Keep the audio data plane separate from the UI control plane:

```text
TUI / tray / third-party UI
             │
             │ local control API
             ▼
         micflurryd
             │
             │ standard CoreAudio output API
             ▼
MicFlurry Internal output
             │ BlackHole shared audio buffer
             ▼
visible MicFlurry input -> consuming application
```

The BlackHole-derived driver does not need a custom Unix socket. The daemon writes decoded PCM to a
CoreAudio output endpoint, and the driver exposes the same frames on the microphone input. The
control socket carries commands, configuration, status, and events; it does not carry PCM.

### HID privilege boundary

The final background service is split by privilege and login-session ownership:

```text
TUI / tray / third-party client
             │ public per-user JSON-RPC socket
             ▼
micflurryd                                           per-user LaunchAgent
├── Bluetooth / ATVV / CoreAudio
├── SQLite settings and button mappings
├── CGEvent output
└── HID helper client
             │ private authenticated XPC
             ▼
micflurry-hid-helper                                 root LaunchDaemon
└── exclusive IOHID capture of registered hardware
```

Do not run all of `micflurryd` as root. Bluetooth, CoreAudio, CGEvent output, state ownership, and the
public control API belong to the logged-in user's service. The root helper is a narrow mechanism for
opening the remote exclusively, reading its input, and releasing it. It must not own mappings,
persist settings, access BLE/audio, or expose a general-purpose HID API.

The planned remapping path is seizure-only. There is no CGEvent suppression fallback in the current
plan: if the helper is unavailable or cannot seize every interface, remapping is unavailable and the
failure is reported to clients. Seizure is atomic across every IOHID interface matching the stable
registered RC003 fingerprint (`MIOM`, vendor `0x2717`, product `0x32b8`). Input capture is not
restricted to a known-button list; every raw report and decoded usage is forwarded so new or unknown
RC003 commands remain observable. Mapping policy remains in `micflurryd`.

The bounded probes have confirmed that this RC003 exposes one matching keyboard interface and can be
seized both as a root child of an Input-Monitoring-approved Terminal and as a root system
LaunchDaemon with its own manually granted Input Monitoring identity. Both paths received complete
raw reports and decoded usages and released the interface normally; the remote's original macOS
actions stopped during direct seizure and returned immediately afterward. The LaunchDaemon run
captured all 13 observed non-empty reports, including OK, and exited zero. Hardware observation also
confirmed that no original RC003 action reached macOS during the LaunchDaemon seizure and that normal
behavior returned immediately on exit. A plain root administrator shell remained
`kIOReturnNotPermitted`, proving that root without TCC consent is insufficient.

The remaining product risk is packaging and lifecycle rather than RC003 seizure feasibility. The
final helper still requires Developer ID signing, notarization, `SMAppService`, authenticated XPC,
lease/crash release, and fast-user-switching validation. The ad-hoc legacy LaunchDaemon test does not
replace those release requirements.

The current LaunchDaemon test is deliberately not a release implementation. With no Developer ID
identity available, it uses a root-owned legacy LaunchDaemon and an ad-hoc-signed app-like bundle to
measure system-launchd TCC behavior. `SMAppService` requires a properly signed and notarized bundle
for LaunchDaemons, so the final helper must repeat the test after release signing exists.

Programs that only need to produce PCM should use the standard CoreAudio endpoint. If a non-CoreAudio
streaming API is ever required, design it later as a separate binary audio protocol rather than
mixing high-rate frames into the control API.

## Ownership of state

The daemon owns business logic and all mutable state. Clients must not read or write its SQLite
database directly.

```text
micflurryd
├── SQLite       settings, known devices, recording metadata, schema version
├── memory       connection, refresh, stream, level, and error state
├── Keychain     future credentials or secrets
└── files        optional recorded audio payloads
```

SQLite is the single persistent source of truth, so there is no `config.toml`. This avoids two
configuration stores, unsafe concurrent writes, and UI coupling to database tables. Database access,
validation, transactions, and migrations stay behind the daemon API.

Only bootstrap concerns belong in process arguments, environment variables, or launchd settings,
for example database path, socket path, foreground mode, and log level. Compiled defaults cover the
normal case. A future declarative workflow should use API-backed import and export commands rather
than introduce another live configuration store:

```bash
micflurry config export > config.json
micflurry config import config.json
```

## Control boundary

Define one client abstraction before splitting processes. The foreground prototype uses an
in-process implementation; the daemon phase adds a socket implementation without changing the TUI's
domain operations.

```rust
trait ControlClient {
    async fn status(&self) -> Status;
    async fn set_settings(&self, change: SettingsChange);
    async fn refresh_devices(&self);
    async fn connect(&self, device: DeviceId);
    async fn release(&self);
    async fn subscribe(&self) -> EventStream;
}
```

The eventual public local API should use a Unix domain stream socket with JSON-RPC 2.0 messages,
framed as one UTF-8 JSON value per line. It should support multiple clients, request/response calls,
and daemon-initiated notifications. "Public" means documented and stable for local clients, not
exposed over the network.

Initial method groups are expected to cover:

- `system.hello` and `system.status`
- system-connected Bluetooth device refresh, listing, attachment, and release
- settings get and set
- recording start, stop, and list
- event subscription for device, attachment, audio statistics, recording, and errors

The API has its own negotiated major version, independent of the application version and the
JSON-RPC `2.0` field. Within API v1, changes are additive, clients ignore unknown fields and events,
and existing meanings are not reused. A breaking protocol gets a new major version and may use a
new endpoint such as `micflurry-control-v2.sock`.

Run the daemon per user. Place its socket under a short per-user runtime path, restrict the directory
to mode `0700` and the socket to `0600`, and verify peer ownership where practical. Do not bind a TCP
listener by default. Aggregate high-rate audio telemetry before publishing it, normally to about
5–10 updates per second.

When the socket API becomes public, add `docs/control-api.md`, a machine-readable schema, and small
reference clients. Third-party clients must be able to implement the wire protocol without linking
the GPL daemon or a GPL-only Rust library. Independently authored schema and SDK code may use a
permissive license, provided it contains no copied BlackHole code; final licensing should be reviewed
before presenting this as a commercial integration guarantee.

## Target repository structure

Grow into this layout only as each milestone needs it:

```text
upstream/BlackHole/                   unmodified Git submodule
upstream/btleplug/                    unmodified Git submodule
patches/mic-flurry.patch              minimal driver patch
patches/btleplug-macos-connected.patch CoreBluetooth retrieval and macOS MTU reporting patch
scripts/                              driver build and verification
packaging/                            package payload and installer scripts

Cargo.toml                            current Rust reference runtime and clients
crates/
├── micflurry-core/                   current hardware-validated reference runtime
├── micflurry-control/                client abstraction and protocol DTOs
├── micflurry-hid-probe/              bounded development feasibility probe
└── micflurry-tui/                    terminal client

Package.swift                          future Swift core packages and executables
Sources/
├── MicFlurryDomain/                  core state and language-independent DTOs
├── MicFlurryATVV/                    ATVV protocol and audio decode
├── MicFlurryAudio/                   CoreAudio adapter and streaming buffer
├── MicFlurryBluetooth/               CoreBluetooth adapter
├── MicFlurryStorage/                 SQLite ownership and migrations
├── MicFlurryControl/                 public local JSON-RPC service
├── MicFlurryHIDProtocol/             private authenticated XPC contract
├── micflurryd/                        per-user core service
└── micflurry-hid-helper/              root-only IOHID seizure service

apps/MicFlurry/                        signed service host; native UI optional
docs/control-api.md                   added when the socket API is made public
docs/TODO-swift-core.md                executable migration and acceptance plan
```

Core packages and the control contract must not depend on a particular UI. Exact module boundaries
can be adjusted when implementation reveals a cleaner dependency graph; the process and ownership
boundaries above should remain stable.

## Planned component identities

Reserve these identifiers for the component split:

- Driver: `io.phateffect.MicFlurry.driver`
- Swift daemon / launchd service: `io.phateffect.MicFlurry.daemon`
- Root HID helper: `io.phateffect.MicFlurry.hid-helper`
- Rust TUI: `io.phateffect.MicFlurry.tui`
- Service host / optional native UI: `io.phateffect.MicFlurry.app`

This is a future migration. The current driver, package receipt, scripts, installed bundle, and
published v0.1 release still use `io.phateffect.MicFlurry`. Change and validate all affected
identifiers together when the restructuring starts.

## Real-time BLE audio sources

MicFlurry targets live short-form voice sessions: audio reaches the Mac while capture is still in
progress rather than being uploaded after recording finishes. A typical session is about 10 seconds
and the hard product limit is 60 seconds. The runtime, and owned firmware where applicable, must
enforce that limit independently of the UI or a final button-release event.

The planned hardware sources are separate GATT profiles, not interchangeable codec modes:

```text
小米语音遥控器 -> Google ATVV 1.0 -> IMA ADPCM decoder -------.
                                                               |-> timestamped mono PCM
ESP32-S3 -> MicFlurry Voice GATT v1 -> Opus reassembly/decoder-'
                                                                    -> streaming resampler
                                                                    -> MicFlurry_2_UID
```

- The first validated hardware is reported by IOHID as `小米语音遥控器`, with manufacturer `MIOM`,
  vendor ID `10007`, and product ID `12984`. MicFlurry keys support on that fingerprint, not on a
  user-editable name or an unverified retail model label.
- The owned ESP32-S3 source will use an independent MicFlurry service and Opus protocol. Google
  ATVV 1.0 does not define Opus, so the custom device must not advertise ATVV UUIDs or treat a
  vendor-specific `0x04` codec bit as part of the ATVV 1.0 contract.
- Both profiles share only the decoded PCM pipeline, CoreAudio output, recording, persistence, and
  control/status abstractions. ATVV control bytes, ADPCM sync state, Opus fragments, and codec-
  specific loss recovery remain behind their profile boundaries.
- This is a real-time best-effort microphone path. Audio queues are bounded and may drop old audio
  to preserve the time domain; do not add recorder-style ACK, resume, commit, or historical replay.

The evidence, protocol corrections, proposed ESP framing, and acceptance criteria are recorded in
`docs/realtime-ble-audio-options.md`. In particular, ATVV `MIC_OPEN` uses the one-byte consumption
mode (`0x00` for real-time playback), not a codec byte. Sessions use the negotiated stream ID and
periodically send `MIC_EXTEND`. On the validated remote, five successful extend writes did not move
the device's 60-second stop; that is an observed firmware boundary rather than a host-enforced limit.

## Delivery sequence

### Milestone 0 — loopback driver baseline (complete)

- Keep BlackHole as an unmodified submodule and maintain only `patches/mic-flurry.patch`.
- Build a universal mono driver reporting USB transport.
- Support 8, 16, 44.1, and 48 kHz, including the 16 kHz mono SInt16 ASR client boundary.
- Ship the unsigned development package used by trusted testers.

### Milestone 1 — polished driver injection topology (complete)

- Expose a visible input-only `MicFlurry` device.
- Add a hidden output-only `MicFlurry Internal` mirror backed by the same driver buffer.
- Give the internal endpoint a stable UID that userspace can resolve through CoreAudio.
- Keep both endpoints mono and validate the existing supported sample rates and ASR conversion path.
- Migrate component identifiers together if this milestone is selected for the naming transition.

### Milestone 2 — foreground Rust vertical slice (implemented; registered hardware validated)

- Add the Rust workspace and keep runtime logic independent of Ratatui.
- Initially run the runtime and TUI in one foreground process using a `LocalControlClient` backed by
  in-process calls or Tokio channels; do not require a daemon, socket, launchd, or `.app` yet.
- Enumerate ATVV peripherals already connected by macOS, correlate CoreBluetooth and IOHID identity,
  and attach only registered hardware fingerprints. Pairing remains a macOS responsibility.
- Decode and resample received audio, then write it to the CoreAudio injection endpoint.
- Support the required CGEvent keyboard actions.
- Read standard BLE Device Information, monitor every IOHID value from the attached fingerprint,
  and allow explicit exclusive seizure for forwarding known remote buttons through CGEvent.
- Save optional recordings as files and store settings and metadata in SQLite.
- Show refresh, attachment, audio, recording, and error status in the TUI.

This milestone proves the complete audio path before adding process lifecycle and IPC complexity.

The foreground workspace, local control abstraction, ATVV v1 implementation, CoreAudio writer,
CGEvent actions, Device Information, IOHID observation/optional seizure, SQLite persistence, WAV
recording, and Ratatui status UI are implemented. Automated
tests cover protocol parsing/decoding, resampling, persistence, and the in-process client. Physical
validation on the registered `小米语音遥控器` fingerprint established:

- `CAPS_RESP`: ATVV 1.00, codec mask `0x02` (16 kHz ADPCM), interaction model `3`, frame size `120`,
  extra configuration `0`, reserved `0`, and no firmware payload;
- HTT `AUDIO_START` reason `3`, 16 kHz audio and a negotiated nonzero stream ID;
- intelligible WAV and visible-device audio with +12 dB default input gain;
- stable short sessions, repeated start/stop, release/reattach, and process restart while preserving
  the macOS-owned Bluetooth connection;
- an exactly 60-second device stop while the button remained held, even after five successful
  `MIC_EXTEND` writes at ten-second intervals. The runtime now independently closes any active stream
  at the same 60-second product limit instead of relying on this firmware behavior.

This validates the registered fingerprint and observed 16 kHz path, not every device marketed under
an RC003/ARN9 label and not arbitrary ATVV peripherals. The runtime now exposes ATT MTU,
notification-size distributions, sync frame gaps, and opt-in notification loss injection. Software
tests cover loss recovery, an 8 kHz sync transition, and the host cutoff policy; an 8 kHz physical
source, deliberate-loss recovery on hardware, and a device that runs beyond 60 seconds remain open
validation work.

### Milestone 2.1 — ESP32-S3 Opus source (planned)

- Freeze a versioned MicFlurry Voice GATT v1 before writing firmware. Use independent 128-bit UUIDs
  with Capabilities/State, Control, and Audio characteristics; do not extend or impersonate ATVV.
- Start with 16 kHz mono SInt16 capture, Opus VOIP, 20 ms frames, 20 kbps CBR, bounded packet sizes,
  notifications for audio, and writes with response for low-rate control.
- Carry a random nonzero session ID, per-Opus-packet sequence, and MTU-safe fragments. The proposed
  v1 audio fragment header is eight bytes and uses 16-bit session/sequence fields because a session
  is capped at 60 seconds.
- Reassemble strictly in order, reject malformed or cross-session fragments, use Opus PLC for
  sequence gaps, and never wait for an application-layer audio retransmission.
- Build separate bounded I2S capture, Opus encode, and BLE notification stages. On congestion, drop
  the oldest complete Opus packet and expose capture, queue, notification, gap, jitter, and
  CoreAudio-underrun statistics.
- Require bonding and link encryption before audio subscription or start. Provide a physical pairing
  window, visible capture indication, and an explicit bond-reset path appropriate to the hardware.
- Validate both default-MTU fragmentation and enlarged-MTU single-notification operation, typical
  10-second and hard-limit 60-second streams, and at least 100 consecutive start/stop sessions.
- Keep fixed-ratio streaming resampling for this short-session scope while measuring queue depth at
  60 seconds. Add adaptive clock recovery only if measurements require it or the product later adds
  long-running continuous capture.

This milestone is complete only when an ESP32-S3 prototype streams live audio into the current
foreground Rust runtime and a consumer records intelligible audio from visible `MicFlurry`. It does
not include reliable stored-recording transfer, OTA, a daemon, or a custom driver IPC path.

### Milestone 3 — independent daemon and public local API

- Implement `micflurryd` and `micflurry-hid-helper` as the Swift core described in
  [docs/TODO-swift-core.md](docs/TODO-swift-core.md). Preserve the current Rust runtime as the
  hardware-validated behavioral reference until the Swift acceptance matrix passes.
- Run `micflurryd` as a per-user LaunchAgent, not as root.
- Implement `SocketControlClient` and the versioned Unix socket protocol described above.
- Convert the TUI into a normal socket client with no direct SQLite, Bluetooth, or CoreAudio access.
- After the root probe validates exclusive capture, add the narrow root `micflurry-hid-helper` and
  its private authenticated XPC protocol. It seizes all interfaces matching the registered RC003
  fingerprint atomically and streams all raw reports/usages; `micflurryd` owns mapping and CGEvent
  output. Do not add a suppression fallback in this milestone.
- Add launchd lifecycle integration, API documentation, schemas, and reference clients.
- Verify simultaneous TUI and third-party clients, reconnect behavior, migrations, permissions,
  helper crash/lease release, fast user switching, and that UI exit never stops active daemon work.

### Milestone 4 — optional clients and product packaging

- Build optional TUI, CLI, web, or native clients using the same public control API; do not duplicate
  daemon business logic.
- Package the driver, independent core services, service host, and any optional clients into coherent
  artifacts while preserving headless operation.
- Add upgrade and uninstall handling for the HAL plug-in, launchd service, database, and application.
- Pursue Developer ID signing, notarization, and low-friction Homebrew distribution only when the
  project is ready to pay for and maintain the required Apple release credentials.

Polished clients are intentionally deferred until the Swift daemon/helper boundary and public API
are stable. The signed `.app` service host is packaging infrastructure and must not couple the core
to a particular UI.

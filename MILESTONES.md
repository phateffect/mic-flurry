# MicFlurry milestones

This document records the planned architecture and delivery sequence discussed on 2026-08-11. It
describes future work, not necessarily the behavior of the current release. `README.md` and
`AGENTS.md` remain authoritative for what is implemented today.

## Product boundary

MicFlurry has a required core and replaceable user interfaces:

```text
MicFlurry Core
├── MicFlurry.driver       virtual microphone and CoreAudio loopback
└── micflurryd             Bluetooth, audio, persistence, and control service

Optional clients
├── CLI / TUI              Rust
├── tray app               Swift
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
├── per-user micflurryd service
└── /Applications/MicFlurry.app             optional Swift tray client
```

Headless installation of the driver and daemon must remain possible. TUI and tray packaging may be
offered separately once maintaining multiple artifacts is useful.

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

Programs that only need to produce PCM should use the standard CoreAudio endpoint. If a non-CoreAudio
streaming API is ever required, design it later as a separate binary audio protocol rather than
mixing high-rate frames into the control API.

## Ownership of state

The daemon owns business logic and all mutable state. Clients must not read or write its SQLite
database directly.

```text
micflurryd
├── SQLite       settings, known devices, recording metadata, schema version
├── memory       connection, scan, stream, level, and error state
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
    async fn scan(&self);
    async fn connect(&self, device: DeviceId);
    async fn subscribe(&self) -> EventStream;
}
```

The eventual public local API should use a Unix domain stream socket with JSON-RPC 2.0 messages,
framed as one UTF-8 JSON value per line. It should support multiple clients, request/response calls,
and daemon-initiated notifications. "Public" means documented and stable for local clients, not
exposed over the network.

Initial method groups are expected to cover:

- `system.hello` and `system.status`
- Bluetooth scan, device listing, pairing, connect, and disconnect
- settings get and set
- recording start, stop, and list
- event subscription for device, pairing, audio statistics, recording, and errors

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
patches/mic-flurry.patch              minimal driver patch
scripts/                              driver build and verification
packaging/                            package payload and installer scripts

Cargo.toml                            Rust workspace, added with runtime work
crates/
├── micflurry-core/                   Bluetooth, audio, recording, domain logic
├── micflurry-control/                client abstraction and protocol DTOs
├── micflurry-daemon/                 daemon executable and socket server
└── micflurry-tui/                    terminal client

apps/MicFlurryTray/                   future Swift tray application
docs/control-api.md                   added when the socket API is made public
```

Core and control crates must not depend on terminal or Swift UI concerns. Exact crate boundaries can
be adjusted when implementation reveals a cleaner dependency graph; the process and ownership
boundaries above should remain stable.

## Planned component identities

Reserve these identifiers for the component split:

- Driver: `io.phateffect.MicFlurry.driver`
- Rust daemon / launchd service: `io.phateffect.MicFlurry.daemon`
- Rust TUI: `io.phateffect.MicFlurry.tui`
- Swift tray app: `io.phateffect.MicFlurry.tray`

This is a future migration. The current driver, package receipt, scripts, installed bundle, and
published v0.1 release still use `io.phateffect.MicFlurry`. Change and validate all affected
identifiers together when the restructuring starts.

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

### Milestone 2 — foreground Rust vertical slice

- Add the Rust workspace and keep runtime logic independent of Ratatui.
- Initially run the runtime and TUI in one foreground process using a `LocalControlClient` backed by
  in-process calls or Tokio channels; do not require a daemon, socket, launchd, or `.app` yet.
- Implement Bluetooth discovery and pairing plus predefined GATT profiles, beginning with ATVV.
- Decode and resample received audio, then write it to the CoreAudio injection endpoint.
- Support the required CGEvent keyboard actions.
- Save optional recordings as files and store settings and metadata in SQLite.
- Show pairing, connection, audio, recording, and error status in the TUI.

This milestone proves the complete audio path before adding process lifecycle and IPC complexity.

### Milestone 3 — independent daemon and public local API

- Extract `micflurryd` from the foreground runtime and run it independently of all UIs.
- Implement `SocketControlClient` and the versioned Unix socket protocol described above.
- Convert the TUI into a normal socket client with no direct SQLite, Bluetooth, or CoreAudio access.
- Add launchd lifecycle integration, API documentation, schemas, and reference clients.
- Verify simultaneous TUI and third-party clients, reconnect behavior, migrations, permissions, and
  that UI exit never stops active daemon work.

### Milestone 4 — Swift tray and product packaging

- Build a Swift tray app using the same public control API; do not duplicate daemon business logic.
- Package driver, independent daemon, and optional tray into a coherent installer while preserving
  headless installation.
- Add upgrade and uninstall handling for the HAL plug-in, launchd service, database, and application.
- Pursue Developer ID signing, notarization, and low-friction Homebrew distribution only when the
  project is ready to pay for and maintain the required Apple release credentials.

The tray is intentionally deferred until the foreground Rust path and daemon boundary are stable.
This keeps the first implementation inspectable and avoids making `.app` lifecycle decisions before
the service behavior is proven.

# Swift core migration TODO

This document is the execution plan for replacing the Milestone 2 foreground Rust runtime with two
independent Swift core services. Start this work from a clean worktree after the validated Milestone
2/HID-probe branch has been merged. The existing Rust implementation is the behavioral reference
until the Swift implementation passes the same automated and hardware checks.

## Language and process decision

The product core is macOS-only and is dominated by CoreBluetooth, CoreAudio, CGEvent, IOHID, XPC,
TCC, launchd, and ServiceManagement lifecycle. Use Swift for both core processes so they share one
native XPC contract and use Apple's typed ownership and availability model at the root boundary.
The Swift services target Apple Silicon (`arm64`) and macOS 15 or later; Intel and older macOS
compatibility are outside the Swift migration scope.

```text
replaceable UI / CLI / web client
              │ versioned local JSON-RPC over a Unix socket
              ▼
micflurryd                                             Swift, per-user LaunchAgent
├── CoreBluetooth / ATVV / CoreAudio
├── SQLite / recordings / mappings
├── CGEvent output
└── authenticated NSXPC client
              │ private authenticated XPC
              ▼
micflurry-hid-helper                                   Swift, root LaunchDaemon
└── exclusive IOHID capture of signed-catalog devices
```

The BlackHole-derived AudioServerPlugIn remains its upstream C++ implementation and patch. Clients
are deliberately language-independent; the existing Rust TUI may remain a reference client, and
future CLI, web, or native clients may use any language that implements the public control API.

Do not use a Rust daemon with a Swift helper. That split would still require a Swift/C ABI bridge for
bidirectional NSXPC callbacks and would duplicate protocol models across the security boundary. Do
not introduce Rust into the Swift core unless a future measured DSP or cross-platform requirement
has a material advantage that outweighs another ABI boundary.

## Preserved product boundaries

- `micflurryd` runs in the logged-in user's launchd session, never as root.
- `micflurry-hid-helper` owns only trusted-device IOHID enumeration, atomic seizure, raw input
  forwarding, and deterministic release.
- Bluetooth connection, ATVV GATT control, audio decoding/output, SQLite, mapping policy, recordings,
  and CGEvent output stay in `micflurryd`.
- ATVV GATT control remains authoritative for voice start and stop. An observed HID key such as F5 is
  input data, not audio-session authority.
- IOHID seizure does not establish or own the Bluetooth connection. ATVV audio must continue while
  HID is seized.
- The helper captures every raw report and decoded value from every interface belonging to the
  selected supported physical device. It does not contain a per-button allowlist.
- There is no suppression fallback. If authenticated XPC or atomic seizure fails, remapping is
  unavailable and the daemon reports the failure.
- The producer continues to write PCM through the standard CoreAudio output API. Do not add PCM to
  XPC, the public control socket, or the AudioServerPlugIn.

## Phase 0 — clean baseline

- [x] Merge the validated Milestone 2/HID-probe commits into the target branch.
- [x] Create a new worktree from that merged commit and verify `git status --short` is empty.
- [x] Run `mise run rust-check`, `./scripts/check-patch.sh`, and
  `./scripts/check-btleplug-patch.sh` to establish the reference baseline.
- [x] Keep the current Rust runtime and its tests buildable until Swift parity is accepted. Do not
  delete it merely to make the migration look complete.
- [x] Do not reuse either discarded helper experiment. Define the Swift package and XPC contract
  cleanly from this document.

## Phase 1 — Swift project and test boundaries

- [x] Add one Swift package for reusable core modules and tests. Keep framework imports at platform
  adapters rather than allowing CoreBluetooth/AppKit concerns into domain types.
- [x] Create modules equivalent to these responsibilities; exact target names may be refined without
  changing process ownership:

  ```text
  MicFlurryDomain          settings, status, mappings, events, device profiles
  MicFlurryATVV            capability/control parsing, ADPCM, session state
  MicFlurryAudio           resampling, bounded ring buffer, AudioUnit output
  MicFlurryBluetooth       CoreBluetooth discovery, GATT, Device Information
  MicFlurryStorage         SQLite migrations, settings, recording metadata
  MicFlurryControl         public Unix-socket JSON-RPC schemas and server
  MicFlurryHIDProtocol     private NSXPC protocols and bounded data models
  micflurryd               per-user executable and lifecycle composition
  micflurry-hid-helper     root executable, trusted catalog, seize lease
  ```

- [x] Add deterministic Swift tests for pure modules without Bluetooth, HAL, TCC, root, or launchd.
- [x] Put compiler/build caches under repository-specific `.build` or `/tmp` paths and keep generated
  products ignored.
- [x] Establish formatting, tests, bundle/plist linting, and signature verification as `mise` tasks.

## Phase 2 — port the behavioral core

Current checkpoint: the Swift daemon composition now connects the ATVV session state machine,
streaming resampler, gain/metering, recording, SQLite owner, and an AUHAL output whose render
callback consumes a preallocated SPSC buffer. The CoreBluetooth adapter retrieves only peripherals
already connected by macOS, verifies the registered RC003 IOHID fingerprint, reads Device
Information, and attaches with bounded rollback. Rust and Swift consume shared ATVV, resampling,
and legacy-schema fixtures. On 2026-08-13, an RC003 hardware smoke test completed a 16 kHz ATVV
start/stream/stop session with 292 notifications, 70,080 decoded source samples, and zero dropped
output samples. AVFoundation then captured 63,430 nonzero SInt16 samples from the visible
`MicFlurry` input, proving the standard CoreAudio loopback path. The complete acceptance matrix,
including 8 kHz, deliberate loss, repeated sessions, and HID seizure independence, remains
outstanding.

- [x] Port ATVV v1 capability negotiation, `START_SEARCH`, `AUDIO_START`, `AUDIO_SYNC`,
  `AUDIO_STOP`, stream IDs, high-nibble-first IMA ADPCM, and the 60-second host cutoff.
- [x] Port the current loss-recovery and frame-gap accounting, including 16-bit wraparound and the
  deliberate one-based notification-drop diagnostic.
- [x] Port 8 and 16 kHz source handling and streaming conversion to the configured CoreAudio rate.
  Prefer a system converter when its streaming latency and reset behavior pass tests; otherwise use
  a small tested implementation or Accelerate. Do not optimize by intuition.
- [x] Use a preallocated bounded single-producer/single-consumer ring buffer at the AudioUnit render
  boundary. The render callback must not allocate, log, access SQLite, await an actor, or take a
  contended general-purpose lock.
- [x] Port input gain, level metering, dropped-sample counters, optional Float32 WAV recording,
  button mappings, and status/event models.
- [x] Create shared protocol fixtures and compare Swift results with the accepted Rust tests for
  capability parsing, ADPCM output, sync recovery, resampling counts, mappings, and database
  migrations.

## Phase 3 — implement `micflurryd`

- [x] Run `micflurryd` as a per-user LaunchAgent so CoreBluetooth, CoreAudio, Accessibility, user
  SQLite state, and CGEvent all belong to the active login session.
- [x] Retrieve macOS-connected ATVV peripherals through the public CoreBluetooth API; do not scan for
  or initiate pairing as a side effect of startup.
- [x] Read the standard Device Information Service and correlate the peripheral with the registered
  IOHID identity before automatic attachment.
- [x] Make BLE/GATT state independent of HID-helper availability. Helper reconnect, release, or crash
  must not disconnect ATVV or end an active audio session.
- [x] Bound private HID event queues and yield between event batches so a report storm cannot starve
  helper heartbeats, public control requests, Bluetooth, or audio state transitions.
- [x] Open `MicFlurry_2_UID` through standard CoreAudio and retain the current 16 kHz SInt16 external
  contract through CoreAudio conversion.
- [x] Keep one SQLite owner in the daemon, with tested migrations from the current schema and no
  direct database access from clients.
- [x] Implement the public versioned JSON-RPC 2.0 Unix-domain socket. Put it in a per-user directory
  owned by the user with mode `0700`; support multiple clients, request/response calls, and daemon
  notifications. Never carry PCM on this socket.
- [x] Adapt the Rust TUI into a socket client only after the daemon API is stable. UI exit must not
  stop Bluetooth, audio, recording, or HID capture owned by the daemon. The Rust client decoded the
  live Swift status and displayed the attached RC003/ATVV/HID state; quitting left the LaunchAgent
  running and the device attached.

## Phase 4 — implement the root HID helper

### Trusted device catalog

- [x] Embed a versioned device-profile manifest as a signed helper resource. The first entry matches
  RC003 by manufacturer `MIOM`, vendor `0x2717`, and product `0x32b8`; optional product/transport
  constraints may be added only after hardware validation.
- [x] Support future devices by shipping another signed profile. XPC callers may supply only a
  trusted `profileID` and, when needed, an enumerated `physicalDeviceID`; never accept arbitrary
  VID/PID, IORegistry paths, match dictionaries, executable paths, or configuration file locations.
- [x] Validate schema version, duplicate profile IDs, maximum interface/report sizes, and profile
  capture policy before accepting a lease.

### Atomic capture

- [x] Enumerate every IOHID interface matching the profile, group interfaces by physical-device ID,
  and require an explicit physical ID when more than one physical device matches.
- [x] Open all interfaces with `kIOHIDOptionsTypeSeizeDevice`. If any open or callback setup fails,
  roll back every interface already opened before returning failure.
- [x] Forward every bounded raw input report and every decoded usage/value with monotonic sequence,
  physical device ID, and interface index. Unknown commands must remain observable.
- [x] On stop, unregister/unschedule callbacks before freeing buffers or callback contexts, then close
  every interface. Make repeated stop and partial-start rollback safe.

### Authenticated XPC and lease

- [x] Define the shared `@objc` NSXPC protocols and `Codable` payloads in
  `MicFlurryHIDProtocol`; negotiate a protocol version and reject oversized messages/events.
- [x] Configure the listener's code-signing requirement before activation. Production policy must
  require the expected `io.phateffect.MicFlurry.daemon` identifier, Apple generic anchor, and the
  project's Developer ID Team ID. An identifier-only ad-hoc requirement is development-only and must
  never ship.
- [x] Have `micflurryd` independently require the expected helper identifier and production signing
  chain. Authentication must be mutual.
- [x] Accept only a non-root client whose effective UID equals the active console user's UID. Reject
  stale sessions after fast user switching.
- [x] Permit one capture owner at a time. Bind ownership to the accepted XPC connection, not to a PID
  supplied in a message.
- [x] Require heartbeats with a short signed-policy timeout (initial target: 10 seconds). Release
  immediately on XPC invalidation/interruption and on explicit stop; release on timeout even while
  the connection remains open.
- [x] Ensure a connection invalidated during capture startup cannot leave a late-opened interface
  seized. Test this race explicitly.
- [x] The helper must not post CGEvents, open CoreBluetooth/CoreAudio, access the user database, or
  interpret a voice button as ATVV state.

## Phase 5 — service host, signing, and installation

Current checkpoint: the UI-less host executable, embedded `BundleProgram` plists, registration
commands, and an unsigned structural app builder are implemented. The builder verifies the complete
payload, plist identities, arm64 slices, and macOS 15 deployment target, and supports inside-out
Developer ID signing when an identity becomes available. The generated development artifact remains
unsigned and uninstalled; no service has been registered. The signed/notarized host and release TCC
tests remain gates.

For the current owner-and-trusted-friends scope, a parallel private route is accepted: an
ad-hoc-signed app installed at the same fixed path with traditional LaunchAgent/LaunchDaemon plists.
The peers pin build-specific CDHashes as well as identifiers, and the installer retains explicit
administrator, Gatekeeper, and TCC approval. This does not satisfy or remove the future public
Developer ID/notarization gates.

- [x] Use `/Applications/MicFlurry.app` as the signed service host even when no native UI is shipped.
  A UI-less host preserves headless operation while providing the container required for modern
  ServiceManagement registration. The private route uses the same fixed host with ad-hoc signing.
- [x] Embed the per-user plist in `Contents/Library/LaunchAgents` and the helper plist in
  `Contents/Library/LaunchDaemons`. Use `BundleProgram` paths so registered services follow the app
  bundle as supported by `SMAppService`.
- [x] Register/status/unregister the services through `SMAppService.agent(plistName:)` and
  `SMAppService.daemon(plistName:)`, handling user approval and `requiresApproval` explicitly.
- [x] Keep the host in `/Applications`; Apple recommends that location when an embedded daemon must
  be accessible before login.
- [x] Add all required usage descriptions and entitlements to the correct signed bundle/process.
  Input Monitoring consent belongs to the final helper identity; Bluetooth and Accessibility belong
  to the user daemon's identity/session. The unsandboxed macOS bundle contains the required
  `NSBluetoothAlwaysUsageDescription`; Input Monitoring and Accessibility use their TCC identities
  and do not define additional purpose-string keys in the target SDK.
- [ ] Sign nested code inside-out with Developer ID, verify designated requirements, notarize the
  complete app/package, staple the ticket, and repeat the LaunchDaemon TCC test using the release
  identity. The current machine has no Developer ID identity, so this release gate cannot be claimed
  by an ad-hoc build.
- [x] Keep development installation narrowly scoped and recoverable. Never edit TCC databases or
  disable Gatekeeper; uninstall must release capture, unregister both services, and remove only exact
  MicFlurry paths.
- [x] Preserve GPL source, exact submodule revisions, patches, build scripts, and upstream attribution
  for distributed MicFlurry components. The private ZIP includes LICENSE, SOURCE.md, and an exact
  Source snapshot containing both upstream trees, patches, fixtures, manifests, and build scripts.

## Phase 6 — acceptance matrix

### Automated

- [x] All pure Swift protocol, ADPCM, resampling, mapping, migration, framing, and lease tests pass.
- [x] Fuzz or property-test malformed ATVV control packets, HID manifest input, public JSON-RPC
  framing, and private XPC payload bounds. Deterministic property-style tests cover every truncation
  of known ATVV controls, all invalid codec bytes, hundreds of malformed JSON/XPC payloads, manifest
  boundary values, and oversized JSON-RPC frames.
- [ ] Verify app/plist structure, bundle IDs, architectures, signing requirements, notarization,
  package payload, uninstall targets, patch application, and `git diff --check`.

### Root-helper security and lifecycle

Private-build checkpoint (2026-08-13): the traditional LaunchDaemon passed mutual identifier/CDHash
authentication, Input Monitoring gating, two-interface RC003 seizure, raw and decoded volume-up/down
press/release capture, responsive control during capture, explicit release, and release on daemon
termination. A second capture validated paired press/release events and raw reports for up, down,
left, right, OK/select, and back. A forced helper restart released its active lease, preserved the
daemon's BLE attachment, automatically reconnected XPC, and allowed another seizure without a
daemon restart. Suspending the daemon with an open XPC lease also triggered the independent
10-second heartbeat timeout; both queues were unregistered and the tester confirmed original volume
control returned before the daemon resumed. A sleep/wake test initially found a stale logical lease
after IOHID re-enumeration; per-interface removal callbacks were added, and the repaired build then
reported inactive/monitor with `device_removed`, unregistered both queues, retained BLE attachment,
and restored the original volume action after wake. The re-enumerated interface was then seized
again without restarting either service; system volume was suppressed during capture and restored
after an explicit stop returned the daemon to inactive/monitor. System logs confirmed both IOHID
queues were unregistered after each repaired release. This is strong private-route evidence, but it
does not yet cover all 13 previously observed non-empty reports, the Developer ID rejection cases,
fast user switching, or signed public-release gates below.

- [ ] The signed daemon connects; a wrong bundle ID, unsigned client, wrong Team ID, root client, and
  non-console user are rejected before a capture command is honored.
- [x] A caller cannot seize unregistered hardware or override the signed manifest. Tests reject
  unknown profiles before enumeration, mismatched manufacturer/VID/PID, unknown physical device
  IDs, and public-control attempts to supply a profile, VID/PID, or IORegistry path.
- [x] RC003 seizure suppresses every original macOS action and forwards all observed reports/usages,
  including the previously observed 13 non-empty button reports and OK. A private LaunchDaemon pass
  observed `0x35`, `0x3e`, `0x4a`, `0x4f`, `0x50`, `0x51`, `0x52`, `0x65`, `0x66`, `0x80`,
  `0x81`, `0xf1`, and `0x28`, each with its release report, with an empty missing set.
- [x] Explicit stop, daemon disconnect/crash, XPC interruption, heartbeat timeout, startup failure,
  helper termination, sleep/wake, and upgrade all restore the original device promptly. Hardware
  runs cover each runtime path; atomic-start rollback and invalidation races also have unit tests.
- [ ] Fast user switching releases the previous user's lease and never streams HID data across login
  sessions.

### BLE/audio independence

- [x] ATVV audio starts, streams, and stops normally while every RC003 HID interface is seized. The
  private LaunchDaemon run delivered 225 16 kHz notifications and 54,000 decoded frames with zero
  drops while also capturing the voice-key `0x3e` press/release reports.
- [x] GATT start/stop remains authoritative and is still visible to `micflurryd`; HID helper restart
  does not disconnect Bluetooth or corrupt the negotiated ATVV stream. After a forced helper
  restart, automatic XPC reconnection and reseizure succeeded, and the next 16 kHz voice session
  delivered 322 notifications and 77,280 decoded frames with zero drops. A later sleep test exposed
  a stale CoreBluetooth attachment; periodic health checking and known-device recovery were added.
  The repaired daemon automatically reattached at ATT MTU 515 and completed three consecutive
  16 kHz start/stop sessions without errors; the final session decoded 73,440 frames with zero drops.
- [ ] Validate 8 and 16 kHz sources, deliberate loss followed by `AUDIO_SYNC`, the 60-second cutoff,
  repeated sessions, recording, gain, and PCM delivery through installed `MicFlurry`. Hardware has
  validated 16 kHz, repeated sessions, installed-driver PCM, and a +12 dB recording run: 631 BLE
  notifications, 151,440 decoded frames, zero drops, and a mono 48 kHz Float32 WAV with 454,318
  samples (454,093 nonzero) whose SQLite metadata matched exactly. The available RC003 has not
  negotiated an 8 kHz source; 8 kHz, injected loss/AUDIO_SYNC, and the 60-second cutoff currently
  pass shared fixture/unit tests but remain non-hardware evidence.
- [x] Run `mise run verify-asr` against the installed release candidate to preserve the 16 kHz mono
  SInt16 producer/consumer contract.

### Public service behavior

- [x] Simultaneous TUI/CLI/third-party clients receive consistent state; reconnecting a client does
  not duplicate actions or stop daemon work. Two live socket clients received the same initial
  state and HID-active broadcast; disconnecting the client that started capture left daemon capture
  active, another client stopped it, and a fresh connection observed inactive/monitor.
- [x] Database migration preserves settings, known devices, and recording metadata. The accepted
  Rust schema has no persisted mappings table; current mappings are compiled policy, so no phantom
  migration was added. Fixture tests cover v1-to-v2 migration and reopen behavior, while the live
  migrated database retained settings, RC003 identity, and matching WAV metadata.
- [ ] UI-free login startup, service approval changes, app relocation/upgrade, and uninstall have
  documented, repeatable outcomes.

## Completion gate

The migration is complete only after the Swift daemon/helper satisfy the acceptance matrix on signed
release-like bundles. At that point, decide in a separate reviewed change whether the Rust
Milestone 2 runtime should be archived or removed. Passing unit tests alone is not permission to
delete the hardware-validated reference implementation or the bounded root probe.

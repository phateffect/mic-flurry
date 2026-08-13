# Swift core migration TODO

This document is the execution plan for replacing the Milestone 2 foreground Rust runtime with two
independent Swift core services. Start this work from a clean worktree after the validated Milestone
2/HID-probe branch has been merged. The existing Rust implementation is the behavioral reference
until the Swift implementation passes the same automated and hardware checks.

## Language and process decision

The product core is macOS-only and is dominated by CoreBluetooth, CoreAudio, CGEvent, IOHID, XPC,
TCC, launchd, and ServiceManagement lifecycle. Use Swift for both core processes so they share one
native XPC contract and use Apple's typed ownership and availability model at the root boundary.

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

- [ ] Merge the validated Milestone 2/HID-probe commits into the target branch.
- [ ] Create a new worktree from that merged commit and verify `git status --short` is empty.
- [ ] Run `mise run rust-check`, `./scripts/check-patch.sh`, and
  `./scripts/check-btleplug-patch.sh` to establish the reference baseline.
- [ ] Keep the current Rust runtime and its tests buildable until Swift parity is accepted. Do not
  delete it merely to make the migration look complete.
- [ ] Do not reuse either discarded helper experiment. Define the Swift package and XPC contract
  cleanly from this document.

## Phase 1 — Swift project and test boundaries

- [ ] Add one Swift package for reusable core modules and tests. Keep framework imports at platform
  adapters rather than allowing CoreBluetooth/AppKit concerns into domain types.
- [ ] Create modules equivalent to these responsibilities; exact target names may be refined without
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

- [ ] Add deterministic Swift tests for pure modules without Bluetooth, HAL, TCC, root, or launchd.
- [ ] Put compiler/build caches under repository-specific `.build` or `/tmp` paths and keep generated
  products ignored.
- [ ] Establish formatting, tests, bundle/plist linting, and signature verification as `mise` tasks.

## Phase 2 — port the behavioral core

- [ ] Port ATVV v1 capability negotiation, `START_SEARCH`, `AUDIO_START`, `AUDIO_SYNC`,
  `AUDIO_STOP`, stream IDs, high-nibble-first IMA ADPCM, and the 60-second host cutoff.
- [ ] Port the current loss-recovery and frame-gap accounting, including 16-bit wraparound and the
  deliberate one-based notification-drop diagnostic.
- [ ] Port 8 and 16 kHz source handling and streaming conversion to the configured CoreAudio rate.
  Prefer a system converter when its streaming latency and reset behavior pass tests; otherwise use
  a small tested implementation or Accelerate. Do not optimize by intuition.
- [ ] Use a preallocated bounded single-producer/single-consumer ring buffer at the AudioUnit render
  boundary. The render callback must not allocate, log, access SQLite, await an actor, or take a
  contended general-purpose lock.
- [ ] Port input gain, level metering, dropped-sample counters, optional Float32 WAV recording,
  button mappings, and status/event models.
- [ ] Create shared protocol fixtures and compare Swift results with the accepted Rust tests for
  capability parsing, ADPCM output, sync recovery, resampling counts, mappings, and database
  migrations.

## Phase 3 — implement `micflurryd`

- [ ] Run `micflurryd` as a per-user LaunchAgent so CoreBluetooth, CoreAudio, Accessibility, user
  SQLite state, and CGEvent all belong to the active login session.
- [ ] Retrieve macOS-connected ATVV peripherals through the public CoreBluetooth API; do not scan for
  or initiate pairing as a side effect of startup.
- [ ] Read the standard Device Information Service and correlate the peripheral with the registered
  IOHID identity before automatic attachment.
- [ ] Make BLE/GATT state independent of HID-helper availability. Helper reconnect, release, or crash
  must not disconnect ATVV or end an active audio session.
- [ ] Open `MicFlurry_2_UID` through standard CoreAudio and retain the current 16 kHz SInt16 external
  contract through CoreAudio conversion.
- [ ] Keep one SQLite owner in the daemon, with tested migrations from the current schema and no
  direct database access from clients.
- [ ] Implement the public versioned JSON-RPC 2.0 Unix-domain socket. Put it in a per-user directory
  owned by the user with mode `0700`; support multiple clients, request/response calls, and daemon
  notifications. Never carry PCM on this socket.
- [ ] Adapt the Rust TUI into a socket client only after the daemon API is stable. UI exit must not
  stop Bluetooth, audio, recording, or HID capture owned by the daemon.

## Phase 4 — implement the root HID helper

### Trusted device catalog

- [ ] Embed a versioned device-profile manifest as a signed helper resource. The first entry matches
  RC003 by manufacturer `MIOM`, vendor `0x2717`, and product `0x32b8`; optional product/transport
  constraints may be added only after hardware validation.
- [ ] Support future devices by shipping another signed profile. XPC callers may supply only a
  trusted `profileID` and, when needed, an enumerated `physicalDeviceID`; never accept arbitrary
  VID/PID, IORegistry paths, match dictionaries, executable paths, or configuration file locations.
- [ ] Validate schema version, duplicate profile IDs, maximum interface/report sizes, and profile
  capture policy before accepting a lease.

### Atomic capture

- [ ] Enumerate every IOHID interface matching the profile, group interfaces by physical-device ID,
  and require an explicit physical ID when more than one physical device matches.
- [ ] Open all interfaces with `kIOHIDOptionsTypeSeizeDevice`. If any open or callback setup fails,
  roll back every interface already opened before returning failure.
- [ ] Forward every bounded raw input report and every decoded usage/value with monotonic sequence,
  physical device ID, and interface index. Unknown commands must remain observable.
- [ ] On stop, unregister/unschedule callbacks before freeing buffers or callback contexts, then close
  every interface. Make repeated stop and partial-start rollback safe.

### Authenticated XPC and lease

- [ ] Define the shared `@objc` NSXPC protocols and `Codable` payloads in
  `MicFlurryHIDProtocol`; negotiate a protocol version and reject oversized messages/events.
- [ ] Configure the listener's code-signing requirement before activation. Production policy must
  require the expected `io.phateffect.MicFlurry.daemon` identifier, Apple generic anchor, and the
  project's Developer ID Team ID. An identifier-only ad-hoc requirement is development-only and must
  never ship.
- [ ] Have `micflurryd` independently require the expected helper identifier and production signing
  chain. Authentication must be mutual.
- [ ] Accept only a non-root client whose effective UID equals the active console user's UID. Reject
  stale sessions after fast user switching.
- [ ] Permit one capture owner at a time. Bind ownership to the accepted XPC connection, not to a PID
  supplied in a message.
- [ ] Require heartbeats with a short signed-policy timeout (initial target: 10 seconds). Release
  immediately on XPC invalidation/interruption and on explicit stop; release on timeout even while
  the connection remains open.
- [ ] Ensure a connection invalidated during capture startup cannot leave a late-opened interface
  seized. Test this race explicitly.
- [ ] The helper must not post CGEvents, open CoreBluetooth/CoreAudio, access the user database, or
  interpret a voice button as ATVV state.

## Phase 5 — service host, signing, and installation

- [ ] Use `/Applications/MicFlurry.app` as the signed service host even when no native UI is shipped.
  A UI-less host preserves headless operation while providing the container required for modern
  ServiceManagement registration.
- [ ] Embed the per-user plist in `Contents/Library/LaunchAgents` and the helper plist in
  `Contents/Library/LaunchDaemons`. Use `BundleProgram` paths so registered services follow the app
  bundle as supported by `SMAppService`.
- [ ] Register/status/unregister the services through `SMAppService.agent(plistName:)` and
  `SMAppService.daemon(plistName:)`, handling user approval and `requiresApproval` explicitly.
- [ ] Keep the host in `/Applications`; Apple recommends that location when an embedded daemon must
  be accessible before login.
- [ ] Add all required usage descriptions and entitlements to the correct signed bundle/process.
  Input Monitoring consent belongs to the final helper identity; Bluetooth and Accessibility belong
  to the user daemon's identity/session.
- [ ] Sign nested code inside-out with Developer ID, verify designated requirements, notarize the
  complete app/package, staple the ticket, and repeat the LaunchDaemon TCC test using the release
  identity. The current machine has no Developer ID identity, so this release gate cannot be claimed
  by an ad-hoc build.
- [ ] Keep development installation narrowly scoped and recoverable. Never edit TCC databases or
  disable Gatekeeper; uninstall must release capture, unregister both services, and remove only exact
  MicFlurry paths.
- [ ] Preserve GPL source, exact submodule revisions, patches, build scripts, and upstream attribution
  for distributed MicFlurry components.

## Phase 6 — acceptance matrix

### Automated

- [ ] All pure Swift protocol, ADPCM, resampling, mapping, migration, framing, and lease tests pass.
- [ ] Fuzz or property-test malformed ATVV control packets, HID manifest input, public JSON-RPC
  framing, and private XPC payload bounds.
- [ ] Verify app/plist structure, bundle IDs, architectures, signing requirements, notarization,
  package payload, uninstall targets, patch application, and `git diff --check`.

### Root-helper security and lifecycle

- [ ] The signed daemon connects; a wrong bundle ID, unsigned client, wrong Team ID, root client, and
  non-console user are rejected before a capture command is honored.
- [ ] A caller cannot seize unregistered hardware or override the signed manifest.
- [ ] RC003 seizure suppresses every original macOS action and forwards all observed reports/usages,
  including the previously observed 13 non-empty button reports and OK.
- [ ] Explicit stop, daemon disconnect/crash, XPC interruption, heartbeat timeout, startup failure,
  helper termination, sleep/wake, and upgrade all restore the original device promptly.
- [ ] Fast user switching releases the previous user's lease and never streams HID data across login
  sessions.

### BLE/audio independence

- [ ] ATVV audio starts, streams, and stops normally while every RC003 HID interface is seized.
- [ ] GATT start/stop remains authoritative and is still visible to `micflurryd`; HID helper restart
  does not disconnect Bluetooth or corrupt the negotiated ATVV stream.
- [ ] Validate 8 and 16 kHz sources, deliberate loss followed by `AUDIO_SYNC`, the 60-second cutoff,
  repeated sessions, recording, gain, and PCM delivery through installed `MicFlurry`.
- [ ] Run `mise run verify-asr` against the installed release candidate to preserve the 16 kHz mono
  SInt16 producer/consumer contract.

### Public service behavior

- [ ] Simultaneous TUI/CLI/third-party clients receive consistent state; reconnecting a client does
  not duplicate actions or stop daemon work.
- [ ] Database migration preserves settings, known devices, mappings, and recording metadata.
- [ ] UI-free login startup, service approval changes, app relocation/upgrade, and uninstall have
  documented, repeatable outcomes.

## Completion gate

The migration is complete only after the Swift daemon/helper satisfy the acceptance matrix on signed
release-like bundles. At that point, decide in a separate reviewed change whether the Rust
Milestone 2 runtime should be archived or removed. Passing unit tests alone is not permission to
delete the hardware-validated reference implementation or the bounded root probe.

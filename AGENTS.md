# MicFlurry project agreements

This file records the project decisions agreed as of 2026-08-13. Agents working in this repository
must preserve these decisions unless the user explicitly changes them.

## Product goal

MicFlurry registers a macOS microphone that other applications can select as an input device. A
producer continuously writes PCM through the standard CoreAudio output API; consumers capture the
same samples from the MicFlurry input.

```text
producer -> MicFlurry Internal output -> BlackHole loopback buffer -> MicFlurry input -> consumer
```

The producer and driver remain separate programs. Do not introduce a custom IPC protocol or move
PCM ingestion into the driver for the MVP.

## Current driver contract (Milestone 1)

- Name: `MicFlurry`
- Bundle ID: `io.phateffect.MicFlurry`
- Visible input device: `MicFlurry`, UID `MicFlurry_UID`, one input and no output
- Hidden injection device: `MicFlurry Internal`, UID `MicFlurry_2_UID`, no input and one output
- Native HAL format: mono 32-bit Float PCM
- ASR client format: signed 16-bit little-endian PCM, mono, 16 kHz through standard CoreAudio
  conversion on both the producer and consumer boundaries
- Supported rates: 8,000, 16,000, 44,100, and 48,000 Hz
- Default rate: 48,000 Hz
- Reported device transport: USB
- Architectures: universal `arm64` and `x86_64`
- Plug-in factory UUID: independent from upstream BlackHole

USB is a compatibility report used for applications that filter virtual devices. It does not make
MicFlurry real USB hardware. Keep the patch scoped to `kAudioDevicePropertyTransportType`; do not
change other transport properties without a demonstrated compatibility need.

## Upstream strategy

BlackHole is an unmodified submodule at `upstream/BlackHole`. Never make or commit edits inside the
submodule working tree.

MicFlurry maintains a small patch at `patches/mic-flurry.patch`. The patch currently changes only:

1. device transport from Virtual to USB
2. the CFPlugIn factory UUID
3. output stream and output control ownership from the visible input device to the internal output
   device, as required by the split mirror topology

Names, bundle identity, manufacturer, channel count, sample rates, endpoint visibility and
input/output presence, and the empty upstream icon setting are supplied through
`GCC_PREPROCESSOR_DEFINITIONS` in `scripts/build-driver.sh`.

When updating BlackHole:

1. move the submodule pointer to an intentional commit or tag
2. run `./scripts/check-patch.sh`
3. refresh only the MicFlurry patch if required
4. build and validate the universal driver
5. commit the submodule pointer and patch together

Do not copy upstream source into this repository or replace the submodule with a merged upstream
history.

## Build and packaging

- `scripts/build-driver.sh` exports a clean submodule snapshot, applies the patch in `.build`, builds
  with Xcode, removes upstream branding resources, and ad-hoc signs `build/MicFlurry.driver`.
- Build intermediates stay under `.build`; generated driver and package artifacts remain ignored.
- `scripts/build-package.sh <version>` rebuilds the driver, creates an unsigned test `.pkg`, and
  emits a SHA-256 file under `dist`.
- Release packages install only `/Library/Audio/Plug-Ins/HAL/MicFlurry.driver` and create the package
  receipt `io.phateffect.MicFlurry`.
- `scripts/build-friend-distribution.sh <version>` (mise task `friend-dist`) builds the all-in-one
  friend zip: driver plus the ad-hoc private service app, double-click `Install/Uninstall
  MicFlurry.command` wrappers from `packaging/friend`, a friend-facing README, and the GPL source
  snapshot. Its installers reuse `private-install-root.sh`/`private-uninstall-root.sh` and add only
  driver install/removal plus a `coreaudiod` restart, all behind one native administrator prompt.
- Never commit `.build`, `build`, `dist`, DerivedData, or local macOS metadata.

Before release, run at minimum:

```bash
./scripts/check-patch.sh
./scripts/build-package.sh <version>
bash -n scripts/*.sh packaging/scripts/*
git diff --check
```

Also verify bundle ID, factory UUID, ad-hoc signature, `arm64`/`x86_64` architectures, package
payload, and checksum. After installing the candidate, run `./scripts/verify-asr-format.swift` to
verify the 16 kHz mono SInt16 producer and consumer contract through AUHAL.

## Installation and operational safety

Installation writes to the system HAL directory and requires explicit user authorization. Restarting
`coreaudiod` interrupts system audio. Do not perform either operation merely as part of a build.

Never disable Gatekeeper globally. The current GitHub Release package is intentionally unsigned and
unnotarized because the project does not have a paid Developer ID. Trusted testers may approve the
download through System Settings → Privacy & Security. Public frictionless distribution and an
official Homebrew Cask are deferred until Developer ID signing and notarization are available.

Use `INSTALL.md` for agent-driven installation and diagnosis. Prefer a reboot for a user-facing
installer; `sudo killall coreaudiod` is the faster development path.

## Sandboxed agent workflow

- Do not repeatedly invoke plain `sudo` from a non-interactive agent shell. For an installation or
  `coreaudiod` restart explicitly requested by the user, use the native macOS administrator prompt
  (for example, AppleScript `do shell script ... with administrator privileges`) and keep the exact
  target limited to MicFlurry. An authorization prompt does not waive the safety rules above.
- Repo builds and Rust tests must write inside the repository. Compiler/module caches that tools
  insist on placing outside the workspace must use a MicFlurry-specific directory under `/tmp`;
  never redirect a broad home directory or shared system cache.
- Swift is the only production core. The Rust workspace contains only the optional socket TUI demo;
  do not add Bluetooth, CoreAudio, SQLite, or HID ownership back to Rust.
- Use `mise run verify-asr` instead of invoking the Swift verifier directly. It puts Swift and Clang
  module caches under `/tmp`. CoreAudio device access can still require running this task in the
  host context because a filesystem-writable sandbox may expose an empty HAL device list.
- `mise run micflurry -- <arguments>` runs the Rust TUI as a pure socket client of `micflurryd`.
  Pass `--socket PATH` for an isolated test daemon. The TUI must never open SQLite, Bluetooth, or
  CoreAudio directly, and quitting it must not stop daemon-owned work.
- `mise run ctl -- <command>` (or `scripts/micflurryctl.py` directly) sends JSON-RPC requests to
  the running daemon's control socket: `status`, `devices`, `refresh`, `connect <uuid>`,
  `release`, `settings`, and raw `call <method> [params-json]`. Use it instead of ad-hoc
  socket clients. Hardware details verified on real remotes are recorded in
  `docs/known-remotes.md`; keep that file current when new hardware is attached.
- After compiling changes to `micflurryd`, the service host, or the HID helper, complete the
  post-build workflow: run `mise run check`; run `mise run swift-private-install` to rebuild,
  validate, stage under `.build/private-service-install`, and install through the native
  administrator prompt; reconnect or reload the affected feature; then verify it against live
  hardware. If macOS Input Monitoring must be toggled for a new ad-hoc signature, toggle
  `/Applications/MicFlurry.app` and run `mise run swift-private-reload` to reinstall the exact
  staged build before continuing verification.
- Put repeatable multi-step shell workflows under `scripts/` and expose operator-facing workflows
  as named tasks in `mise.toml`, so approvals apply to stable, reviewable commands. Use
  `mise run keymap-input-check` for the fixed 15-second remote-input observation window; do not
  issue ad-hoc agent commands beginning with `sleep N` or combine sleeps with follow-up commands.
- Private distribution to a small trusted tester group may use the repository's ad-hoc-signed
  traditional LaunchAgent/LaunchDaemon package instead of `SMAppService`. Its daemon and helper must
  mutually pin the expected identifiers and build-specific CDHashes, install only the documented
  exact paths, and retain native administrator authorization, Gatekeeper, and TCC approval. Keep the
  Developer ID/notarized `SMAppService` route as the public-distribution design.
- Treat filesystem access, host-service access, and administrator authorization as separate
  concerns. `/tmp` solves cache/state writes only; it does not grant CoreAudio, Bluetooth,
  Accessibility, HAL installation, or service-restart privileges.

## Roadmap boundaries

- The current Milestone 1 topology exposes a visible input-only `MicFlurry` backed by a hidden
  output-only `MicFlurry Internal` mirror device.
- Milestone 2's Rust foreground runtime has been removed after the Swift core refactor. The retained
  `micflurry-tui` is a demo UI and talks only to the public local control socket.
- The first predefined BLE profile is Google ATVV v1. Audio notifications are high-nibble-first IMA
  ADPCM at 8 or 16 kHz and are resampled in userspace before standard CoreAudio output to
  `MicFlurry_2_UID`.
- Runtime settings, known devices, and recording metadata live in SQLite. Optional recordings are
  mono Float32 WAV files. Clients must use the control abstraction rather than opening SQLite.
- The Swift daemon reads the standard BLE Device Information Service and correlates the exact
  attached hardware UUID. Exclusive IOHID seizure belongs only to the helper and must release the
  device on detach, disconnect, failure, and shutdown.
- `micflurryd` is a per-user LaunchAgent. The separate root LaunchDaemon named
  `io.phateffect.MicFlurry.hid-helper` owns only IOHID seizure
  and reports raw input to `micflurryd` over a private authenticated XPC boundary. Bluetooth,
  CoreAudio, SQLite, mapping policy, and CGEvent output remain in the per-user daemon.
- Implement the core processes, `micflurryd` and `micflurry-hid-helper`, in Swift. The
  AudioServerPlugIn remains the upstream-derived C++ driver, and UI/control clients remain language
  independent. Swift is the sole runtime implementation.
- Target the Swift core services and service host at Apple Silicon (`arm64`) and macOS 15 or later.
  Intel and older macOS compatibility are outside the Swift migration scope.
- Use `/Applications/MicFlurry.app` as the signed ServiceManagement host for the Swift LaunchAgent
  and LaunchDaemon even if no native UI is shipped. Core packages and public control contracts must
  not depend on TUI, web, or native UI concerns.
- The remapping path is seizure-only. Do not add an IOHID-plus-CGEvent suppression fallback
  unless the user explicitly changes this decision. Seize every IOHID interface matching the
  registered RC001/RC003 structured fingerprint and capture every raw report and decoded usage; do
  not use advertised names or IOHID product strings for identity, and do not require a
  per-button usage allowlist at the helper boundary.
- Additional GATT profiles may be added behind the same runtime/control boundaries after ATVV
  hardware validation; do not couple profile-specific code to the TUI.

Do not add custom driver IPC or move PCM away from standard CoreAudio unless the user explicitly
changes the product contract.

## Licensing and branding

The repository, driver patch, build tooling, and distributed MicFlurry driver use GPL-3.0. Preserve
the root `LICENSE`, upstream attribution, exact corresponding source, submodule commit, and build
scripts for every binary release.

BlackHole names, logos, package artwork, and branding are not licensed for a modified distribution.
Do not add `BlackHole.icns` or other upstream branding to MicFlurry artifacts.

A separate commercial application that only writes PCM through standard CoreAudio APIs is normally
treated as a separate work; distributing MicFlurry with it still requires full GPL compliance for
the MicFlurry component. This is project guidance, not legal advice. Avoid linking or copying GPL
driver code into a non-GPL application.

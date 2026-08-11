# MicFlurry project agreements

This file records the project decisions agreed as of 2026-08-11. Agents working in this repository
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
- Use `mise run verify-asr` instead of invoking the Swift verifier directly. It puts Swift and Clang
  module caches under `/tmp`. CoreAudio device access can still require running this task in the
  host context because a filesystem-writable sandbox may expose an empty HAL device list.
- Use `mise run micflurry -- <arguments>` for agent smoke tests. Its default SQLite database is
  `/tmp/micflurry-dev.db`; pass a later `--database PATH` to override it. Do not use the production
  database in `~/Library/Application Support` for automated tests.
- Treat filesystem access, host-service access, and administrator authorization as separate
  concerns. `/tmp` solves cache/state writes only; it does not grant CoreAudio, Bluetooth,
  Accessibility, HAL installation, or service-restart privileges.

## Roadmap boundaries

- The current Milestone 1 topology exposes a visible input-only `MicFlurry` backed by a hidden
  output-only `MicFlurry Internal` mirror device.
- Milestone 2 adds a foreground Rust process composed of `micflurry-control`, `micflurry-core`, and
  `micflurry-tui`. Runtime logic stays independent of Ratatui and is reached through
  `LocalControlClient`; do not add a daemon or socket before Milestone 3.
- The first predefined BLE profile is Google ATVV v1. Audio notifications are high-nibble-first IMA
  ADPCM at 8 or 16 kHz and are resampled in userspace before standard CoreAudio output to
  `MicFlurry_2_UID`.
- Runtime settings, known devices, and recording metadata live in SQLite. Optional recordings are
  mono Float32 WAV files. Clients must use the control abstraction rather than opening SQLite.
- Additional GATT profiles may be added behind the same runtime/control boundaries after ATVV
  hardware validation; do not couple profile-specific code to the TUI.

Do not begin BLE/GATT or custom driver IPC work unless the user explicitly advances the roadmap.

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

# MicFlurry project agreements

This file records the project decisions agreed as of 2026-08-11. Agents working in this repository
must preserve these decisions unless the user explicitly changes them.

## Product goal

MicFlurry registers a macOS microphone that other applications can select as an input device. A
producer continuously writes PCM through the standard CoreAudio output API; consumers capture the
same samples from the MicFlurry input.

```text
producer -> MicFlurry output -> BlackHole loopback buffer -> MicFlurry input -> consumer
```

The producer and driver remain separate programs. Do not introduce a custom IPC protocol or move
PCM ingestion into the driver for the MVP.

## v0.1 driver contract

- Name: `MicFlurry`
- Bundle ID: `io.phateffect.MicFlurry`
- Device UID: `MicFlurry_UID`
- Channels: one input and one output, both visible
- Sample format: 32-bit Float PCM
- Supported rates: exactly 16,000, 44,100, and 48,000 Hz
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

Names, bundle identity, manufacturer, channel count, sample rates, input/output presence, and the
empty upstream icon setting are supplied through `GCC_PREPROCESSOR_DEFINITIONS` in
`scripts/build-driver.sh`.

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
payload, and checksum.

## Installation and operational safety

Installation writes to the system HAL directory and requires explicit user authorization. Restarting
`coreaudiod` interrupts system audio. Do not perform either operation merely as part of a build.

Never disable Gatekeeper globally. The current GitHub Release package is intentionally unsigned and
unnotarized because the project does not have a paid Developer ID. Trusted testers may approve the
download through System Settings → Privacy & Security. Public frictionless distribution and an
official Homebrew Cask are deferred until Developer ID signing and notarization are available.

Use `INSTALL.md` for agent-driven installation and diagnosis. Prefer a reboot for a user-facing
installer; `sudo killall coreaudiod` is the faster development path.

## Roadmap boundaries

- v0.1 keeps the mature BlackHole input/output loopback as the injection path.
- v0.2 may expose a visible input-only `MicFlurry` backed by a hidden output-only mirror device.
- v0.3 may add remote/GATT receive, decoding, and userspace resampling before CoreAudio output.

Do not begin hidden-device, BLE/GATT, or custom driver IPC work unless the user explicitly advances
the roadmap.

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

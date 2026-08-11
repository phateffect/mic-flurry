# MicFlurry

MicFlurry is a macOS virtual microphone based on
[BlackHole](https://github.com/ExistentialAudio/BlackHole). A producer resolves the hidden
`MicFlurry Internal` endpoint by UID and writes audio to it; consuming applications see only the
`MicFlurry` microphone input.

```text
PCM producer -> MicFlurry Internal output -> shared loopback buffer -> MicFlurry input -> consuming app
```

## Install MicFlurry

MicFlurry currently ships as an unsigned, unnotarized test package for macOS. It is intended for
developers and trusted testers.

The published v0.1.0 package is the Milestone 0 baseline and still exposes input and output on the
same visible device. The Milestone 1 topology described elsewhere in this README is currently
available from source and will apply to the next package release.

1. Open the [latest GitHub Release](https://github.com/phateffect/mic-flurry/releases/latest).
2. Download both `MicFlurry-<version>.pkg` and `MicFlurry-<version>.pkg.sha256`.
3. Put the two files in the same directory and verify the download in Terminal:

   ```bash
   cd ~/Downloads
   shasum -a 256 -c MicFlurry-0.1.0.pkg.sha256
   ```

4. Double-click `MicFlurry-0.1.0.pkg` and follow the Installer prompts.
5. If macOS blocks the package, first attempt to open it, then go to **System Settings → Privacy &
   Security**, find the blocked package, and choose **Open Anyway**. Do not disable Gatekeeper
   globally.
6. Restart the Mac after installation. For development, restarting CoreAudio is often enough:

   ```bash
   sudo killall coreaudiod
   ```

7. Open **Audio MIDI Setup** or **System Settings → Sound → Input** and confirm that `MicFlurry`
   appears. Restart applications that were open during installation because they may cache the
   audio-device list.

With the published v0.1.0 package, select `MicFlurry` for both producer output and consumer input.
With a current source build, consumers select `MicFlurry`, while producers resolve the hidden
injection endpoint using CoreAudio's `kAudioHardwarePropertyTranslateUIDToDevice` and the stable UID
`MicFlurry_2_UID`; it intentionally does not appear in normal device pickers.

If the driver file exists at `/Library/Audio/Plug-Ins/HAL/MicFlurry.driver` but the device does not
appear, restart CoreAudio, reopen Audio MIDI Setup, and finally reboot macOS. See [INSTALL.md](INSTALL.md)
for detailed verification and troubleshooting commands.

## Driver profile

- Device and driver name: `MicFlurry`
- Bundle ID: `io.phateffect.MicFlurry`
- Visible input: `MicFlurry`, UID `MicFlurry_UID`, one input channel and no output channels
- Hidden injection output: `MicFlurry Internal`, UID `MicFlurry_2_UID`, no input channels and one
  output channel
- Independent CFPlugIn factory UUID
- Transport type: USB (for applications that reject virtual transport devices)
- Format: 1-channel, 32-bit Float PCM
- Supported sample rates: 8 kHz, 16 kHz, 44.1 kHz, and 48 kHz (48 kHz default)

The driver's native HAL buffer remains mono `Float32`, as required by the upstream BlackHole data
path. Standard CoreAudio clients can write and capture signed 16-bit mono PCM at 16 kHz: AUHAL
performs the conversion at the application boundary. This is the common `SInt16LE / mono / 16000 Hz`
format expected by ASR services, so applications do not need to modify the driver or its ring buffer.
The 8 kHz mode is also available for telephony ASR models; 16 kHz remains the recommended default
for general speech recognition.

### ASR compatibility target

The baseline is based on the vendors' current official streaming-ASR documentation:

| Service | PCM requirement | Typical upload cadence |
| --- | --- | --- |
| [Doubao / Volcengine Realtime ASR](https://www.volcengine.com/docs/6893/1527759) | raw PCM, 16 kHz, 16-bit, mono | official example uses 100 ms chunks (3,200 bytes) |
| [iFLYTEK real-time transcription](https://static.xfyun.cn/doc/asr/rtasr/API.html) | `pcm_s16le`, 16 kHz, 16-bit | 40 ms / 1,280 bytes recommended |
| [Alibaba Cloud real-time speech recognition](https://help.aliyun.com/zh/isi/developer-reference/api-reference) | mono, 16-bit; 8 or 16 kHz | API-dependent; 16 kHz is the general model target |

Chunk size and WebSocket pacing belong in the ASR uploader, not in this driver. At 16 kHz mono
SInt16, 20/40/100 ms contain 640/1,280/3,200 bytes respectively.

BlackHole remains an unmodified Git submodule. `patches/mic-flurry.patch` contains the only source
differences: the USB transport type, the independent plug-in UUID, and output-object ownership for
the split mirror topology. Names, visibility, formats, and other customization are passed to
`xcodebuild` by `scripts/build-driver.sh`.

## Clone and build

Requirements: macOS with full Xcode installed (Command Line Tools alone are insufficient).

```bash
git clone --recurse-submodules git@github.com:phateffect/mic-flurry.git
cd mic-flurry
./scripts/check-patch.sh
./scripts/build-driver.sh
```

For an existing clone:

```bash
git submodule update --init --recursive
```

The ad-hoc signed development driver is written to `build/MicFlurry.driver`. Distribution builds
need to be signed with your Developer ID and notarized separately.

## Build a release-style test installer

Build an unsigned `.pkg` like the artifact users will eventually download from GitHub Releases:

```bash
./scripts/build-package.sh 0.1.0
```

This produces:

```text
dist/MicFlurry-0.1.0.pkg
dist/MicFlurry-0.1.0.pkg.sha256
```

Verify a downloaded package and checksum from the directory containing both files:

```bash
shasum -a 256 -c MicFlurry-0.1.0.pkg.sha256
```

Double-click the package to install it. Because this test package has no Developer ID signature or
notarization ticket, a Mac that downloaded it from the internet may require explicit approval in
System Settings → Privacy & Security. Do not disable Gatekeeper globally. Reboot after installation
so CoreAudio loads the driver.

## Development installation

Close applications currently using audio, copy the driver into the system HAL directory, then
restart CoreAudio:

```bash
sudo cp -R build/MicFlurry.driver /Library/Audio/Plug-Ins/HAL/
sudo killall coreaudiod
```

Verify the following in Audio MIDI Setup:

1. `MicFlurry` appears as an input-only audio device with one channel.
2. `MicFlurry Internal` does not appear in normal device pickers but resolves by UID
   `MicFlurry_2_UID` and has one output channel.
3. Both endpoints offer 8,000, 16,000, 44,100, and 48,000 Hz.
4. Playing a test signal to `MicFlurry Internal` can be recorded from `MicFlurry`.

Run the executable compatibility check after installation. It verifies the device rates and asks
AUHAL to initialize both the producer and consumer sides as signed Int16, mono, 16 kHz while the
driver remains at its current native rate:

```bash
./scripts/verify-asr-format.swift
```

Some applications cache the audio-device list and must be restarted after driver installation.
Applications also need macOS microphone permission before they can capture from MicFlurry.

## Updating BlackHole

```bash
git -C upstream/BlackHole fetch origin
git -C upstream/BlackHole checkout <new-commit-or-tag>
./scripts/check-patch.sh
```

Commit the new submodule pointer only after the patch check and a driver build pass. If the patch no
longer applies, refresh only `patches/mic-flurry.patch`; do not edit the submodule working tree.

## Roadmap

- Milestone 0: visible input + output loopback baseline
- Milestone 1: visible input-only device backed by a hidden output-only mirror device (complete)
- Milestone 2: foreground Rust Bluetooth-to-CoreAudio vertical slice (implemented; physical ATVV
  remote validation remains)

The component boundaries, daemon/control API design, persistence decisions, and staged delivery plan
are documented in [MILESTONES.md](MILESTONES.md).

## Foreground Rust prototype

Milestone 2 adds a Rust workspace with UI-independent control and runtime crates plus a Ratatui
foreground client. It discovers BLE remotes, connects through CoreBluetooth (which triggers macOS
pairing when the remote requires it), negotiates the Google ATVV v1 GATT profile, decodes its IMA
ADPCM stream, resamples 8 or 16 kHz speech to the configured driver rate, and writes mono `Float32`
to `MicFlurry_2_UID` through AUHAL.

Install the pinned toolchain and verify the workspace:

```bash
mise install
mise run rust-check
```

Install and activate the MicFlurry driver as described above, allow Bluetooth access for the
terminal application under System Settings → Privacy & Security → Bluetooth, then run:

```bash
mise run micflurry
```

The terminal also needs Accessibility permission before CGEvent keyboard actions work. The runtime
does not install the driver, restart CoreAudio, or change either permission itself. Use `s` to scan,
the arrow keys and Return to pair/connect, `r` to record, and `q` to quit. The complete controls,
state paths, protocol behavior, and hardware checklist are in
[docs/milestone-2.md](docs/milestone-2.md).

## License

MicFlurry, including its driver patches and build tooling, is distributed under GPL-3.0. See
`LICENSE` and the upstream project for details. Non-GPL distribution may require a separate license
from Existential Audio. BlackHole branding and artwork are not included in MicFlurry distributions.

# MicFlurry

MicFlurry is a macOS virtual microphone based on
[BlackHole](https://github.com/ExistentialAudio/BlackHole). An application writes audio to the
MicFlurry output and another application reads the same audio from the MicFlurry input.

The first MVP intentionally exposes both sides of one loopback device:

```text
PCM producer -> MicFlurry output -> shared loopback buffer -> MicFlurry input -> consuming app
```

## Install MicFlurry

MicFlurry currently ships as an unsigned, unnotarized test package for macOS. It is intended for
developers and trusted testers.

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

To use it, select `MicFlurry` as the output device in the application producing audio, then select
`MicFlurry` as the microphone/input device in the application receiving audio. Both sides are
visible in the v0.1 MVP.

If the driver file exists at `/Library/Audio/Plug-Ins/HAL/MicFlurry.driver` but the device does not
appear, restart CoreAudio, reopen Audio MIDI Setup, and finally reboot macOS. See [INSTALL.md](INSTALL.md)
for detailed verification and troubleshooting commands.

## Driver profile

- Device and driver name: `MicFlurry`
- Bundle ID: `io.phateffect.MicFlurry`
- Device UID: `MicFlurry_UID`
- Independent CFPlugIn factory UUID
- Transport type: USB (for applications that reject virtual transport devices)
- Format: 1-channel, 32-bit Float PCM
- Supported sample rates: 8 kHz, 16 kHz, 44.1 kHz, and 48 kHz (48 kHz default)
- Input and output are both visible in v0.1

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
differences: the USB transport type and the independent plug-in UUID. All other customization is
passed to `xcodebuild` by `scripts/build-driver.sh`.

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

1. `MicFlurry` appears as an audio device.
2. It has one input channel and one output channel.
3. Its available sample rates are 8,000, 16,000, 44,100, and 48,000 Hz.
4. Playing a test signal to its output can be recorded from its input.

Run the executable compatibility check after installation. It verifies the device rates and asks
AUHAL to initialize both the producer and consumer sides as signed Int16, mono, 16 kHz. It briefly
changes MicFlurry to 16 kHz and restores the previous rate before exiting:

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

- v0.1: visible input + output loopback and a PCM/test-tone producer
- v0.2: visible input-only device backed by a hidden output-only mirror device
- v0.3: receive, decode, resample, and inject remote audio

The component boundaries, daemon/control API design, persistence decisions, and staged delivery plan
are documented in [MILESTONES.md](MILESTONES.md).

## License

MicFlurry, including its driver patches and build tooling, is distributed under GPL-3.0. See
`LICENSE` and the upstream project for details. Non-GPL distribution may require a separate license
from Existential Audio. BlackHole branding and artwork are not included in MicFlurry distributions.

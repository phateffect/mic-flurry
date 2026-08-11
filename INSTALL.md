# MicFlurry installation runbook for agents

This runbook is for an automation agent installing or diagnosing MicFlurry on a user's Mac. Prefer
the GitHub Release package for user-like testing. Use a source build only for driver development.

## Safety rules

- Installing the driver writes to `/Library/Audio/Plug-Ins/HAL` and requires explicit user
  authorization plus administrator credentials.
- Restarting `coreaudiod` briefly interrupts all system audio. Tell the user before doing it.
- Never disable Gatekeeper globally and never recommend `spctl --master-disable`.
- Do not remove quarantine attributes as a generic workaround. For a browser-downloaded unsigned
  package, use the macOS **Privacy & Security → Open Anyway** flow.
- Do not delete or replace another audio driver. The only installation target in scope is
  `/Library/Audio/Plug-Ins/HAL/MicFlurry.driver`.

## Install a GitHub Release

The example below installs v0.1.0. For another version, update the version in all three URLs and
filenames together.

1. Create an isolated download directory and fetch the package plus checksum:

   ```bash
   micflurry_download_dir="$(mktemp -d)"
   curl -fL \
     -o "$micflurry_download_dir/MicFlurry-0.1.0.pkg" \
     https://github.com/phateffect/mic-flurry/releases/download/v0.1.0/MicFlurry-0.1.0.pkg
   curl -fL \
     -o "$micflurry_download_dir/MicFlurry-0.1.0.pkg.sha256" \
     https://github.com/phateffect/mic-flurry/releases/download/v0.1.0/MicFlurry-0.1.0.pkg.sha256
   ```

2. Verify integrity from the directory containing both files:

   ```bash
   cd "$micflurry_download_dir"
   shasum -a 256 -c MicFlurry-0.1.0.pkg.sha256
   pkgutil --payload-files MicFlurry-0.1.0.pkg | \
     grep -F 'Library/Audio/Plug-Ins/HAL/MicFlurry.driver/Contents/MacOS/MicFlurry'
   ```

   Stop if the checksum or expected payload path does not match. The v0.1.0 package itself is
   intentionally unsigned; the contained driver is ad-hoc signed.

3. With user authorization, install the verified package:

   ```bash
   sudo /usr/sbin/installer \
     -pkg "$micflurry_download_dir/MicFlurry-0.1.0.pkg" \
     -target /
   ```

   If `installer` reports that the package is untrusted or blocked, stop. Ask the user to open the
   package in Finder and approve it through **System Settings → Privacy & Security → Open Anyway**;
   do not bypass the assessment with `spctl` or `xattr`.

4. Restart CoreAudio and reopen clients that enumerate audio devices:

   ```bash
   sudo killall coreaudiod
   ```

   If the device still does not appear, reboot macOS. A reboot is the release-package default because
   it gives CoreAudio a clean driver scan.

5. Verify the installed bundle:

   ```bash
   micflurry_driver=/Library/Audio/Plug-Ins/HAL/MicFlurry.driver
   stat -f '%Su:%Sg %Sp %N' "$micflurry_driver"
   plutil -extract CFBundleIdentifier raw "$micflurry_driver/Contents/Info.plist"
   codesign --verify --deep --strict --verbose=2 "$micflurry_driver"
   file "$micflurry_driver/Contents/MacOS/MicFlurry"
   pkgutil --pkg-info io.phateffect.MicFlurry
   ```

   Expected results:

   - owner/group: `root:wheel`
   - bundle ID and package receipt: `io.phateffect.MicFlurry`
   - code signature verification succeeds with an ad-hoc signature
   - executable contains both `arm64` and `x86_64`

6. Verify device behavior in Audio MIDI Setup:

   - device name: `MicFlurry`
   - transport: USB
   - one input channel and one output channel (the v0.1.0 Milestone 0 topology)
   - available rates: 8,000, 16,000, 44,100, and 48,000 Hz

The current `scripts/verify-asr-format.swift` targets the Milestone 1 split topology and is not
compatible with the published v0.1.0 package.

## Build and install from source

Requirements: full Xcode, not only Command Line Tools.

```bash
git clone --recurse-submodules https://github.com/phateffect/mic-flurry.git
cd mic-flurry
./scripts/check-patch.sh
./scripts/build-driver.sh
```

The output is `build/MicFlurry.driver`. With user authorization:

```bash
sudo cp -R build/MicFlurry.driver /Library/Audio/Plug-Ins/HAL/
sudo killall coreaudiod
```

For a release-style local installer:

```bash
./scripts/build-package.sh <version>
```

## Verify a Milestone 1 source build

After installing the current source candidate with explicit user authorization, verify that:

- visible `MicFlurry` has one input and no output
- hidden `MicFlurry Internal` resolves by UID `MicFlurry_2_UID`, with no input and one output
- both endpoints offer 8,000, 16,000, 44,100, and 48,000 Hz

Then verify the common ASR client format:

```bash
./scripts/verify-asr-format.swift
```

This resolves both endpoints by UID, checks their visibility and channel topology, and asks AUHAL
to initialize `MicFlurry Internal` as the producer and `MicFlurry` as the consumer using signed
16-bit little-endian PCM, mono, 16 kHz while the driver remains at its current native rate. The
driver keeps its native Float32 buffer; CoreAudio performs the application-boundary format
conversion.

## Troubleshooting a missing device

Work from least disruptive to most disruptive:

1. Confirm the exact bundle exists under `/Library/Audio/Plug-Ins/HAL`.
2. Validate its Info.plist, executable architecture, ownership, permissions, and code signature.
3. Close and reopen Audio MIDI Setup, System Settings, and the consuming application.
4. Run `sudo killall coreaudiod` and wait for launchd to restart it.
5. Reboot macOS.
6. Only then inspect recent local CoreAudio/system logs for a bundle-load rejection. Do not use cloud
   log tooling for this local diagnostic.

An installed file does not prove that CoreAudio loaded the plug-in. Signature failures, malformed
Info.plist data, incorrect ownership, cached device enumeration, or a process that has not restarted
can all leave the bundle present while the device remains absent.

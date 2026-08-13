# MicFlurry private distribution

This package is for the project owner and a small group of trusted testers. It uses an ad-hoc-signed
app plus a traditional per-user LaunchAgent and root LaunchDaemon. It is not notarized and does not
use `SMAppService`.

The private build does not use the DEBUG identifier-only XPC bypass. `micflurryd` and
`micflurry-hid-helper` are signed separately, and each process requires both the expected peer
identifier and the exact peer CDHash embedded in the sealed app Info.plist. Updating either service
therefore requires reinstalling the complete matched app.

## Install

1. Verify the `.zip.sha256` file before extracting the archive.
2. Double-click `Install MicFlurry.command` as the logged-in user. Do not run it with `sudo`.
3. Accept the native macOS administrator prompt. The installer replaces only these service paths:

   ```text
   /Applications/MicFlurry.app
   ~/Library/LaunchAgents/io.phateffect.MicFlurry.daemon.plist
   /Library/LaunchDaemons/io.phateffect.MicFlurry.hid-helper.plist
   ```

4. If Gatekeeper blocks the app, approve this exact MicFlurry build through System Settings →
   Privacy & Security. Do not disable Gatekeeper or remove quarantine attributes globally.
5. Grant Bluetooth and Accessibility to the per-user MicFlurry identity when those features request
   them. Grant Input Monitoring to `/Applications/MicFlurry.app` for HID seizure. Never edit the TCC
   database directly.

The audio driver remains a separate installation. Installing these services does not replace or
restart the CoreAudio driver.

The archive includes `SOURCE.md` and an exact `Source/` snapshot containing MicFlurry source,
upstream submodule source, patches, fixtures, and build scripts. Keep them with any copy of the
binary package so recipients receive the corresponding GPL source at the same time.

## Upgrade

Run the newer package's `Install MicFlurry.command`. The privileged step stops the old helper,
stages and verifies the new app, atomically replaces the fixed app path, installs the matching plist,
and starts the helper service. If replacement fails, it restores the previous app and helper plist.
The user LaunchAgent is then replaced and bootstrapped.

Because the ad-hoc CDHash changes when a service binary changes, macOS may require Input Monitoring
or other TCC approval again. Device-catalog-only releases still change the sealed app and should be
treated as full private upgrades.

If seizure reports `TCC deny IOHIDDeviceOpen` after an upgrade, toggling the existing Input
Monitoring switch may be insufficient. Remove the old MicFlurry entry with `-`, add the exact
`/Applications/MicFlurry.app` again with `+`, enable it, and restart the helper through the normal
installer or native administrator prompt. Do not reset or edit the TCC database.

## Uninstall services

Double-click `Uninstall MicFlurry.command` as the logged-in user and accept the administrator
prompt. It stops and removes only the app, LaunchAgent, and LaunchDaemon paths listed above. It leaves
the audio driver, recordings, and user database intact.

The private installer is intentionally separate from the future Developer ID and notarized
`SMAppService` distribution. It is suitable only where every recipient understands and accepts the
manual Gatekeeper and TCC approval steps.

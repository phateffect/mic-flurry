# Swift service host

`/Applications/MicFlurry.app` is the planned UI-less ServiceManagement host. Its payload is:

```text
MicFlurry.app/Contents/MacOS/MicFlurry
MicFlurry.app/Contents/MacOS/micflurryd
MicFlurry.app/Contents/MacOS/micflurry-hid-helper
MicFlurry.app/Contents/Library/LaunchAgents/io.phateffect.MicFlurry.daemon.plist
MicFlurry.app/Contents/Library/LaunchDaemons/io.phateffect.MicFlurry.hid-helper.plist
```

Both launchd plists use `BundleProgram`, so ServiceManagement resolves the executables relative to
the containing application. The helper plist owns only the
`io.phateffect.MicFlurry.hid-helper` Mach service. The per-user daemon starts at login; the helper is
launched on demand by its Mach service.

`mise run swift-app` creates an unsigned structural artifact at `build/MicFlurry.app` and checks its
plists, payload, arm64 architecture, and macOS 15 minimum deployment target. It is not installable
through `SMAppService`: Apple requires a code-signed app, and an app containing a LaunchDaemon must
also be notarized.

When a Developer ID is available, the same build script accepts `MICFLURRY_SIGN_IDENTITY` and the
matching 10-character `MICFLURRY_TEAM_ID`. It signs the two service executables with their distinct
identifiers and signs the host last. Signing alone is not a release: notarization, stapling, and the
release TCC acceptance matrix still have to pass.

The installed host accepts these commands:

```bash
/Applications/MicFlurry.app/Contents/MacOS/MicFlurry status
/Applications/MicFlurry.app/Contents/MacOS/MicFlurry register
/Applications/MicFlurry.app/Contents/MacOS/MicFlurry unregister
/Applications/MicFlurry.app/Contents/MacOS/MicFlurry open-settings
```

Registration is refused unless the containing bundle is exactly `/Applications/MicFlurry.app`.
`register` reports `requires_approval` for the LaunchDaemon rather than treating submission for
approval as activation. `open-settings` is a separate explicit command; registration never opens a
GUI by itself.

The app Info.plist contains the Bluetooth usage description used by the per-user daemon. macOS
Accessibility/PostEvent and Input Monitoring/ListenEvent are TCC identities, not sandbox
entitlements. No app-sandbox entitlement is used: Bluetooth, CoreAudio, the per-user database, and
the local control socket remain owned by `micflurryd`, while the root helper owns only IOHID seizure.

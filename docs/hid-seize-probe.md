# RC003 root IOHID seizure probe

This probe answers one question before MicFlurry implements a privileged helper: can a root process
exclusively open every IOHID interface exposed by the registered RC003 and receive its complete input
stream?

It is a bounded development executable, not a daemon or an installer. It does not use Bluetooth,
CoreAudio, SQLite, CGEvent, XPC, or the production database.

## Matching and capture

The probe matches every IOHID device with the registered immutable fingerprint:

- manufacturer `MIOM`
- vendor ID `0x2717` (`10007`)
- product ID `0x32b8` (`12984`)

It deliberately does not match a Bluetooth UUID or individual button usage. Every matching IOHID
interface must open successfully with `kIOHIDOptionsTypeSeizeDevice`; a partial open is rolled back.
While seized, the probe prints both complete raw input reports and every decoded IOHID usage/value,
including unknown usages. This verifies the device as a whole without maintaining a per-button
allowlist in privileged code.

## Build and run

Build as the normal user:

```bash
mise run hid-seize-probe-build
```

Before elevating, the probe can explicitly request the IOHID ListenEvent permission used by
IOHIDManager/IOHIDDevice:

```bash
target/debug/micflurry-hid-probe --request-access
```

This call is diagnostic: TCC evaluates the identity and responsible-process context of the actual
process. A permission granted to a terminal or foreground application must not be assumed to transfer
to a root process or future LaunchDaemon. Every root probe run prints its own `TCC ListenEvent=...`
status before opening the device.

Run `target/debug/micflurry-hid-probe --duration 30` through the native macOS administrator prompt.
Do not repeatedly invoke plain `sudo` from an agent shell and do not install the probe under
`/Library/LaunchDaemons`.

The successful startup markers are:

```text
MATCH ... interfaces=N
INTERFACE ...
PROBE_READY seized_interfaces=N ...
```

During the bounded window, press every RC003 button at least once and hold a direction and volume
button long enough to produce repeat behavior. `REPORT` lines contain the unmodified input reports;
`VALUE` lines contain IOHID's decoded usages. On normal completion the probe closes every interface
and prints:

```text
PROBE_COMPLETE events=N released_interfaces=N
```

## Acceptance criteria

1. Root opening succeeds for every matched interface; there is no `SEIZE_FAILED` line.
2. The probe observes raw reports for every RC003 button without a known-usage filter.
3. While the probe is active, the original RC003 buttons do not affect macOS.
4. ATVV voice capture still starts and delivers audio while HID is seized.
5. On bounded exit, the original RC003 behavior returns immediately.
6. Repeat the test after Bluetooth reconnect and sleep/wake.
7. Force-terminate the probe once in a separate run and verify that process teardown releases the
   device. Do this only after the bounded normal-exit test has passed.

If any interface cannot be seized as root, do not implement the final helper around an assumption
that root is sufficient. Record the exact IOReturn, ListenEvent access state, responsible-process
context, code signature, and interface properties first.

The initial 2026-08-13 results were:

1. The ad-hoc-signed development binary reported `ListenEvent=denied` in the agent execution
   context; `IOHIDRequestAccess` returned false.
2. The same binary launched as root through AppleScript's administrator shell reported
   `ListenEvent=unknown`, matched one complete RC003 keyboard interface, and failed seizure with
   `0xe00002e2` (`kIOReturnNotPermitted`).
3. Calling `IOHIDRequestAccess` in that root context returned false and changed its observed state
   from `unknown` to `denied`; no usable interactive grant was produced.
4. Input Monitoring was then granted to Terminal and Terminal was restarted. Running the same root
   binary as a `sudo` child of that authorized Terminal reported `ListenEvent=granted`, seized the
   one matching RC003 keyboard interface successfully, captured 140 raw/value events, closed it at
   the 30-second deadline, and reported `released_interfaces=1`.
5. That successful run captured raw reports for usages `0x35`, `0x3e`, `0x4a`, `0x4f`, `0x50`,
   `0x51`, `0x52`, `0x65`, `0x66`, `0x80`, `0x81`, and `0xf1`, plus their release reports. This
   covers TV, voice/F5, Home, all four directions, Menu, Power, both volume buttons, and Back. The
   run did not contain `0x28` (OK/Enter), so that individual command should be pressed in a later
   lifecycle run; the probe has no usage filter and requires no code change to capture it.
6. The tester confirmed that RC003's original macOS actions were completely suppressed for the
   duration of seizure and returned immediately after the probe's normal close. This passes the
   exclusive-capture and normal-release acceptance criteria on the validated machine.

These results establish that the RC003 itself is root-seizable and that all of its input can be read
without a per-button allowlist. They also establish that elevation alone is insufficient: TCC used
the authorized Terminal responsible-process context for the successful development run, while an
AppleScript administrator shell did not receive that grant. A final LaunchDaemon therefore still
needs a stable signed bundle and a supported Input Monitoring authorization path; the Terminal result
proves IOHID feasibility but is not itself a product architecture. The current final plan has no
non-exclusive CGEvent suppression fallback.

## Follow-on helper boundary

If the probe passes, Milestone 3 may add `io.phateffect.MicFlurry.hid-helper` as a root LaunchDaemon.
The helper will expose a private authenticated XPC service, accept only the registered fingerprint,
seize all matching interfaces atomically, stream raw HID input to the active user's `micflurryd`, and
release its lease when that client disconnects. Mapping configuration and CGEvent output remain in
the per-user daemon.

## Development LaunchDaemon probe

The repository also builds an app-like probe bundle with the stable bundle identifier
`io.phateffect.MicFlurry.hid-probe`. This tests the next boundary: whether the same binary can obtain
ListenEvent access and seize RC003 when it is launched by the system launchd domain rather than as a
child of an authorized Terminal.

There is no Developer ID signing identity on the current development machine. Apple requires an app
containing an `SMAppService` LaunchDaemon to be signed and notarized, so this test does not pretend to
validate the final SMAppService packaging. It uses an ad-hoc-signed bundle and a legacy root-owned
LaunchDaemon for one bounded development test. Its designated requirement is cdhash-based and changes
when the binary is rebuilt; any TCC result applies only to that exact build.

Build without administrator privileges:

```bash
mise run hid-seize-launchdaemon-probe-build
```

The build produces the ignored artifact `build/MicFlurry HID Probe.app`. The dedicated root
installer copies it to the exact root-owned path below and bootstraps a job that has no `RunAtLoad`
or `KeepAlive` behavior:

```text
/Library/Application Support/MicFlurry/MicFlurry HID Probe.app
/Library/LaunchDaemons/io.phateffect.MicFlurry.hid-probe.plist
```

Agent-driven installation, launch, and removal must invoke the corresponding repository scripts
through a native macOS administrator prompt. Do not run the scripts through repeated noninteractive
`sudo` calls.

The run script clears only the two probe log files and asks launchd to start one 30-second run:

```text
/var/tmp/micflurry-hid-probe.out.log
/var/tmp/micflurry-hid-probe.err.log
```

On the first run, record `TCC ListenEvent` and the exact open result. If access is not granted, add
the installed `MicFlurry HID Probe.app` under System Settings → Privacy & Security → Input Monitoring
and start the job again. A successful run must meet the same capture, suppression, and release
criteria as the direct root probe. Whether the UI accepts the entry and whether the grant is visible
to a root LaunchDaemon are themselves test results; do not modify the system TCC database.

After testing, run the dedicated uninstaller through the native administrator prompt. It bootstraps
out only `system/io.phateffect.MicFlurry.hid-probe` and removes only the two installed probe paths.
Diagnostic logs remain in `/var/tmp` for the test record.

### LaunchDaemon result — 2026-08-13

This development test passed on macOS 26.4.1 (`25E253`):

1. The root-owned legacy LaunchDaemon loaded successfully in the system launchd domain. Before its
   own Input Monitoring grant it reported `ListenEvent=unknown`, failed seizure with
   `0xe00002e2` (`kIOReturnNotPermitted`), exited once, and did not restart.
2. The installed `MicFlurry HID Probe.app` was manually added to Input Monitoring. On the next
   launchd start, the same system-domain process reported `ListenEvent=granted` and seized the one
   matching RC003 keyboard interface.
3. The 30-second run captured 170 raw/value events and every observed non-empty RC003 report:
   `0x28`, `0x35`, `0x3e`, `0x4a`, `0x4f`, `0x50`, `0x51`, `0x52`, `0x65`, `0x66`, `0x80`,
   `0x81`, and `0xf1`. This includes OK/Enter and all commands captured by the earlier direct probe.
4. The process printed `PROBE_COMPLETE events=170 released_interfaces=1`, launchd recorded exit code
   zero, and the job remained stopped rather than respawning.
5. The tester confirmed that none of the original RC003 actions reached macOS while the system
   LaunchDaemon held the interface, and that normal behavior returned immediately when the bounded
   run exited. This passes exclusive suppression and normal-release acceptance from the actual
   system launchd context.
6. The temporary LaunchDaemon, plist, and installed bundle were removed after the result was
   captured. Logs were intentionally retained under `/var/tmp`.

This proves that a root system LaunchDaemon with its own manually granted Input Monitoring identity
can seize and read the complete registered RC003 on the validated system. It does not yet prove the
release packaging: `SMAppService` registration, Developer ID signing, notarization, authenticated
XPC, leases, crash recovery, and fast-user-switching remain implementation and validation work.

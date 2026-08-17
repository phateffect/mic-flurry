# Swift HID helper implementation notes

`micflurry-hid-helper` is a root LaunchDaemon mechanism for one task: atomically seize every IOHID
interface belonging to a trusted physical device and forward bounded raw reports and decoded values
to the active user's daemon. It does not own Bluetooth, audio, SQLite, mappings, or CGEvent output.

The helper embeds `device-profiles.json`; XPC clients can request only a profile ID and an optional
physical device ID selected from enumeration. Registered profiles include `rc001-v1` and
`rc003-v1` for the trusted `MIOM`, `0x2717:0x32b8` family. The user-editable mapping design never
adds trusted devices or helper profiles. Arbitrary match dictionaries, VID/PID values, IORegistry
paths, and report policies are not part of the protocol.

Capture is serialized under a single connection-owned lease. All matching interfaces open with
`kIOHIDOptionsTypeSeizeDevice` before callbacks are accepted. Any failure unregisters callbacks and
closes every already-open interface in reverse order. Explicit stop, XPC interruption/invalidation,
or a missed 10-second heartbeat releases the lease.

The XPC listener rejects root clients and clients outside the active console user's UID. Before a
connection is activated it applies a code-signing requirement for
`io.phateffect.MicFlurry.daemon`, the Apple generic anchor, and the configured Developer ID Team ID.
Release builds cannot use the identifier-only development requirement. The daemon independently
requires `io.phateffect.MicFlurry.hid-helper`, the Apple generic anchor, and the same configured
Developer ID Team ID before activating its privileged XPC connection.

Do not run the Swift helper directly or as an administrator-shell child. Public distribution uses
the signed and notarized `SMAppService` LaunchDaemon described by the migration TODO. The accepted
owner-and-trusted-testers route uses the repository's ad-hoc private app plus a traditional
LaunchDaemon; peers mutually pin their expected identifiers and build-specific CDHashes, and install
through the dedicated native administrator prompt. The bounded probe remains only for isolated
hardware experiments.

## Private LaunchDaemon hardware result — 2026-08-13

The ad-hoc private app was installed at `/Applications/MicFlurry.app`; its per-user LaunchAgent and
root LaunchDaemon bootstrapped successfully. The daemon and helper accepted each other using the
expected identifiers and embedded peer CDHashes. The first seize attempt was correctly rejected by
TCC until the exact installed app was removed and re-added in Input Monitoring.

After authorization, the helper atomically seized both registered RC003 IOHID interfaces. During a
12-second capture the daemon received 20 bounded raw/value events for volume up and volume down,
including raw report IDs, interface index, monotonic sequence, mapped press, and mapped release.
In a subsequent 25-second capture, the directional, OK, and back buttons produced the expected
`up`, `down`, `left`, `right`, `select`, and `back` mappings. Every mapping had paired press and
release events, with raw keyboard reports `0x52`, `0x51`, `0x50`, `0x4f`, `0x28`, and `0xf1`.
After restoring a deliberately invalidated GATT attachment, a combined seizure/audio run captured
the voice-key report `0x3e` and its release while the independent ATVV channel completed a 16 kHz
start/stream/stop session. It delivered 225 notifications and 54,000 decoded source frames in
3.634 seconds with zero dropped frames, demonstrating that seizing both HID interfaces does not
block the remote's GATT voice control or audio notifications.
The helper was then force-restarted by launchd while holding a capture lease. Its XPC interruption
immediately changed daemon HID state to inactive without clearing the attached BLE device. The new
helper process accepted an automatic XPC reconnect and a fresh seizure without restarting the user
daemon. A post-restart voice session delivered 322 notifications and 77,280 decoded 16 kHz frames
in 5.867 seconds with zero drops, followed by a successful explicit HID release.
For the heartbeat failure case, the user daemon was stopped with `SIGSTOP` while its XPC connection
and capture lease remained open. The helper independently expired the lease after the 10-second
policy window, unregistered both IOHID queues, and reported `heartbeat_timeout`. The daemon was
resumed after 14 seconds, the BLE attachment remained present, and the tester confirmed that the
remote's original macOS volume action had returned before the daemon resumed.
An initial sleep/wake run exposed a distinct lifecycle bug: macOS re-enumerated the RC003 interface
and restored its original behavior, but the helper retained a stale active lease because it had no
IOHID removal callback. The helper now registers a removal callback on every seized interface; the
first removal atomically tears down all interfaces, clears lease ownership, and notifies the daemon.
After installing that fix, a repeat sleep/wake run ended with `hid.active=false`, mode `monitor`, and
`device_removed:00000001001dbb11`; both IOHID queues were unregistered, BLE attachment remained
present, and the tester confirmed that macOS volume control worked after wake. Without restarting
either service, a fresh capture then seized the re-enumerated interface and suppressed the volume
action again. Explicit stop returned the daemon to inactive/monitor with no error, and the tester
confirmed that volume control immediately returned, completing the post-wake reseizure cycle.
The daemon now retains successful capture intent across an unexpected `device_removed`, helper
interruption, or invalidation and retries seizure every two seconds once the attached remote,
trusted profile, and keymap are available. Explicit `stop_hid_capture` and `release` clear that
intent and remain in monitor mode.
Finally, a 60-second full-button pass observed every previously catalogued non-empty keyboard report:
`0x35`, `0x3e`, `0x4a`, `0x4f`, `0x50`, `0x51`, `0x52`, `0x65`, `0x66`, `0x80`, `0x81`, `0xf1`,
and OK/Enter `0x28`. Every pressed report was followed by the empty release report, the missing set
was empty, and explicit stop returned the daemon to inactive/monitor while BLE remained attached.
The same sleep cycle exposed a stale CoreBluetooth attachment separately from HID: the daemon still
reported a connected device but received no GATT control/audio events. The runtime now checks the
active CoreBluetooth peripheral against the system-connected ATVV set every two seconds, clears a
stale attachment, and retries the last known supported device without undoing an explicit user
release. After installing the fix, RC003 automatically reattached with ATT MTU 515 and no stale
error. Three consecutive 16 kHz voice sessions then produced three paired start/stop sequences with
no errors; the final session delivered 306 notifications and 73,440 decoded frames with zero drops.
The control socket remained responsive after HID event batching was made cooperative. Explicit
`v1.stop_hid_capture` succeeded, `hid.active` became false, and system logs confirmed that both HID
queues were unregistered. Separately, terminating the daemon invalidated XPC and caused the helper
to unregister both queues, validating crash/disconnect release without disconnecting the BLE system
link.

# Per-model key mapping configuration design

Status: implemented. `micflurryd` loads the attached model's file, supports click, double-click,
hold, `noop`, and serialized chord sequences, and can reload it through `v1.reload_keymap`.

## File location and ownership

Each supported model has one user configuration file:

```text
~/.config/micflurry/mi-rc001.toml
~/.config/micflurry/mi-rc003.toml
```

A reviewed file can be installed atomically with
`mise run keymap-install -- <model> <source.toml>`, then activated with
`mise run ctl -- reload-keymap` when that model is attached.

`mi-rc001` and `mi-rc003` are stable MicFlurry model IDs. The compiled trusted remote catalog owns
hardware fingerprints and maps each attached remote to one of these IDs. Bluetooth names, IOHID
product strings, fingerprints, usages, report IDs, and helper profiles do not belong in this file.
The root helper never reads it.

## Version 1 example

```toml
schema_version = 1
model = "mi-rc001"

[options]
double_click_ms = 300
hold_ms = 600
sequence_interval_ms = 50

# Simple mappings use a chord string or an ordered chord array.
[keymap]
up = "up"
down = "down"
left = "left"
right = "right"
back = "escape"
home = "command+space"
volume_up = "cmd+ctrl+p"
volume_down = "cmd+ctrl+n"

# Use a subtable when one remote action needs gesture-specific behavior.
[keymap.select]
click = "noop"
double_click = ["cmd+b", "p", "1"]
hold = "cmd+x"
```

The `mi-rc003.toml` file has the same shape with `model = "mi-rc003"`; each model may define
different mappings and options.

## Top-level contract

- `schema_version` is required and version 1 accepts only `1`.
- `model` is required and must equal the filename stem and the model selected by the trusted
  catalog.
- `[options]` contains model-wide key-mapping behavior. Version 1 defines gesture and sequence
  timing fields, while future schema versions may add non-timing behavior here.
- `[keymap]` maps supported semantic remote actions to output behavior.
- Unknown actions, fields, sections, and invalid chords are configuration errors.

For `mi-rc001` and `mi-rc003`, the configurable actions match the physical remote: `power`,
`microphone`, `up`, `down`, `left`, `right`, `select`, `back`, `home`, `menu`, `volume_down`,
`volume_up`, and `tv`. Newly generated files list every available action explicitly, so the file
itself also serves as the editable action reference.
Direction actions default to their matching arrow keys, `select` defaults to `return`, `back`
defaults to `escape`, and other actions without a migrated mapping default to `"noop"`.

The daemon's built-in model profile remains responsible for translating trusted HID usages into
these semantic actions. ATVV control remains authoritative for voice start and stop, so the voice
HID usage is not configurable here.

## Output values and sequences

Every gesture output accepts one of:

```toml
# One simultaneous chord
click = "command+return"

# Complete chords emitted in order
double_click = ["cmd+b", "p", "1"]

# Explicitly emit nothing
hold = "noop"
```

A chord string presses its keys together and releases them in reverse order. An array completely
presses and releases each chord, waits `sequence_interval_ms`, and then starts the next chord. Keys
are never held across array elements.

`noop` is a reserved output value, not a keyboard key. It must appear alone as a string and is
rejected inside an array. Omitting a gesture has the same no-output result in version 1; explicit
`noop` is useful in generated files and documents intent.

Sequences contain 1–16 non-empty chord strings, stop if any step fails, and are serialized so two
remote inputs cannot interleave their steps. Text typing, shell commands, nested sequences, and
holding a generated macOS key across steps are outside version 1.

Chord tokens are case-insensitive and joined with `+`. Canonical modifiers are `fn`, `control`,
`option`, `shift`, and `command`; compatibility aliases are `ctrl`, `alt`, and `cmd`. Plain keys
include letters, digits, Space, Return, Tab, Escape, Delete, arrows, and F1–F12.

## Simple and gesture-specific mappings

A value directly under `[keymap]` is shorthand for its `click` behavior:

```toml
[keymap]
select = "return"
next = ["ctrl+b", "n"]
```

Use a subtable to configure double-click or hold:

```toml
[keymap.select]
click = "noop"
double_click = ["cmd+b", "p", "1"]
hold = "cmd+x"
```

The allowed subtable fields are exactly `click`, `double_click`, and `hold`. Each accepts a chord
string, sequence, or `noop` as described above. An action cannot have both a shorthand value and a
subtable.

## Options and gesture recognition

```toml
[options]
double_click_ms = 300
hold_ms = 600
sequence_interval_ms = 50
```

| Field | Meaning | Default | Version 1 range |
| --- | --- | --- | --- |
| `double_click_ms` | Maximum gap between two short clicks | 300 ms | 100–1000 ms |
| `hold_ms` | Continuous press duration that triggers `hold` | 600 ms | 250–3000 ms |
| `sequence_interval_ms` | Wait between completed chord steps | 50 ms | 0–1000 ms |

Gesture recognition follows these rules:

1. Press/release events are paired by semantic action using monotonic time.
2. If `double_click` is configured, the first short click waits for `double_click_ms`. A second short
   click inside that window cancels `click` and emits `double_click` once.
3. When a continuous press reaches `hold_ms`, `hold` emits once immediately. Its `click` and any
   pending first click are cancelled; release emits nothing further.
4. Hold does not repeat and does not keep the generated macOS chord held. It recognizes the remote
   gesture and then taps the configured chord or sequence once.
5. Without `double_click`, `click` emits immediately on release. Without `hold`, a long physical
   press falls back to `click` on release.
6. Detach, HID capture stop, helper interruption, sleep-related device removal, or configuration
   replacement cancels all pending gesture state without emitting keyboard output.

The daemon owns timers and gesture state. The root helper continues forwarding every bounded raw
report and decoded value without gesture policy.

## Loading and SQLite migration

The loader resolves the trusted model first, then reads exactly
`~/.config/micflurry/<model>.toml` as the logged-in user. It parses and validates an immutable
candidate before replacing the active keymap atomically. An explicit reload failure keeps the last
valid mapping. An invalid file at initial load prevents HID seizure while leaving Bluetooth and
ATVV audio available.

When a model file is missing, the daemon creates it atomically from the legacy SQLite
`action_chords` mapping and then immediately uses the generated TOML. It never overwrites an
existing file. After creation, TOML is authoritative; SQLite remains only as the original migration
source. New control requests that try to update `action_chords` are rejected.

After editing a file, reconnect the remote or run `mise run ctl -- reload-keymap`. A valid reload
atomically replaces the mapping. A failed reload preserves the last valid mapping and reports the
error through control status.

Other settings—including dictation mode/chords, audio, recording, and last connected device—remain
in SQLite unless separately redesigned.

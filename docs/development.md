# Development guide

The production core is the Swift package at the repository root. The only Rust component is an
optional terminal demo client for the language-independent control socket.

## Repository layout

```text
Package.swift, Sources/, Tests/      production Swift core and services
packaging/swift-app/                 public ServiceManagement app templates
packaging/private/                   trusted-tester distribution templates
Cargo.toml, crates/micflurry-tui/    optional Rust socket TUI demo
Fixtures/                            cross-language protocol and migration fixtures
scripts/                             builds, validation, packaging, and hardware tools
scripts/lib/                         sourced shell helpers
patches/, upstream/                  minimal patches and pristine upstream submodules
docs/                                architecture, protocols, operations, and historical research
```

Keep SwiftPM's conventional `Sources/` and `Tests/` layout. Keep driver and upstream preparation
scripts at their documented top-level paths because release and GPL corresponding-source workflows
depend on them. Generated content belongs only in `.build/`, `build/`, `dist/`, or the dedicated
MicFlurry cache directories under `/tmp`.

## Daily commands

Install the pinned tools once with `mise install`, then use the short production-core tasks:

```bash
mise run build
mise run test
mise run lint
mise run check
```

`check` runs Swift formatting and tests plus script syntax, plist validation, the BlackHole patch
check, and `git diff --check`. The optional Rust demo UI is independent of production-core
validation. Run its checks when changing the socket contract or TUI:

```bash
mise run demo-ui-check
```

The previous `swift-build`, `swift-test`, and `swift-check` task names remain available as aliases.

## App and distribution builds

App tasks use version `0.3.0` and build number `1` by default. Override either without editing
`mise.toml`:

```bash
MICFLURRY_VERSION=0.4.0 MICFLURRY_BUILD_NUMBER=2 mise run swift-app
MICFLURRY_VERSION=0.4.0 mise run swift-private-dist
```

Useful focused tasks are:

```bash
mise run swift-app
mise run swift-app-check
mise run swift-private-app
mise run swift-private-test
mise run swift-socket-test
mise run verify-asr
```

The reusable `scripts/swift-package.sh` wrapper owns the Apple Silicon target and the
MicFlurry-specific Swift/Clang/SwiftPM cache paths. Build scripts call the same wrapper, so local,
test, and packaged builds cannot silently drift in platform or cache configuration.

Installation, service registration, CoreAudio restart, and root HID work are deliberately not part
of `check`. Follow `INSTALL.md`, `docs/private-distribution.md`, or `docs/hid-helper.md`; these
operations require explicit authorization and may affect system audio or input handling.

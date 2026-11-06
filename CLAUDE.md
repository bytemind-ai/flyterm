# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FlyTerm is a mobile SSH/Mosh terminal for iOS and Android (Flutter), inspired by iTerm2. It provides a keyboard-friendly terminal experience with AI assistance, layout (split + floating-window) support, and a fully customizable on-screen key bar.

The project is GPL-3.0-or-later. Contributions require a CLA (see [CLA.md](./CLA.md)).

## Architecture

See [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — layering, provider wiring, route map, and the key design decisions (private-key storage, data-driven key bar, `SplitManager` layout state, the synchronous `noteFor()` constraint, the single-place 4 KiB note cap, and why knowledge lives app-side rather than on the servers). Protocol details are in [docs/protocols/](./docs/protocols/).

Keep architecture facts there, not here — one source of truth, so an architectural change doesn't need two edits.

## Toolchain and builds

See [CONTRIBUTING.md](./CONTRIBUTING.md) — the pinned toolchain table (Flutter / Gradle / AGP / Kotlin / NDK / Rust), why AGP is pinned to Flutter's lower bound, Rust prerequisites, and how to build an APK without release signing credentials.

## Commands

Flutter 3.47.2 / Dart 3.13.2. If `flutter` is not on your `PATH`, call it as `$FLUTTER_HOME/bin/flutter`.

```bash
# Resolve dependencies
flutter pub get

# Run all tests (requires libsqlite3-dev)
flutter test

# Run a single test file
flutter test test/data/keybar_config_test.dart

# Store-build semantics (the IAP-enabled second run; also a CI gate)
flutter test test/commerce/ --dart-define=FLYTERM_ENABLE_IAP=true

# Static analysis — must report zero errors
flutter analyze

# Regenerate l10n after editing lib/l10n/app_en.arb / app_zh.arb
flutter gen-l10n

# IMPORTANT: before building an APK, regenerate flyterm-server binaries
scripts/build-server-assets.sh

# Build (single entry point)
scripts/build_apk.sh
```

> **In-app purchases default to OFF.** `kEnableInAppPurchase`
> (`lib/commerce/feature_flags.dart`) is `false` unless
> `--dart-define=FLYTERM_ENABLE_IAP=true` is passed, so a build from source is
> fully unlocked with no flag. Only store builds pass the flag. Tests run
> twice for this reason — bare `flutter test` covers the open-source default,
> and `flutter test test/commerce/ --dart-define=FLYTERM_ENABLE_IAP=true`
> covers the store semantics. Both are CI gates.

## Testing Notes

- SQLite tests use `sqflite_common_ffi` with `databaseFactoryFfi`. Each test must open its own `Database` in `setUp` and close it in `tearDown` — shared in-memory instances cause state leakage between tests.
- Widget tests for the keybar editor that include the right-buttons section need a 1080×2400 view size override; the section is below the fold of the default 800×600 test viewport.
- Inside `testWidgets`, awaiting a `sqflite` future **hangs** instead of failing — it will sit there for ten minutes rather than report an error. Wrap database work in `tester.runAsync(...)`, and when a tap triggers the write, wrap the tap in it too.
- KeyBar / SessionManager / SplitManager unit + widget tests run device-free.
- SSH connection and full terminal tests require a real device or emulator.
- `test/ssh/ssp_v2/integration/real_mosh_server_test.dart` is a real-network integration test; it self-skips when `mosh-server` isn't installed. (The old v1 `test/ssh/ssp/mosh_integration_test.dart` was removed along with `lib/ssh/ssp/`.)

## Design Documents

- `docs/ARCHITECTURE.md` — Architecture and key design decisions
- `docs/protocols/` — Protocol details
- `docs/user/` — User-facing setup guides
- `CHANGELOG.md` — Release notes

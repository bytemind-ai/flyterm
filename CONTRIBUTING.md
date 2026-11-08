# Contributing to FlyTerm

Thanks for taking the time. FlyTerm is a mobile SSH/Mosh terminal written in
Flutter, with a Rust component for the QUIC transport. This document covers the
toolchain, how to build and test, and what a mergeable pull request looks like.

- Architecture overview: [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)
- Protocol specs: [docs/protocols/](./docs/protocols/)
- Threat model and vulnerability reporting: [SECURITY.md](./SECURITY.md)
- Contributor License Agreement: [CLA.md](./CLA.md)
- Code of Conduct: [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md)

---

## Language policy

> Comments and commit messages in this repository are predominantly Chinese,
> and that is fine. Contributions in either Chinese or English are welcome —
> there is no requirement to translate existing comments, and no requirement to
> write new ones in English. User-facing strings go through `lib/l10n/` and do
> need both locales.

Concretely, for user-facing text: add the key to `lib/l10n/app_en.arb` **and**
`lib/l10n/app_zh.arb`, then regenerate:

```bash
flutter gen-l10n
```

The generated `lib/l10n/app_localizations*.dart` files are checked in, so
regenerate them in the same commit as the `.arb` change.

---

## Toolchain versions

These versions are interlocking. The Flutter Android build validates them in
**three chained gates — Gradle, then AGP, then KGP** — and only reports the next
one after you clear the previous one. If you upgrade by trial and error you will
hit them one at a time. Pin all of these up front:

| Component     | Version              | Where it is pinned                                |
| ------------- | -------------------- | ------------------------------------------------- |
| Flutter       | 3.47.2 (Dart 3.13.2) | `pubspec.yaml` requires SDK `^3.13.0`; CI pins `FLUTTER_VERSION: '3.47.2'` |
| Gradle        | 8.14.3               | `android/gradle/wrapper/gradle-wrapper.properties` |
| AGP           | 8.11.1               | `android/settings.gradle.kts`                      |
| Kotlin (KGP)  | 2.2.20               | `android/settings.gradle.kts`                      |
| NDK           | 28.2.13676358        | `android/app/build.gradle.kts`                     |
| Rust          | 1.99                 | `rust/rust-toolchain.toml`                         |
| Java (JDK)    | 17                   | CI uses `temurin` 17                               |

A Dart SDK older than 3.13 will not even resolve dependencies — `flutter pub
get` fails outright against `pubspec.yaml`'s `^3.13.0` constraint.

### AGP is pinned to Flutter's *lower bound*, not the newest release

Do not "helpfully" bump AGP to 9.x. AGP 9 only reads the new Gradle DSL, which
makes `flutter-gradle-plugin` fail at apply time — the build dies before it ever
reaches your code. The two opt-outs in `android/gradle.properties` go with this
pin:

```properties
android.builtInKotlin=false
android.newDsl=false
```

**Do not delete those two lines.** They were added by the Flutter migrator and
are what keep the old DSL path active.

### The NDK version also selects the Rust cross-compiler

`android.ndkVersion` is not only an AGP setting. The `buildAqtClientFfi` task in
`android/app/build.gradle.kts` derives `ANDROID_NDK_HOME` from it (falling back
to `sdk.dir/ndk/<ndkVersion>` from `local.properties`). Changing the NDK version
therefore changes which NDK cross-compiles the Rust FFI library as well — check
both sides when you touch it.

---

## Prerequisites

### Flutter and Dart

Install Flutter 3.47.2. If the SDK is not on your `PATH`, export `FLUTTER_HOME`
and call it explicitly; the rest of this document assumes `flutter` resolves to
3.47.2.

```bash
flutter --version   # expect 3.47.2 / Dart 3.13.2
```

### SQLite (required for tests)

The test suite uses `sqflite_common_ffi`, which loads the system SQLite:

```bash
sudo apt-get install -y libsqlite3-dev     # Debian/Ubuntu
```

Without it, every database-backed test fails to load the native library.

### Rust (required to build the APK, not to run tests)

The QUIC server (`rust/flyterm-server/`) ships inside the APK as a statically
linked musl binary for two architectures, and the client FFI library
(`rust/aqt_client_ffi/`) is cross-compiled for Android by the Gradle build.

```bash
rustup toolchain install 1.99
rustup target add --toolchain 1.99 x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-linux-android
sudo apt-get install -y musl-tools     # provides x86_64-linux-musl-gcc
cargo install --locked cargo-ndk       # builds libaqt_client_ffi.so for Android
```

The Android build fails fast (`verifyAqtNativeLib`) if `cargo-ndk` is missing
and no `libaqt_client_ffi.so` is present: the library is not kept in git.

The aarch64 musl target is cross-compiled with `cargo-zigbuild`, because the
`ring` crate's NEON assembly requires a real cross `gcc`. That needs **zig 0.13**,
which you install yourself:

```bash
pip install ziglang==0.13.0            # or your package manager / ziglang.org
```

`cargo-zigbuild` itself is installed by `scripts/build-server-assets.sh` if
missing. Without zig the script warns and ships x86_64 only; set
`FLYTERM_REQUIRE_AARCH64=1` to make that a hard failure, as CI does.

### Android SDK

NDK `28.2.13676358` must be installed in your Android SDK, or
`ANDROID_NDK_HOME` must point at it. JDK 17.

---

## Everyday commands

```bash
flutter pub get
flutter gen-l10n          # after editing lib/l10n/*.arb

flutter analyze           # must report zero errors
flutter test              # full suite
flutter test test/data/keybar_config_test.dart   # a single file
```

### `flutter analyze` must be clean

`flutter analyze` currently reports **zero errors**, and CI fails the PR if that
number rises above zero. (Info-level lints do not block.)

Note on the two vendored forks, `packages/xterm/` and `patches/dartssh2/`: each
carries its own `pubspec.yaml`, which makes the Dart analyzer treat it as an
**independent analysis context root**. The root `analysis_options.yaml` cannot
exclude anything inside them — its `packages/*/test/**`-style entries are inert
fallbacks. The exclusions that actually work live in each fork's own
`analysis_options.yaml`. If you need to adjust analyzer scope for a fork, edit
the file inside that fork.

---

## Building

### Android

Before building an APK, refresh the embedded server binaries — otherwise you
package a `flyterm-server` that does not match the current `rust/` sources, and
that mismatch only shows up on a real device:

```bash
scripts/build-server-assets.sh
```

Then build. The project ships one build entry point:

```bash
scripts/build_apk.sh
```

It resolves the right Flutter SDK, refreshes the server assets, applies the
build constraints, and verifies that the artifact's version matches
`pubspec.yaml`.

**Building without release signing credentials.** The release keystore is not in
the repository, and the release build type normally fails hard when it is
missing — a silent fallback to debug signing is exactly what that guard exists
to prevent. Contributors pass the fallback explicitly:

```bash
flutter build apk --release --split-per-abi \
  --target-platform android-arm64 \
  -PallowDebugSigning=true
```

This is the same command CI runs; `scripts/build_apk.sh` adds the flag for
you when `android/key.properties` is missing, and says so. The resulting APK is
debug-signed and **must not be distributed** — Android's debug keystore is a
publicly known fixed key, so anyone can forge an "update" for it, and Android
refuses upgrades across signing keys, so a shipped debug build can't be quietly
replaced later.

Build-shape constraints for anything that could be published: release only
(never `--debug`), always `--split-per-abi` (no fat APK), `arm64` target.

### iOS

iOS builds are verified by the `ios-build` workflow (manual dispatch) and need
macOS plus Xcode. Beyond `flutter pub get` and a standard `flutter build ios`,
two Rust pieces are built:

- `ios/build-aqt-xcframework.sh` builds the QUIC client library
  (`AqtClientFfi.xcframework`); run it once, and again after Rust changes.
- The Xcode build phase *Prepare flyterm-server* runs
  `scripts/build-server-assets.sh` so the app bundles the Linux server
  binaries it installs on remote hosts (skipped when they are fresh). macOS
  has no musl cross compiler, so zig builds both architectures: install
  zig 0.13 and the two linux-musl Rust targets as in the Rust prerequisites
  above (musl-tools is not needed).
  Release builds fail if either binary cannot be built.

The Xcode project carries the maintainers' signing team
(`DEVELOPMENT_TEAM = F8QR85A9N5`). To run on your own device, pick your team
under *Runner → Signing & Capabilities* in Xcode (and change the bundle id if
it is taken), but don't commit that change. `flutter build ios --no-codesign`,
which is what CI runs, needs no team at all.

---

## Testing notes

- SQLite tests use `sqflite_common_ffi` with `databaseFactoryFfi`. Each test
  must open its **own** `Database` in `setUp` and close it in `tearDown`; a
  shared in-memory instance leaks state between tests.
- Widget tests for the key bar editor that reach the right-buttons section need
  a 1080×2400 view size override — that section is below the fold of the default
  800×600 test viewport.
- Inside `testWidgets`, awaiting a `sqflite` future **hangs** rather than
  failing. Wrap database work in `tester.runAsync(...)`, and if a tap triggers
  the write, wrap the tap too.
- Key bar, `SessionManager`, and `SplitManager` tests run device-free. SSH
  connection and full terminal tests need a real device or emulator.
- `test/ssh/ssp_v2/integration/real_mosh_server_test.dart` is a real-network
  integration test; it self-skips when `mosh-server` is not installed.

---

## Pull requests

1. **Open an issue first for anything non-trivial.** A bug fix or a small,
   self-contained improvement can go straight to a PR. For a new feature or a
   change to protocol/storage/security behaviour, describe the problem in an
   issue before writing code — it is cheaper for both sides than reviewing a
   finished branch built on the wrong assumption.
2. Branch from `main`.
3. Keep the diff focused. Unrelated reformatting in the same commit makes a
   change very hard to review; send it separately.
4. Before pushing:
   ```bash
   flutter analyze                        # zero errors
   flutter test                           # green
   ```
5. Fill in the PR template: what changed, why, and how you verified it. "Why"
   matters more than "what" — the diff already shows what.
6. CI must be green. The `ci` workflow runs analyze, both test runs, and a
   debug-signed Android build.

### Commit messages

Conventional-commit prefixes are used (`feat(ai):`, `fix(terminal):`,
`chore(build):`, …). Write the body in whichever of Chinese or English you think
in; explain *why*, since the diff already covers *what*.

### License headers

New `.dart` files under `lib/` and `.rs` files under `rust/` start with:

```
// SPDX-License-Identifier: GPL-3.0-or-later
```

Vendored code (`packages/xterm/`, `patches/dartssh2/`, `rust/vendor/`) keeps
its upstream headers, and generated files (`lib/l10n/app_localizations*.dart`)
don't get one.

### Contributor License Agreement

Every contributor signs a CLA before their first merge. CLA Assistant comments
on your first pull request with a link; signing is one click.

**You keep the copyright to your contribution.** The CLA exists for a specific,
narrow reason: FlyTerm is GPLv3, and the same codebase is also distributed
through the App Store and Google Play, whose terms conflict with GPLv3 §6. As
sole copyright holder the project owner can grant that exception; once
third-party contributions are merged, the exception no longer covers the whole
work. The CLA resolves exactly that and nothing more. Full text and reasoning:
[CLA.md](./CLA.md).

---

## Reporting security issues

Do **not** open a public issue for a vulnerability. See
[SECURITY.md](./SECURITY.md) for the private reporting channel and for the
threat model — including which parts of the codebase have not been audited.

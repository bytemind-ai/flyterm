# FlyTerm

**Your coding agent doesn't stop when you close the laptop.**

[English] · [中文](./README.zh-CN.md)

FlyTerm is a coding agent that lives on your phone and works on your servers.
It connects over SSH, Mosh, or its own QUIC transport, runs tasks that survive
you locking the screen, and sends you a push notification when it needs a
decision.

> **Screenshot / demo GIF goes here.** Record the on-call flow: a lock-screen
> notification reading `agent wants to run systemctl restart nginx — approve?`,
> tapping through to see the command in context, approving, and the agent
> carrying on. That single clip demonstrates remote jobs, push approval,
> multi-host, and knowledge capture at once.

## Why this isn't just a terminal with a chat box

Three things are structural, not cosmetic — desktop agents are not built this
way and have little reason to change:

**Tasks live on the server, not in the client.** `run_background` drops the job
into `~/.flyterm/jobs/` on the target host; `check_job` and `list_jobs` come
back for it later. Lock your phone, lose signal, let the OS kill the app — the
job keeps running. A desktop agent's task is tied to the terminal process it
was started from.

**Approvals arrive as push notifications.** When the agent needs sign-off it
notifies you, with foreground suppression so it stays quiet while you're
already looking at that session. This is a place where a phone is *better*
than a desktop, not a compromise: desktop agents need you watching the terminal
to notice they asked a question.

**Multiple hosts are first-class.** `bash` and `read_file` take a `server`
argument; there's `copy_between_servers` and `list_servers`. One session can
reach across your fleet. Most coding agents model a single machine and a single
working directory.

Two more that follow from the above: the agent can reconfigure the app itself
(add a server entry, open a tunnel, generate an SSH key, change the layout),
and knowledge persists app-side rather than per-directory — reusable skills
travel across hosts, per-machine notes stay with the machine.

## Everything else

**Your session survives the subway.** Mosh-style state synchronisation plus a
QUIC transport means switching from Wi-Fi to 5G, or going through a tunnel,
doesn't drop your work.

**Built for agent sessions on a small screen.** Scrollback renders locally with
zero network round-trips, so scrolling back through what the agent did is
instant. TUI applications are detected and scroll handling switches to match
them. Flicker is suppressed. Long-press backspace repeats. CJK double-width
cells render correctly. These are the problems you only find by actually
running an agent on a phone.

**Auditable.** This is an SSH client — you hand it credentials to production
machines. The source is open and the protocol implementations are readable.
See [SECURITY.md](./SECURITY.md) for the threat model, including what has *not*
been audited.

**The usual terminal things**, because you still need them: SFTP, SSH key
management (Ed25519 and RSA 4096), jump-host chaining, port forwarding,
split panes and a floating window, a fully programmable on-screen key bar,
tmux integration, and 10 colour themes.

## Install

Grab the APK from [Releases](https://github.com/bytemind-ai/flyterm/releases),
or build it yourself (below). Every feature is free; there are no in-app
purchases.

## Build

Requires Flutter 3.47.2 (Dart 3.13.2), JDK 17, and the Rust 1.99 toolchain.
Full setup in [CONTRIBUTING.md](./CONTRIBUTING.md).

```bash
flutter pub get
flutter gen-l10n
flutter test
scripts/build_apk.sh
```

Output: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

If `flutter` isn't on your `PATH` at the required version, point the script at
it: `export FLYTERM_FLUTTER=/path/to/flutter/bin/flutter`.

**Signing.** A release APK normally needs credentials in
`android/key.properties` (that file and the keystore are both out of git). You
almost certainly don't have them, so when they're missing `scripts/build_apk.sh`
opts into debug signing for you and says so loudly. That is fine for local
builds and for reading the code on a device — but a debug-signed APK must never
be distributed. Android's debug keystore is a publicly known fixed key, so
anyone can forge an "update" for it, and Android refuses upgrades across signing
keys, so shipping one is not a mistake you can quietly correct later.

## Documentation

- [ARCHITECTURE.md](./docs/ARCHITECTURE.md) — layering, provider wiring, key design decisions
- [CONTRIBUTING.md](./CONTRIBUTING.md) — toolchain, build, test, PR process
- [SECURITY.md](./SECURITY.md) — threat model and vulnerability reporting
- [docs/protocols/](./docs/protocols/) — SSP v2 and AQT protocol notes
- [CHANGELOG.md](./CHANGELOG.md)

## Telemetry

Source builds send **nothing**. Crash reporting requires a `SENTRY_DSN`
compile-time variable that open-source builds never inject; with it absent the
telemetry layer returns immediately at startup. Store builds do report crashes,
with hostnames hashed and usernames reduced to a length token before anything
leaves the device.

## License

[GPL-3.0-or-later](./LICENSE). Third-party attributions in [NOTICE](./NOTICE).

Contributions require signing a [CLA](./CLA.md) — you keep your copyright; the
grant exists so the same code can be distributed through app stores, which
GPLv3 alone does not permit.

## Trademark

The name "FlyTerm" and the app icon are not covered by the GPL. If you fork and
redistribute, please use a different name and icon.

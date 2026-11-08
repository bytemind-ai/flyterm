<div align="center">

# FlyTerm

**Your coding agent doesn't stop when you close the laptop.**

A coding agent that lives on your phone and works on your servers —
over SSH, Mosh, or a QUIC connection that doesn't drop.

[![Release](https://img.shields.io/github/v/release/bytemind-ai/flyterm)](https://github.com/bytemind-ai/flyterm/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](./LICENSE)
![Platform](https://img.shields.io/badge/platform-Android-3ddc84)

[**Download APK**](https://github.com/bytemind-ai/flyterm/releases/latest) ·
[Get started](#get-started) ·
[中文](./README.zh-CN.md)

<img src="docs/images/hero.gif" alt="A notification asks to approve systemctl restart nginx; tapping through shows the command, the user approves, and the agent carries on" width="320">

</div>

---

## What it does

### Tasks keep running when you walk away

Ask the agent to run a migration, a build, a long test suite. The job runs on
the server, not in the app: lock your phone, lose signal, let Android kill
FlyTerm — it keeps going. Come back later and pick up where it is.

<img src="docs/images/jobs.png" alt="The agent's job list: a build still running, a test run finished, output one tap away" width="300">

### It asks before it acts — and tells you when it's waiting

When the agent wants to run something that needs your sign-off, you get a
notification. Tap it, see the exact command and why, approve or decline. You
don't have to be watching a terminal to notice it's waiting — and it stays
quiet while you're already looking at that session.

Running Claude Code or Codex on the server? Hook them up to `flyterm notify`
and they can reach your phone too — straight from your server, with no
third-party relay or account ([how](./docs/agent-notifications.md)).

<img src="docs/images/approve.png" alt="An approval prompt showing the exact command and the conversation that led to it" width="300">

### One conversation, your whole fleet

"Compare the nginx config on web-1 and web-2." "Copy the build from the CI box
to staging." The agent runs commands, reads files and moves files across every
server you've added, in a single session — not just the one you happened to
connect to.

<img src="docs/images/multi-host.png" alt="The agent comparing configuration across two servers in one reply" width="300">

It also remembers what it learns: reusable skills travel with you across
servers, and per-machine notes stay with the machine they describe. It can even
set FlyTerm up for you — add a server, open a tunnel, generate an SSH key.

## A terminal that doesn't drop

Under the agent is a full terminal, built for the way phones actually lose
connections.

- **Switch networks, keep your session.** Wi-Fi to 5G, into a tunnel and out:
  FlyTerm's QUIC connection moves with you instead of reconnecting.
- **UDP blocked? It still works.** On networks that block UDP — hotel Wi-Fi,
  corporate VPNs, servers with only port 22 open — FlyTerm carries the same
  connection through SSH, and moves back to UDP on its own when it can. No
  setting to flip, no reconnect.
- **Mosh too**, with local echo for typing on slow links.
- **Made for a small screen.** Scrollback is local, so scrolling back through
  what the agent did is instant. A fully programmable key bar, split panes and
  a floating window, tmux integration, correct CJK rendering, 10 colour themes.

<img src="docs/images/terminal.png" alt="tmux running in FlyTerm with the custom key bar above the keyboard" width="300">

## Get started

1. **Install** the APK from [Releases](https://github.com/bytemind-ai/flyterm/releases/latest)
   (Android 7.0 or later, arm64). Every feature is free — no subscription, no
   in-app purchases.
2. **Add a server** with a password or an SSH key. For the QUIC connection,
   FlyTerm installs its small server component on the host the first time you
   connect ([what it installs](./docs/user/quic-setup.md)).
3. **Bring your own model.** Add an API key for Anthropic, OpenAI, Gemini or
   OpenRouter — or point it at a local Ollama.

## Everything in one place

| | |
|---|---|
| **Connect** | SSH · Mosh · QUIC with seamless network switching and SSH fallback · jump hosts · port forwarding |
| **Terminal** | tmux integration · split panes · floating window · programmable key bar · 10 themes · CJK |
| **Files** | SFTP browser · upload and download over the live session |
| **Agent** | background jobs · approvals by notification · multi-server tools · skills and per-host notes |
| **Keys** | Ed25519 and RSA 4096 generation · keys stay on the device |

## Privacy and security

- **Open source, end to end.** You hand an SSH client the keys to production
  machines; you should be able to read it. The protocol implementations are
  documented in [docs/protocols/](./docs/protocols/).
- **Your credentials stay on your phone**, in the platform's secure storage.
- **No telemetry in builds from source.** Crash reporting only exists when a
  build is compiled with a `SENTRY_DSN`, which open-source builds never are.
  Store builds report crashes with hostnames hashed and usernames reduced to a
  length.
- Threat model and how to report a vulnerability: [SECURITY.md](./SECURITY.md).

## Build from source

You need Flutter, a Rust toolchain and the Android SDK — the exact versions and
every step are in [CONTRIBUTING.md](./CONTRIBUTING.md). Once they're installed:

```bash
scripts/build_apk.sh
```

## Documentation

- [Set up the QUIC connection](./docs/user/quic-setup.md) ·
  [Troubleshooting](./docs/user/quic-troubleshooting.md)
- [Agent notifications for Claude Code / Codex](./docs/agent-notifications.md)
- [Architecture](./docs/ARCHITECTURE.md) · [Protocols](./docs/protocols/) ·
  [Changelog](./CHANGELOG.md)
- [Contributing](./CONTRIBUTING.md) · [Security](./SECURITY.md)

Android is supported today; iOS is on the way.

## License

[GPL-3.0-or-later](./LICENSE); third-party attributions in [NOTICE](./NOTICE).
Contributions require a [CLA](./CLA.md) — you keep your copyright; the grant
lets the same code ship through app stores, which GPLv3 alone does not allow.

The name "FlyTerm" and the app icon are not covered by the GPL. If you fork and
redistribute, please use a different name and icon.

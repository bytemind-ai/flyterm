# Security Policy

FlyTerm is an SSH client. What you hand it are credentials for production
machines, so this document tries to be specific about what the code actually
does — and blunt about what has not been reviewed.

## Reporting a vulnerability

Use GitHub's **Private Vulnerability Reporting**:

<https://github.com/bytemind-ai/flyterm/security/advisories/new>

That opens a private advisory draft visible only to the maintainer. Please do
not open a public issue, and do not post details on social media before a fix
ships.

Helpful things to include: affected version and install source, the
configuration needed to reproduce (transport in use — SSH, Mosh, or QUIC —
whether a jump host is involved, tmux or not), and the impact you believe it
has. Redact your own hostnames and usernames.

What to expect: an acknowledgement within a few days, and an assessment with a
rough timeline once the report has been reproduced. This is a small project
without a dedicated security team, so please be patient. Credit in the release
notes if you want it.

## Supported versions

Fixes land on `main` and go out in the next release. Only the latest release is
supported; there are no backports to older tags.

## Scope and limitations

**The custom protocol implementations have not been independently audited.**
Specifically: the Mosh-style state-synchronisation protocol in
`lib/ssh/ssp_v2/`, and the AQT QUIC transport (`rust/aqt_protocol/`,
`rust/flyterm-server/`). They are written and tested in good faith, including
interoperability testing against the reference `mosh-server`, but no
third-party cryptographic review has been performed. If your threat model
requires audited transports, use plain SSH — it goes through `dartssh2` and
standard OpenSSH servers.

Two further caveats in the same spirit:

- The repository vendors forks of `xterm.dart` (`packages/xterm/`) and
  `dartssh2` (`patches/dartssh2/`). Those forks carry local changes and do not
  automatically pick up upstream security fixes; see `NOTICE` for provenance.
- `rust/flyterm-server` runs on *your* machines, deployed over SFTP into
  `~/.flyterm-server/bin/`. It is an unaudited network listener you are
  installing on a host you care about. Treat enabling the QUIC transport as a
  deliberate decision, not a default.

## SSH transport

The algorithm preference list lives in `lib/ssh/ssh_connection.dart`
(`_kPreferredAlgorithms`). As currently written:

**Ciphers**, in preference order:

1. `chacha20-poly1305@openssh.com`
2. `aes128-ctr`, `aes256-ctr`
3. `aes128-cbc`, `aes256-cbc` — legacy fallback only

ChaCha20-Poly1305 is first for a performance reason, not a policy one: the Dart
implementation is pure software, and software ChaCha beats software AES on ARM
devices that lack AES hardware extensions. It was added in `ec3f939d`. (A
comment block near the top of that file still reads "Use CTR/CBC only" — it
predates the ChaCha change and was not updated. The list below it is
authoritative.)

**AES-GCM is deliberately excluded.** GCM support in `dartssh2` 2.17 is
opt-in and incomplete, and enabling it caused the server to close the
connection during authentication on reconnect, surfacing as
`SSHAuthAbortError` (`34c99e72`). It will be reconsidered when upstream GCM is
stable.

CBC remains in the list only so that genuinely old servers stay reachable. It
is negotiated only when the server offers nothing better. If you need to
guarantee it is never used, remove it from the server's `Ciphers` list — the
client takes the best mutually supported option.

**Key exchange** prefers `curve25519-sha256`, then the NIST P-curves, with
fixed-group DH (`diffie-hellman-group14-sha256`, then `-sha1`) as a legacy
fallback. The group-exchange variants (`diffie-hellman-group-exchange-*`) are
excluded because they cost an extra round trip, not for security reasons.

**MACs** prefer the encrypt-then-MAC variant
(`hmac-sha2-256-etm@openssh.com`), then `hmac-sha2-256`, with `hmac-sha1` kept
for legacy servers. (With ChaCha20-Poly1305 or a GCM-style AEAD the MAC
negotiation is moot; it matters for the CTR/CBC path.)

### Host key verification

Host keys are verified trust-on-first-use against a local `known_hosts` table
keyed by `(host, port, keyType)`:

- No record → the user is prompted and the fingerprint is pinned on accept.
- Record matches → accepted silently.
- Record differs → the user gets an explicit mismatch prompt showing both
  fingerprints. Nothing is accepted silently in this case.

**Known limitation:** fingerprints are stored and displayed as MD5, because
that is the only form `dartssh2` exposes — the raw host public key is not
available at that layer, so a SHA-256 fingerprint cannot be computed. MD5 is
used here as a pinning identifier rather than as a security boundary against a
collision-crafting adversary, but it is weaker than OpenSSH's SHA-256 display
and is worth knowing about when you compare a fingerprint by eye.

## Private key storage

Private keys are written **only** to the platform secure store via
`flutter_secure_storage` — iOS Keychain, Android Keystore — under the key
`ssh_key_<id>` (`lib/data/secure_storage.dart`). SQLite stores the key's name,
type, and **public** key only.

There is no read path that hands a private key back to the application layer.
In particular, the AI agent's key-listing tool
(`AppControlService.listSshKeys`) returns exactly three fields — `name`,
`type`, `public_key` — and this is covered by tests in
`test/app_control/ssh_key_tools_test.dart`, including an assertion that no
`PRIVATE KEY` material appears in the result and that revoking a key also
deletes it from the secure store rather than leaving an orphan.

Server passwords (`server_pw_<id>`) and AI provider API keys (`ai_key_<id>`)
use the same secure store.

## Telemetry

**Open-source builds send nothing.** Crash reporting is Sentry, and
`lib/telemetry/sentry_init.dart` reads the DSN from the compile-time variable
`SENTRY_DSN`. That value is never committed and is never injected into
open-source builds, so the DSN is empty and the initialiser returns before the
SDK is touched. Debug builds short-circuit too.

Store builds do report crashes, gated additionally on an in-app consent toggle.
Everything that does go out passes through `DataScrubber`
(`lib/telemetry/data_scrubber.dart`) as a Sentry `beforeSend` hook:

- hostnames / IPs → first 8 hex characters of their SHA-256 (stable across
  events for correlation, not reversible to an address)
- usernames → `len=N`, keeping only the length
- screenshots, view hierarchy, and Sentry's default PII are all disabled
- terminal output, keystrokes, and key material are never passed into
  breadcrumbs or events in the first place

## Out of scope

- Compromise of the remote host itself, or of credentials you have already
  disclosed.
- Debug-signed builds. `-PallowDebugSigning=true` produces an APK signed with
  Android's publicly known debug key; such builds are for local development
  and are not distributable. This is intentional, not a vulnerability.
- Physical access to an unlocked device. The secure store protects keys at
  rest, not against an attacker operating your unlocked phone.
- Reports generated solely by an automated scanner, with no analysis of
  whether the finding is reachable in this codebase.

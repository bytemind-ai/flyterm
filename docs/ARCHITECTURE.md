# FlyTerm Architecture

This document is the single source of truth for how FlyTerm is put together. It
is written against the code, not against historical design notes — every class,
function and path named here exists in the tree. If the code moves, this file
moves with it.

FlyTerm is a Flutter application (Android + iOS) that connects to remote
machines over three interchangeable transports — SSH, Mosh (an in-app
reimplementation of the state-synchronization protocol), and AQT (a QUIC
protocol backed by a small Rust server binary) — and layers an AI agent on top
of the resulting shells.

- `docs/protocols/ssp-v2.md` — the Mosh implementation
- `docs/protocols/aqt.md` — the QUIC protocol and its Rust server

---

## 1. Layering

```
lib/
  main.dart                 Composition root: opens the DB, loads settings,
                            builds every service, wires the provider tree.
  app.dart                  MaterialApp, theme, route table, RouteObserver.

  data/                     Persistence and plain data models.
  ssh/                      Connection logic. No Flutter widgets.
  ai/                       Provider clients, the agent loop, its tools.
  ui/                       Everything that draws.
  telemetry/                Opt-in crash reporting and scrubbing.

  app_control/              Lets the agent mutate app state (with undo).
  config_import/            Parsers for `ssh_config`, `ssh` command lines.
  consent/                  First-run consent state; gates telemetry.
  legal/                    Privacy policy and terms text.
  sftp/                     SFTP service, channel pool, transfer tasks.
  tunnel/                   Port forwarding and a SOCKS5 handler.
  update/                   Version checks (GitHub releases, Play in-app).
  util/                     `dlog` and other leaf helpers.
```

### `data/` — persistence

Three storage backends, deliberately separated by sensitivity:

| Backend | Used for | Entry point |
|---|---|---|
| SQLite (`sqflite`) | Structured records: servers, keys' *public* halves, tunnels, known hosts, agent sessions and skills, per-machine notes, saved tabs | `AppDatabase.open()` in `data/database.dart` |
| `flutter_secure_storage` | Anything secret: SSH private keys, passwords, AI API keys, AQT session tokens | `SecureStorageService` in `data/secure_storage.dart` |
| `shared_preferences` | Non-secret config and small caches: key-bar layout, agent permission rules, notification dedup windows | used directly by the owning service |

`data/database.dart` holds the schema and the full `_onUpgrade` ladder
(`_dbVersion` is currently `43`). `data/models/` are plain Dart classes with
`toMap`/`fromMap`; `data/repositories/` are thin CRUD wrappers over `Database`
— no policy, no caching. Settings objects that need to notify the UI
(`TerminalSettings`, `KeybarSettings`) live here too and are `ChangeNotifier`s.

### `ssh/` — connection logic

Flutter-free, so it is testable without a widget binding.

- `ssh_connection.dart` wraps `dartssh2` (connect / shell / resize / close);
  `ssh_connection_pool.dart` reuses clients across tabs.
- `session_manager.dart` is the `ChangeNotifier` that owns the list of
  `SessionTab`s, the active index, and tab persistence via
  `TabSessionRepository`. `classifyConnectError()` lives here and maps raw
  exceptions onto the `ErrCategory` enum the UI shows.
- `transport/` is the abstraction every shell goes through: `Transport` /
  `TransportFactory`, with `LocalTransportFactory`, `SshTransportFactory` and
  `aqt/AqtTransportFactory` behind `CompositeTransportFactory`.
- `ssp_v2/` is the Mosh implementation (see `docs/protocols/ssp-v2.md`).
  `mosh_connection.dart` performs the `mosh-server new` handshake over SSH.
- `aqt/` is the QUIC client (see `docs/protocols/aqt.md`), including bootstrap,
  first-run install, the FFI wrapper and session-resume coordination.
- `reconnect_service.dart` listens to `connectivity_plus` and drives debounced
  retries; `host_key_verifier.dart` implements TOFU host-key checks backed by
  `KnownHostRepository`; `multiplexer/` abstracts tmux attach/detach
  (`TmuxBackend` / `NoneBackend`); `foreground_service.dart` plus
  `keep_alive_controller.dart` keep connections alive when the app is
  backgrounded.

### `ai/` — providers and the agent

- `ai_provider.dart` + `providers/` — one client per vendor
  (`AnthropicProvider`, `OpenAIProvider`, `GeminiProvider`, `OllamaProvider`),
  all speaking a common message/tool shape. `AIProviderService` holds the
  currently selected one.
- `agent/agent_loop.dart` — the turn loop: build messages, call the provider,
  dispatch tool calls, apply permission rules, repeat.
- `agent/agent_assembly.dart` — the composition root *for the agent*. It is
  where the loop's dependencies (tool registry, exec channel, knowledge
  writers, system-prompt closure) are bolted together.
- `agent/tool_registry.dart` + `agent/tool_executors/` — tool declarations and
  their implementations, grouped by `tool_groups.dart`.
- `agent/agent_session_manager.dart` — app-level owner of permission rules,
  permission mode, and the live `AgentLoop` per server. The loop lives here and
  not in a widget, so closing the panel does not kill a running turn.
- `agent/agent_skill_manager.dart`, `agent/builtin_skill_manager.dart`,
  `agent/server_notes_manager.dart` — the knowledge layer (see §4).

### `ui/`

Grouped by feature: `home/` (server list and form), `terminal/` (terminal
screen, key bar, split and floating layouts, selection, debug overlay),
`ai/` (the agent panel and the global AI screen), `settings/`, `sftp/`,
`tunnel/`, `notifications/`, `jobs/`, `update/`, `legal/`, `voice/`, and
`shell/` (`AppShell`, the bottom-tab container). `ui/design/fly_tokens.dart`
is the single source of truth for theme tokens — `app.dart` calls
`buildFlyTermTheme()` rather than deriving a scheme from a seed colour.

### `telemetry/`

Opt-in only. `main()` awaits `ConsentManager.instance.load()` *before*
`initSentryIfAllowed()`, so consent is known before any SDK init.
`runWithCrashCapture()` (`crash_zone.dart`) wraps app startup;
`DataScrubber` (`data_scrubber.dart`) strips sensitive fields from events
before they leave the device.

---

## 2. Provider wiring

Everything is constructed in `_initApp()` in `lib/main.dart` and injected via a
single `MultiProvider`. Two conventions are used:

- `ChangeNotifierProvider.value` — the object was built (and usually
  `load()`ed) during startup, and the UI must rebuild when it changes.
- `Provider.value` / `Provider(create:)` — stateless services and repositories.

| Provider | Registration | Purpose |
|---|---|---|
| `SharedPreferences` | `Provider<SharedPreferences>.value` | Needed by `GlobalAIScreen`, which builds its own `AgentLoop`. |
| `TransportFactory` | `Provider<TransportFactory>.value` | `CompositeTransportFactory` — picks local / SSH / QUIC. |
| `Database` | `Provider.value` | The `sqflite` singleton. |
| `TerminalSettings` | `ChangeNotifierProvider.value` | Font, theme, cursor, keyboard trigger, keep-alive, debug overlay. |
| `KeybarSettings` | `ChangeNotifierProvider.value` | Key-bar items and right buttons; `seedIfEmpty()` awaited at startup. |
| `SecureStorageService` | `Provider.value` | Keychain / Keystore wrapper. |
| `ServerRepository` | `Provider.value` | Servers table. |
| `MoshProcessRepository` | `Provider.value` | Tracks `mosh-server` PIDs for orphan cleanup. |
| `SSHKeyRepository` | `Provider(create:)` | Public keys and metadata. |
| `AIProviderRepository` | `Provider.value` | Stored AI provider configs. |
| `FavoriteCommandRepository` | `Provider.value` | Saved commands. |
| `SessionManager` | `ChangeNotifierProvider.value` | Tabs, active tab, restore. |
| `AIProviderService` | `ChangeNotifierProvider.value` | Currently selected AI provider. |
| `AttachmentStore` | `Provider.value` | On-disk agent attachments. |
| `AgentSessionManager` | `ChangeNotifierProvider.value` | Permission rules/mode, live loops, history archive. |
| `AgentSkillManager` | `ChangeNotifierProvider.value` | Cross-machine skills; `reload()` awaited at startup. |
| `BuiltinSkillManager` | `ChangeNotifierProvider.value` | Bundled skills and their enable state. |
| `AgentSkillRepository` | `Provider.value` | Registered separately because config backup reads it directly. |
| `ServerNotesManager` | `ChangeNotifierProvider.value` | Per-machine notes. `migrateFromPrefs()` then `load()` — **in that order**. |
| `ServerNotesRepository` | `Provider.value` | Same reason as the skill repo: config backup. |
| `AiCommandManager` | `ChangeNotifierProvider.value` | Saved-command index for the agent. |
| `VoiceInputService` | `ChangeNotifierProvider.value` | Microphone recognition; initialised lazily on first tap. |
| `ReconnectService` | `Provider.value` | Connectivity listener; `start()`ed at construction. |
| `KnownHostRepository` | `Provider.value` | TOFU host-key store. |
| `HostKeyVerifier` | `Provider<HostKeyVerifier>.value` | `DefaultHostKeyVerifier`, prompting through `appNavigatorKey`. |
| `SshConnectionPool` | `Provider<SshConnectionPool>.value` | Shared `dartssh2` clients. |
| `TunnelRepository` | `Provider.value` | Saved forwards. |
| `TunnelManager` | `ChangeNotifierProvider.value` | Live port forwarding. |
| `SplitManager` | `ChangeNotifierProvider.value` | Layout state (see §3). |
| `ConsentManager` | `ChangeNotifierProvider.value` | Singleton; gates telemetry. |
| `AppControlService?` | `Provider<AppControlService?>.value` | Agent-facing facade over settings/servers/sessions/tunnels/key bar/layout/keys/commands/skills/known hosts/notes. Registered as a **nullable** type so widget tests that do not wire it read `null` instead of throwing `ProviderNotFoundException`. |

Ordering constraints that are not obvious from the table:

- `ConsentManager.load()` runs before Sentry init.
- `KeepAliveController.apply()` runs before any `ReconnectService` connect, or
  the first connection of the session starts without a foreground service.
- `NotifyOrchestrator.start()` runs before any QUIC connection, or early
  `onNotify` events are dropped silently for want of a listener.
- `ServerNotesManager.migrateFromPrefs()` runs before `load()` (§4).

`appNavigatorKey` (declared in `main.dart`) is the escape hatch that lets the
connection layer raise UI — the host-key TOFU dialog, the QUIC install prompt,
fallback snack bars — without threading a `BuildContext` through every call
site.

---

## 3. Routing

`app.dart` builds the `MaterialApp`. `initialRoute` is chosen in `main.dart`:
`/terminal` when saved tabs were restored, `/home` otherwise.

`onGenerateInitialRoutes` is where the back-stack is seeded. For `/terminal` it
pushes `AppShell` *underneath* `TerminalScreen`, so the system back button
lands on the server list rather than exiting the app. For the default route it
wraps `AppShell` in a `Consumer<ConsentManager>` and shows
`ConsentFirstRunScreen` while `needsConsent` is true.

Named routes, all resolved in `onGenerateRoute`:

| Route | Screen | Argument |
|---|---|---|
| `/home` | `HomeScreen` | `true` forces a new tab |
| `/server-form` | `ServerFormScreen` | `Server?` |
| `/settings` | `SettingsScreen` | — (kept as a deep-link target; settings is a bottom tab) |
| `/settings/keys` | `KeyManagerScreen` | — |
| `/settings/known-hosts` | `KnownHostsScreen` | — |
| `/settings/keybar` | `KeybarEditorScreen` | — |
| `/settings/fet` | `FetSettingsScreen` | — |
| `/settings/agent` | `AgentSettingsScreen` | — |
| `/settings/appearance` | `AppearanceSettingsScreen` | — |
| `/settings/connection-advanced` | `ConnectionAdvancedScreen` | — |
| `/settings/security` | `SecuritySettingsScreen` | — |
| `/settings/privacy` | `PrivacySettingsScreen` | — |
| `/settings/about` | `AboutScreen` | — |
| `/settings/ai-providers` | `AIProvidersScreen` | — |
| `/settings/ai-providers/form` | `AIProviderFormScreen` | `AIProviderConfig?` |
| `/tunnels` | `TunnelListScreen` | — |
| `/tunnels/form` | `TunnelFormScreen` | `TunnelFormArgs?` |
| `/jobs` | `JobBoardHost` | — |

`/terminal` has no `onGenerateRoute` case — it exists only as an initial route;
`TerminalScreen` is otherwise pushed directly.

Everything else is pushed with a bare `MaterialPageRoute`, including
`KeybarItemEditScreen`, `KeybarSpecialKeyPicker`, the skill screens
(`AgentSkillsScreen`, `AgentSkillDetailScreen`, `AgentSkillCreateScreen`),
`AgentServerNotesListScreen` and `OpenSourceLicensesScreen`.

`appRouteObserver` (a `RouteObserver<ModalRoute<void>>`, also in `app.dart`) is
registered as a navigator observer. `TerminalScreen` subscribes to it and
unfocuses the active `TerminalView` whenever a route is pushed on top —
otherwise `xterm` re-opens the soft keyboard when focus is restored on pop.

---

## 4. Key design decisions

These are the non-obvious constraints. Each one encodes a failure that has
actually happened.

### 4.1 Private keys never touch SQLite

`SecureStorageService` (`lib/data/secure_storage.dart`) is the only place
secrets are written. Private keys go to `ssh_key_<id>`, passwords to
`server_pw_<serverId>`, AI keys to `ai_key_<providerId>` — all through
`flutter_secure_storage`, i.e. the iOS Keychain and the Android Keystore.

The `ssh_keys` table in `data/database.dart` holds only `id`, `name`, `type`
and `public_key`. The `servers` table holds `key_id` — a reference string, not
material. Nothing in the relational schema can leak a private key, which also
means a database export (config backup) is safe by construction rather than by
a filter someone has to remember to maintain.

### 4.2 The key bar is data-driven

The on-screen key bar has no hardcoded buttons. `lib/data/keybar_config.dart`
defines the model, and `KeybarSettings` persists it in `shared_preferences`.

`KeyToken` is a **sealed** hierarchy with exactly two cases:

- `TextToken(String text)` — literal characters.
- `SpecialToken(SpecialKey key)` — one of the ~70 values of the `SpecialKey`
  enum (arrows, F-keys, paging, `ctrlA`…`ctrlZ`, and the composites that cannot
  be expressed any other way).

Sealing matters: `encodeSequence` and the editor both switch exhaustively over
the two cases, so adding a third token kind is a compile error rather than a
silent fall-through. `KeyToken.fromJson` throws `ArgumentError` on an unknown
discriminator instead of degrading.

A `KeyBarItem` is `{id, label, sequence: List<KeyToken>, sticky, repeatable}`.
The right-hand side of the bar is a parallel list of `RightButtonItem`s over
the `RightButton` enum (`keyboard`, `favorites`, `microphone`, `ai`,
`attachFile`); `KeybarSettings` is forward-compatible with enum values it does
not recognise, so a config written by a newer build does not brick an older one.

**DECCKM.** `encodeSequence(List<KeyToken>, {bool cursorKeysAppMode})` is the
only byte encoder. `cursorKeysAppMode` mirrors xterm's DECCKM (`CSI ? 1 h`).
When it is false, arrows emit the CSI form (`ESC [ A`); when true, the SS3 form
(`ESC O A`). TUIs — vim, less, Ink/blessed pickers, the Claude CLI's `/resume`
list — turn application-cursor mode on and only recognise SS3. `KeyBar` reads
the live value from `widget.terminal.cursorKeysMode` on every tap, so the same
button sends different bytes depending on what the remote program asked for.
Ctrl-modified arrows (`ctrlUp` … `ctrlRight`) always use the CSI form with
modifier parameter 5, because xterm defines no SS3 variant for them.

**Sticky CTRL.** An item with `sticky: true` does not send anything — it arms a
flag (`_ctrlActive`; the Shift equivalent is `_shiftActive`, and the two are
mutually exclusive). The next non-sticky tap goes through
`_applyCtrlModifier`, which falls through three cases in order:

1. The item is a single `SpecialToken` with a dedicated Ctrl twin
   (`_ctrlModifiedFor`: `up→ctrlUp`, `down→ctrlDown`, `left→ctrlLeft`,
   `right→ctrlRight`, `backspace→ctrlBackspace`) — re-encode as that key.
2. Otherwise, if the first byte is printable ASCII `0x40..0x7e`, apply the
   classic XOR `c & 0x1f` and keep the rest of the payload.
3. Otherwise the modifier does not apply. The *unmodified* payload is still
   sent, and `_flashCtrlNotApplicable()` shows a one-shot snack bar.

Case 3 is the point of the whole design. A naive "XOR the first byte"
implementation silently no-ops on arrows, paging and F-keys — the user presses
CTRL, presses the key, and nothing distinguishable happens.
`_ctrlNotApplicable` lists the keys for which no Ctrl form is consistently
defined across terminals (F1–F12, insert/delete, page up/down, home/end,
shift-tab) so the app says so rather than guessing.

### 4.3 `SplitManager` owns all layout state

`lib/ui/terminal/split_manager.dart` is a `ChangeNotifier` holding:

- `splitMode` — the `SplitMode` enum (`off`, `horizontal`, `vertical`)
- `secondarySession` — the `SessionTab` in the second pane
- `floatingSession` — the `SessionTab` in the picture-in-picture window
- `splitRatio` — the divider position
- `floatRatioW` / `floatRatioH` — the floating window's size as a fraction of
  the screen, so it survives rotation

Mutators are `setSplitMode`, `setSecondary`, `setFloating`, `setSplitRatio`,
`setFloatRatio`, `clearSplit`, `clearFloating`, and `onTabClosed` (which drops
a tab from both slots when it dies).

Centralising this is a hard requirement, not tidiness: `AppControlService`'s
`layout_set` tool lets the AI agent change the layout, and `SplitPaneView` /
`FloatingTerminalWindow` render it. If the tool and the UI each built their own
manager, the layout the agent reports and the layout the user sees would
diverge with no error anywhere. `main.dart` therefore hoists `splitManager`
into a local and passes the *same instance* to both the provider and the
`AppControlService` constructor.

### 4.4 `ServerNotesManager.noteFor()` must be synchronous

`AgentLoop` takes a `systemPromptProvider` — look at the field declaration in
`lib/ai/agent/agent_loop.dart`:

```dart
final String Function(AgentPromptInputs inputs) systemPromptProvider;
```

It returns `String`, not `Future<String>`, and it is called once per turn from
`_refreshSystemPrompt()`. Everything the system prompt needs must therefore be
readable synchronously.

Per-machine notes go into that prompt on every turn. So `ServerNotesManager`
keeps the entire note set in memory (`Map<String, ServerNote> _notes`) and
exposes:

```dart
String? noteFor(String serverId) => _notes[serverId]?.body;
```

The in-memory copy is **not** a performance optimisation — it is what makes the
synchronous signature possible at all. The same constraint is why
`AgentSkillManager`, `BuiltinSkillManager` and `AiCommandManager` all keep
hot caches and all require an awaited `load()`/`reload()` during startup. This
is also why `migrateFromPrefs()` must run *before* `load()` in `main.dart`:
migrate-then-load leaves the cache hot; load-then-migrate leaves the newly
imported notes invisible until the next cold start.

### 4.5 The 4 KiB note cap is checked in exactly one place

`kMaxInstructionBytes = 4096` is declared in
`lib/ai/agent/agent_instructions.dart`. `ServerNotesManager._overflowOf()` is
the only enforcement point, and both public writers funnel through it:

- `replaceNote({serverId, body})` — whole-document replace.
- `appendNote({serverId, heading, body})` — read-modify-write via the pure
  function `composeAppendedNote()`, then delegates to `replaceNote`.

There are three write paths in the product, and all three end up in one of
those two methods:

| Path | Call site | Method |
|---|---|---|
| Knowledge-distillation card | `onWriteMachineNotes` in `lib/ui/terminal/terminal_screen.dart` | `appendNote` |
| `save_note` tool | `serverNoteSaver` in `lib/ai/agent/agent_assembly.dart` | `appendNote` |
| Manual edit in settings | `lib/ui/settings/agent_server_notes_sheet.dart` | `replaceNote` |

(`AppControlService` also calls `replaceNote` when undoing a server deletion,
restoring the note that was removed with it.)

This matters because **notes are re-sent with the system prompt every single
turn**. A path that skips the check does not cost one oversized write — it
costs an oversized prompt on every turn for the lifetime of the session, and
the cap may as well not exist. The check deliberately lives in the manager
rather than in `ServerNotesRepository`: the repository stays pure SQL, and the
migration path needs a writer that does *not* check the cap. That writer is
`_adoptRaw`, and it is private precisely so nobody outside the class can reach
it — a doc comment would not have stopped them.

`appendNote` also refuses up front when the *existing* note is already over the
limit, returning `ServerNoteSaveResult.failed` (a sentence for a human) rather
than `rejected(overflowBytes)` (a number for the caller to subtract). A model
that only controls the section it is adding cannot fix a pre-existing overflow
by writing less; telling it a byte count just burns tokens on retries. The two
outcomes are separate constructors on `ServerNoteSaveResult` for this reason.

### 4.6 Knowledge lives in the app, not on the servers

The agent accumulates two kinds of knowledge:

- **Skills** — reusable across machines. Stored in the `agent_skills` table,
  owned by `AgentSkillManager`.
- **Machine facts** — "this host uses podman", "logs are in `/data`". Stored in
  the `server_notes` table, one row per `server_id`, owned by
  `ServerNotesManager`.

Machine facts were once written to a file on the remote host itself —
`~/.flyterm/AGENTS.md`, read and cached on every panel open. In October 2026
they moved back into the app. **Do not move them back out.**

The argument for remote storage was not wrong: notes survive a phone swap, are
shared across devices, and the agent can maintain them in place. It optimised
the wrong axis. Those properties are all *durability*; the actual pain was
*manageability* — knowledge scattered across N machines cannot be reviewed as a
whole, deleted, or exported from the app, and a host reinstall or IP change
loses the file anyway, so the durability advantage was weaker than it looked.

The criterion is: **a single source of truth beats following the subject.** The
cost — notes are lost when you change phones — is explicitly accepted, and is
mitigated by config backup rather than by distributing the data again.

This reasoning is deliberately recorded in two places, and **both halves must
be read together**: the storage-side half is the class doc of
`ServerNotesManager` (`lib/ai/agent/server_notes_manager.dart`), and the
agent-side half is on `_kInstructionsKey` in
`lib/ai/agent/agent_session_manager.dart`, which explains why the *global*
instructions are global and why the machine-level ones are not. Changing one
without the other leaves a reader with half an argument.

One exception survives: `~/.flyterm/skills/*.md` on a remote host is still
imported (`lib/ai/agent/remote_skills.dart`, `skill_file_import.dart`). That is
a one-way server→app import source; the stored copy still lands in the app's
database.

`ServerNotesManager.migrateFromPrefs()` performs the one-shot import of the old
cached remote notes out of `shared_preferences`, gated by the boolean
`server_notes_migrated_v37`. It routes through `_adoptRaw`, which skips the cap
check — rejecting an oversized legacy note would silently delete a user's
content during an upgrade; importing it and letting them see an over-limit
warning next time they edit is the lesser harm.

---

## 5. Testing

- SQLite tests use `sqflite_common_ffi` with `databaseFactoryFfi`. Each test
  opens its own `Database` in `setUp` and closes it in `tearDown` — a shared
  in-memory instance leaks state between tests.
- Key-bar, `SessionManager` and `SplitManager` tests run device-free.
- Widget tests covering the key-bar editor's right-button section need a
  1080×2400 view size; that section is below the fold at the default 800×600.
- Do not `await` a `sqflite` future directly inside `testWidgets` — it hangs
  rather than failing. Wrap it in `tester.runAsync`, including the tap that
  triggers the write.
- `test/ssh/ssp_v2/integration/real_mosh_server_test.dart` is a real-network
  test and self-skips when `mosh-server` is not installed.
- SSH connection and full terminal tests need a real device or emulator.

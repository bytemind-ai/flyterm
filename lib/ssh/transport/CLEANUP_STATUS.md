# Transport Abstraction Cleanup Status

## Completed (Stage 2.5)

- `RemoteTransport` interface defined with capability set
- `SshTransport`, `MoshTransport`, `LocalTransport` wrappers implemented
- `TransportFactory` + `CompositeTransportFactory` created
- `SessionTab.transport: RemoteTransport?` field added
- `TerminalWidget.transport` field added; helpers route to transport when set
- `DebugOverlay` reads `transport.metrics` with moshShell fallback
- `ReconnectService` dispatches `setForeground`/`heartbeat`/`roam` via transport

## Remaining (deferred to Stage 3 / future cleanup)

- `dynamic moshShell` field in `SessionTab` still present — used by
  ReconnectService's Mosh reconnect lifecycle (recreate/reassign on reconnect).
  Full removal requires refactoring the reconnect state machine to use
  MoshTransport internally.
- `widget.isMosh` still referenced in debug strings/logs (cosmetic, not branching)
- `debug_overlay.dart` still has some `t.moshShell as dynamic` reads for
  Mosh-specific diagnostics not exposed through TransportMetrics yet
- `TunnelManager` capability gate deferred to Stage 3

## Hard metric (verification target)

`grep "dynamic moshShell" lib/` → 1 line (field definition)
Current: still multiple references in ReconnectService legacy path

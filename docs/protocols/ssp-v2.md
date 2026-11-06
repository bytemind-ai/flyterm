# SSP v2 — the Mosh state-synchronization protocol

FlyTerm speaks Mosh's State Synchronization Protocol natively, in Dart. There
is no bundled `mosh-client`; the app opens the UDP socket, runs the crypto, and
drives the state machine itself. The remote side is **stock upstream
`mosh-server`** — nothing is installed or patched on the host.

Source lives under `lib/ssh/ssp_v2/`. The "v2" is an internal generation
marker: an earlier `lib/ssh/ssp/` implementation existed and was deleted. The
on-the-wire protocol version is 2 (`TransportInstruction.kProtocolVersion`),
matching upstream Mosh.

```
lib/ssh/ssp_v2/
  moshv2_shell.dart            createMoshV2Transport() — factory
  mosh_shell_v2.dart           MoshShellV2 — shell-shaped wrapper (stdin/stdout/resize)
  transport_message.dart       Protobuf codec: TransportInstruction, MoshUserMessage,
                               MoshHostMessage
  local_echo_predictor.dart    LocalEchoPredictor
  network/
    udp_socket.dart            MoshUdpSocket — RawDatagramSocket wrapper
    ocb_cipher.dart            OcbCipher — AES-128-OCB3 (RFC 7253)
    nonce.dart                 NonceGenerator, NonceDirection
    packet.dart                MoshPacket — wire framing
  state_machine/
    transport_instruction.dart TransportInstruction
    transport_sender.dart      TransportSender, SentState
    transport_receiver.dart    TransportReceiver, ReceiverResult, ReceivedState
    sent_state.dart            SentState
    received_state.dart        ReceivedState
    fragmenter.dart            Fragment, Fragmenter, FragmentAssembler
    tui_detector.dart          TuiDetector
  transport/
    connection.dart            MoshV2Connection — the orchestrator
    heartbeat.dart             Heartbeat
    liveness_supervisor.dart   LivenessSupervisor, SspLivenessEvent, SspLivenessKind
    roaming.dart               Roamer
    clock_drift_detector.dart  ClockDriftDetector
    app_lifecycle_hook.dart    foreground/background hook
```

`MoshV2Connection` implements `SspTransport` (`lib/ssh/ssp_interface.dart`):
`write`, `resize`, `close`, plus the `hostBytes` and `liveness` streams.

---

## 1. Handshake

`MoshHandshake` in `lib/ssh/mosh_connection.dart` does the bootstrap over an
ordinary SSH exec channel:

```
mosh-server new -s -c 256 -l LANG=UTF-8 -l MOSH_SERVER_NETWORK_TMOUT=1800 \
    -p <portRange> -w <cols> -t <rows>
```

Two regexes carry the whole result:

- `_connectRe` — `MOSH CONNECT (\d+) ([A-Za-z0-9+/=]{22,24})` on stdout. Group
  1 is the UDP port; group 2 is the base64 session key, which decodes to the
  16 bytes handed to `OcbCipher`.
- `_stderrPidRe` — `pid\s*=\s*(\d+)` on stderr, from the
  `[mosh-server detached, pid = N]` line.

The PID is persisted through `MoshProcessRepository`. `main.dart` calls
`_cleanOrphanedMoshPids()` at startup, which SSHes back in and
`MoshHandshake.killOrphanedPid()`s any `mosh-server` that outlived a crash or
force-quit. Without it, every crash leaks a detached server process that holds
a UDP port and a shell for `MOSH_SERVER_NETWORK_TMOUT` seconds.

Note that the connect line is matched *streaming* — it arrives before
`mosh-server` forks and detaches, so waiting for channel EOF would deadlock.

---

## 2. Datagram layer

### Framing

`MoshPacket.encode` / `MoshPacket.decode` in `network/packet.dart`:

```
[ 8-byte nonce ] [ OCB ciphertext || 16-byte tag ]
```

OCB uses a 96-bit nonce, but Mosh has always transmitted only the trailing
64-bit sequence number. The full nonce is reconstructed as
`{0,0,0,0} || <8 wire bytes>`. This is not cosmetic: if the client puts all 12
bytes on the wire, `mosh-server` treats the extra 4 as ciphertext and OCB
authentication fails on the very first packet.

### Cipher

`OcbCipher` (`network/ocb_cipher.dart`) is an AES-128-OCB3 implementation per
RFC 7253. `encrypt()` returns ciphertext concatenated with the 16-byte tag;
`decrypt()` throws `OcbAuthException` when the tag does not verify. The key is
the 16 bytes from `MOSH CONNECT`.

### Nonces

`NonceGenerator` (`network/nonce.dart`) emits 12-byte nonces from a 64-bit
counter. The direction flag is the **high bit of byte 4**: client-to-server
packets clear it, server-to-client packets set `0x80`. `NonceDirection` names
the two. Sharing one key across both directions is only safe because the nonce
spaces are disjoint by that bit.

### Plaintext payload

Inside the encrypted envelope, `MoshV2Connection._sendCurrentDiff()` lays out:

```
[ ts 2B BE ] [ ts_reply 2B BE ] [ instr_id 8B BE ] [ frag 2B BE ] [ zlib(TransportInstruction) ]
```

- `ts` — the local millisecond clock masked to 16 bits.
- `ts_reply` — the most recently received peer `ts`, echoed back. On receipt,
  `(now - ts_reply) & 0xFFFF` gives a wrap-safe RTT sample, published on
  `MoshV2Connection`'s authenticated-packet stream and fed to
  `Heartbeat.updateSrtt()`. `0xFFFF` is the "nothing to echo" sentinel and is
  skipped.
- The instruction itself is zlib-compressed (`ZLibCodec(level: 1)`) before
  encryption, matching what `mosh-server` expects.

### Fragmentation

`state_machine/fragmenter.dart`. `Fragmenter.split(seq, payload)` chops a
payload into `Fragment`s at a 500-byte MTU. A `Fragment` carries `seq`
(64-bit instruction id), `rawIndex` (16-bit, with `0x8000` marking the final
fragment) and `body`. `FragmentAssembler.feed()` reassembles, dropping
incomplete sequences after a 30-second TTL rather than holding them forever.

### Liveness, roaming, drift

Four layers sit on top of the socket, all in `transport/`:

- `Heartbeat` — send cadence between `kSendIntervalMin` (20 ms) and
  `kSendIntervalMax` (250 ms), targeting `srtt / 2`; `kAckInterval` (3000 ms)
  forces a bare ack when there is nothing to say.
- `LivenessSupervisor` — a staged watchdog emitting `SspLivenessEvent`s with
  `SspLivenessKind` values `healthy`, `gracePeriod`, `roaming`,
  `hardReconnectNeeded`. Any authenticated packet resets it to healthy.
- `Roamer` — rebinds the socket to a fresh ephemeral local port while keeping
  the remote address. This is how a Wi-Fi→cellular switch survives: Mosh
  identifies the client by its key, not its address, so the server simply
  starts replying to whatever source address last authenticated.
- `ClockDriftDetector` — notices OS suspend/resume by spotting a tick gap far
  larger than the expected interval, so a phone waking from sleep does not
  misread the gap as packet loss.

---

## 3. State synchronization

Mosh does not stream bytes. Both ends hold a *numbered sequence of states* and
exchange diffs between them; the receiver is free to skip intermediate states
because only the latest one is observable. That is why Mosh survives a lossy
link without head-of-line blocking, and why it can drop stale output instead of
replaying it.

### The instruction

`TransportInstruction` (`state_machine/transport_instruction.dart`, codec in
`transport_message.dart`) is a hand-rolled protobuf message:

| Field | # | Meaning |
|---|---|---|
| `protocolVersion` | 1 | `kProtocolVersion = 2` |
| `oldNum` | 2 | State this diff is based on |
| `newNum` | 3 | State this diff produces |
| `ackNum` | 4 | Highest peer state **we** have applied |
| `throwawayNum` | 5 | Oldest of **our own** states still worth keeping (see §4) |
| `diff` | 6 | Encoded `UserMessage` / `HostMessage` |
| `chaff` | 7 | Random padding; ignored by the server |

The diff bodies come from `MoshUserMessage` (client→server:
`encodeKeystrokes`, `encodeResize`) and `MoshHostMessage` (server→client:
`extractHostBytes`, which pulls the terminal bytes out of the nested
`HostMessage`/`Instruction` structure).

### Sending

`TransportSender` holds `sentStates: List<SentState>` and
`assumedReceiverStateNum`. A `SentState` is `{num, timestamp, userInput}` where
`userInput` is the **cumulative** byte string for that state, not a delta.
`makeDiffFromAssumed()` produces the diff from `assumedReceiverStateNum` to the
newest state. `onAck(ackNum)` trims acknowledged states and advances
`assumedReceiverStateNum`; if the ack jumps past everything held locally, the
sender re-seeds rather than desynchronising. Two hard-reset thresholds —
`kHardResetMaxAge` (120 s of ack stall, measured by `ackStallDuration()`) and
`kHardResetMaxPending` (1000 unacknowledged states) — stop an unbounded backlog
from accumulating across a long partition. The 120 s figure is chosen to sit
*after* the `LivenessSupervisor` escalation ladder, so the watchdog gets to try
roaming and a hard reconnect first.

### Receiving

`TransportReceiver` keeps `receivedStates` in a `SplayTreeMap<int,
ReceivedState>` capped at `kMaxStates = 128`, plus `latestNum`. `onPacket()`
runs three gates in order, each with its own counter:

1. `inst.oldNum` not present → `baseMissingDrops++`. We cannot apply a diff
   whose base we never had.
2. `inst.newNum <= latestNum` → `staleDrops++`. Already past this.
3. `inst.oldNum != latestNum` → `chainGateDrops++`. Strict chaining: only a
   diff that continues from exactly where we are is applied.

A packet that survives all three advances `latestNum`, stores a new
`ReceivedState`, and returns `ReceiverResult(inst.diff)` — which
`MoshV2Connection` feeds to `MoshHostMessage.extractHostBytes` and then onto
the `hostBytes` stream.

`seedAt(num)` exists for soft reconnect. After the app returns from the
background, the server may ack a state number the client no longer has any
history for; without seeding, every subsequent `D(num→X)` would be a
`baseMissing` drop and the terminal would stay blank forever.
`MoshV2Connection` watches these three counters and, when the receiver stays
stuck for more than 10 seconds, raises
`SspLivenessKind.hardReconnectNeeded` with the counter values in the reason
string, rather than silently showing a frozen screen.

### Resize

`MoshV2Connection.resize(cols, rows)` encodes a resize through
`MoshUserMessage.encodeResize`, appends it to the sender's user input, and
**flushes immediately** instead of waiting for the next heartbeat tick. On a
phone, a resize is usually the soft keyboard appearing; a 20–250 ms delay
leaves the TUI drawn at the previous size for a visible beat. The initial
geometry is additionally passed to `mosh-server` via `-w` / `-t`.

---

## 4. `throwaway_num` — client state, never server state

This is the single most dangerous field in the protocol, and the implementation
carries a comment in `transport/connection.dart` saying so.

`throwaway_num` tells the peer which of **our own** states it may discard. The
correct value is the base of the diff we are currently sending — the oldest
un-acknowledged client state:

```dart
final diff = _sender.makeDiffFromAssumed();
final base = diff?.oldNum ?? _sender.assumedReceiverStateNum;
...
final inst = TransportInstruction(
  oldNum: base,
  newNum: newN,
  ackNum: _receiver.latestNum,
  // throwawayNum is client-side state, NOT server-side. Sending
  // _receiver.throwawayNum triggers mosh-server's fatal_assert in
  // process_throwaway_until and kills the session — pending diffs pile
  // up and the user sees a frozen terminal. Use our oldNum (oldest
  // unACKed client state) instead. Matches v1's _sendDiff and the
  // mosh::TransportSender::send_to_receiver invariant.
  throwawayNum: base,
  diff: body,
);
```

The plausible-looking mistake is to send `_receiver.throwawayNum` — the oldest
*server* state we are still holding. `TransportReceiver` even exposes such a
getter, which is exactly why the trap is easy to fall into. It is wrong for a
structural reason: `throwaway_num` and `ack_num` index **different numbering
spaces**. `ack_num` refers to the peer's states; `throwaway_num` refers to our
own. Mixing them hands `mosh-server` a number from the wrong sequence.

The failure mode is not a dropped packet. Upstream's
`process_throwaway_until` asserts on the value, and `fatal_assert` aborts the
server process. From the phone it looks like the session simply stops: diffs
accumulate in `sentStates`, nothing is ever acked, and the terminal freezes
with no error. There is no client-side symptom pointing at the real cause —
which is why this is written down here as well as in the code.

The invariant to preserve: **`throwawayNum` must always equal the `oldNum` of
the same instruction.** If a refactor ever makes those two diverge, the change
is wrong.

---

## 5. Local echo prediction

`LocalEchoPredictor` (`local_echo_predictor.dart`) renders a typed character
immediately, underlined, before the server confirms it — the same trick
upstream `mosh-client` uses to make a 200 ms link feel instant.

**Emitting.** `buildEcho(data)` returns
`ESC[4m` + the character + `ESC[24m` + `ESC[<W>D`: underline on, the glyph,
underline off, then move the cursor back `W` columns so the real server output
overwrites the prediction in place. `W` is 1 for ASCII and 2 for wide glyphs —
`_isWide` classifies CJK and emoji code points, and `_isControlOrCombining`
excludes code points that occupy no cell.

**Scope.** Only one prediction is outstanding at a time
(`_maxPendingCols = 1`). Predicting a whole line and then being wrong about
it is far more disruptive than not predicting at all; one character bounds the
damage to one cell.

**Confirmation.** `notifyServerOutput(bytes)` is called with every chunk from
`hostBytes`. Any server output clears the pending prediction — whether it
confirms or contradicts it, the server's bytes are authoritative and land on
top of the underlined cell.

**Expiry.** `notifyPredicted(colWidth)` starts a `_predictionTimeout` (2 s)
timer. If the server says nothing for that long, `_onTimeoutFire()` emits an
erase (`ESC[<n>D`, spaces, `ESC[<n>D`) through the `onTimeout` callback and
clears state, so a dropped packet does not leave a phantom character on screen.

**Suppression.** Prediction is turned off where it would leak or corrupt:

- Password prompts — `_passwordRe` is matched against the tail of recent
  server output, and matches arm `_suppressDuration` (3 s) of silence.
  Echoing a password character, even underlined, is unacceptable.
- The alternate screen buffer — `_detectAltBuffer` watches for
  `CSI ? 1049 h/l` and `CSI ? 1047 h/l`. Full-screen programs position the
  cursor themselves; a local echo would land in the wrong cell.
- `suppressNext()` / `suppressAll()` for one-shot and blanket disabling.

`stateDiag` exposes the current reason as a short string for the debug overlay.

`TuiDetector` (`state_machine/tui_detector.dart`) is the related heuristic on
the output side: it watches for `ESC[r` (scroll region), `ESC[?25l` (cursor
hide) and absolute positioning to decide a TUI is on screen. Activation needs
at least four distinct rows; deactivation needs an `ESC[r` with few rows and no
cursor-hide across two consecutive frames.

---

## 6. Interoperability boundary

**What works.** FlyTerm interoperates with unmodified upstream `mosh-server`
over its real wire format: the `MOSH CONNECT` handshake, the 8-byte-nonce OCB
framing, zlib-compressed protobuf instructions, protocol version 2, keystroke
and resize user messages, host-message terminal bytes, fragmentation,
timestamp echo, and client roaming.

**What is required of the host.** Only that `mosh-server` is on `PATH` and that
the UDP port range (`mosh_port_range` on the server record, default
`60000:61000`) is reachable. Nothing is uploaded. Compare AQT
(`docs/protocols/aqt.md`), which does ship a binary.

**Deliberate divergences.**

- The server's terminal emulation is not reimplemented. Upstream
  `mosh-client` maintains a `CompleteTerminal` and diffs framebuffers;
  FlyTerm applies the host diff bytes straight into the `xterm` package's
  emulator. `ReceivedState` therefore carries only `{num, timestamp}` — the
  screen lives in the widget, not in the state machine. The practical
  consequence is that FlyTerm relies on the strict chain gate (§3) instead of
  being able to reconstruct an arbitrary state from a skipped diff.
- `HostMessage.echoack` (the `optional EchoAck echoack = 7` extension noted in
  `transport_message.dart`) is skipped by the decoder, not consumed. Prediction
  confirmation is driven by output arrival (§5) rather than by the server's
  echo acknowledgement.
- `chaff` (field 7 of the instruction) is decoded and ignored; the client never
  populates it, so `encode()` omits it.

**Known-fragile areas.** The three places where a change will break real
servers rather than fail a test: the 8-byte nonce truncation (§2), the
`throwaway_num` invariant (§4), and the zlib layer sitting *inside* the
encryption envelope rather than outside it.

**Testing.** `test/ssh/ssp_v2/integration/real_mosh_server_test.dart` drives a
real `mosh-server` and self-skips when the binary is absent, so a machine
without Mosh installed still gets a green run — check that it actually ran
before trusting it on a protocol change.

// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_pty/flutter_pty.dart';

import 'terminal_env.dart';

/// Thin wrapper around a [Pty] that adds liveness tracking so callers
/// can detect process death across two independent signals:
///
///   1. [Pty.exitCode] — resolves the moment the child process exits.
///      Fastest, fires before stdout's onDone in most cases.
///   2. The wrapper's [stdout] onDone — triggered when EOF is delivered
///      on the read side. Can lag behind exitCode (or never fire if the
///      stream listener was paused while backgrounded).
///   3. A defensive write-time check — if a caller writes after we've
///      already marked the shell dead, [onDead] is triggered immediately
///      so the first keystroke after a missed exit signal still kicks
///      off recovery.
///
/// All three paths funnel into a single idempotent [onDead] callback so
/// terminal_screen can wire one restart handler instead of three.
class LocalShell {
  Pty? _pty;
  bool _alive = false;

  /// Fires exactly once when the underlying PTY process is determined
  /// to have exited (via any of the three detection paths). Idempotent
  /// — subsequent transitions don't re-fire.
  void Function()? onDead;

  bool get isAlive => _alive;

  Stream<Uint8List> get stdout => _pty!.output;

  Future<void> start({int columns = 80, int rows = 24}) async {
    _pty = Pty.start(
      '/system/bin/sh',
      environment: {
        'TERM': 'xterm-256color',
        // 见 terminal_env.dart：不声明的话 TUI 会降级到 256 色调色板。
        'COLORTERM': kColorTermValue,
        'HOME': '/data/local/tmp',
        'PATH': '/system/bin:/system/xbin:/sbin',
      },
      workingDirectory: '/data/local/tmp',
      columns: columns,
      rows: rows,
    );
    _alive = true;
    // Path 1: exitCode resolves when the child process exits.
    _pty!.exitCode.then((_) => _markDead());
  }

  void _markDead() {
    if (!_alive) return;
    _alive = false;
    final cb = onDead;
    if (cb != null) cb();
  }

  /// Mark dead from an external signal (e.g. stdout.onDone).
  /// Idempotent and safe to call from listeners.
  void notifyExited() => _markDead();

  void write(String data) {
    if (!_alive) {
      // Path 3: defensive — input attempted on a known-dead shell.
      // This catches scenarios where exitCode resolved but the listener
      // was queued behind a paused isolate and onDead hadn't propagated
      // yet, AND stdout.onDone is similarly delayed. The first keystroke
      // after death pokes the recovery flow into action.
      _markDead();
      return;
    }
    _pty?.write(Uint8List.fromList(const Utf8Encoder().convert(data)));
  }

  /// flutter_pty resize takes (rows, columns) — note reversed order vs. xterm.
  void resizeTerminal(int width, int height) {
    if (!_alive) return;
    _pty?.resize(height, width);
  }

  void close() {
    _markDead();
    _pty?.kill();
  }
}

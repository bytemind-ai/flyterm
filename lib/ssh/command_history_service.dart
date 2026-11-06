// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';

/// Provides command history for completion from two sources:
///   1. Remote shell history files (~/.bash_history, ~/.zsh_history) — loaded
///      once per session via SSH exec on first completion request.
///   2. Commands typed in the current session — recorded on every Enter press.
///
/// Session commands are prepended to history so the most recent work surfaces
/// first.  Sensitive commands (containing credentials/tokens) are never stored.
class CommandHistoryService {
  static const _kMaxHistory = 300;
  static const _kMaxResults = 15;

  static final _sensitiveRe = RegExp(
    r'(password|passwd|secret|token|apikey|api_key|sudo\s+-S)',
    caseSensitive: false,
  );
  static final _terminalControlResponseRe = RegExp(
    r'^(\??[0-9;]*[A-Za-z]|[>\?]?[0-9;]{3,}.*)$',
  );

  final _fileHistory = <String>[]; // from remote history files
  final _sessionHistory = <String>[]; // typed this session
  bool _loaded = false;

  /// Reads remote shell history files once.  Safe to call multiple times.
  Future<void> loadFromServer(SSHClient? client) async {
    if (_loaded || client == null || client.isClosed) return;
    _loaded = true;

    const script =
        r'(cat ~/.bash_history 2>/dev/null; '
        r"cat ~/.zsh_history 2>/dev/null | sed 's/^: [0-9]*:[0-9]*;//') "
        r"| awk '!seen[$0]++' | tail -300";
    final b64 = base64.encode(utf8.encode(script));
    try {
      final session = await client
          .execute('echo $b64|base64 -d|bash')
          .timeout(const Duration(seconds: 5));
      final output = await session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 5), onTimeout: () => '');
      session.stderr.drain<void>().catchError((_) {});

      final lines =
          output
              .split('\n')
              .map((l) => l.trim())
              .where(
                (l) =>
                    l.isNotEmpty &&
                    !_sensitiveRe.hasMatch(l) &&
                    !_looksLikeTerminalControlResponse(l),
              )
              .toList();

      // Store in reverse so most recent history file entries come first.
      _fileHistory
        ..clear()
        ..addAll(lines.reversed.take(_kMaxHistory));
    } catch (_) {
      // Non-fatal: completion still works via session history + compgen.
    }
  }

  /// Call on every Enter press to track current-session commands.
  void recordCommand(String cmd) {
    final trimmed = cmd.trim();
    if (trimmed.isEmpty ||
        _sensitiveRe.hasMatch(trimmed) ||
        _looksLikeTerminalControlResponse(trimmed)) {
      return;
    }
    _sessionHistory.remove(trimmed);
    _sessionHistory.insert(0, trimmed);
  }

  /// Returns commands matching [prefix], session commands first.
  /// Returns empty list if prefix has fewer than 2 characters.
  List<String> filter(String prefix) {
    if (prefix.trim().length < 2) return [];

    final seen = <String>{};
    final results = <String>[];

    void add(String cmd) {
      if (!_looksLikeTerminalControlResponse(cmd) &&
          cmd.startsWith(prefix) &&
          seen.add(cmd)) {
        results.add(cmd);
      }
    }

    for (final cmd in _sessionHistory) {
      add(cmd);
    }
    for (final cmd in _fileHistory) {
      add(cmd);
    }

    return results.take(_kMaxResults).toList();
  }

  void reset() {
    _fileHistory.clear();
    _sessionHistory.clear();
    _loaded = false;
  }

  static bool _looksLikeTerminalControlResponse(String value) {
    if (value.contains('\x1b')) return true;
    if (_terminalControlResponseRe.hasMatch(value)) return true;
    final punctuation = RegExp(r'[?;><]').allMatches(value).length;
    return punctuation >= 3 && !value.contains(' ');
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'completion_suggestion.dart';

/// Provides shell tab-completion suggestions by running `compgen` via an SSH
/// exec channel.  No AI / LLM is involved — results are the same candidates
/// the remote shell would offer on Tab press.
///
/// Strategy:
///   • First token  → `compgen -c` (command names)
///   • Other tokens → `compgen -f` (file/directory names relative to cwd)
///
/// The bash script is base64-encoded before transmission so arbitrary cwd
/// paths and prefixes require no shell quoting on the sending side.
class ShellCompletionService {
  static const _kTimeout = Duration(seconds: 2);
  static const _kCacheSize = 30;

  final _cache = <String, List<CompletionSuggestion>>{};
  final _cacheKeys = <String>[];

  Future<List<CompletionSuggestion>> suggest({
    required String currentLine,
    required SSHClient? sshClient,
    String? cwd,
  }) async {
    if (currentLine.trim().length < 2) return [];
    if (sshClient == null || sshClient.isClosed) return [];

    final trimmed = currentLine.trimRight();
    final tokens = trimmed.split(RegExp(r'\s+'));
    final prefix = tokens.last;
    if (prefix.isEmpty) return [];

    final cacheKey = '$currentLine|$cwd';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;

    final isFirstToken = tokens.length == 1;
    final cdLine = cwd != null ? 'cd ${_q(cwd)} && ' : '';
    final compgenLine = isFirstToken
        ? 'compgen -c -- ${_q(prefix)} 2>/dev/null | sort -u | head -8'
        : 'compgen -f -- ${_q(prefix)} 2>/dev/null | sort | head -8';
    final script = '$cdLine$compgenLine';

    // Base64-encode so the command string sent via SSH needs no quoting at all.
    final b64 = base64.encode(utf8.encode(script));
    final cmd = 'echo $b64|base64 -d|bash';

    try {
      final session = await sshClient.execute(cmd).timeout(_kTimeout);
      final output = await session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(_kTimeout, onTimeout: () => '');
      session.stderr.drain<void>().catchError((_) {});

      final completions = output
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty && s.startsWith(prefix))
          .take(8)
          .toList();

      final List<String> texts;
      if (isFirstToken) {
        texts = completions;
      } else {
        final leading = tokens.sublist(0, tokens.length - 1).join(' ');
        texts = completions.map((c) => '$leading $c').toList();
      }

      final suggestions = texts
          .map((t) => CompletionSuggestion(text: t, source: CompletionSource.shell))
          .toList();

      _insertCache(cacheKey, suggestions);
      return suggestions;
    } catch (_) {
      return [];
    }
  }

  // Single-quote a shell argument, escaping any embedded single quotes.
  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  void _insertCache(String key, List<CompletionSuggestion> value) {
    if (_cacheKeys.length >= _kCacheSize) {
      final evict = _cacheKeys.removeAt(0);
      _cache.remove(evict);
    }
    _cache[key] = value;
    _cacheKeys.add(key);
  }

  void clearCache() {
    _cache.clear();
    _cacheKeys.clear();
  }
}

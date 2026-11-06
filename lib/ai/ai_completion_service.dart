// SPDX-License-Identifier: GPL-3.0-or-later
import 'ai_provider.dart';

class AICompletionService {
  String? _cachedInput;
  List<String>? _cachedResult;

  Future<List<String>> suggest({
    required String currentLine,
    required AIProvider provider,
  }) async {
    if (currentLine == _cachedInput && _cachedResult != null) {
      return _cachedResult!;
    }
    final reply = await provider.complete([
      const AIMessage(
        role: 'system',
        content: 'You are a shell command autocomplete engine. '
            'Return only completions, one per line, no explanations.',
      ),
      AIMessage(
        role: 'user',
        content: 'Complete: $currentLine',
      ),
    ]);
    final results = reply
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    _cachedInput = currentLine;
    _cachedResult = results;
    return results;
  }
}

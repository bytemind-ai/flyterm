// SPDX-License-Identifier: GPL-3.0-or-later
enum CompletionSource { history, shell }

class CompletionSuggestion {
  final String text;
  final CompletionSource source;

  const CompletionSuggestion({required this.text, required this.source});

  @override
  bool operator ==(Object other) =>
      other is CompletionSuggestion && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

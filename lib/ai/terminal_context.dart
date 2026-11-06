// SPDX-License-Identifier: GPL-3.0-or-later
// lib/ai/terminal_context.dart
class TerminalContext {
  final String? cwd;
  final String? shell;
  final String? lastCommand;
  final String? terminalBuffer;

  const TerminalContext({
    this.cwd,
    this.shell,
    this.lastCommand,
    this.terminalBuffer,
  });

  String toContextString() {
    final parts = <String>[];
    if (cwd != null) parts.add('Working directory: $cwd');
    if (shell != null) parts.add('Shell: $shell');
    if (lastCommand != null) parts.add('Last command: $lastCommand');
    final buffer = StringBuffer();
    if (parts.isNotEmpty) {
      buffer.writeln('Session context:');
      for (final p in parts) {
        buffer.writeln('- $p');
      }
    }
    if (terminalBuffer != null && terminalBuffer!.isNotEmpty) {
      buffer.writeln('\nRecent terminal output:\n```\n$terminalBuffer\n```');
    }
    return buffer.toString().trimRight();
  }
}

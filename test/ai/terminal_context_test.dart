import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/terminal_context.dart';

void main() {
  test('toContextString includes all fields when set', () {
    const ctx = TerminalContext(
      cwd: '/var/log',
      shell: 'bash',
      lastCommand: 'ls -la',
      terminalBuffer: 'total 48',
    );
    final s = ctx.toContextString();
    expect(s, contains('Working directory: /var/log'));
    expect(s, contains('Shell: bash'));
    expect(s, contains('Last command: ls -la'));
    expect(s, contains('total 48'));
  });

  test('toContextString omits null fields', () {
    const ctx = TerminalContext(cwd: '/tmp');
    final s = ctx.toContextString();
    expect(s, contains('/tmp'));
    expect(s, isNot(contains('Shell:')));
    expect(s, isNot(contains('Last command:')));
  });

  test('toContextString returns empty string when all null', () {
    expect(const TerminalContext().toContextString(), isEmpty);
  });
}

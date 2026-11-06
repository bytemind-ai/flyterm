import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/data/host_normalize.dart';

void main() {
  test('plain IPv4 / hostname pass through (with trim)', () {
    expect(normalizeHost('192.168.0.1'), '192.168.0.1');
    expect(normalizeHost('  example.com  '), 'example.com');
  });

  test('bare IPv6 literal passes through (Dart Socket.connect form)', () {
    expect(normalizeHost('2001:db8::1'), '2001:db8::1');
    expect(normalizeHost('::1'), '::1');
  });

  test('bracketed IPv6 strips a single matched pair', () {
    expect(normalizeHost('[2001:db8::1]'), '2001:db8::1');
    expect(normalizeHost('[::1]'), '::1');
    expect(normalizeHost('  [2001:db8::1]  '), '2001:db8::1');
  });

  test('only-strips matching wrapper, not internal brackets', () {
    // not a wrapper — leave alone
    expect(normalizeHost('foo[bar]'), 'foo[bar]');
    expect(normalizeHost('[2001:db8::1'), '[2001:db8::1');
    expect(normalizeHost('1.2.3.4]'), '1.2.3.4]');
  });

  test('empty / minimal inputs are safe', () {
    expect(normalizeHost(''), '');
    expect(normalizeHost('   '), '');
    expect(normalizeHost('[]'), '');
  });
}

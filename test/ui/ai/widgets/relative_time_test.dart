import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/ai/widgets/relative_time.dart';

void main() {
  final t0 = DateTime(2026, 10, 6, 12, 0, 0);
  String at(Duration ago) =>
      relativeTime(t0.subtract(ago), now: t0, justNow: 'now');

  test('59 秒内是刚刚', () {
    expect(at(const Duration(seconds: 59)), 'now');
  });
  test('1 分钟起走 m', () {
    expect(at(const Duration(minutes: 1)), '1m');
    expect(at(const Duration(minutes: 59)), '59m');
  });
  test('1 小时起走 h', () {
    expect(at(const Duration(hours: 1)), '1h');
    expect(at(const Duration(hours: 23)), '23h');
  });
  test('1 天起走 d，29 天仍是 d', () {
    expect(at(const Duration(days: 1)), '1d');
    expect(at(const Duration(days: 29)), '29d');
  });
  test('30 天跨到绝对日期', () {
    expect(at(const Duration(days: 30)), '2026-09-06');
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/aqt/aqt_port_spec.dart';

void main() {
  group('AqtPortSpec.parse', () {
    test('单个端口与范围', () {
      expect(AqtPortSpec.parse('60000'), const AqtPortSpec(60000, 60000));
      expect(AqtPortSpec.parse('61001-61999'), const AqtPortSpec(61001, 61999));
      expect(AqtPortSpec.parse(' 61001-61999 '), const AqtPortSpec(61001, 61999),
          reason: '首尾空白容忍（输入框里常见）');
    });

    test('非法输入返回 null', () {
      for (final s in [
        '', '-', 'abc', '0', '80', '1023', '65536', '61999-61001', '61001-',
        '-61001', '1-2-3', '61001 - 61999', '6.1',
      ]) {
        expect(AqtPortSpec.parse(s), isNull, reason: s);
      }
    });

    test('端口必须在 1024–65535（不碰特权端口）', () {
      expect(AqtPortSpec.parse('1024'), const AqtPortSpec(1024, 1024));
      expect(AqtPortSpec.parse('65535'), const AqtPortSpec(65535, 65535));
      expect(AqtPortSpec.parse('1000-2000'), isNull);
    });
  });

  test('forServer：未配置或配置非法时用默认范围 61001-61999', () {
    expect(AqtPortSpec.forServer(null), AqtPortSpec.defaults);
    expect(AqtPortSpec.forServer(''), AqtPortSpec.defaults);
    expect(AqtPortSpec.forServer('  '), AqtPortSpec.defaults);
    expect(AqtPortSpec.forServer('junk'), AqtPortSpec.defaults);
    expect(AqtPortSpec.forServer('60000'), const AqtPortSpec(60000, 60000));
    expect(AqtPortSpec.defaults, const AqtPortSpec(61001, 61999));
  });

  test('contains 与 arg', () {
    const r = AqtPortSpec(61001, 61999);
    expect(r.contains(61001), isTrue);
    expect(r.contains(61999), isTrue);
    expect(r.contains(61000), isFalse);
    expect(r.contains(62000), isFalse);
    expect(r.arg, '61001-61999');
    expect(const AqtPortSpec(60000, 60000).arg, '60000');
  });
}

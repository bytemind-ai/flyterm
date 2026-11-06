// test/telemetry/data_scrubber_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/telemetry/data_scrubber.dart';

void main() {
  group('DataScrubber - PII redaction', () {
    test('hashHost shortens to 8 hex chars', () {
      final h = DataScrubber.hashHost('prod-web-01.example.com');
      expect(h.length, 8);
      expect(h, matches(RegExp(r'^[0-9a-f]{8}$')));
    });

    test('hashHost is deterministic', () {
      expect(
        DataScrubber.hashHost('10.0.1.5'),
        DataScrubber.hashHost('10.0.1.5'),
      );
    });

    test('redactUsername replaces with length token', () {
      expect(DataScrubber.redactUsername('root'), 'len=4');
      expect(DataScrubber.redactUsername('deployer'), 'len=8');
      expect(DataScrubber.redactUsername(''), 'len=0');
    });

    test('scrubBreadcrumbData strips known sensitive keys', () {
      final data = {
        'host': '10.0.1.5',
        'username': 'root',
        'port': 22,
        'safe_field': 'keep_me',
      };
      final scrubbed = DataScrubber.scrubBreadcrumbData(data)!;
      expect(scrubbed['host'], isNot('10.0.1.5'));
      expect(scrubbed['host'], matches(RegExp(r'^[0-9a-f]{8}$')));
      expect(scrubbed['username'], 'len=4');
      expect(scrubbed['port'], 22); // 公开信息保留
      expect(scrubbed['safe_field'], 'keep_me');
    });

    test('scrubBreadcrumbData accepts null', () {
      expect(DataScrubber.scrubBreadcrumbData(null), null);
    });
  });
}

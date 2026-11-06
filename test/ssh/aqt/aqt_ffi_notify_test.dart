import 'dart:typed_data';

import 'package:flyterm/ssh/aqt/aqt_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AqtFfi.normalizeNotifyTabId', () {
    test('-1 sentinel normalizes to null (Option<u32>::None)', () {
      expect(AqtFfi.normalizeNotifyTabId(-1), isNull);
    });

    test('non-negative values pass through unchanged', () {
      expect(AqtFfi.normalizeNotifyTabId(0), 0);
      expect(AqtFfi.normalizeNotifyTabId(1), 1);
      expect(AqtFfi.normalizeNotifyTabId(0xffffffff), 0xffffffff);
    });
  });

  group('AqtFfi.decodeNotifyPayload', () {
    Uint8List buildPayload({
      required int eventId,
      required int tsUnixMs,
      required int rawTabId,
      required String text,
    }) {
      final textBytes = Uint8List.fromList(text.codeUnits);
      final buf = ByteData(24 + textBytes.length);
      buf.setUint64(0, eventId, Endian.little);
      buf.setUint64(8, tsUnixMs, Endian.little);
      buf.setInt64(16, rawTabId, Endian.little);
      final out = buf.buffer.asUint8List();
      out.setRange(24, 24 + textBytes.length, textBytes);
      return out;
    }

    test('decodes tab_id = -1 as null (no tab)', () {
      final payload = buildPayload(
        eventId: 42,
        tsUnixMs: 1700000000000,
        rawTabId: -1,
        text: 'hello world',
      );
      final decoded = AqtFfi.decodeNotifyPayload(payload);
      expect(decoded.eventId, 42);
      expect(decoded.tsUnixMs, 1700000000000);
      expect(decoded.tabId, isNull);
      expect(decoded.text, 'hello world');
    });

    test('decodes a real tab_id as its own value (not null)', () {
      final payload = buildPayload(
        eventId: 7,
        tsUnixMs: 123456,
        rawTabId: 3,
        text: 'build finished',
      );
      final decoded = AqtFfi.decodeNotifyPayload(payload);
      expect(decoded.tabId, 3);
      expect(decoded.text, 'build finished');
    });

    test('tab_id = 0 is a real tab, not confused with the -1 sentinel', () {
      final payload = buildPayload(
        eventId: 1,
        tsUnixMs: 1,
        rawTabId: 0,
        text: '',
      );
      final decoded = AqtFfi.decodeNotifyPayload(payload);
      expect(decoded.tabId, 0);
    });
  });
}

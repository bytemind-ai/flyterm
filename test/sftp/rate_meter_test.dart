import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/rate_meter.dart';

void main() {
  group('RateMeter 速率', () {
    test('样本不足时返回 null（不显示会跳变的假数字）', () {
      final m = RateMeter();
      m.sample(bytesDone: 100, at: DateTime(2026, 1, 1, 0, 0, 0));
      expect(m.bytesPerSecond, isNull, reason: '单点无法算速率');
    });

    test('两个样本给出速率', () {
      final m = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      m.sample(bytesDone: 0, at: t0);
      m.sample(bytesDone: 1000, at: t0.add(const Duration(seconds: 1)));
      expect(m.bytesPerSecond, closeTo(1000, 1));
    });

    test('速率取窗口内平均，不是首尾瞬时', () {
      final m = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      m.sample(bytesDone: 0, at: t0);
      m.sample(bytesDone: 10000, at: t0.add(const Duration(seconds: 1)));
      // 第二个一秒只涨了 1000 —— 速率应显著低于第一秒的 10000。
      m.sample(bytesDone: 11000, at: t0.add(const Duration(seconds: 2)));
      expect(m.bytesPerSecond, lessThan(6000));
      expect(m.bytesPerSecond, greaterThan(4000));
    });

    test('速率突变后读数跟随（滑动窗口的意义）', () {
      final m = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      // 先跑 10 秒快（10 MB/s）
      for (var i = 0; i <= 10; i++) {
        m.sample(bytesDone: i * 10000000, at: t0.add(Duration(seconds: i)));
      }
      // 再跑 10 秒慢（100 KB/s）
      var bytes = 10 * 10000000;
      for (var i = 11; i <= 20; i++) {
        bytes += 100000;
        m.sample(bytesDone: bytes, at: t0.add(Duration(seconds: i)));
      }
      // 窗口只有几秒，旧的高速率样本应已被挤出。
      expect(m.bytesPerSecond, lessThan(1000000),
          reason: '不该还报着 10 MB/s');
    });
  });

  group('RateMeter ETA', () {
    test('总字节已知时给出 ETA', () {
      final m = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      m.sample(bytesDone: 0, at: t0);
      m.sample(bytesDone: 1000, at: t0.add(const Duration(seconds: 1)));
      final eta = m.etaFor(totalBytes: 5000, bytesDone: 1000);
      expect(eta, isNotNull);
      expect(eta!.inSeconds, closeTo(4, 1));
    });

    test('总字节未知时 ETA 为 null', () {
      final m = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      m.sample(bytesDone: 0, at: t0);
      m.sample(bytesDone: 1000, at: t0.add(const Duration(seconds: 1)));
      expect(m.etaFor(totalBytes: 0, bytesDone: 1000), isNull);
    });

    test('已传完时 ETA 为 0 而非负数', () {
      final m = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      m.sample(bytesDone: 0, at: t0);
      m.sample(bytesDone: 1000, at: t0.add(const Duration(seconds: 1)));
      final eta = m.etaFor(totalBytes: 1000, bytesDone: 1000);
      expect(eta, isNotNull);
      expect(eta!.isNegative, isFalse);
    });

    test('速率为 0 时 ETA 为 null（不能除零）', () {
      final m = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      m.sample(bytesDone: 100, at: t0);
      m.sample(bytesDone: 100, at: t0.add(const Duration(seconds: 1)));
      expect(m.etaFor(totalBytes: 9999, bytesDone: 100), isNull);
    });
  });

  group('RateMeter.reset', () {
    test('reset 后回到样本不足状态', () {
      final m = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      m.sample(bytesDone: 0, at: t0);
      m.sample(bytesDone: 1000, at: t0.add(const Duration(seconds: 1)));
      expect(m.bytesPerSecond, isNotNull);
      m.reset();
      expect(m.bytesPerSecond, isNull);
    });

    test('续传场景：不 reset 会算出虚高速率，reset 后正常', () {
      // 断点续传时 bytesDone 从断点起算（比如 500 MB）。若不 reset，
      // 第一个样本仍是「之前那次传输的 0」，差值会把断点算成瞬时速率。
      final m = RateMeter();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      m.sample(bytesDone: 0, at: t0); // 上一轮传输留下的样本
      m.reset(); // 续传开始
      const resumeAt = 500 * 1024 * 1024;
      m.sample(bytesDone: resumeAt, at: t0.add(const Duration(seconds: 10)));
      m.sample(
        bytesDone: resumeAt + 1000,
        at: t0.add(const Duration(seconds: 11)),
      );
      expect(m.bytesPerSecond, closeTo(1000, 1),
          reason: '只算续传后的增量，不含断点');
    });
  });
}

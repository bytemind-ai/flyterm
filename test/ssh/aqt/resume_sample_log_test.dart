import 'package:flyterm/ssh/aqt/resume_sample.dart';
import 'package:flyterm/ssh/aqt/resume_sample_log.dart';
import 'package:flutter_test/flutter_test.dart';

ResumeSample sampleWith({required int totalMs, int? backgroundMs}) {
  return ResumeSample(
    trigger: ResumeTrigger.foreground,
    backgroundMs: backgroundMs ?? 5 * 60 * 1000,
    decideMs: 0,
    retryMs: 0,
    handshakeMs: 0,
    transferMs: 0,
    applyMs: totalMs,
    attempts: const [],
    screenBytes: 1024,
    outcome: ResumeOutcomeKind.ok,
  );
}

void main() {
  group('percentile', () {
    test('空列表返回 null', () {
      expect(percentile([], 0.5), isNull);
    });

    test('单元素', () {
      expect(percentile([42], 0.5), 42);
      expect(percentile([42], 0.9), 42);
    });

    test('p50 / p90', () {
      final v = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100];
      // percentile() 用 round((N-1)*p) 取最近邻下标，遇到精确 .5 的平局
      // 一律向上取整（Dart num.round() 的行为）；N=10 时 (10-1)*0.5=4.5
      // 落在下标 4/5 正中间，按此规则取下标 5 → 60，与下面「按档位聚合」
      // 用例里 N=2 的平局 (2-1)*0.5=0.5 取下标 1 是同一条规则、同一个方向。
      expect(percentile(v, 0.5), 60);
      expect(percentile(v, 0.9), 90);
    });

    test('输入乱序也正确', () {
      expect(percentile([100, 10, 50], 0.5), 50);
    });

    test('不修改调用方的列表', () {
      final v = [30, 10, 20];
      percentile(v, 0.5);
      expect(v, [30, 10, 20]);
    });

    test('p=0.0 取最小值，p=1.0 取最大值', () {
      final v = [10, 20, 30, 40];
      expect(percentile(v, 0.0), 10);
      expect(percentile(v, 1.0), 40);
    });
  });

  group('ResumeSampleLog', () {
    test('超出容量丢最旧', () {
      final log = ResumeSampleLog(cap: 3);
      for (var i = 1; i <= 5; i++) {
        log.add(sampleWith(totalMs: i));
      }
      expect(log.samples.length, 3);
      expect(log.samples.first.totalMs, 3);
      expect(log.samples.last.totalMs, 5);
    });

    test('cap=1 只留最新一条', () {
      final log = ResumeSampleLog(cap: 1);
      log.add(sampleWith(totalMs: 1));
      log.add(sampleWith(totalMs: 2));
      expect(log.samples.length, 1);
      expect(log.samples.single.totalMs, 2);
    });

    test('按档位聚合', () {
      final log = ResumeSampleLog();
      log.add(sampleWith(totalMs: 100, backgroundMs: 10 * 1000));
      log.add(sampleWith(totalMs: 200, backgroundMs: 10 * 1000));
      log.add(sampleWith(totalMs: 900, backgroundMs: 10 * 60 * 1000));

      final stats = log.statsByBucket();
      expect(stats[BackgroundBucket.under30s]!.n, 2);
      expect(stats[BackgroundBucket.under30s]!.p50, 200);
      expect(stats[BackgroundBucket.under30min]!.n, 1);
      expect(stats.containsKey(BackgroundBucket.under90s), isFalse,
          reason: '没有样本的档位不出现在结果里');
    });

    test('abandoned 样本不进分位数统计', () {
      final log = ResumeSampleLog();
      log.add(sampleWith(totalMs: 100, backgroundMs: 10 * 1000));
      log.add(ResumeSample(
        trigger: ResumeTrigger.foreground,
        backgroundMs: 10 * 1000,
        decideMs: 0, retryMs: 0, handshakeMs: 0, transferMs: 0,
        applyMs: 99999,
        attempts: const [], screenBytes: 0,
        outcome: ResumeOutcomeKind.abandoned,
      ));
      final stats = log.statsByBucket();
      expect(stats[BackgroundBucket.under30s]!.n, 1,
          reason: '半途放弃的样本会把 p90 拉到毫无意义的高位');
    });

    test('无档位的样本（非前台触发）不进分档统计', () {
      final log = ResumeSampleLog();
      log.add(ResumeSample(
        trigger: ResumeTrigger.connectivity,
        backgroundMs: null,
        decideMs: 0, retryMs: 0, handshakeMs: 0, transferMs: 0,
        applyMs: 100,
        attempts: const [], screenBytes: 0,
        outcome: ResumeOutcomeKind.ok,
      ));
      expect(log.statsByBucket(), isEmpty);
      expect(log.samples.length, 1, reason: '样本本身仍然留存');
    });

    test('export 一行一样本', () {
      final log = ResumeSampleLog();
      log.add(sampleWith(totalMs: 100));
      log.add(sampleWith(totalMs: 200));
      expect(log.export().split('\n').length, 2);
    });
  });

  group('ResumeSampleLog.probeHits', () {
    test('按档位累加', () {
      final log = ResumeSampleLog();
      log.recordProbeHit(BackgroundBucket.under90s);
      log.recordProbeHit(BackgroundBucket.under90s);
      log.recordProbeHit(BackgroundBucket.under30s);
      expect(log.probeHits[BackgroundBucket.under90s], 2);
      expect(log.probeHits[BackgroundBucket.under30s], 1);
    });

    test('null 档位被忽略', () {
      final log = ResumeSampleLog();
      log.recordProbeHit(null);
      expect(log.probeHits, isEmpty);
    });

    test('命中不是样本 —— 不出现在 statsByBucket() 里', () {
      final log = ResumeSampleLog();
      log.recordProbeHit(BackgroundBucket.under90s);
      log.recordProbeHit(BackgroundBucket.under90s);
      expect(log.statsByBucket(), isEmpty,
          reason: '命中意味着没有发生恢复，没有五段耗时，不该混进分位数统计');
      expect(log.samples, isEmpty, reason: '命中不占用 64 条样本环的额度');
    });

    test('clear() 一并清空命中计数', () {
      final log = ResumeSampleLog();
      log.add(sampleWith(totalMs: 100));
      log.recordProbeHit(BackgroundBucket.under30s);
      log.clear();
      expect(log.samples, isEmpty);
      expect(log.probeHits, isEmpty);
    });
  });

  group('ResumeSampleLog.hasAnythingToExport', () {
    test('全空 —— 无需导出', () {
      final log = ResumeSampleLog();
      expect(log.hasAnythingToExport, isFalse);
    });

    test('只有样本 —— 需要导出', () {
      final log = ResumeSampleLog();
      log.add(sampleWith(totalMs: 100));
      expect(log.hasAnythingToExport, isTrue);
    });

    test('只有探测命中、没有样本 —— 仍然需要导出', () {
      // 这是 90s 阈值赌注成立时的典型形态：整轮都是探测命中，samples 一直
      // 为空。导出守卫如果只查 samples 就会漏掉这种情况，一个文件都不写。
      final log = ResumeSampleLog();
      log.recordProbeHit(BackgroundBucket.under90s);
      expect(log.samples, isEmpty);
      expect(log.hasAnythingToExport, isTrue,
          reason: '命中也是需要落盘的数据，不能因为 samples 为空就判定没东西可导出');
    });

    test('clear() 之后回到无需导出', () {
      final log = ResumeSampleLog();
      log.recordProbeHit(BackgroundBucket.under90s);
      log.clear();
      expect(log.hasAnythingToExport, isFalse);
    });
  });

  // 真机上 45 个样本里只有 5 个进了分档统计（bg<30s n:1 / bg<90s n:0 /
  // bg<30m n:4），另外 40 个 `backgroundMs == null`（网络切换、看门狗触发）
  // 一个都没被统计到 —— 而 overlay 上没有任何地方提示它们的存在，那几个
  // p50 看起来像整体表现，实际是 1 个样本算出来的。
  //
  // statsByBucket 跳过无档位样本是对的（它服务于 90s 阈值那个赌注），缺的
  // 是一个不分档的整体视图。
  group('statsAll —— 不分档的整体统计', () {
    ResumeSample s({
      required int totalMs,
      int? backgroundMs,
      ResumeOutcomeKind outcome = ResumeOutcomeKind.ok,
    }) =>
        ResumeSample(
          trigger: ResumeTrigger.foreground,
          backgroundMs: backgroundMs,
          decideMs: 0,
          retryMs: 0,
          handshakeMs: 0,
          transferMs: 0,
          applyMs: totalMs,
          attempts: const [],
          screenBytes: 1024,
          outcome: outcome,
        );

    test('没有样本时返回 null', () {
      expect(ResumeSampleLog().statsAll(), isNull);
    });

    test('把无档位样本一并算进去 —— 这正是分档视图看不见的那批', () {
      final log = ResumeSampleLog();
      log.add(s(totalMs: 100, backgroundMs: 10 * 1000)); // 有档位
      log.add(s(totalMs: 200)); // 无档位（网络切换）
      log.add(s(totalMs: 300)); // 无档位

      final all = log.statsAll()!;
      expect(all.n, 3, reason: '三个样本都要算，不能只算有档位的那一个');
      expect(all.p50, 200);
    });

    test('只统计 ok —— abandoned 的耗时是放弃时刻，混进去会污染分位数', () {
      final log = ResumeSampleLog();
      log.add(s(totalMs: 100));
      log.add(s(totalMs: 9999, outcome: ResumeOutcomeKind.abandoned));

      final all = log.statsAll()!;
      expect(all.n, 1);
      expect(all.p50, 100);
    });

    test('全是非 ok 样本时返回 null，而不是 n=0 的空壳', () {
      final log = ResumeSampleLog();
      log.add(s(totalMs: 100, outcome: ResumeOutcomeKind.failed));
      expect(log.statsAll(), isNull);
    });
  });

  // 五段分解是归因所需的那一维：知道 p50 是 1145ms 而不知道它花在握手还是
  // 传输上，就只能靠推算。数据一直在采（ResumeSample 的五个字段），只是从
  // 没有被聚合、也没上过屏。
  group('segmentStats —— 五段各自的 p50', () {
    ResumeSample s({
      int decide = 0,
      int retry = 0,
      int handshake = 0,
      int transfer = 0,
      int apply = 0,
      ResumeOutcomeKind outcome = ResumeOutcomeKind.ok,
    }) =>
        ResumeSample(
          trigger: ResumeTrigger.foreground,
          backgroundMs: null,
          decideMs: decide,
          retryMs: retry,
          handshakeMs: handshake,
          transferMs: transfer,
          applyMs: apply,
          attempts: const [],
          screenBytes: 1024,
          outcome: outcome,
        );

    test('没有 ok 样本时返回 null', () {
      expect(ResumeSampleLog().segmentStats(), isNull);
      final log = ResumeSampleLog();
      log.add(s(apply: 100, outcome: ResumeOutcomeKind.abandoned));
      expect(log.segmentStats(), isNull);
    });

    test('每段独立取 p50，不是按总耗时挑出的那个样本的分段', () {
      final log = ResumeSampleLog();
      // 故意让「总耗时最大」和「transfer 最大」落在不同样本上：
      // 若实现偷懒去取中位样本的分段，这条会挂。
      log.add(s(handshake: 500, transfer: 10));
      log.add(s(handshake: 10, transfer: 500));
      log.add(s(handshake: 100, transfer: 100));

      final seg = log.segmentStats()!;
      expect(seg.n, 3);
      expect(seg.handshakeMs, 100);
      expect(seg.transferMs, 100);
    });

    test('abandoned 样本不参与 —— 未走到的段兜底为 0，会把分段归因带偏', () {
      final log = ResumeSampleLog();
      log.add(s(handshake: 100, transfer: 100));
      log.add(s(handshake: 0, transfer: 0, outcome: ResumeOutcomeKind.abandoned));

      final seg = log.segmentStats()!;
      expect(seg.n, 1);
      expect(seg.handshakeMs, 100);
    });

    test('五段都取到，且与样本字段一一对应', () {
      final log = ResumeSampleLog();
      log.add(s(decide: 1, retry: 2, handshake: 3, transfer: 4, apply: 5));

      final seg = log.segmentStats()!;
      expect(
        [seg.decideMs, seg.retryMs, seg.handshakeMs, seg.transferMs, seg.applyMs],
        [1, 2, 3, 4, 5],
      );
    });
  });
}

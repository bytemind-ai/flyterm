import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/reconnect_service.dart';

// Unit test for retry delay sequence — no real SSH needed.
//
// **不要在这个文件里复制一份延迟常量再断言它自己。** 它原先就是那么写的：
// 顶部一个本地 `_kRetryDelays = [100ms, 500ms, 3s]`，前两条用例断言这个副本
// 等于自己写的字面量。实现后来改成 [50, 200, 800, 3000] 之后，那两条自证的
// 用例照样全绿，而真正引用 ReconnectService 的两条一起变红 —— 副本既没起到
// 护栏作用，还制造了「测试通过」的假象。值一律从实现现读。

void main() {
  // 数值护栏只在这两条里，改延迟序列时照着改这里是预期成本；下面的
  // trigger→档位映射用例一概不碰具体数字。
  test('conservative delays escalate monotonically', () {
    final d = ReconnectService.debugRetryDelays;
    expect(d, const [
      Duration(milliseconds: 50),
      Duration(milliseconds: 200),
      Duration(milliseconds: 800),
      Duration(seconds: 3),
    ]);
    for (var i = 1; i < d.length; i++) {
      expect(d[i], greaterThan(d[i - 1]),
          reason: '退避的全部意义就是逐级拉长，第 $i 项没有变长');
    }
  });

  test('fast delays stay under one second in total', () {
    final d = ReconnectService.debugFastRetryDelays;
    expect(d, const [
      Duration(milliseconds: 50),
      Duration(milliseconds: 150),
      Duration(milliseconds: 500),
    ]);
    final total = d.fold(Duration.zero, (a, b) => a + b);
    expect(total, lessThan(const Duration(seconds: 1)),
        reason: 'fast 档的存在理由就是亚秒级总等待，超了它就没有意义了');
  });

  test('network recovery triggers use fast retry delays', () {
    for (final trigger in const [
      'connectivity/typeChange',
      'appResume',
      'isClosedPoll',
    ]) {
      expect(ReconnectService.retryDelaysForTrigger(trigger),
          ReconnectService.debugFastRetryDelays,
          reason: trigger);
    }
  });

  test('generic retries keep conservative retry delays', () {
    expect(
      ReconnectService.retryDelaysForTrigger('periodicTimer'),
      ReconnectService.debugRetryDelays,
    );
  });

  group('bannerDelayForTrigger', () {
    test('mosh escalation shows banner immediately', () {
      // mosh soft 已经失败 1.5s+ 才会转 full，full 阶段无需再静默。
      expect(
        ReconnectService.bannerDelayForTrigger('moshV2SoftFailed/full'),
        Duration.zero,
      );
    });

    test('QUIC freeze recovery gets 3s silent window for C2 race', () {
      // proactive RESUME 失败后的 fallback 走 C2 race（RESUME ↔ bootstrap），
      // 通常 3-5s 完成。3s 静默让多数卡死恢复对用户无感。
      expect(
        ReconnectService.bannerDelayForTrigger('aqtRoamFail'),
        ReconnectService.kQuicFreezeBannerDelay,
      );
      expect(
        ReconnectService.bannerDelayForTrigger('aqtRoamException'),
        ReconnectService.kQuicFreezeBannerDelay,
      );
      expect(
        ReconnectService.kQuicFreezeBannerDelay,
        const Duration(milliseconds: 3000),
      );
    });

    test('connectivity/roam triggers keep 1.5s silent window', () {
      expect(
        ReconnectService.bannerDelayForTrigger('connectivity/typeChange'),
        ReconnectService.kBannerDelay,
      );
      expect(
        ReconnectService.bannerDelayForTrigger('connectivity/settle'),
        ReconnectService.kBannerDelay,
      );
    });

    test('first-time-disconnect triggers keep 1.5s silent window', () {
      // 真断开首次重试可能是瞬时 TCP reset，给一次静默机会。
      expect(
        ReconnectService.bannerDelayForTrigger('doneCb/init'),
        ReconnectService.kBannerDelay,
      );
      expect(
        ReconnectService.bannerDelayForTrigger('aqtDead'),
        ReconnectService.kBannerDelay,
      );
      expect(
        ReconnectService.bannerDelayForTrigger('appResume'),
        ReconnectService.kBannerDelay,
      );
    });

    test('unknown trigger defaults to 1.5s silent window', () {
      expect(
        ReconnectService.bannerDelayForTrigger('whatever'),
        ReconnectService.kBannerDelay,
      );
    });
  });
}

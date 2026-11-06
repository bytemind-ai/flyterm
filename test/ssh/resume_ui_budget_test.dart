// ReconnectService.resumeUiBudget —— 一次重连尝试的两项预算。
//
// 这组用例锁的是一个具体回归：「QUIC 自动恢复完成后会弹『已重新连接』」。
//
// 成因是 fastPath 和横幅延迟被写在同一个三元表达式里：
//     bannerDelay = fastPath ? Duration.zero : bannerDelayForTrigger(trigger)
// 于是 App 回前台触发的 fastPath 顺带拿到"立即显示横幅"，isReconnecting
// 被点亮，成功后 silentReconnect 判定失效 → 弹提示。而 fastPath 恰恰是
// 最该安静的场景：通常几百毫秒就恢复了，用户根本没察觉断过。
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/reconnect_service.dart' show ReconnectService;

void main() {
  ({Duration bannerDelay, List<Duration> retryDelays}) budget(
    String trigger, {
    bool fastPath = false,
  }) =>
      ReconnectService.resumeUiBudget(trigger: trigger, fastPath: fastPath);

  group('fastPath 只压缩重试，不动横幅', () {
    // 这条是本次修复的核心断言。
    test('fastPath 不得让横幅提前', () {
      for (final trigger in [
        'appResume',
        'dozeResume',
        'reconnectAll',
        'connectivity/settle',
        'connectivity/typeChange',
        'isClosedPoll',
        'aqtDead',
      ]) {
        expect(
          budget(trigger, fastPath: true).bannerDelay,
          budget(trigger, fastPath: false).bannerDelay,
          reason: '$trigger：fastPath 改变了横幅延迟。横幅一提前点亮，'
              'isReconnecting 就为真，成功后 silentReconnect 失效 → '
              '静默恢复变成弹「已重新连接」',
        );
      }
    });

    test('fastPath 确实把重试曲线压成单次尝试', () {
      expect(budget('appResume', fastPath: true).retryDelays, isEmpty);
      expect(budget('appResume', fastPath: false).retryDelays, isNotEmpty);
    });

    test('fastPath 下前台类 trigger 的横幅延迟仍然大于零', () {
      for (final trigger in ['appResume', 'dozeResume', 'reconnectAll']) {
        expect(budget(trigger, fastPath: true).bannerDelay,
            greaterThan(Duration.zero),
            reason: '$trigger 在 fastPath 下横幅延迟归零，就是这次要修的 bug');
      }
    });
  });

  group('立即显示横幅的场景不受影响', () {
    // 「已失败转级」——软重连已经失败、用户已经卡了一会儿，立刻给横幅是对的。
    test('moshV2SoftFailed/full 横幅延迟为零', () {
      expect(budget('moshV2SoftFailed/full').bannerDelay, Duration.zero);
    });

    test('moshV2SoftFailed/full 在 fastPath 下同样为零', () {
      expect(budget('moshV2SoftFailed/full', fastPath: true).bannerDelay,
          Duration.zero,
          reason: '它的零来自 bannerDelayForTrigger，与 fastPath 无关');
    });

    test('它是唯一一个零延迟 trigger', () {
      for (final trigger in [
        'appResume',
        'dozeResume',
        'reconnectAll',
        'connectivity/settle',
        'connectivity/typeChange',
        'isClosedPoll',
        'aqtDead',
        'aqtRoamFail',
        'aqtRoamException',
        'doneCb/init',
        'doneCb/reconnect',
        'unknown',
      ]) {
        expect(budget(trigger).bannerDelay, isNot(Duration.zero),
            reason: '$trigger 不该立即显示横幅');
      }
    });
  });

  group('与 bannerDelayForTrigger / retryDelaysForTrigger 保持一致', () {
    // 呼叫点以前两处各算一遍，现在统一取自 resumeUiBudget。
    test('非 fastPath 时两者都等价于各自的单独函数', () {
      for (final trigger in ['appResume', 'aqtRoamFail', 'unknown']) {
        final b = budget(trigger);
        expect(b.bannerDelay, ReconnectService.bannerDelayForTrigger(trigger));
        expect(b.retryDelays, ReconnectService.retryDelaysForTrigger(trigger));
      }
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/approval_notification.dart';

/// 审批通知的**展示失败补偿**判定。
///
/// ## 问题
///
/// `NotificationService.show()` 返回 `false` 表示「确定弹不出来」（权限被拒 /
/// 频道被关）。QUIC notify 那条路径对这个返回值有完整处理（降级 SnackBar、
/// 不 ack、等下轮补投），但**审批这条路把它丢了**：
///
/// ```dart
/// unawaited(NotificationService.show(...));
/// ```
///
/// 返回值直接不要了。后果是权限被拒时，审批通知**静默消失且没有任何前台
/// 降级** —— 用户既没收到锁屏通知，app 里也没提示，只看到 agent 停在那里。
/// 与 QUIC 路径的「宁可重复，不可静默丢失」承诺不一致。
///
/// 审批没有离线补投语义（进程重启 loop 就没了），所以补偿方式只能是
/// 「当场改用别的渠道让用户看见」，不能是「等下轮重投」。
///
/// 本文件锁定这个决策：什么情况下该降级为应用内提示。
void main() {
  group('审批通知展示失败补偿', () {
    test('系统通知展示成功 → 不需要降级', () {
      expect(
        shouldFallbackToInApp(
          systemNotificationShown: true,
          appInForeground: true,
        ),
        isFalse,
      );
    });

    test('系统通知失败 + app 在前台 → 降级为应用内提示', () {
      expect(
        shouldFallbackToInApp(
          systemNotificationShown: false,
          appInForeground: true,
        ),
        isTrue,
      );
    });

    test('系统通知失败 + app 在后台 → 不降级（后台根本没人看应用内提示）', () {
      // 后台时 SnackBar 会挂在一个不可见的 Scaffold 上，什么也解决不了。
      // 此时正确的做法是**不假装补偿** —— 让审批卡留在面板里，用户回到 app
      // 自然看到。这里返回 false 是为了不让调用方做无用功。
      expect(
        shouldFallbackToInApp(
          systemNotificationShown: false,
          appInForeground: false,
        ),
        isFalse,
      );
    });
  });
}

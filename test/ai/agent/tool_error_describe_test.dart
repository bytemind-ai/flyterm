import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';

/// `_describeToolError` 的行为守卫。
///
/// 起因是一次真机事故：`bash` 工具的每一条调用都只回一句
/// `Execution failed: Null check operator used on a null value` —— 连
/// `echo hi` 都是。那句话零信息量，没有文件也没有行号，而 `TypeError` 必然是
/// 我们自己的代码在某个 null 上用了 `!`。栈当时确实被记进了 `errorStack`，
/// 但没有任何界面读它，于是排查只能靠在源码里逐个 grep `!`。
void main() {
  group('工具错误文案', () {
    test('TypeError 带上栈 —— 那是代码 bug，栈是唯一有用的信息', () {
      late Object err;
      late StackTrace stack;
      try {
        // 制造一个真的 Null check operator 错误，而不是手搓一个 TypeError：
        // 要守的正是真机上那种形态。
        final Object? nothing = null;
        (nothing as String?)!.length;
      } catch (e, st) {
        err = e;
        stack = st;
      }

      final out = describeToolError(err, stack);
      expect(out, startsWith('Execution failed:'));
      expect(out.split('\n').length, greaterThan(1),
          reason: '只有一行就说明栈没带上，那就退回到零信息量的原状了');
      expect(out.split('\n').length, lessThanOrEqualTo(5),
          reason: '最多 4 帧 —— 再多会挤占 8 KiB 的输出预算');
    });

    test('普通执行失败不带栈 —— message 本身就说明了问题', () {
      // 命令返回非 0、超时、连接断开都属于这一类：附栈只会把模型的注意力
      // 引向我们的实现细节。
      final out = describeToolError(
          Exception('exit 127: command not found'), StackTrace.current);
      expect(out, 'Execution failed: Exception: exit 127: command not found');
      expect(out.contains('\n'), isFalse);
    });

    test('NoSuchMethodError 同样带栈', () {
      late Object err;
      late StackTrace stack;
      try {
        (null as dynamic).nope();
      } catch (e, st) {
        err = e;
        stack = st;
      }
      final out = describeToolError(err, stack);
      expect(out.split('\n').length, greaterThan(1));
    });
  });
}

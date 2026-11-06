import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/agent_assembly.dart';

/// 钉死 [resolveHasOtherServers] 的阈值分叉。
///
/// 这行判据是 `buildAgentLoop` 里语义最新、最容易被改错的一行：终端页 AI
/// 面板（绑定一台机器，要刨掉「自己」）用 `> 1`，全局 AI tab（没有「当前这
/// 台」，`server` 参数本身必填）用 `>= 1`。抽成顶层纯函数后不需要任何
/// provider/数据库搭建，直接枚举 `(sshServerCount, requireExplicitServer)`
/// 的四种组合即可覆盖两个阈值的边界。
void main() {
  group('resolveHasOtherServers — 终端页 AI 面板（requireExplicitServer=false）',
      () {
    // 会话绑定在当前这台机器上，判据是「除自己外还有没有别的」，阈值 > 1。
    test('0 台 ssh 服务器 → false', () {
      expect(
        resolveHasOtherServers(
            sshServerCount: 0, requireExplicitServer: false),
        isFalse,
      );
    });

    test('1 台 ssh 服务器（只有自己）→ false', () {
      expect(
        resolveHasOtherServers(
            sshServerCount: 1, requireExplicitServer: false),
        isFalse,
      );
    });

    test('2 台 ssh 服务器（自己 + 1 台别的）→ true', () {
      expect(
        resolveHasOtherServers(
            sshServerCount: 2, requireExplicitServer: false),
        isTrue,
      );
    });
  });

  group('resolveHasOtherServers — 全局 AI tab（requireExplicitServer=true）',
      () {
    // 没有「当前这台」的概念，判据是「有没有至少一台」，阈值 >= 1。
    test('0 台 ssh 服务器 → false', () {
      expect(
        resolveHasOtherServers(sshServerCount: 0, requireExplicitServer: true),
        isFalse,
      );
    });

    test('1 台 ssh 服务器 → true（全局会话这就算「有机器可打」）', () {
      expect(
        resolveHasOtherServers(sshServerCount: 1, requireExplicitServer: true),
        isTrue,
      );
    });

    test('2 台 ssh 服务器 → true', () {
      expect(
        resolveHasOtherServers(sshServerCount: 2, requireExplicitServer: true),
        isTrue,
      );
    });
  });
}

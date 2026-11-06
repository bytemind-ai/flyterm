import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ssh/ssh_connection.dart';

/// `isSshChannelSetupFailure` 是「连接还活着但开不出 channel」的唯一判据，
/// 连接池、agent exec channel、SFTP 三处共用它来识别半死连接。判据一旦漏判，
/// 那条半死连接就会被反复递给下一个调用方（这正是 QUIC 会话下 SFTP 与 AI
/// panel 同时失效的机理）；一旦误判，健康连接会被无谓地丢弃重建。
void main() {
  group('isSshChannelSetupFailure', () {
    test('SSHChannelOpenError 是最直接的信号', () {
      expect(
        isSshChannelSetupFailure(
          SSHChannelOpenError(1, 'open failed'),
        ),
        isTrue,
      );
    });

    test('SSHConnection 包装后的 StateError 也要认出来', () {
      // ssh_connection.dart 在 shell() 失败时会抛这个包装消息。
      expect(
        isSshChannelSetupFailure(
          StateError('SSH channel setup failed: whatever'),
        ),
        isTrue,
      );
    });

    test('StateError 里夹带原始类名同样算', () {
      expect(
        isSshChannelSetupFailure(
          StateError('boom: SSHChannelOpenError(1)'),
        ),
        isTrue,
      );
    });

    test('字符串里含 SSHChannelOpenError 的任意异常都算 —— 兜底匹配', () {
      expect(
        isSshChannelSetupFailure(
          Exception('wrapped: SSHChannelOpenError happened'),
        ),
        isTrue,
      );
    });

    test('认证失败不算 —— 那要走凭据流程，重建连接无济于事', () {
      expect(
        isSshChannelSetupFailure(Exception('Authentication failed')),
        isFalse,
      );
    });

    test('超时不算 —— 重建连接同样会超时，不该把它当半死连接', () {
      expect(
        isSshChannelSetupFailure(
          StateError('Authentication timed out'),
        ),
        isFalse,
      );
    });

    test('普通 StateError 不算', () {
      expect(isSshChannelSetupFailure(StateError('unrelated')), isFalse);
    });
  });
}

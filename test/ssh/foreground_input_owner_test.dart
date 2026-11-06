import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/foreground_input_owner.dart';

void main() {
  group('foregroundOwnsInputLine —— 前台程序是否接管了输入行', () {
    // 这是本次 bug 的现场：Claude Code 稳态。
    // 真机诊断行实测：tui:F xtCur:vis xtAlt:F sync，recent esc 里全是
    // CUU/CHA/SGR，一个 ?25l / ?1049h 都没有。
    test('cc 稳态：主 buffer + 光标可见 + focus tracking → 接管', () {
      expect(
        foregroundOwnsInputLine(
          cursorVisible: true,
          altBuffer: false,
          focusTracking: true,
          inTmux: false,
        ),
        isTrue,
        reason: 'cc 不切 alt buffer 也不藏光标，只能靠 focus tracking 认出来',
      );
    });

    test('bash 提示符：光标可见 + 无 alt buffer + 无 focus tracking → 不接管', () {
      expect(
        foregroundOwnsInputLine(
          cursorVisible: true,
          altBuffer: false,
          focusTracking: false,
          inTmux: false,
        ),
        isFalse,
      );
    });

    test('vim/less/top：alt buffer → 接管', () {
      expect(
        foregroundOwnsInputLine(
          cursorVisible: true,
          altBuffer: true,
          focusTracking: false,
          inTmux: false,
        ),
        isTrue,
      );
    });

    test('光标隐藏 → 接管（原有判据保留）', () {
      expect(
        foregroundOwnsInputLine(
          cursorVisible: false,
          altBuffer: false,
          focusTracking: false,
          inTmux: false,
        ),
        isTrue,
      );
    });

    // tmux attach 时自己就开 focus tracking，不排除的话 tmux 下
    // 整个会话都会被判成 TUI，补全永久失效 —— 那是比原 bug 更严重的回归。
    test('tmux 下忽略 focus tracking —— 否则补全在 tmux 里永久失效', () {
      expect(
        foregroundOwnsInputLine(
          cursorVisible: true,
          altBuffer: false,
          focusTracking: true,
          inTmux: true,
        ),
        isFalse,
        reason: 'tmux 自己开 focus tracking，这个信号在 tmux 下没有判别力',
      );
    });

    test('tmux 下 alt buffer 仍然有效 —— vim 等照常被认出', () {
      expect(
        foregroundOwnsInputLine(
          cursorVisible: true,
          altBuffer: true,
          focusTracking: true,
          inTmux: true,
        ),
        isTrue,
      );
    });

    test('tmux 下光标隐藏仍然有效', () {
      expect(
        foregroundOwnsInputLine(
          cursorVisible: false,
          altBuffer: false,
          focusTracking: true,
          inTmux: true,
        ),
        isTrue,
      );
    });
  });
}

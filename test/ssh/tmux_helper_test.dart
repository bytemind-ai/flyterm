import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/tmux_helper.dart';
import 'package:flyterm/ssh/ssh_connection.dart';

void main() {
  group('TmuxHelper commands', () {
    const fakeTabId = '12345678-0000-0000-0000-000000000000';

    test('sessionName uses first 12 chars of tabId', () {
      expect(TmuxHelper.sessionName(fakeTabId), 'flyterm-12345678-000');
    });

    test('attachOrCreate generates correct tmux command', () {
      expect(
        TmuxHelper.attachOrCreate(fakeTabId),
        r'tmux new-session -A -s flyterm-12345678-000 -e COLORTERM=truecolor -e CLAUDE_CODE_NO_FLICKER=1 -e CLAUDE_CODE_SCROLL_SPEED=3 \; set-option -g status off \; set-option -g mouse on \; set-option -g focus-events on \; set-option -g history-limit 10000 \; set-environment -t flyterm-12345678-000 COLORTERM truecolor \; set-environment -t flyterm-12345678-000 CLAUDE_CODE_NO_FLICKER 1 \; set-environment -t flyterm-12345678-000 CLAUDE_CODE_SCROLL_SPEED 3 \; set-option -ga terminal-overrides ",*:Tc"',
      );
    });

    test('attachOrCreate does not amplify scroll speed for mosh', () {
      expect(
        TmuxHelper.attachOrCreate(fakeTabId, isMosh: true),
        isNot(contains('CLAUDE_CODE_SCROLL_SPEED')),
      );
      expect(
        TmuxHelper.attachOrCreate(fakeTabId, isMosh: true),
        isNot(contains('CLAUDE_CODE_DISABLE_MOUSE')),
      );
    });

    test('attach generates correct tmux command', () {
      expect(
        TmuxHelper.attach(fakeTabId),
        r'tmux attach-session -t flyterm-12345678-000 \; set-option -g status off \; set-option -g mouse on \; set-option -g focus-events on \; set-option -g history-limit 10000 \; set-environment -t flyterm-12345678-000 COLORTERM truecolor \; set-environment -t flyterm-12345678-000 CLAUDE_CODE_NO_FLICKER 1 \; set-environment -t flyterm-12345678-000 CLAUDE_CODE_SCROLL_SPEED 3 \; set-option -ga terminal-overrides ",*:Tc"',
      );
    });
  });

  // 纯蓝背景的回归护栏。COLORTERM 缺失 → 远端 TUI 退回 256 色调色板 →
  // 深靛蓝底被量化到色立方 21 号（#0000FF）。详见 lib/ssh/terminal_env.dart。
  group('truecolor declaration', () {
    const fakeTabId = '12345678-0000-0000-0000-000000000000';

    test('non-mosh sessions declare COLORTERM on both create and attach', () {
      for (final cmd in [
        TmuxHelper.attachOrCreate(fakeTabId),
        TmuxHelper.attach(fakeTabId),
      ]) {
        // new-session -e 与 set-environment 两条都要有：前者管新建会话的首个
        // pane（-A 命中已有会话时 -e 被忽略），后者管之后 Ctrl+B c 开的 pane。
        expect(cmd, contains('set-environment -t flyterm-12345678-000 '
            'COLORTERM truecolor'));
      }
      expect(
        TmuxHelper.attachOrCreate(fakeTabId),
        contains('-e COLORTERM=truecolor'),
      );
    });

    test('non-mosh sessions tell tmux to pass RGB through', () {
      // 光声明 COLORTERM 不够 —— tmux 不认识 RGB 时会把 48;2;r;g;b 量化回
      // 调色板，等于白声明。
      expect(
        TmuxHelper.attachOrCreate(fakeTabId),
        contains(r'set-option -ga terminal-overrides ",*:Tc"'),
      );
    });

    test('RGB override is the last command in the chain', () {
      // 链式命令里一条失败会让 tmux 跳过其后所有命令。把这条放最后，万一某个
      // tmux 版本不吃它，mouse on / history-limit 不会跟着陪葬。
      expect(
        TmuxHelper.attachOrCreate(fakeTabId),
        endsWith(r'set-option -ga terminal-overrides ",*:Tc"'),
      );
    });

    test('mosh declares neither COLORTERM nor the RGB override', () {
      // mosh 1.3.2（Ubuntu 20.04/22.04 自带）不支持 24-bit 色，声明了只会让
      // 应用发出 mosh 读不懂的 RGB，颜色直接丢失 —— 比 256 色降级更差。
      for (final cmd in [
        TmuxHelper.attachOrCreate(fakeTabId, isMosh: true),
        TmuxHelper.attach(fakeTabId, isMosh: true),
      ]) {
        expect(cmd, isNot(contains('COLORTERM')));
        expect(cmd, isNot(contains('terminal-overrides')));
      }
    });
  });

  group('TmuxHelper.detect', () {
    test('returns false when SSHConnection has no client', () async {
      final conn = SSHConnection(); // client is null → throws → caught → false
      final result = await TmuxHelper.detect(conn);
      expect(result, isFalse);
    });
  });
}

/// IME 长按退格的回归测试。
///
/// 覆盖 [CustomTextEditState.updateEditingValue] 里的三条不变式：
///   1. 一次回调里输入法删掉了 N 个假缓冲字符，就必须补发 **N** 个退格 ——
///      以前上限 8 会把 Gboard 长按加速时合并回传的删除截断，表现为「删几个
///      就停」。
///   2. 缓冲没见底时不许重置 InputConnection（重置会打断连发）。
///   3. 缓冲见底时补回满值，且本地镜像同步更新（否则下一次差值算错）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';

/// 假缓冲的满值长度与补发上限 —— 与实现同步的观测点。
const int kBufferLength = 256;

void main() {
  group('CustomTextEdit delete accounting', () {
    late List<int> deletes;
    late List<String> inserts;
    late CustomTextEditState state;

    Future<void> pumpEditor(WidgetTester tester) async {
      deletes = <int>[];
      inserts = <String>[];
      final key = GlobalKey<CustomTextEditState>();
      await tester.pumpWidget(
        MaterialApp(
          home: CustomTextEdit(
            key: key,
            focusNode: FocusNode(),
            onInsert: inserts.add,
            onDelete: deletes.add,
            onComposing: (_) {},
            onAction: (_) {},
            onKeyEvent: (_, __) => KeyEventResult.ignored,
            deleteDetection: true,
            child: const SizedBox.shrink(),
          ),
        ),
      );
      state = key.currentState!;
    }

    TextEditingValue bufferOf(int length) => TextEditingValue(
          text: ' ' * length,
          selection: TextSelection.collapsed(offset: length),
        );

    testWidgets('reports the full merged delete count, not a capped 8', (
      tester,
    ) async {
      await pumpEditor(tester);

      state.updateEditingValue(bufferOf(kBufferLength - 20));

      expect(deletes, [20], reason: '合并回传的 20 次删除必须全部补发');
    });

    testWidgets('does not refill while the buffer still has headroom', (
      tester,
    ) async {
      await pumpEditor(tester);

      state.updateEditingValue(bufferOf(kBufferLength - 20));

      // 没见底 → 不重置，下一次的基准仍是「上次删剩的内容」
      expect(state.currentTextEditingValue!.text.length, kBufferLength - 20);
    });

    testWidgets('refills to full once the buffer runs low', (tester) async {
      await pumpEditor(tester);

      state.updateEditingValue(bufferOf(4));

      expect(state.currentTextEditingValue!.text.length, kBufferLength,
          reason: '见底后必须补回满值，否则长按会因「无可删文本」而中止');
      expect(state.currentTextEditingValue!.selection.baseOffset, kBufferLength);
    });

    testWidgets('stale read right after refill cannot wipe the line', (
      tester,
    ) async {
      await pumpEditor(tester);
      state.updateEditingValue(bufferOf(4)); // 触发补缓冲
      deletes.clear();

      // 补缓冲还没送达，输入法仍在按旧内容删 → 差值看起来是 250 左右
      state.updateEditingValue(bufferOf(0));

      expect(deletes.single, lessThanOrEqualTo(48),
          reason: '竞态差值是补缓冲造成的假象，一口气发几百个退格会清空命令行');
    });

    testWidgets('typing still inserts exactly the appended text', (
      tester,
    ) async {
      await pumpEditor(tester);

      state.updateEditingValue(bufferOf(kBufferLength));
      state.updateEditingValue(
        TextEditingValue(
          text: '${' ' * kBufferLength}ls',
          selection: const TextSelection.collapsed(
            offset: kBufferLength + 2,
          ),
        ),
      );

      expect(inserts, ['ls']);
    });
  });

  group('Terminal.encodeKey', () {
    test('encodes backspace without sending it', () {
      final terminal = Terminal(maxLines: 100);
      final sent = <String>[];
      terminal.onOutput = sent.add;

      final seq = terminal.encodeKey(TerminalKey.backspace);

      expect(seq, '\x7f');
      expect(sent, isEmpty, reason: 'encodeKey 只编码，不该有输出');
    });

    test('keyInput still emits, so the single-delete path is unchanged', () {
      final terminal = Terminal(maxLines: 100);
      final sent = <String>[];
      terminal.onOutput = sent.add;

      expect(terminal.keyInput(TerminalKey.backspace), isTrue);
      expect(sent, ['\x7f']);
    });

    test('a burst can be built from one encode', () {
      final terminal = Terminal(maxLines: 100);
      final sent = <String>[];
      terminal.onOutput = sent.add;

      final seq = terminal.encodeKey(TerminalKey.backspace)!;
      terminal.onOutput!(seq * 20);

      expect(sent.single.length, 20);
      expect(sent.first, '\x7f' * 20);
    });
  });
}

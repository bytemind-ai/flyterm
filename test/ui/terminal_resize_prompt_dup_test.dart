import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// 键盘弹出（视口变矮）之后多出一个 prompt。
///
/// ## 时序还原
///
/// 三段都是实测来的，不是构造的：
///
/// 1. bash 收到 SIGWINCH 后吐出的**真实字节**是 `\r\x1b[K\rPROMPT$ `
///    （本机 bash 5.2 在 PTY 里纯改行数所得）—— 回行首、清到行尾、重画
///    prompt，全程不含换行。在正常终端上它覆盖当前行，不产生新行。
/// 2. 键盘弹出把视口从 71 行压到 40 行（真机 debug overlay 的 oFB/cFB）。
/// 3. 列宽不变。
///
/// 所以只要终端在 resize 之后把光标留在了 prompt 的**下一行**，那串重绘就会
/// 清一个空行、把 prompt 画在空行上，而原来那行 prompt 原封不动 —— 屏幕上
/// 就是两个 prompt。
///
/// 这里不预设结论：先钉住"resize 之后光标仍与 prompt 同行"，跑出来是什么就
/// 是什么。
void main() {
  /// bash 5.2 在 PTY 里对纯行数 SIGWINCH 的真实响应。
  const bashRedraw = '\r\x1b[K\rPROMPT\$ ';

  String textAt(Terminal t, int row) =>
      t.buffer.lines[row].getText(0, t.viewWidth).trimRight();

  int promptCount(Terminal t) {
    var n = 0;
    for (var i = 0; i < t.buffer.lines.length; i++) {
      if (textAt(t, i).contains('PROMPT\$')) n++;
    }
    return n;
  }

  test('刚连上只有一个 prompt：视口变矮后重绘不应多出第二个', () {
    final t = Terminal(maxLines: 1000)..resize(75, 71);
    t.write('PROMPT\$ ');
    expect(promptCount(t), 1, reason: '前置：只有一个 prompt');

    // 键盘弹出。
    t.resize(75, 40);
    // bash 的 SIGWINCH 重绘。
    t.write(bashRedraw);

    expect(promptCount(t), 1,
        reason: '重绘应当覆盖原 prompt，而不是在新行再画一个');
  });

  test('prompt 上方已有输出时，视口变矮后重绘不应多出第二个', () {
    final t = Terminal(maxLines: 1000)..resize(75, 71);
    // 更贴近真机：连上时先有几行输出，再是 prompt。
    t.write('motd line 1\r\nmotd line 2\r\n');
    t.write('PROMPT\$ ');
    expect(promptCount(t), 1);

    t.resize(75, 40);
    t.write(bashRedraw);

    expect(promptCount(t), 1);
  });

  test('内容已填满视口时，视口变矮后重绘不应多出第二个', () {
    final t = Terminal(maxLines: 1000)..resize(75, 71);
    // 71 行视口写满 70 行输出，第 71 行是 prompt。
    for (var i = 0; i < 70; i++) {
      t.write('line-$i\r\n');
    }
    t.write('PROMPT\$ ');
    expect(promptCount(t), 1);

    t.resize(75, 40);
    t.write(bashRedraw);

    expect(promptCount(t), 1);
  });

  test('键盘收起（视口变高）同样不应多出 prompt', () {
    final t = Terminal(maxLines: 1000)..resize(75, 40);
    t.write('PROMPT\$ ');
    t.resize(75, 71);
    t.write(bashRedraw);

    expect(promptCount(t), 1);
  });
}

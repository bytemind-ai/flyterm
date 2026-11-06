// SPDX-License-Identifier: GPL-3.0-or-later
/// 调试面板的实时状态镜像 —— 由 TerminalWidget 就地更新，DebugOverlay 读取。
///
/// 这里只放**面板真正会显示**的字段。历史上这个文件长到 171 行，装着三个
/// State 类和两个环形日志，其中大半是给已经结案的调查（选区归属、键盘弹出
/// 多一行 prompt、滚动路径分叉）留的埋点：面板早就不显示了，写入却还在每次
/// 滑动、每次 resize 时跑。加字段前先问一句它会不会被显示出来。
class TerminalDebugState {
  /// tmux copy-mode 是否卡住 —— 滚动被拦的头号成因。
  bool tmuxInCopyMode = false;

  /// xterm 内建 Scrollable 有没有接上，以及当前滚动位置。
  /// scHasClients=false 而 scHasController=true 即 scrollback 溢出的判据。
  bool scHasController = false; // widget.scrollController != null
  bool scHasClients = false;    // scrollController.hasClients
  double scOffset = 0;          // scrollController.offset (when hasClients)
  double scMaxExtent = 0;       // scrollController.position.maxScrollExtent

  /// 最近一次上报给远端的 xterm 网格尺寸。
  int gridW = 0;
  int gridH = 0;

  // ── IME 长按退格（仅开发者浮层显示，不写终端屏幕、不弹 SnackBar）──────
  //
  // 这两个数是「长按退格为什么连发不了」的分诊器：
  //   imeHold > 0           → 自补重复跑了；远端仍只删一个，才轮到怀疑远端。
  //   imeHold = 0 且 gap 小 → 输入法 down/up 一起发（没有按住窗口），
  //                           自补重复无从下手，只能让输入法改走文本编辑通道。
  //   imeHold = 0 且 gap≈按住时长 → 定时器没接线。
  int imeHold = 0; // 自补重复（HoldRepeat）实际发出的退格数
  int imeKeyGapMs = 0; // 最近一次退格 KeyDown→KeyUp 的间隔

  /// 走文本编辑通道（`deleteSurroundingText` → `updateEditingValue`）的删除：
  /// imeDelCbs = 回调次数，imeDelChars = 输入法要求删掉的总字符数。
  ///
  /// 它和 imeHold 配合就能把一次长按拆干净：
  ///   imeDelCbs 不动 + imeHold=0  → 输入法这次长按什么都没发给我们（连发通道
  ///                                在引擎层就丢了），应用侧无从下手。
  ///   imeDelCbs 涨 但只删了一个 → 远端吞了批量退格。
  int imeDelCbs = 0;
  int imeDelChars = 0;
}

final termDebug = TerminalDebugState();

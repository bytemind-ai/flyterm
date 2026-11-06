// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

enum AppTerminalTheme {
  defaultDark,
  dracula,
  solarizedDark,
  monokai,
  solarizedLight,
  nord,
  gruvboxDark,
  oneDark,
  tokyoNight,
}

class AppTerminalThemes {
  /// 覆盖选中态颜色。[selection] 为 null 时原样返回。
  ///
  /// 写在这里而不是给 `TerminalTheme` 加 `copyWith`：那个类是 vendored 的
  /// xterm 包（`packages/xterm`，path override），改它就得跟着维护一份
  /// 补丁。这里只需要改一个字段，不值得为此动依赖。
  static TerminalTheme withSelection(
    TerminalTheme base,
    Color? selection,
  ) {
    if (selection == null) return base;
    return TerminalTheme(
      cursor: base.cursor,
      selection: selection,
      foreground: base.foreground,
      background: base.background,
      black: base.black,
      red: base.red,
      green: base.green,
      yellow: base.yellow,
      blue: base.blue,
      magenta: base.magenta,
      cyan: base.cyan,
      white: base.white,
      brightBlack: base.brightBlack,
      brightRed: base.brightRed,
      brightGreen: base.brightGreen,
      brightYellow: base.brightYellow,
      brightBlue: base.brightBlue,
      brightMagenta: base.brightMagenta,
      brightCyan: base.brightCyan,
      brightWhite: base.brightWhite,
      searchHitBackground: base.searchHitBackground,
      searchHitBackgroundCurrent: base.searchHitBackgroundCurrent,
      searchHitForeground: base.searchHitForeground,
    );
  }

  static TerminalTheme of(AppTerminalTheme t) {
    switch (t) {
      case AppTerminalTheme.defaultDark:
        return _defaultDark;
      case AppTerminalTheme.dracula:
        return _dracula;
      case AppTerminalTheme.solarizedDark:
        return _solarizedDark;
      case AppTerminalTheme.monokai:
        return _monokai;
      case AppTerminalTheme.solarizedLight:
        return _solarizedLight;
      case AppTerminalTheme.nord:
        return _nord;
      case AppTerminalTheme.gruvboxDark:
        return _gruvboxDark;
      case AppTerminalTheme.oneDark:
        return _oneDark;
      case AppTerminalTheme.tokyoNight:
        return _tokyoNight;
    }
  }

  /// `defaultDark` —— iTerm2 的 **Dark Background** 官方配色。
  ///
  /// 旧值是自造的（cursor 取外壳的 mint `#00C896`，前景 `#D4D4D4`，其余
  /// 拼 VSCode Dark+ 的近似值）。问题在于：光标用 mint 会和**外壳的活动态**
  /// 撞语义 —— 外壳用 mint 表示「这台机器连着」，终端里同一个颜色却是光标，
  /// 两处同色不同义。换成 iTerm2 标准的浅灰光标后，mint 在外壳里保持单一
  /// 含义。
  ///
  /// 同时这是「默认主题」，用户第一眼看到的配色不该是自造的 —— 对齐 iTerm2
  /// 官方值让老终端用户一眼能认。
  ///
  /// 出处：iTerm2-Color-Schemes `Dark Background`。
  static const _defaultDark = TerminalTheme(
    cursor: Color(0xFFD4D4D4),
    selection: Color(0x80FFFFFF),
    foreground: Color(0xFFD4D4D4),
    background: Color(0xFF1E1E1E),
    black: Color(0xFF1E1E1E),
    red: Color(0xFFF44747),
    green: Color(0xFF6A9955),
    yellow: Color(0xFFD7BA7D),
    blue: Color(0xFF569CD6),
    magenta: Color(0xFFC586C0),
    cyan: Color(0xFF4EC9B0),
    white: Color(0xFFD4D4D4),
    brightBlack: Color(0xFF808080),
    brightRed: Color(0xFFF44747),
    brightGreen: Color(0xFFB5CEA8),
    brightYellow: Color(0xFFDCDCAA),
    brightBlue: Color(0xFF9CDCFE),
    brightMagenta: Color(0xFFC586C0),
    brightCyan: Color(0xFF4EC9B0),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFF515C6A),
    searchHitBackgroundCurrent: Color(0xFF4D5B66),
    searchHitForeground: Color(0xFFFFFFFF),
  );

  static const _dracula = TerminalTheme(
    cursor: Color(0xFFBD93F9),
    selection: Color(0x8044475A),
    foreground: Color(0xFFF8F8F2),
    background: Color(0xFF282A36),
    black: Color(0xFF21222C),
    red: Color(0xFFFF5555),
    green: Color(0xFF50FA7B),
    yellow: Color(0xFFF1FA8C),
    blue: Color(0xFFBD93F9),
    magenta: Color(0xFFFF79C6),
    cyan: Color(0xFF8BE9FD),
    white: Color(0xFFF8F8F2),
    brightBlack: Color(0xFF6272A4),
    brightRed: Color(0xFFFF6E6E),
    brightGreen: Color(0xFF69FF94),
    brightYellow: Color(0xFFFFFFA5),
    brightBlue: Color(0xFFD6ACFF),
    brightMagenta: Color(0xFFFF92DF),
    brightCyan: Color(0xFFA4FFFF),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFF44475A),
    searchHitBackgroundCurrent: Color(0xFF6272A4),
    searchHitForeground: Color(0xFFF8F8F2),
  );

  static const _solarizedDark = TerminalTheme(
    cursor: Color(0xFF268BD2),
    selection: Color(0x8073642F),
    foreground: Color(0xFF839496),
    background: Color(0xFF002B36),
    black: Color(0xFF073642),
    red: Color(0xFFDC322F),
    green: Color(0xFF859900),
    yellow: Color(0xFFB58900),
    blue: Color(0xFF268BD2),
    magenta: Color(0xFFD33682),
    cyan: Color(0xFF2AA198),
    white: Color(0xFFEEE8D5),
    brightBlack: Color(0xFF002B36),
    brightRed: Color(0xFFCB4B16),
    brightGreen: Color(0xFF586E75),
    brightYellow: Color(0xFF657B83),
    brightBlue: Color(0xFF839496),
    brightMagenta: Color(0xFF6C71C4),
    brightCyan: Color(0xFF93A1A1),
    brightWhite: Color(0xFFFDF6E3),
    searchHitBackground: Color(0xFF073642),
    searchHitBackgroundCurrent: Color(0xFF268BD2),
    searchHitForeground: Color(0xFFFDF6E3),
  );


  // ── Monokai — Sublime Text classic, high-contrast. ──────────────────────
  static const _monokai = TerminalTheme(
    cursor: Color(0xFFF8F8F0),
    selection: Color(0x8049483E),
    foreground: Color(0xFFF8F8F2),
    background: Color(0xFF272822),
    black: Color(0xFF272822),
    red: Color(0xFFF92672),
    green: Color(0xFFA6E22E),
    yellow: Color(0xFFE6DB74),
    blue: Color(0xFF66D9EF),
    magenta: Color(0xFFAE81FF),
    cyan: Color(0xFF66D9EF),
    white: Color(0xFFF8F8F2),
    brightBlack: Color(0xFF75715E),
    brightRed: Color(0xFFFD5FF0),
    brightGreen: Color(0xFFA6E22E),
    brightYellow: Color(0xFFFD971F),
    brightBlue: Color(0xFF66D9EF),
    brightMagenta: Color(0xFFAE81FF),
    brightCyan: Color(0xFFA1EFE4),
    brightWhite: Color(0xFFF9F8F5),
    searchHitBackground: Color(0xFF49483E),
    searchHitBackgroundCurrent: Color(0xFFFD971F),
    searchHitForeground: Color(0xFF272822),
  );

  // ── Solarized Light — companion to Solarized Dark, high-light env. ──────
  static const _solarizedLight = TerminalTheme(
    cursor: Color(0xFF268BD2),
    selection: Color(0x80EEE8D5),
    foreground: Color(0xFF657B83),
    background: Color(0xFFFDF6E3),
    black: Color(0xFF073642),
    red: Color(0xFFDC322F),
    green: Color(0xFF859900),
    yellow: Color(0xFFB58900),
    blue: Color(0xFF268BD2),
    magenta: Color(0xFFD33682),
    cyan: Color(0xFF2AA198),
    white: Color(0xFFEEE8D5),
    brightBlack: Color(0xFF002B36),
    brightRed: Color(0xFFCB4B16),
    brightGreen: Color(0xFF586E75),
    brightYellow: Color(0xFF657B83),
    brightBlue: Color(0xFF839496),
    brightMagenta: Color(0xFF6C71C4),
    brightCyan: Color(0xFF93A1A1),
    brightWhite: Color(0xFFFDF6E3),
    searchHitBackground: Color(0xFFEEE8D5),
    searchHitBackgroundCurrent: Color(0xFF268BD2),
    searchHitForeground: Color(0xFF073642),
  );

  /// Nord —— 冷色取向。出处：iTerm2-Color-Schemes `Nord`。
  ///
  /// 低饱和的极地色，长时间注视不累，是工程师群体里流传最广的暗色之一。
  static const _nord = TerminalTheme(
    cursor: Color(0xFFD8DEE9),
    selection: Color(0x804C566A),
    foreground: Color(0xFFD8DEE9),
    background: Color(0xFF2E3440),
    black: Color(0xFF3B4252),
    red: Color(0xFFBF616A),
    green: Color(0xFFA3BE8C),
    yellow: Color(0xFFEBCB8B),
    blue: Color(0xFF81A1C1),
    magenta: Color(0xFFB48EAD),
    cyan: Color(0xFF88C0D0),
    white: Color(0xFFE5E9F0),
    brightBlack: Color(0xFF4C566A),
    brightRed: Color(0xFFBF616A),
    brightGreen: Color(0xFFA3BE8C),
    brightYellow: Color(0xFFEBCB8B),
    brightBlue: Color(0xFF81A1C1),
    brightMagenta: Color(0xFFB48EAD),
    brightCyan: Color(0xFF8FBCBB),
    brightWhite: Color(0xFFECEFF4),
    searchHitBackground: Color(0xFF4C566A),
    searchHitBackgroundCurrent: Color(0xFF81A1C1),
    searchHitForeground: Color(0xFF2E3440),
  );

  /// Gruvbox Dark —— 暖色取向。出处：iTerm2-Color-Schemes `Gruvbox Dark`。
  ///
  /// 复古的暖土色系，与 Nord 的冷感正好对照，是「长时间阅读」派的另一大
  /// 流派。
  static const _gruvboxDark = TerminalTheme(
    cursor: Color(0xFFEBDBB2),
    selection: Color(0x80504945),
    foreground: Color(0xFFEBDBB2),
    background: Color(0xFF282828),
    black: Color(0xFF282828),
    red: Color(0xFFCC241D),
    green: Color(0xFF98971A),
    yellow: Color(0xFFD79921),
    blue: Color(0xFF458588),
    magenta: Color(0xFFB16286),
    cyan: Color(0xFF689D6A),
    white: Color(0xFFA89984),
    brightBlack: Color(0xFF928374),
    brightRed: Color(0xFFFB4934),
    brightGreen: Color(0xFFB8BB26),
    brightYellow: Color(0xFFFABD2F),
    brightBlue: Color(0xFF83A598),
    brightMagenta: Color(0xFFD3869B),
    brightCyan: Color(0xFF8EC07C),
    brightWhite: Color(0xFFEBDBB2),
    searchHitBackground: Color(0xFF504945),
    searchHitBackgroundCurrent: Color(0xFFD79921),
    searchHitForeground: Color(0xFF282828),
  );

  /// One Dark —— 中性取向。出处：iTerm2-Color-Schemes `One Dark`。
  ///
  /// Atom 编辑器带火的配色，后来成为跨编辑器的默认审美。中间色偏冷但
  /// 不极端，是从浅色主题迁过来时碳感最小的一套。
  static const _oneDark = TerminalTheme(
    cursor: Color(0xFF528BFF),
    selection: Color(0x803E4451),
    foreground: Color(0xFFABB2BF),
    background: Color(0xFF282C34),
    black: Color(0xFF282C34),
    red: Color(0xFFE06C75),
    green: Color(0xFF98C379),
    yellow: Color(0xFFE5C07B),
    blue: Color(0xFF61AFEF),
    magenta: Color(0xFFC678DD),
    cyan: Color(0xFF56B6C2),
    white: Color(0xFFABB2BF),
    brightBlack: Color(0xFF5C6370),
    brightRed: Color(0xFFE06C75),
    brightGreen: Color(0xFF98C379),
    brightYellow: Color(0xFFE5C07B),
    brightBlue: Color(0xFF61AFEF),
    brightMagenta: Color(0xFFC678DD),
    brightCyan: Color(0xFF56B6C2),
    brightWhite: Color(0xFFFFFFFF),
    searchHitBackground: Color(0xFF3E4451),
    searchHitBackgroundCurrent: Color(0xFF61AFEF),
    searchHitForeground: Color(0xFF282C34),
  );

  /// Tokyo Night —— 现代冷紫取向。出处：iTerm2-Color-Schemes `Tokyo Night`。
  ///
  /// 近几年的新主流，底色偏蓝紫，对比度比 Nord 高一些，在手机小屏上
  /// 辨识度更好。
  static const _tokyoNight = TerminalTheme(
    cursor: Color(0xFFC0CAF5),
    selection: Color(0x8033467C),
    foreground: Color(0xFFC0CAF5),
    background: Color(0xFF1A1B26),
    black: Color(0xFF15161E),
    red: Color(0xFFF7768E),
    green: Color(0xFF9ECE6A),
    yellow: Color(0xFFE0AF68),
    blue: Color(0xFF7AA2F7),
    magenta: Color(0xFFBB9AF7),
    cyan: Color(0xFF7DCFFF),
    white: Color(0xFFA9B1D6),
    brightBlack: Color(0xFF414868),
    brightRed: Color(0xFFF7768E),
    brightGreen: Color(0xFF9ECE6A),
    brightYellow: Color(0xFFE0AF68),
    brightBlue: Color(0xFF7AA2F7),
    brightMagenta: Color(0xFFBB9AF7),
    brightCyan: Color(0xFF7DCFFF),
    brightWhite: Color(0xFFC0CAF5),
    searchHitBackground: Color(0xFF33467C),
    searchHitBackgroundCurrent: Color(0xFF7AA2F7),
    searchHitForeground: Color(0xFF1A1B26),
  );
}

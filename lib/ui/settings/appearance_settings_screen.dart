// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/font_options.dart';
import '../../data/terminal_settings.dart';
import '../../l10n/l10n.dart';
import '../terminal/terminal_themes.dart';
import 'font_preview.dart';
import 'widgets/settings_section_header.dart';

/// 外观领域子页：终端主题 / 光标样式 / 字体 / 字号 / 行高 / 字体预览。
///
/// 全部控件原样迁自 SettingsScreen 的「终端」段（2026-10-07 重排）；
/// 交互与持久化未变，只是换了挂载点。
class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.appearanceSettingsTitle),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        children: [
          const SettingsSectionHeader('THEME'),
          _TerminalThemeTile(),
          _TerminalCursorStyleTile(),
          _TerminalCursorBlinkTile(),
          _TerminalSelectionColorTile(),
          const SettingsSectionHeader('FONT'),
          _FontFamilyTile(),
          _FontSizeTile(),
          _LineHeightTile(),
          _FontPreviewTile(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// then the 7 moved classes verbatim
class _TerminalThemeTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: const Icon(Icons.palette_outlined, size: 20),
      title: Text(l.terminalTheme),
      trailing: DropdownButton<AppTerminalTheme>(
        value: settings.terminalTheme,
        underline: const SizedBox(),
        isDense: true,
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        icon: const Icon(Icons.expand_more, size: 18),
        items: [
          for (final theme in AppTerminalTheme.values)
            DropdownMenuItem(
              value: theme,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ThemeColorDots(theme: theme),
                  const SizedBox(width: 8),
                  Text(_themeLabel(l, theme),
                      style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null) settings.setTerminalTheme(v);
        },
      ),
    );
  }

  static String _themeLabel(dynamic l, AppTerminalTheme t) {
    switch (t) {
      case AppTerminalTheme.defaultDark:
        return l.terminalThemeDefault;
      case AppTerminalTheme.dracula:
        return l.terminalThemeDracula;
      case AppTerminalTheme.solarizedDark:
        return l.terminalThemeSolarizedDark;
      case AppTerminalTheme.monokai:
        return l.terminalThemeMonokai;
      case AppTerminalTheme.solarizedLight:
        return l.terminalThemeSolarizedLight;
      case AppTerminalTheme.nord:
        return l.terminalThemeNord;
      case AppTerminalTheme.gruvboxDark:
        return l.terminalThemeGruvboxDark;
      case AppTerminalTheme.oneDark:
        return l.terminalThemeOneDark;
      case AppTerminalTheme.tokyoNight:
        return l.terminalThemeTokyoNight;
    }
  }
}

class _ThemeColorDots extends StatelessWidget {
  const _ThemeColorDots({required this.theme});
  final AppTerminalTheme theme;

  @override
  Widget build(BuildContext context) {
    final t = AppTerminalThemes.of(theme);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dot(t.background),
        const SizedBox(width: 2),
        _dot(t.foreground),
        const SizedBox(width: 2),
        _dot(t.cursor),
      ],
    );
  }

  Widget _dot(Color color) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
      ),
    );
  }
}

class _TerminalCursorStyleTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: const Icon(Icons.text_fields, size: 20),
      title: Text(l.terminalCursorStyle),
      trailing: DropdownButton<TerminalCursorStyle>(
        value: settings.cursorStyle,
        underline: const SizedBox(),
        isDense: true,
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        icon: const Icon(Icons.expand_more, size: 18),
        items: [
          DropdownMenuItem(
            value: TerminalCursorStyle.defaultStyle,
            child: Text(l.terminalCursorStyleDefault,
                style: const TextStyle(fontSize: 13)),
          ),
          DropdownMenuItem(
            value: TerminalCursorStyle.verticalBar,
            child: Text(l.terminalCursorStyleVerticalBar,
                style: const TextStyle(fontSize: 13)),
          ),
          DropdownMenuItem(
            value: TerminalCursorStyle.block,
            child: Text(l.terminalCursorStyleBlock,
                style: const TextStyle(fontSize: 13)),
          ),
          DropdownMenuItem(
            value: TerminalCursorStyle.underline,
            child: Text(l.terminalCursorStyleUnderline,
                style: const TextStyle(fontSize: 13)),
          ),
        ],
        onChanged: (v) {
          if (v != null) settings.setCursorStyle(v);
        },
      ),
    );
  }
}

/// 光标闪烁开关。
///
/// 与 [_TerminalCursorStyleTile] 拆开是刻意的：旧实现把「形态」和「闪不闪」
/// 硬编成一件事（选默认态就不闪、选其他形态就闪）。iTerm2 里它们是两个独立
/// 开关，「块状 + 不闪」是常用组合。
class _TerminalCursorBlinkTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    return SwitchListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      secondary: const Icon(Icons.blur_on, size: 20),
      title: Text(l.cursorBlink),
      subtitle: Text(
        l.cursorBlinkSubtitle,
        style: const TextStyle(fontSize: 11.5),
      ),
      value: settings.cursorBlink,
      onChanged: settings.setCursorBlink,
    );
  }
}

/// 选中态颜色。
///
/// 选了预设色后才覆盖主题的 `selection`；「跟随主题」是默认项，也是唯一
/// 能保证换主题后高亮仍看得见的选择。
class _TerminalSelectionColorTile extends StatelessWidget {
  /// 预设色。选「跟随主题」之外的任一项都会覆盖主题自带值。
  ///
  /// 用固定档位而不是自由取色器：选中态只需要「与背景可区分」，自由取色
  /// 多出来的选择空间对用户没有价值，反而容易调出一个看不清的高亮。
  static const _presets = <(String, Color?)>[
    ('follow', null),
    ('blue', Color(0x80528BFF)),
    ('purple', Color(0x80B48EAD)),
    ('orange', Color(0x80D79921)),
    ('gray', Color(0x80FFFFFF)),
  ];

  String _presetLabel(AppLocalizations l, String key) => switch (key) {
        'follow' => l.selectionColorFollowTheme,
        'blue' => l.selectionColorBlue,
        'purple' => l.selectionColorPurple,
        'orange' => l.selectionColorOrange,
        _ => l.selectionColorGray,
      };

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: const Icon(Icons.highlight_alt, size: 20),
      title: Text(l.selectionColor),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, color) in _presets)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: _SelectionSwatch(
                label: _presetLabel(l, label),
                color: color,
                selected: settings.selectionColor == color,
                onTap: () => settings.setSelectionColor(color),
              ),
            ),
        ],
      ),
    );
  }
}

class _SelectionSwatch extends StatelessWidget {
  const _SelectionSwatch({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color? color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(3),
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: color ?? Colors.transparent,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: selected ? cs.primary : cs.outline,
                width: selected ? 2 : 0.5,
              ),
            ),
            // 「跟随主题」没有具体颜色可画，用一个斜杠标记 —— 留空会被
            // 误认为「白色」这个选项。
            child: color == null
                ? Icon(Icons.format_color_reset, size: 13, color: cs.onSurface)
                : null,
          ),
        ),
      ),
    );
  }
}

class _FontFamilyTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: const Icon(Icons.font_download_outlined, size: 20),
      title: Text(l.codeFont),
      trailing: DropdownButton<String>(
        value: settings.fontFamily,
        underline: const SizedBox(),
        isDense: true,
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        icon: const Icon(Icons.expand_more, size: 18),
        onChanged: (v) {
          if (v != null) settings.setFontFamily(v);
        },
        items: [
          for (final id in FontOptions.builtInFamilies)
            DropdownMenuItem(
              value: id,
              child: Text(
                id == 'system'
                    ? l.fontFamilySystem
                    : FontOptions.familyDisplayName(id),
                style: TextStyle(
                  fontFamily: id == 'system' ? null : id,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LineHeightTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: const Icon(Icons.format_line_spacing, size: 20),
          title: Text(l.lineHeight),
          // 数值用 JetBrains Mono 跟 _FontSizeTile trailing 风格一致。
          trailing: Text(
            settings.lineHeight.toStringAsFixed(2),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11.5,
              color: cs.onSurface.withOpacity(0.6),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Slider(
            value: settings.lineHeight,
            min: TerminalSettings.minLineHeight,
            max: TerminalSettings.maxLineHeight,
            divisions: 20,
            onChanged: settings.setLineHeight,
          ),
        ),
      ],
    );
  }
}

class _FontPreviewTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final settings = context.watch<TerminalSettings>();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FontPreview(
        fontFamily: settings.fontFamily,
        fontSize: settings.fontSize,
        height: settings.lineHeight,
      ),
    );
  }
}

class _FontSizeTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = context.watch<TerminalSettings>();
    final size = settings.fontSize;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ListTile 标准 pattern：跟其他 Tile 一致的 leading 字号/dense/紧凑度。
        // trailing value 用 JetBrains Mono 数字字体一致风格（与 _LineHeightTile 对齐）。
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: const Icon(Icons.text_fields, size: 20),
          title: Text(l.terminalFontSize),
          trailing: Text(
            '${size.round()} pt',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11.5,
              color: cs.onSurface.withOpacity(0.6),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Row(
            children: [
              IconButton(
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: size <= TerminalSettings.minFontSize
                    ? null
                    : () => settings.setFontSize(size - 1),
              ),
              Expanded(
                child: Slider(
                  value: size,
                  min: TerminalSettings.minFontSize,
                  max: TerminalSettings.maxFontSize,
                  divisions: (TerminalSettings.maxFontSize -
                          TerminalSettings.minFontSize)
                      .round(),
                  onChanged: settings.setFontSize,
                ),
              ),
              IconButton(
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_circle_outline),
                onPressed: size >= TerminalSettings.maxFontSize
                    ? null
                    : () => settings.setFontSize(size + 1),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later
/// Pure data model for KeyBar customization. No Flutter imports — usable
/// from settings layer, test layer, and runtime layer alike.

enum SpecialKey {
  esc, tab, enter, backspace,
  up, down, left, right,
  home, end,
  // Editing & paging — added in v2 (none of these can be composed via
  // TextToken because their byte sequences contain a literal 0x1B).
  delete, insert, pageUp, pageDown, shiftTab, shift, alt, ctrl,
  space, shiftEnter,
  // Ctrl-modified arrows (word-jump in shells/editors) and a few other
  // ctrl combos that can't be expressed via the sticky-CTRL XOR rule
  // because their unmodified payload doesn't start with a printable
  // ASCII char in the 0x40–0x7e range.
  ctrlUp, ctrlDown, ctrlLeft, ctrlRight,
  ctrlBackspace, ctrlSpace,
  f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
  ctrlA, ctrlB, ctrlC, ctrlD, ctrlE, ctrlF, ctrlG, ctrlH, ctrlI, ctrlJ,
  ctrlK, ctrlL, ctrlM, ctrlN, ctrlO, ctrlP, ctrlQ, ctrlR, ctrlS, ctrlT,
  ctrlU, ctrlV, ctrlW, ctrlX, ctrlY, ctrlZ,
}

sealed class KeyToken {
  const KeyToken();

  Map<String, dynamic> toJson();

  static KeyToken fromJson(Map<String, dynamic> j) {
    final type = j['type'];
    switch (type) {
      case 'text':
        return TextToken(j['text'] as String);
      case 'special':
        final name = j['key'] as String;
        final key = SpecialKey.values.firstWhere(
          (k) => k.name == name,
          orElse: () => throw ArgumentError('Unknown SpecialKey: $name'),
        );
        return SpecialToken(key);
      default:
        throw ArgumentError('Unknown KeyToken type: $type');
    }
  }
}

class TextToken extends KeyToken {
  final String text;
  const TextToken(this.text);

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};

  @override
  bool operator ==(Object other) =>
      other is TextToken && other.text == text;
  @override
  int get hashCode => text.hashCode;
}

class SpecialToken extends KeyToken {
  final SpecialKey key;
  const SpecialToken(this.key);

  @override
  Map<String, dynamic> toJson() => {'type': 'special', 'key': key.name};

  @override
  bool operator ==(Object other) =>
      other is SpecialToken && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

/// Convert a sequence of tokens into the raw byte string sent to the
/// terminal.
///
/// [cursorKeysAppMode] mirrors xterm's DECCKM (CSI ? 1 h). When true,
/// arrows emit SS3 form (`ESC O A/B/C/D`) instead of the default CSI
/// form. TUIs like Claude CLI's `/resume` picker, vim, less, and most
/// Ink/blessed-based pickers enable application cursor mode and
/// require SS3 to recognize arrow input.
String encodeSequence(List<KeyToken> tokens,
    {bool cursorKeysAppMode = false}) {
  final buf = StringBuffer();
  for (final t in tokens) {
    if (t is TextToken) {
      buf.write(t.text);
    } else if (t is SpecialToken) {
      buf.write(_encodeSpecial(t.key, cursorKeysAppMode));
    }
  }
  return buf.toString();
}

String _encodeSpecial(SpecialKey k, bool appCursor) {
  switch (k) {
    case SpecialKey.esc:        return '\x1b';
    case SpecialKey.tab:        return '\t';
    case SpecialKey.enter:      return '\r';
    case SpecialKey.backspace:  return '\x7f';
    case SpecialKey.up:         return appCursor ? '\x1bOA' : '\x1b[A';
    case SpecialKey.down:       return appCursor ? '\x1bOB' : '\x1b[B';
    case SpecialKey.right:      return appCursor ? '\x1bOC' : '\x1b[C';
    case SpecialKey.left:       return appCursor ? '\x1bOD' : '\x1b[D';
    case SpecialKey.home:       return '\x1b[H';
    case SpecialKey.end:        return '\x1b[F';
    case SpecialKey.delete:     return '\x1b[3~';
    case SpecialKey.insert:     return '\x1b[2~';
    case SpecialKey.pageUp:     return '\x1b[5~';
    case SpecialKey.pageDown:   return '\x1b[6~';
    case SpecialKey.shiftTab:   return '\x1b[Z';
    case SpecialKey.shift:      return '';
    case SpecialKey.alt:        return '';
    case SpecialKey.ctrl:       return '';
    case SpecialKey.space:      return ' ';
    case SpecialKey.shiftEnter: return '\x1b\r';
    // Modified arrows always use CSI form regardless of DECCKM (xterm
    // doesn't define SS3 variants for the modified versions). Modifier
    // code 5 = Ctrl per the standard xterm parameter table.
    case SpecialKey.ctrlUp:        return '\x1b[1;5A';
    case SpecialKey.ctrlDown:      return '\x1b[1;5B';
    case SpecialKey.ctrlRight:     return '\x1b[1;5C';
    case SpecialKey.ctrlLeft:      return '\x1b[1;5D';
    case SpecialKey.ctrlBackspace: return '\x17'; // readline word-delete
    case SpecialKey.ctrlSpace:     return '\x00'; // NUL — emacs/vim mark
    case SpecialKey.f1:         return '\x1bOP';
    case SpecialKey.f2:         return '\x1bOQ';
    case SpecialKey.f3:         return '\x1bOR';
    case SpecialKey.f4:         return '\x1bOS';
    case SpecialKey.f5:         return '\x1b[15~';
    case SpecialKey.f6:         return '\x1b[17~';
    case SpecialKey.f7:         return '\x1b[18~';
    case SpecialKey.f8:         return '\x1b[19~';
    case SpecialKey.f9:         return '\x1b[20~';
    case SpecialKey.f10:        return '\x1b[21~';
    case SpecialKey.f11:        return '\x1b[23~';
    case SpecialKey.f12:        return '\x1b[24~';
    case SpecialKey.ctrlA:      return '\x01';
    case SpecialKey.ctrlB:      return '\x02';
    case SpecialKey.ctrlC:      return '\x03';
    case SpecialKey.ctrlD:      return '\x04';
    case SpecialKey.ctrlE:      return '\x05';
    case SpecialKey.ctrlF:      return '\x06';
    case SpecialKey.ctrlG:      return '\x07';
    case SpecialKey.ctrlH:      return '\x08';
    case SpecialKey.ctrlI:      return '\x09';
    case SpecialKey.ctrlJ:      return '\x0a';
    case SpecialKey.ctrlK:      return '\x0b';
    case SpecialKey.ctrlL:      return '\x0c';
    case SpecialKey.ctrlM:      return '\x0d';
    case SpecialKey.ctrlN:      return '\x0e';
    case SpecialKey.ctrlO:      return '\x0f';
    case SpecialKey.ctrlP:      return '\x10';
    case SpecialKey.ctrlQ:      return '\x11';
    case SpecialKey.ctrlR:      return '\x12';
    case SpecialKey.ctrlS:      return '\x13';
    case SpecialKey.ctrlT:      return '\x14';
    case SpecialKey.ctrlU:      return '\x15';
    case SpecialKey.ctrlV:      return '\x16';
    case SpecialKey.ctrlW:      return '\x17';
    case SpecialKey.ctrlX:      return '\x18';
    case SpecialKey.ctrlY:      return '\x19';
    case SpecialKey.ctrlZ:      return '\x1a';
  }
}

class KeyBarItem {
  final String id;
  final String label;
  final List<KeyToken> sequence;
  final bool sticky;
  final bool repeatable;

  const KeyBarItem({
    required this.id,
    required this.label,
    required this.sequence,
    required this.sticky,
    required this.repeatable,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'sequence': sequence.map((t) => t.toJson()).toList(),
        'sticky': sticky,
        'repeatable': repeatable,
      };

  factory KeyBarItem.fromJson(Map<String, dynamic> j) => KeyBarItem(
        id: j['id'] as String,
        label: j['label'] as String,
        sequence: (j['sequence'] as List)
            .map((e) => KeyToken.fromJson(e as Map<String, dynamic>))
            .toList(),
        sticky: j['sticky'] as bool? ?? false,
        repeatable: j['repeatable'] as bool? ?? false,
      );

  KeyBarItem copyWith({
    String? id,
    String? label,
    List<KeyToken>? sequence,
    bool? sticky,
    bool? repeatable,
  }) =>
      KeyBarItem(
        id: id ?? this.id,
        label: label ?? this.label,
        sequence: sequence ?? this.sequence,
        sticky: sticky ?? this.sticky,
        repeatable: repeatable ?? this.repeatable,
      );
}

/// Seed configuration mirroring the legacy hardcoded KeyBar 1:1 so users
/// see no behavioural change after upgrade.
List<KeyBarItem> defaultKeyBarItems() => [
      _seedItem('seed-esc', 'ESC',
          [SpecialToken(SpecialKey.esc)]),
      _seedItem('seed-tab', 'TAB',
          [SpecialToken(SpecialKey.tab)]),
      KeyBarItem(
          id: 'seed-ctrl',
          label: 'CTRL',
          sequence: const [],
          sticky: true,
          repeatable: false),
      _seedItem('seed-alt', 'ALT',
          [SpecialToken(SpecialKey.esc)]),
      KeyBarItem(
          id: 'seed-shift',
          label: '⇧',
          sequence: const [SpecialToken(SpecialKey.shift)],
          sticky: true,
          repeatable: false),
      _seedItem('seed-up', '↑',
          [SpecialToken(SpecialKey.up)], repeatable: true),
      _seedItem('seed-down', '↓',
          [SpecialToken(SpecialKey.down)], repeatable: true),
      _seedItem('seed-left', '←',
          [SpecialToken(SpecialKey.left)], repeatable: true),
      _seedItem('seed-right', '→',
          [SpecialToken(SpecialKey.right)], repeatable: true),
      _seedItem('seed-bksp', '⌫',
          [SpecialToken(SpecialKey.backspace)], repeatable: true),
      _seedItem('seed-pipe', '|', [TextToken('|')]),
      _seedItem('seed-tilde', '~', [TextToken('~')]),
      _seedItem('seed-slash', '/', [TextToken('/')]),
      _seedItem('seed-dash', '-', [TextToken('-')]),
    ];

KeyBarItem _seedItem(String id, String label, List<KeyToken> seq,
        {bool repeatable = false}) =>
    KeyBarItem(
        id: id,
        label: label,
        sequence: seq,
        sticky: false,
        repeatable: repeatable);

/// Identifies the built-in right-side function buttons. Unlike
/// [KeyBarItem], these trigger app-level callbacks (favorites picker,
/// voice input, AI panel) rather than sending bytes to the terminal —
/// so users can only enable/disable and reorder them, not create new
/// ones or delete them outright.
///
/// [keyboard] is retained for backward-compatible JSON parsing of
/// older builds that persisted it as a customizable item, but it is
/// no longer offered in the editor. The soft-keyboard show button is
/// now driven by [TerminalSettings.keyboardTrigger] and rendered as a
/// fixed leftmost icon in the right block whenever the user has
/// selected the icon-button trigger mode. See keybar_editor_screen.
enum RightButton { keyboard, favorites, microphone, ai, attachFile }

class RightButtonItem {
  final RightButton type;
  final bool enabled;
  const RightButtonItem({required this.type, required this.enabled});

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'enabled': enabled,
      };

  factory RightButtonItem.fromJson(Map<String, dynamic> j) {
    final name = j['type'] as String;
    final type = RightButton.values.firstWhere(
      (e) => e.name == name,
      orElse: () => throw ArgumentError('Unknown RightButton: $name'),
    );
    return RightButtonItem(
      type: type,
      enabled: j['enabled'] as bool? ?? true,
    );
  }

  RightButtonItem copyWith({RightButton? type, bool? enabled}) =>
      RightButtonItem(
        type: type ?? this.type,
        enabled: enabled ?? this.enabled,
      );
}

/// Default right-button order. Excludes [RightButton.keyboard] because
/// the soft-keyboard trigger is now managed via the keyboard-mode
/// section of the editor (TerminalSettings.keyboardTrigger), not as a
/// customizable right-side button. All entries start enabled.
List<RightButtonItem> defaultRightButtons() => const [
      RightButtonItem(type: RightButton.favorites, enabled: true),
      RightButtonItem(type: RightButton.microphone, enabled: true),
      RightButtonItem(type: RightButton.ai, enabled: true),
      // 加进默认列表**就是**存量用户的迁移路径：KeybarSettings 加载时会把
      // 「默认里有、存储里没有」的按钮追加进去（keybar_settings.dart:78-87）。
      // 用户主动关掉是 enabled:false，那一项仍在存储里，不属于 missing，
      // 不会被重新加回来。
      RightButtonItem(type: RightButton.attachFile, enabled: true),
    ];

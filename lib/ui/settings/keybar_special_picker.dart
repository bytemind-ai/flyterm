// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import '../../data/keybar_config.dart';
import '../../l10n/l10n.dart';

/// Modal bottom sheet that lets the user pick a single SpecialKey to
/// insert into the sequence currently being edited. Returns the picked
/// key via Navigator.pop, or null if dismissed.
///
/// Usage:
///   final key = await showModalBottomSheet<SpecialKey>(
///     context: ctx,
///     builder: (_) => const KeybarSpecialKeyPicker(),
///   );
class KeybarSpecialKeyPicker extends StatelessWidget {
  const KeybarSpecialKeyPicker({super.key});

  static const _control = [
    SpecialKey.esc, SpecialKey.tab, SpecialKey.shiftTab,
    SpecialKey.enter, SpecialKey.shiftEnter, SpecialKey.space,
    SpecialKey.backspace, SpecialKey.delete,
  ];
  static const _modifiers = [
    SpecialKey.shift, SpecialKey.alt, SpecialKey.ctrl,
  ];
  static const _arrows = [
    SpecialKey.up, SpecialKey.down, SpecialKey.left, SpecialKey.right,
  ];
  static const _nav = [
    SpecialKey.home, SpecialKey.end,
    SpecialKey.pageUp, SpecialKey.pageDown,
  ];
  static const _modifierCombos = [
    SpecialKey.ctrlUp, SpecialKey.ctrlDown,
    SpecialKey.ctrlLeft, SpecialKey.ctrlRight,
    SpecialKey.ctrlBackspace, SpecialKey.ctrlSpace,
  ];
  static const _function = [
    SpecialKey.f1, SpecialKey.f2, SpecialKey.f3, SpecialKey.f4,
    SpecialKey.f5, SpecialKey.f6, SpecialKey.f7, SpecialKey.f8,
    SpecialKey.f9, SpecialKey.f10, SpecialKey.f11, SpecialKey.f12,
  ];
  static const _ctrl = [
    SpecialKey.ctrlA, SpecialKey.ctrlB, SpecialKey.ctrlC, SpecialKey.ctrlD,
    SpecialKey.ctrlE, SpecialKey.ctrlF, SpecialKey.ctrlG,
    SpecialKey.ctrlK, SpecialKey.ctrlL,
    SpecialKey.ctrlN, SpecialKey.ctrlO, SpecialKey.ctrlP,
    SpecialKey.ctrlQ, SpecialKey.ctrlR, SpecialKey.ctrlS, SpecialKey.ctrlT,
    SpecialKey.ctrlU, SpecialKey.ctrlV, SpecialKey.ctrlW, SpecialKey.ctrlX,
    SpecialKey.ctrlY, SpecialKey.ctrlZ,
  ];

  static String labelFor(SpecialKey k) {
    switch (k) {
      case SpecialKey.esc:        return 'Esc';
      case SpecialKey.tab:        return 'Tab';
      case SpecialKey.enter:      return 'Enter';
      case SpecialKey.backspace:  return '⌫';
      case SpecialKey.up:         return '↑';
      case SpecialKey.down:       return '↓';
      case SpecialKey.left:       return '←';
      case SpecialKey.right:      return '→';
      case SpecialKey.home:       return 'Home';
      case SpecialKey.end:        return 'End';
      case SpecialKey.delete:     return 'Del';
      case SpecialKey.insert:     return 'Ins';
      case SpecialKey.pageUp:     return 'PgUp';
      case SpecialKey.pageDown:   return 'PgDn';
      case SpecialKey.shiftTab:   return '⇤Tab';
      case SpecialKey.shift:      return 'Shift';
      case SpecialKey.alt:        return 'Alt';
      case SpecialKey.ctrl:       return 'Ctrl';
      case SpecialKey.space:      return 'Space';
      case SpecialKey.shiftEnter: return '⇧Enter';
      case SpecialKey.ctrlUp:        return '^↑';
      case SpecialKey.ctrlDown:      return '^↓';
      case SpecialKey.ctrlLeft:      return '^←';
      case SpecialKey.ctrlRight:     return '^→';
      case SpecialKey.ctrlBackspace: return '^⌫';
      case SpecialKey.ctrlSpace:     return '^Space';
      case SpecialKey.f1:  return 'F1';
      case SpecialKey.f2:  return 'F2';
      case SpecialKey.f3:  return 'F3';
      case SpecialKey.f4:  return 'F4';
      case SpecialKey.f5:  return 'F5';
      case SpecialKey.f6:  return 'F6';
      case SpecialKey.f7:  return 'F7';
      case SpecialKey.f8:  return 'F8';
      case SpecialKey.f9:  return 'F9';
      case SpecialKey.f10: return 'F10';
      case SpecialKey.f11: return 'F11';
      case SpecialKey.f12: return 'F12';
      case SpecialKey.ctrlA: return '^A';
      case SpecialKey.ctrlB: return '^B';
      case SpecialKey.ctrlC: return '^C';
      case SpecialKey.ctrlD: return '^D';
      case SpecialKey.ctrlE: return '^E';
      case SpecialKey.ctrlF: return '^F';
      case SpecialKey.ctrlG: return '^G';
      case SpecialKey.ctrlH: return '^H';
      case SpecialKey.ctrlI: return '^I';
      case SpecialKey.ctrlJ: return '^J';
      case SpecialKey.ctrlK: return '^K';
      case SpecialKey.ctrlL: return '^L';
      case SpecialKey.ctrlM: return '^M';
      case SpecialKey.ctrlN: return '^N';
      case SpecialKey.ctrlO: return '^O';
      case SpecialKey.ctrlP: return '^P';
      case SpecialKey.ctrlQ: return '^Q';
      case SpecialKey.ctrlR: return '^R';
      case SpecialKey.ctrlS: return '^S';
      case SpecialKey.ctrlT: return '^T';
      case SpecialKey.ctrlU: return '^U';
      case SpecialKey.ctrlV: return '^V';
      case SpecialKey.ctrlW: return '^W';
      case SpecialKey.ctrlX: return '^X';
      case SpecialKey.ctrlY: return '^Y';
      case SpecialKey.ctrlZ: return '^Z';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => SafeArea(
        child: ListView(
          controller: scrollController,
          padding: EdgeInsets.zero,
          children: [
            // Sheet title
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                l.keybarSpecialPickerTitle,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
            ),
            // 0.5px hairline
            Container(
              height: 0.5,
              margin: const EdgeInsets.symmetric(horizontal: 16),
              color: cs.onSurface.withOpacity(0.08),
            ),
            _section(context, l.keybarSpecialCategoryControl, _control),
            _section(context, l.keybarSpecialCategoryModifiers, _modifiers),
            _section(context, l.keybarSpecialCategoryArrows, _arrows),
            _section(context, l.keybarSpecialCategoryNav, _nav),
            _section(context, l.keybarSpecialCategoryModifierCombos,
                _modifierCombos),
            _section(context, l.keybarSpecialCategoryFunction, _function),
            _section(context, l.keybarSpecialCategoryCtrl, _ctrl),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<SpecialKey> keys) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: keys.map((k) {
              final lbl = labelFor(k);
              return _KeyChip(label: lbl, onTap: () => Navigator.of(context).pop(k));
            }).toList(),
          ),
        ),
        // thin hairline between sections
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            height: 0.5,
            color: cs.onSurface.withOpacity(0.08),
          ),
        ),
      ],
    );
  }
}

/// Single tappable key chip — mono uppercase, 0.5px border, 6px radius.
class _KeyChip extends StatelessWidget {
  const _KeyChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  static const _accent = Color(0xFF00C896);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: cs.surfaceVariant.withOpacity(0.35),
          border: Border.all(
            color: cs.onSurface.withOpacity(0.18),
            width: 0.5,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: _accent,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

/// Industrial Monitor Console 风格 section header。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  static bool _isAscii(String s) {
    for (final c in s.codeUnits) {
      if (c > 0x7E) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final ascii = _isAscii(label);
    final color = Theme.of(context).colorScheme.onSurface.withOpacity(0.55);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        ascii ? label.toUpperCase() : label,
        style: TextStyle(
          fontFamily: ascii ? 'JetBrainsMono' : null,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: ascii ? 1.2 : 0,
          height: 1.0,
        ),
      ),
    );
  }
}

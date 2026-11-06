// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import '../../data/keybar_config.dart';
import '../../data/keybar_settings.dart';
import '../../l10n/l10n.dart';

class KeyBar extends StatefulWidget {
  final Terminal terminal;
  final VoidCallback? onAITap;
  final VoidCallback? onMicTap;
  final VoidCallback? onFavoritesTap;
  final VoidCallback? onShowKeyboard;
  /// 附件按钮。为 null 时不渲染 —— 与其它右侧按钮同一惯例。
  final VoidCallback? onAttachTap;
  final bool aiActive;
  final bool micActive;
  const KeyBar({
    super.key,
    required this.terminal,
    this.onAITap,
    this.onMicTap,
    this.onFavoritesTap,
    this.onShowKeyboard,
    this.onAttachTap,
    this.aiActive = false,
    this.micActive = false,
  });

  @override
  State<KeyBar> createState() => _KeyBarState();
}

class _KeyBarState extends State<KeyBar> {
  /// True while a sticky modifier (CTRL) is armed. The next tap on a
  /// non-sticky key has its first character converted to its Ctrl-prefixed
  /// form and the flag is cleared.
  bool _ctrlActive = false;
  bool _shiftActive = false;
  // ScrollController for the key list — used to detect whether the user
  // has scrolled right so we can show a left-edge fade hint.
  final _scrollCtrl = ScrollController();
  bool _showLeftFade = false;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(() {
      final show = _scrollCtrl.offset > 4;
      if (show != _showLeftFade) setState(() => _showLeftFade = show);
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  static bool _isShiftItem(KeyBarItem item) =>
      item.sticky &&
      item.sequence.any((t) => t is SpecialToken && t.key == SpecialKey.shift);

  void _handleTap(KeyBarItem item) {
    if (item.sticky) {
      if (_isShiftItem(item)) {
        setState(() { _shiftActive = !_shiftActive; _ctrlActive = false; });
      } else {
        setState(() { _ctrlActive = !_ctrlActive; _shiftActive = false; });
      }
      return;
    }
    final appCursor = widget.terminal.cursorKeysMode;
    String payload = encodeSequence(item.sequence, cursorKeysAppMode: appCursor);
    if (_shiftActive && payload.isNotEmpty) {
      payload = _applyShiftModifier(item, payload);
      setState(() => _shiftActive = false);
    } else if (_ctrlActive && payload.isNotEmpty) {
      payload = _applyCtrlModifier(item, payload, appCursor);
      setState(() => _ctrlActive = false);
    }
    widget.terminal.onOutput?.call(payload);
  }

  /// Apply the sticky-CTRL modifier to [payload] in a way that respects
  /// each key's actual byte form, instead of blindly XOR'ing the first
  /// byte (which silently no-op'd for arrows / page keys / function
  /// keys).
  ///
  /// Strategy:
  ///   1. If the user typed text or a Ctrl-prefixable char (0x40..0x7e),
  ///      apply the classic ASCII XOR: `c & 0x1f` → ^A..^_.
  ///   2. If the item is a single arrow / page / nav key with a known
  ///      Ctrl-modified CSI form, swap to that form.
  ///   3. Otherwise (F-keys, BS, Tab, Enter, Space, etc.), fall back to
  ///      the explicit dedicated SpecialKey if one exists; if not, send
  ///      the unmodified payload AND surface a one-shot SnackBar so the
  ///      user knows the modifier didn't apply.
  String _applyCtrlModifier(KeyBarItem item, String payload, bool appCursor) {
    // Case 2: single special-key item with a Ctrl-modified equivalent.
    if (item.sequence.length == 1 && item.sequence.first is SpecialToken) {
      final key = (item.sequence.first as SpecialToken).key;
      final modified = _ctrlModifiedFor(key);
      if (modified != null) {
        return encodeSequence([SpecialToken(modified)],
            cursorKeysAppMode: appCursor);
      }
      // Known-but-unmodifiable special key (e.g., F1..F12, sticky-Tab).
      if (_ctrlNotApplicable(key)) {
        _flashCtrlNotApplicable();
        return payload;
      }
    }
    // Case 1: ASCII XOR for printable bytes.
    final firstByte = payload.codeUnitAt(0);
    if (firstByte >= 0x40 && firstByte <= 0x7e) {
      final ctrlChar = firstByte & 0x1f;
      return String.fromCharCode(ctrlChar) + payload.substring(1);
    }
    // Case 3: byte is outside the XOR-able range and item isn't a known
    // special-with-Ctrl. Send unmodified and let the user know.
    _flashCtrlNotApplicable();
    return payload;
  }

  static SpecialKey? _ctrlModifiedFor(SpecialKey k) {
    switch (k) {
      case SpecialKey.up:        return SpecialKey.ctrlUp;
      case SpecialKey.down:      return SpecialKey.ctrlDown;
      case SpecialKey.left:      return SpecialKey.ctrlLeft;
      case SpecialKey.right:     return SpecialKey.ctrlRight;
      case SpecialKey.backspace: return SpecialKey.ctrlBackspace;
      default:                   return null;
    }
  }

  static bool _ctrlNotApplicable(SpecialKey k) {
    // F-keys, paging, insert/delete have no consistently-defined Ctrl
    // form across terminals; we surface a hint instead of guessing.
    switch (k) {
      case SpecialKey.f1: case SpecialKey.f2: case SpecialKey.f3:
      case SpecialKey.f4: case SpecialKey.f5: case SpecialKey.f6:
      case SpecialKey.f7: case SpecialKey.f8: case SpecialKey.f9:
      case SpecialKey.f10: case SpecialKey.f11: case SpecialKey.f12:
      case SpecialKey.insert:
      case SpecialKey.pageUp:
      case SpecialKey.pageDown:
      case SpecialKey.home:
      case SpecialKey.end:
      case SpecialKey.shiftTab:
      case SpecialKey.delete:
        return true;
      default:
        return false;
    }
  }

  void _flashCtrlNotApplicable() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.removeCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 1500),
      content: Text(context.l10n.keybarCtrlNotApplicable),
    ));
  }

  String _applyShiftModifier(KeyBarItem item, String payload) {
    if (item.sequence.length == 1 && item.sequence.first is SpecialToken) {
      final key = (item.sequence.first as SpecialToken).key;
      switch (key) {
        case SpecialKey.enter:
          return '\x1b\r';
        case SpecialKey.tab:
          return '\x1b[Z';
        default:
          break;
      }
    }
    _flashShiftNotApplicable();
    return payload;
  }

  void _flashShiftNotApplicable() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.removeCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(
      duration: const Duration(milliseconds: 1500),
      content: Text(context.l10n.keybarShiftNotApplicable),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final items = context.watch<KeybarSettings>().items;
    final barBg = Theme.of(context).colorScheme.surfaceContainerHighest;

    return Container(
      height: 44,
      color: barBg,
      child: Row(
        children: [
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      context.l10n.keybarEmptyHint,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  )
                : ShaderMask(
                    shaderCallback: (bounds) => LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        _showLeftFade ? Colors.transparent : Colors.white,
                        Colors.white,
                        Colors.white,
                        Colors.white,
                      ],
                      stops: const [0.0, 0.06, 0.94, 1.0],
                    ).createShader(bounds),
                    blendMode: BlendMode.dstIn,
                    child: ListView.separated(
                      controller: _scrollCtrl,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 2),
                      itemBuilder: (_, i) => _KeyButton(
                        item: items[i],
                        ctrlActive: _ctrlActive,
                        shiftActive: _shiftActive,
                        onTap: () => _handleTap(items[i]),
                      ),
                    ),
                  ),
          ),
          ..._buildRightButtons(context),
        ],
      ),
    );
  }

  /// Render right-side function buttons.
  ///
  /// The keyboard-show icon is fixed and always renders first whenever
  /// [KeyBar.onShowKeyboard] is provided — that callback is non-null
  /// only when the user has selected the icon-button keyboard-trigger
  /// mode in the keybar editor, so its presence alone is the correct
  /// gate. The remaining buttons are driven by [KeybarSettings] and
  /// can be reordered/toggled by the user; entries whose corresponding
  /// callback is null (action not supported on this tab) are filtered
  /// out, as is the deprecated [RightButton.keyboard] in case it
  /// survived in older persisted data.
  ///
  /// Prepends a vertical divider only when at least one button renders.
  List<Widget> _buildRightButtons(BuildContext context) {
    final config = context.watch<KeybarSettings>().rightButtons;
    final buttons = <Widget>[];
    if (widget.onShowKeyboard != null) {
      buttons.add(_AiButton(
        icon: Icons.keyboard_outlined,
        isActive: false,
        onTap: widget.onShowKeyboard!,
      ));
    }
    for (final entry in config) {
      if (!entry.enabled) continue;
      if (entry.type == RightButton.keyboard) continue;
      final button = _renderRightButton(entry.type);
      if (button != null) buttons.add(button);
    }
    if (buttons.isEmpty) return const [];
    return [
      Container(
        width: 1,
        margin: const EdgeInsets.symmetric(vertical: 6),
        color: Theme.of(context).dividerColor,
      ),
      ...buttons,
    ];
  }

  Widget? _renderRightButton(RightButton type) {
    switch (type) {
      case RightButton.keyboard:
        // Handled directly in _buildRightButtons; falling through here
        // returns null so a stray legacy entry never renders twice.
        return null;
      case RightButton.favorites:
        if (widget.onFavoritesTap == null) return null;
        return _AiButton(
          icon: Icons.star_border,
          isActive: false,
          onTap: widget.onFavoritesTap!,
        );
      case RightButton.microphone:
        if (widget.onMicTap == null) return null;
        return _AiButton(
          icon: widget.micActive ? Icons.mic : Icons.mic_none,
          isActive: widget.micActive,
          onTap: widget.onMicTap!,
        );
      case RightButton.ai:
        if (widget.onAITap == null) return null;
        return _AiButton(
          icon: Icons.auto_awesome,
          isActive: widget.aiActive,
          onTap: widget.onAITap!,
        );
      case RightButton.attachFile:
        if (widget.onAttachTap == null) return null;
        return _AiButton(
          icon: Icons.attach_file,
          isActive: false,
          onTap: widget.onAttachTap!,
        );
    }
  }
}

class _AiButton extends StatelessWidget {
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  const _AiButton({
    required this.icon,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF00C896);
    const inactive = Color(0x66FFFFFF);
    final color = isActive ? accent : inactive;
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 44,
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
        decoration: BoxDecoration(
          color: isActive ? accent.withAlpha(38) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive ? accent.withAlpha(102) : inactive.withAlpha(60),
            width: 1,
          ),
        ),
        child: Icon(icon, size: 17, color: color),
      ),
    );
  }
}

class _KeyButton extends StatefulWidget {
  final KeyBarItem item;
  final bool ctrlActive;
  final bool shiftActive;
  final VoidCallback onTap;
  const _KeyButton({
    required this.item,
    required this.ctrlActive,
    required this.shiftActive,
    required this.onTap,
  });

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  Timer? _repeatTimer;

  void _startRepeat() {
    widget.onTap();
    _repeatTimer = Timer(const Duration(milliseconds: 400), () {
      _repeatTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
        widget.onTap();
      });
    });
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  @override
  void dispose() {
    _stopRepeat();
    super.dispose();
  }

  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isShift = _KeyBarState._isShiftItem(widget.item);
    final isStickyOn = widget.item.sticky &&
        (isShift ? widget.shiftActive : widget.ctrlActive);
    final bg = isStickyOn
        ? Theme.of(context).colorScheme.primary
        : (_pressed
            ? Theme.of(context).colorScheme.surface.withValues(alpha: 0.7)
            : Theme.of(context).colorScheme.surface);
    final fg = isStickyOn
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.onSurface;

    // Vertical margin 5dp top+bottom → effective key height ≈ 34dp in 44dp bar,
    // consistent with right-side function buttons (margin: vertical: 4).
    // Minimum width 36dp so single-char keys (↑ ← / ) don't become too narrow.
    Widget child = Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      constraints: const BoxConstraints(minWidth: 36),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        widget.item.label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );

    // Unified gesture handler for both repeatable and non-repeatable keys:
    // - onTapDown: visual press state + haptic
    // - onTapUp/Cancel: clear press state
    // - repeatable: start/stop auto-repeat timer
    return GestureDetector(
      onTapDown: (_) {
        HapticFeedback.lightImpact();
        setState(() => _pressed = true);
        if (widget.item.repeatable) _startRepeat();
      },
      onTapUp: (_) {
        setState(() => _pressed = false);
        if (widget.item.repeatable) {
          _stopRepeat();
        } else {
          widget.onTap();
        }
      },
      onTapCancel: () {
        setState(() => _pressed = false);
        _stopRepeat();
      },
      child: child,
    );
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../data/keybar_config.dart';
import '../../data/keybar_settings.dart';
import '../../l10n/l10n.dart';
import 'keybar_special_picker.dart';

/// Edit (or create) a single KeyBarItem. Pass [itemId] to edit an
/// existing item, or null to create a new one.
class KeybarItemEditScreen extends StatefulWidget {
  final String? itemId;
  const KeybarItemEditScreen({super.key, this.itemId});

  @override
  State<KeybarItemEditScreen> createState() => _KeybarItemEditScreenState();
}

class _KeybarItemEditScreenState extends State<KeybarItemEditScreen> {
  static const _accent = Color(0xFF00C896);

  late final TextEditingController _labelCtrl;
  late final TextEditingController _trailingTextCtrl;
  final FocusNode _seqFocus = FocusNode();
  late List<KeyToken> _sequence;
  late bool _repeatable;
  late bool _sticky;
  String? _labelError;
  String? _seqError;

  @override
  void initState() {
    super.initState();
    _seqFocus.addListener(_onSeqFocusChange);
    final settings = context.read<KeybarSettings>();
    final existing = widget.itemId == null
        ? null
        : settings.items.firstWhere((e) => e.id == widget.itemId,
            orElse: () => throw StateError('item ${widget.itemId} not found'));
    _labelCtrl = TextEditingController(text: existing?.label ?? '');
    _sequence = [...?existing?.sequence];
    _repeatable = existing?.repeatable ?? false;
    _sticky = existing?.sticky ?? false;
    _trailingTextCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _trailingTextCtrl.dispose();
    _seqFocus.removeListener(_onSeqFocusChange);
    _seqFocus.dispose();
    super.dispose();
  }

  void _onSeqFocusChange() {
    if (mounted) setState(() {});
  }

  Future<void> _pickSpecial() async {
    // Flush any in-progress text typing into a TextToken first.
    _flushTrailingText();
    final picked = await showModalBottomSheet<SpecialKey>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const KeybarSpecialKeyPicker(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _sequence.add(SpecialToken(picked));
    });
  }

  void _flushTrailingText() {
    final text = _trailingTextCtrl.text;
    if (text.isEmpty) return;
    setState(() {
      // Merge with adjacent TextToken if any.
      if (_sequence.isNotEmpty && _sequence.last is TextToken) {
        final last = _sequence.last as TextToken;
        _sequence[_sequence.length - 1] = TextToken(last.text + text);
      } else {
        _sequence.add(TextToken(text));
      }
      _trailingTextCtrl.clear();
    });
  }

  void _removeChip(int index) {
    setState(() => _sequence.removeAt(index));
  }

  Future<void> _save() async {
    _flushTrailingText();
    final l = context.l10n;
    setState(() {
      _labelError =
          _labelCtrl.text.trim().isEmpty ? l.keybarEditItemValidationLabel : null;
      _seqError = (!_sticky && _sequence.isEmpty)
          ? l.keybarEditItemValidationSequence
          : null;
    });
    if (_labelError != null || _seqError != null) return;

    // Enforce the sticky invariant: a sticky modifier (CTRL)
    // cannot carry a sequence — the runtime only flips a flag for it. If the
    // user typed text into the sequence editor while editing a sticky item,
    // discard that text on save rather than persisting an inconsistent shape.
    final saveSeq = _sticky ? const <KeyToken>[] : _sequence;

    final settings = context.read<KeybarSettings>();
    if (widget.itemId == null) {
      await settings.add(KeyBarItem(
        id: const Uuid().v4(),
        label: _labelCtrl.text.trim(),
        sequence: saveSeq,
        sticky: _sticky,
        repeatable: _repeatable,
      ));
    } else {
      final existing =
          settings.items.firstWhere((e) => e.id == widget.itemId);
      await settings.update(existing.copyWith(
        label: _labelCtrl.text.trim(),
        sequence: saveSeq,
        sticky: _sticky,
        repeatable: _repeatable,
      ));
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.itemId == null
            ? l.keybarEditItemNew
            : l.keybarEditItemTitle),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          // ── LABEL ────────────────────────────────────────────────────
          _SectionHeader(l.keybarEditItemLabel),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _labelCtrl,
              decoration: InputDecoration(
                errorText: _labelError,
                // 2026-10-13：去掉写死的 `isDense` / `border` / `contentPadding`
                // （vertical 10，比全局标准高 4dp），交给全局 theme。
                //
                // 它是页面级表单输入框，应当与设置页其它输入框同高；
                // 各页面自己调一个数字正是「跨页跳转觉得不一致」的来源。
                // 全局标准由 `fly_tokens.dart` 与
                // `input_height_baseline_test` 共同定义。
              ),
            ),
          ),

          // ── SEQUENCE ──────────────────────────────────────────────────
          _SectionHeader(l.keybarEditItemSequence),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Tapping anywhere inside the bordered "input box" focuses
              // the trailing text field, matching Material form-field
              // expectations. Without this the only hit target was the
              // ~thin IntrinsicWidth TextField at the end of the wrap.
              onTap: _sticky ? null : () => _seqFocus.requestFocus(),
              child: AnimatedContainer(
                // Colour/width transitions match the OutlineInputBorder
                // animation Material uses on its outlined text fields.
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _seqError != null
                        ? cs.error
                        : _seqFocus.hasFocus
                            ? _accent
                            : cs.onSurface.withOpacity(0.2),
                    width: _seqFocus.hasFocus ? 1.5 : 0.5,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (int i = 0; i < _sequence.length; i++)
                      _SequenceChip(
                        token: _sequence[i],
                        onDelete: () => _removeChip(i),
                      ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 80),
                      child: TextField(
                        focusNode: _seqFocus,
                        controller: _trailingTextCtrl,
                        enabled: !_sticky,
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          // 这个 TextField 嵌在外层自绘边框里，自己不能再有
                          // 边框/填充。只写 `border` 是不够的：TextField 会
                          // `applyDefaults(theme.inputDecorationTheme)`，把全局
                          // 的 enabled/focusedBorder 填进来，而 InputDecorator
                          // 取边框时**状态专属的优先于 border** —— 结果 theme
                          // 的 focusedBorder 生效，聚焦时画出第二圈绿框。
                          // 三个都要显式关掉。
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 6),
                          hintText: l.keybarEditItemSequenceHint,
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: cs.onSurface.withOpacity(0.4),
                          ),
                        ),
                        onSubmitted: (_) => _flushTrailingText(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_seqError != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(
                _seqError!,
                style: TextStyle(color: cs.error, fontSize: 12),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 16, 4),
            child: TextButton.icon(
              onPressed: _pickSpecial,
              icon: const Icon(Icons.add, size: 18, color: _accent),
              label: Text(
                l.keybarEditItemInsertSpecial,
                style: const TextStyle(color: _accent),
              ),
            ),
          ),

          // ── FLAGS ─────────────────────────────────────────────────────
          _SectionHeader(l.keybarEditItemRepeatable.split(' ').first == 'Auto'
              ? 'FLAGS'
              : 'FLAGS'),
          // Repeatable switch
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            title: Text(l.keybarEditItemRepeatable),
            trailing: Switch(
              value: _repeatable,
              onChanged: _sticky
                  ? null
                  : (v) => setState(() => _repeatable = v),
              activeColor: _accent,
            ),
          ),
          // Sticky switch
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            title: Text(l.keybarEditItemSticky),
            subtitle: Text(l.keybarEditItemStickyHint),
            trailing: Switch(
              value: _sticky,
              onChanged: (v) => setState(() {
                _sticky = v;
                if (_sticky) {
                  // Sticky modifier semantics: a CTRL-style key carries no
                  // sequence and is not auto-repeatable; when toggling on,
                  // clear those fields so the saved item is consistent.
                  _sequence = [];
                  _repeatable = false;
                  _seqError = null;
                  _trailingTextCtrl.clear();
                }
              }),
              activeColor: _accent,
            ),
          ),
        ],
      ),
      // ── Bottom SAVE button ───────────────────────────────────────────
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.black,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Text(
              l.keybarEditItemSave,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Industrial Monitor Console 风格 section header（内联版）。
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

class _SequenceChip extends StatelessWidget {
  final KeyToken token;
  final VoidCallback onDelete;
  const _SequenceChip({required this.token, required this.onDelete});

  static const _accent = Color(0xFF00C896);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = token;
    final isSpecial = t is SpecialToken;
    final label = isSpecial
        ? KeybarSpecialKeyPicker.labelFor(t.key)
        : '"${(t as TextToken).text}"';
    return InputChip(
      label: Text(
        label,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 12,
          color: isSpecial ? _accent : cs.onSurface,
          fontWeight: isSpecial ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      onDeleted: onDelete,
      visualDensity: VisualDensity.compact,
      side: BorderSide(
        color: isSpecial
            ? _accent.withOpacity(0.6)
            : cs.onSurface.withOpacity(0.2),
        width: 0.5,
      ),
      backgroundColor: isSpecial
          ? _accent.withOpacity(0.08)
          : cs.surfaceVariant.withOpacity(0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    );
  }
}

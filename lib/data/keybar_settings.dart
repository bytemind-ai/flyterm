// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import '../util/dlog.dart';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'keybar_config.dart';

/// Persistent KeyBar configuration. Single source of truth for what the
/// [KeyBar] widget renders. Stores two parallel ordered lists:
///   • Left-side terminal keys ([items]) under [_kItemsKey] —
///     fully customizable: add/remove/edit/reorder.
///   • Right-side function buttons ([rightButtons]) under [_kRightKey] —
///     fixed set (keyboard / favorites / microphone / ai); user can only
///     toggle enabled and reorder.
///
/// Lifecycle:
///   - Constructed once at app startup and registered as a Provider.
///   - [seedIfEmpty] is awaited at startup. If a prefs key is missing
///     (first launch / fresh install) or corrupt, the legacy default
///     seed is written for that side. Otherwise the stored list loads.
///   - All mutations persist immediately and call [notifyListeners].
class KeybarSettings extends ChangeNotifier {
  static const _kItemsKey = 'keybar_items_v1';
  static const _kRightKey = 'keybar_right_buttons_v1';

  /// The active set of right-button types this build offers in the
  /// editor. Computed once from [defaultRightButtons] so deprecated
  /// enum values are filtered out of stored data on load.
  static final Set<RightButton> _activeRightButtons =
      defaultRightButtons().map((e) => e.type).toSet();

  List<KeyBarItem> _items = [];
  List<KeyBarItem> get items => List.unmodifiable(_items);

  List<RightButtonItem> _rightButtons = [];
  List<RightButtonItem> get rightButtons => List.unmodifiable(_rightButtons);

  /// On first launch (or a corrupt prefs entry) write defaults; otherwise
  /// load the existing list. Idempotent — safe to call again. Seeds both
  /// the left items and the right buttons.
  Future<void> seedIfEmpty() async {
    final prefs = await SharedPreferences.getInstance();
    await _seedItemsIfEmpty(prefs);
    await _seedRightIfEmpty(prefs);
    notifyListeners();
  }

  Future<void> _seedItemsIfEmpty(SharedPreferences prefs) async {
    final raw = prefs.getString(_kItemsKey);
    if (raw == null) {
      _items = defaultKeyBarItems();
      await _persistItems(prefs);
      return;
    }
    try {
      _items = (jsonDecode(raw) as List)
          .map((e) => KeyBarItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      dlog('KeybarSettings', 'corrupt items prefs, restoring defaults: $e');
      _items = defaultKeyBarItems();
      await _persistItems(prefs);
    }
  }

  Future<void> _seedRightIfEmpty(SharedPreferences prefs) async {
    final raw = prefs.getString(_kRightKey);
    if (raw == null) {
      _rightButtons = defaultRightButtons();
      await _persistRight(prefs);
      return;
    }
    try {
      final loaded = (jsonDecode(raw) as List)
          .map((e) => RightButtonItem.fromJson(e as Map<String, dynamic>))
          .where((e) => _activeRightButtons.contains(e.type))
          .toList();
      // Forward-compat: append any active RightButton values missing
      // from the stored list as enabled defaults. The "active" set is
      // derived from defaultRightButtons() so deprecated values
      // (e.g. RightButton.keyboard) are silently dropped on load.
      final present = loaded.map((e) => e.type).toSet();
      for (final t in _activeRightButtons) {
        if (!present.contains(t)) {
          loaded.add(RightButtonItem(type: t, enabled: true));
        }
      }
      _rightButtons = loaded;
    } catch (e) {
      dlog('KeybarSettings',
          'corrupt right-buttons prefs, restoring defaults: $e');
      _rightButtons = defaultRightButtons();
      await _persistRight(prefs);
    }
  }

  // ── Left-side terminal-key mutations ─────────────────────────────────────

  Future<void> add(KeyBarItem item) async {
    _items = [..._items, item];
    await _persistItemsAndNotify();
  }

  Future<void> remove(String id) async {
    _items = _items.where((e) => e.id != id).toList();
    await _persistItemsAndNotify();
  }

  Future<void> update(KeyBarItem updated) async {
    _items = _items
        .map((e) => e.id == updated.id ? updated : e)
        .toList(growable: false);
    await _persistItemsAndNotify();
  }

  Future<void> reorder(int oldIdx, int newIdx) async {
    // Match ReorderableListView semantics: when moving down, newIdx is
    // off-by-one because the source has been removed first.
    final adjusted = (newIdx > oldIdx) ? newIdx - 1 : newIdx;
    final next = [..._items];
    final moved = next.removeAt(oldIdx);
    next.insert(adjusted, moved);
    _items = next;
    await _persistItemsAndNotify();
  }

  // ── Right-side button mutations ──────────────────────────────────────────

  Future<void> setRightButtonEnabled(RightButton type, bool enabled) async {
    _rightButtons = _rightButtons
        .map((e) => e.type == type ? e.copyWith(enabled: enabled) : e)
        .toList(growable: false);
    await _persistRightAndNotify();
  }

  Future<void> reorderRightButtons(int oldIdx, int newIdx) async {
    final adjusted = (newIdx > oldIdx) ? newIdx - 1 : newIdx;
    final next = [..._rightButtons];
    final moved = next.removeAt(oldIdx);
    next.insert(adjusted, moved);
    _rightButtons = next;
    await _persistRightAndNotify();
  }

  /// Reset both sides to their legacy defaults.
  Future<void> restoreDefaults() async {
    _items = defaultKeyBarItems();
    _rightButtons = defaultRightButtons();
    final prefs = await SharedPreferences.getInstance();
    await _persistItems(prefs);
    await _persistRight(prefs);
    notifyListeners();
  }

  // ── Config backup (export / import) ──────────────────────────────────────

  /// Serializes the current key bar (both sides) for a config backup.
  Map<String, dynamic> exportToMap() => {
        'items': _items.map((e) => e.toJson()).toList(),
        'right_buttons': _rightButtons.map((e) => e.toJson()).toList(),
      };

  /// Replaces the key bar from a config backup and persists. Unknown/deprecated
  /// right-button types are filtered out (same rule as [_seedRightIfEmpty]).
  Future<void> importFromMap(Map<String, dynamic> m) async {
    final prefs = await SharedPreferences.getInstance();
    final rawItems = m['items'] as List?;
    if (rawItems != null) {
      _items = rawItems
          .map((e) => KeyBarItem.fromJson(e as Map<String, dynamic>))
          .toList();
      await _persistItems(prefs);
    }
    final rawRight = m['right_buttons'] as List?;
    if (rawRight != null) {
      final loaded = rawRight
          .map((e) => RightButtonItem.fromJson(e as Map<String, dynamic>))
          .where((e) => _activeRightButtons.contains(e.type))
          .toList();
      final present = loaded.map((e) => e.type).toSet();
      for (final t in _activeRightButtons) {
        if (!present.contains(t)) {
          loaded.add(RightButtonItem(type: t, enabled: true));
        }
      }
      _rightButtons = loaded;
      await _persistRight(prefs);
    }
    notifyListeners();
  }

  // ── Persistence helpers ──────────────────────────────────────────────────

  Future<void> _persistItemsAndNotify() async {
    final prefs = await SharedPreferences.getInstance();
    await _persistItems(prefs);
    notifyListeners();
  }

  Future<void> _persistRightAndNotify() async {
    final prefs = await SharedPreferences.getInstance();
    await _persistRight(prefs);
    notifyListeners();
  }

  Future<void> _persistItems(SharedPreferences prefs) async {
    final json = jsonEncode(_items.map((e) => e.toJson()).toList());
    await prefs.setString(_kItemsKey, json);
  }

  Future<void> _persistRight(SharedPreferences prefs) async {
    final json = jsonEncode(_rightButtons.map((e) => e.toJson()).toList());
    await prefs.setString(_kRightKey, json);
  }
}

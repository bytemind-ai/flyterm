import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/data/keybar_config.dart';
import 'package:flyterm/data/keybar_settings.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // 数量一律从 defaultKeyBarItems() 现算，不写字面量：这几条测的是「种子有
  // 没有落地」「增删有没有生效」，默认键增减与它们无关。写死数字的后果就是
  // 加一个 ⇧ 键让四条无关的用例一起变红（2026-09-06 前的状态）。
  int defaultCount() => defaultKeyBarItems().length;

  test('seedIfEmpty writes all defaults when key absent', () async {
    final s = KeybarSettings();
    await s.seedIfEmpty();
    expect(s.items.length, defaultCount());
    expect(s.items.first.label, 'ESC');
    expect(s.items[2].label, 'CTRL');
    expect(s.items[2].sticky, isTrue);
  });

  test('seedIfEmpty is a no-op when key already present', () async {
    SharedPreferences.setMockInitialValues({
      'keybar_items_v1': '[{"id":"x","label":"X","sequence":[],"sticky":false,"repeatable":false}]'
    });
    final s = KeybarSettings();
    await s.seedIfEmpty();
    expect(s.items.length, 1);
    expect(s.items.first.label, 'X');
  });

  test('add appends item, persists, notifies', () async {
    final s = KeybarSettings();
    await s.seedIfEmpty();
    int notified = 0;
    s.addListener(() => notified++);
    await s.add(KeyBarItem(
      id: 'new',
      label: ':wq',
      sequence: [
        SpecialToken(SpecialKey.esc),
        TextToken(':wq'),
        SpecialToken(SpecialKey.enter),
      ],
      sticky: false,
      repeatable: false,
    ));
    expect(s.items.length, defaultCount() + 1);
    expect(s.items.last.label, ':wq');
    expect(notified, 1);

    final reloaded = KeybarSettings();
    await reloaded.seedIfEmpty();
    expect(reloaded.items.last.label, ':wq');
  });

  test('remove drops by id, persists, notifies', () async {
    final s = KeybarSettings();
    await s.seedIfEmpty();
    int notified = 0;
    s.addListener(() => notified++);
    await s.remove('seed-tab');
    expect(s.items.any((e) => e.id == 'seed-tab'), isFalse);
    expect(notified, 1);
  });

  test('update replaces item by id, persists, notifies', () async {
    final s = KeybarSettings();
    await s.seedIfEmpty();
    int notified = 0;
    s.addListener(() => notified++);
    final updated = s.items.first.copyWith(label: 'Escape');
    await s.update(updated);
    expect(s.items.first.label, 'Escape');
    expect(notified, 1);
  });

  test('reorder moves item from oldIdx to newIdx, persists, notifies',
      () async {
    final s = KeybarSettings();
    await s.seedIfEmpty();
    int notified = 0;
    s.addListener(() => notified++);
    final firstLabel = s.items.first.label;
    await s.reorder(0, 3);
    expect(s.items[2].label, firstLabel);
    expect(notified, 1);
  });

  test('restoreDefaults overwrites and notifies', () async {
    final s = KeybarSettings();
    await s.seedIfEmpty();
    await s.add(KeyBarItem(
        id: 'extra',
        label: 'Extra',
        sequence: [TextToken('x')],
        sticky: false,
        repeatable: false));
    expect(s.items.length, defaultCount() + 1);
    int notified = 0;
    s.addListener(() => notified++);
    await s.restoreDefaults();
    expect(s.items.length, defaultCount());
    expect(s.items.any((e) => e.id == 'extra'), isFalse);
    expect(notified, 1);
  });

  test('load with corrupt JSON falls back to defaults', () async {
    SharedPreferences.setMockInitialValues({
      'keybar_items_v1': 'not valid json{{{'
    });
    final s = KeybarSettings();
    await s.seedIfEmpty();
    expect(s.items.length, defaultCount());
    expect(s.items.first.label, 'ESC');
  });

  group('rightButtons', () {
    test('seedIfEmpty seeds 4 right buttons all enabled in legacy order',
        () async {
      final s = KeybarSettings();
      await s.seedIfEmpty();
      expect(s.rightButtons.map((e) => e.type).toList(), [
        RightButton.favorites,
        RightButton.microphone,
        RightButton.ai,
        RightButton.attachFile,
      ]);
      expect(s.rightButtons.every((e) => e.enabled), isTrue);
    });

    test('setRightButtonEnabled flips a button, persists, notifies',
        () async {
      final s = KeybarSettings();
      await s.seedIfEmpty();
      int notified = 0;
      s.addListener(() => notified++);
      await s.setRightButtonEnabled(RightButton.microphone, false);
      final mic = s.rightButtons.firstWhere(
          (e) => e.type == RightButton.microphone);
      expect(mic.enabled, isFalse);
      expect(notified, 1);

      final reloaded = KeybarSettings();
      await reloaded.seedIfEmpty();
      final reloadedMic = reloaded.rightButtons.firstWhere(
          (e) => e.type == RightButton.microphone);
      expect(reloadedMic.enabled, isFalse);
    });

    test('reorderRightButtons moves a button, persists, notifies', () async {
      final s = KeybarSettings();
      await s.seedIfEmpty();
      int notified = 0;
      s.addListener(() => notified++);
      // Move "ai" (index 2) to the front (index 0).
      await s.reorderRightButtons(2, 0);
      expect(s.rightButtons.first.type, RightButton.ai);
      expect(notified, 1);
    });

    test('corrupt right-buttons JSON falls back to defaults', () async {
      SharedPreferences.setMockInitialValues({
        'keybar_right_buttons_v1': 'not valid{{{'
      });
      final s = KeybarSettings();
      await s.seedIfEmpty();
      expect(s.rightButtons.length, 4);
      expect(s.rightButtons.first.type, RightButton.favorites);
    });

    test('missing RightButton enum values get appended (forward compat)',
        () async {
      // Simulate an upgrade where stored data has only "ai" disabled.
      SharedPreferences.setMockInitialValues({
        'keybar_right_buttons_v1':
            '[{"type":"ai","enabled":false}]'
      });
      final s = KeybarSettings();
      await s.seedIfEmpty();
      expect(s.rightButtons.length, 4);
      // attachFile 是后加的枚举值,存储里没有它 —— 这条测试同时也是
      // 「新按钮怎么到达存量用户」那条路径的验证:靠的就是这个追加机制,
      // 而不是一次性迁移代码。
      expect(s.rightButtons.any((e) => e.type == RightButton.attachFile),
          isTrue);
      // Original entry preserved with original enabled state.
      final ai = s.rightButtons.firstWhere((e) => e.type == RightButton.ai);
      expect(ai.enabled, isFalse);
      // Missing active values appended as enabled.
      final fav = s.rightButtons.firstWhere(
          (e) => e.type == RightButton.favorites);
      expect(fav.enabled, isTrue);
    });

    test('legacy keyboard entry is silently dropped on load', () async {
      SharedPreferences.setMockInitialValues({
        'keybar_right_buttons_v1':
            '[{"type":"keyboard","enabled":true},'
            '{"type":"favorites","enabled":true},'
            '{"type":"microphone","enabled":true},'
            '{"type":"ai","enabled":true}]'
      });
      final s = KeybarSettings();
      await s.seedIfEmpty();
      // 4 = 存储里那 3 个有效值 + 追加进来的 attachFile；keyboard 被丢弃
      expect(s.rightButtons.length, 4);
      expect(s.rightButtons.any((e) => e.type == RightButton.keyboard),
          isFalse);
    });

    test('restoreDefaults resets both items and right buttons', () async {
      final s = KeybarSettings();
      await s.seedIfEmpty();
      await s.setRightButtonEnabled(RightButton.ai, false);
      await s.reorderRightButtons(0, 3);  // move favorites to end
      expect(s.rightButtons.first.type, isNot(RightButton.favorites));

      await s.restoreDefaults();
      expect(s.rightButtons.first.type, RightButton.favorites);
      expect(s.rightButtons.every((e) => e.enabled), isTrue);
    });
  });
}

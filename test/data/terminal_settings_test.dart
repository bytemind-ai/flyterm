import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/ui/terminal/terminal_themes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('TerminalSettings.fontFamily', () {
    test('default is JetBrainsMono', () {
      final s = TerminalSettings(SecureStorageService());
      expect(s.fontFamily, 'JetBrainsMono');
    });

    test('setFontFamily updates value and notifies', () async {
      final s = TerminalSettings(SecureStorageService());
      var calls = 0;
      s.addListener(() => calls++);
      await s.setFontFamily('CourierPrime');
      expect(s.fontFamily, 'CourierPrime');
      expect(calls, 1);
    });

    // 字体名必须取自 FontOptions.builtInFamilies —— load() 有一道白名单
    // 校验（`isBuiltInFamily`），非内置的名字写得进去、读不回来。这三个
    // 用例原本用 'Hack' / 'CourierPrime'，那是字体列表精简成三项之前的遗留，
    // persists 那条因此必然失败（另两条只看内存值和通知次数，侥幸通过）。
    test('setFontFamily persists and reloads', () async {
      final s1 = TerminalSettings(SecureStorageService());
      await s1.setFontFamily('CourierPrime');
      final s2 = TerminalSettings(SecureStorageService());
      await s2.load();
      expect(s2.fontFamily, 'CourierPrime');
    });

    test('setFontFamily idempotent: same value does not notify', () async {
      final s = TerminalSettings(SecureStorageService());
      await s.setFontFamily('CourierPrime');
      var calls = 0;
      s.addListener(() => calls++);
      await s.setFontFamily('CourierPrime');
      expect(calls, 0);
    });
  });

  group('TerminalSettings.lineHeight', () {
    test('default is 1.2', () {
      final s = TerminalSettings(SecureStorageService());
      expect(s.lineHeight, 1.2);
    });

    test('clamps to [1.0, 2.0]', () async {
      final s = TerminalSettings(SecureStorageService());
      await s.setLineHeight(0.5);
      expect(s.lineHeight, 1.0);
      await s.setLineHeight(3.0);
      expect(s.lineHeight, 2.0);
      s.dispose(); // flush pending debounce so it doesn't bleed into later tests
    });

    test('setLineHeight notifies and reloads after persist', () async {
      final s1 = TerminalSettings(SecureStorageService());
      await s1.setLineHeight(1.5);
      // Debounce flushes on dispose
      s1.dispose();
      // Wait for any pending writes
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final s2 = TerminalSettings(SecureStorageService());
      await s2.load();
      expect(s2.lineHeight, 1.5);
    });
  });

  group('TerminalSettings.backgroundKeepAlive', () {
    test('default is false', () {
      final s = TerminalSettings(SecureStorageService());
      expect(s.backgroundKeepAlive, isFalse);
    });

    test('setBackgroundKeepAlive updates value and notifies', () async {
      final s = TerminalSettings(SecureStorageService());
      var calls = 0;
      s.addListener(() => calls++);
      await s.setBackgroundKeepAlive(true);
      expect(s.backgroundKeepAlive, isTrue);
      expect(calls, 1);
    });

    test('setBackgroundKeepAlive persists and reloads', () async {
      final s1 = TerminalSettings(SecureStorageService());
      await s1.setBackgroundKeepAlive(true);
      final s2 = TerminalSettings(SecureStorageService());
      await s2.load();
      expect(s2.backgroundKeepAlive, isTrue);
    });

    test('setBackgroundKeepAlive idempotent: same value does not notify', () async {
      final s = TerminalSettings(SecureStorageService());
      await s.setBackgroundKeepAlive(true);
      var calls = 0;
      s.addListener(() => calls++);
      await s.setBackgroundKeepAlive(true);
      expect(calls, 0);
    });
  });

  group('TerminalSettings.cursorBlink', () {
    test('默认为 true（与 iTerm2 一致）', () {
      final s = TerminalSettings(SecureStorageService());
      expect(s.cursorBlink, isTrue);
    });

    test('setCursorBlink 改值并通知', () async {
      final s = TerminalSettings(SecureStorageService());
      var calls = 0;
      s.addListener(() => calls++);
      await s.setCursorBlink(false);
      expect(s.cursorBlink, isFalse);
      expect(calls, 1);
    });

    test('setCursorBlink 持久化并能读回', () async {
      final s1 = TerminalSettings(SecureStorageService());
      await s1.setCursorBlink(false);
      final s2 = TerminalSettings(SecureStorageService());
      await s2.load();
      expect(s2.cursorBlink, isFalse);
    });

    test('setCursorBlink 幂等：同值不通知', () async {
      final s = TerminalSettings(SecureStorageService());
      await s.setCursorBlink(false);
      var calls = 0;
      s.addListener(() => calls++);
      await s.setCursorBlink(false);
      expect(calls, 0);
    });

    // 回归：闪烁曾与光标形态硬编在一起
    // （`cursorBlink: style != defaultStyle`）。这条钉住“形态变了不影响
    // 闪烁开关”，防止有人把两者又合回去。
    test('改光标形态不影响闪烁开关', () async {
      final s = TerminalSettings(SecureStorageService());
      await s.setCursorBlink(false);
      await s.setCursorStyle(TerminalCursorStyle.block);
      expect(s.cursorBlink, isFalse);
    });
  });

  group('TerminalSettings.selectionColor', () {
    test('默认 null —— 跟随主题', () {
      final s = TerminalSettings(SecureStorageService());
      expect(s.selectionColor, isNull);
    });

    test('setSelectionColor 改值并通知', () async {
      final s = TerminalSettings(SecureStorageService());
      var calls = 0;
      s.addListener(() => calls++);
      await s.setSelectionColor(const Color(0x80528BFF));
      expect(s.selectionColor, const Color(0x80528BFF));
      expect(calls, 1);
    });

    // 带 alpha 是重点：选中色是半透明的，存成 6 位 hex 会丢掉 alpha，
    // 高亮就变成遮住文字的实心块。
    test('setSelectionColor 保存 alpha 并能读回', () async {
      final s1 = TerminalSettings(SecureStorageService());
      await s1.setSelectionColor(const Color(0x80528BFF));
      final s2 = TerminalSettings(SecureStorageService());
      await s2.load();
      expect(s2.selectionColor, const Color(0x80528BFF));
    });

    test('setSelectionColor(null) 回到跟随主题并能读回', () async {
      final s1 = TerminalSettings(SecureStorageService());
      await s1.setSelectionColor(const Color(0x80528BFF));
      await s1.setSelectionColor(null);
      expect(s1.selectionColor, isNull);
      final s2 = TerminalSettings(SecureStorageService());
      await s2.load();
      expect(s2.selectionColor, isNull);
    });

    test('setSelectionColor 幂等：同值不通知', () async {
      final s = TerminalSettings(SecureStorageService());
      await s.setSelectionColor(const Color(0x80528BFF));
      var calls = 0;
      s.addListener(() => calls++);
      await s.setSelectionColor(const Color(0x80528BFF));
      expect(calls, 0);
    });
  });

  group('AppTerminalThemes', () {
    test('新主题都在 of() 里有分支（不会落到 default）', () {
      for (final t in AppTerminalTheme.values) {
        final theme = AppTerminalThemes.of(t);
        expect(theme, isNotNull, reason: '$t 没有映射');
      }
    });

    test('withSelection(null) 原样返回', () {
      final base = AppTerminalThemes.of(AppTerminalTheme.nord);
      expect(AppTerminalThemes.withSelection(base, null), same(base));
    });

    test('withSelection 只改 selection，其余字段不变', () {
      final base = AppTerminalThemes.of(AppTerminalTheme.nord);
      final out = AppTerminalThemes.withSelection(base, const Color(0xFF123456));
      expect(out.selection, const Color(0xFF123456));
      expect(out.background, base.background);
      expect(out.foreground, base.foreground);
      expect(out.cursor, base.cursor);
      expect(out.blue, base.blue);
      expect(out.searchHitBackground, base.searchHitBackground);
    });

    // defaultDark 的光标曾是外壳的 mint，与“活动态”撞语义。换成 iTerm2
    // 标准的浅灰光标后，mint 在外壳里保持单一含义。
    test('defaultDark 的光标不再是品牌 mint', () {
      final theme = AppTerminalThemes.of(AppTerminalTheme.defaultDark);
      expect(theme.cursor, isNot(const Color(0xFF00C896)));
    });
  });
}

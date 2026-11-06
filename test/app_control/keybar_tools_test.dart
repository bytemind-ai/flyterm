import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/keybar_config.dart';
import 'package:flyterm/data/keybar_settings.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KeybarSettings kb;
  late AppControlService svc;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    kb = KeybarSettings();
    svc = AppControlService(
      settings: TerminalSettings(SecureStorageService()),
      keybar: kb,
    );
  });

  group('addKeybarItem', () {
    test('加一个并能读回，序列被解析成 token', () async {
      final r = await svc.addKeybarItem(label: 'GS', sequence: 'git status\n');
      expect(r.ok, isTrue);

      final item = kb.items.single;
      expect(item.label, 'GS');
      expect(item.sequence, hasLength(2));
      expect((item.sequence[0] as TextToken).text, 'git status');
      expect((item.sequence[1] as SpecialToken).key, SpecialKey.enter);
    });

    test('占位符写法', () async {
      await svc.addKeybarItem(label: 'Cancel', sequence: '[ctrl-c]');
      final item = kb.items.single;
      expect((item.sequence.single as SpecialToken).key, SpecialKey.ctrlC);
    });

    test('序列解析失败时不落库，错误里带可用名', () async {
      final r = await svc.addKeybarItem(label: 'X', sequence: '[nope]');
      expect(r.ok, isFalse);
      expect(r.error, contains('Unknown special key'));
      expect(kb.items, isEmpty);
    });

    test('重名被拒', () async {
      await svc.addKeybarItem(label: 'GS', sequence: 'a');
      final r = await svc.addKeybarItem(label: 'GS', sequence: 'b');
      expect(r.ok, isFalse);
      expect(kb.items, hasLength(1));
    });

    test('空 label 被拒', () async {
      final r = await svc.addKeybarItem(label: '  ', sequence: 'a');
      expect(r.ok, isFalse);
      expect(kb.items, isEmpty);
    });

    test('撤销把新加的键删掉', () async {
      await svc.addKeybarItem(label: 'GS', sequence: 'a');
      await svc.changeLog.undoAll();
      expect(kb.items, isEmpty);
    });

    test('sticky / repeatable 透传', () async {
      await svc.addKeybarItem(
          label: 'C', sequence: '[ctrl]', sticky: true, repeatable: true);
      expect(kb.items.single.sticky, isTrue);
      expect(kb.items.single.repeatable, isTrue);
    });
  });

  group('removeKeybarItem', () {
    test('删掉并可撤销 —— 键原样回来', () async {
      await svc.addKeybarItem(label: 'GS', sequence: 'git status\n');
      svc.changeLog.clear();

      final r = await svc.removeKeybarItem('GS');
      expect(r.ok, isTrue);
      expect(kb.items, isEmpty);

      await svc.changeLog.undoAll();
      final back = kb.items.single;
      expect(back.label, 'GS');
      expect(back.sequence, hasLength(2));
    });

    test('删不存在的回明确错误', () async {
      final r = await svc.removeKeybarItem('nope');
      expect(r.ok, isFalse);
      expect(r.error, contains('No key labelled'));
    });
  });

  test('没注入 KeybarSettings 时明确回不可用', () async {
    final bare = AppControlService(
      settings: TerminalSettings(SecureStorageService()),
    );
    final r = await bare.addKeybarItem(label: 'a', sequence: 'b');
    expect(r.ok, isFalse);
    expect(r.error, contains('not available'));
  });
}

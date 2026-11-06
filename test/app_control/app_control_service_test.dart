import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/app_control/writable_settings.dart';
import 'package:flyterm/data/keybar_settings.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/ui/terminal/terminal_themes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TerminalSettings settings;
  late AppControlService svc;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    settings = TerminalSettings(SecureStorageService());
    svc = AppControlService(settings: settings);
  });

  group('readSettings', () {
    test('返回键集合恰好等于白名单', () {
      final keys = svc.readSettings().keys.toSet();
      expect(keys, equals(kAgentWritableSettings));
    });

    test('硬禁区的键不出现在结果里', () {
      final keys = svc.readSettings().keys;
      expect(keys, isNot(contains('dangerousCommandGuard')));
      expect(keys, isNot(contains('dangerousCommandGuard')));
    });

    test('值反映当前真实状态', () async {
      await settings.setFontSize(17);
      expect(svc.readSettings()['fontSize'], 17.0);
    });

    test('enum 值导出成 .name 字符串，不是 toString', () {
      final v = svc.readSettings()['terminalTheme'];
      expect(v, isA<String>());
      expect(v, equals(settings.terminalTheme.name));
      expect(v, isNot(contains('AppTerminalTheme.')));
    });
  });

  group('setSetting —— 白名单与禁区', () {
    test('白名单内的键写得进去', () async {
      final r = await svc.setSetting('fontSize', 16);
      expect(r.ok, isTrue);
      expect(settings.fontSize, 16.0);
    });

    test('白名单外的键被拒，且设置没被改动', () async {
      final before = settings.dangerousCommandGuard;
      final r = await svc.setSetting('dangerousCommandGuard', !before);
      expect(r.ok, isFalse);
      expect(r.error, contains('not writable'));
      expect(settings.dangerousCommandGuard, before);
    });

    test('硬禁区的键被拒 —— 提权拦截', () async {
      final r = await svc.setSetting('agent.defaultMode', 'bypass');
      expect(r.ok, isFalse);
      expect(r.error, contains('not writable'));
    });

    test('未知键被拒', () async {
      final r = await svc.setSetting('nonexistentKey', 1);
      expect(r.ok, isFalse);
    });
  });

  group('setSetting —— 类型与 clamp', () {
    test('字符串数字被接受（模型常回传字符串）', () async {
      final r = await svc.setSetting('fontSize', '16');
      expect(r.ok, isTrue);
      expect(settings.fontSize, 16.0);
    });

    test('类型不匹配被拒而不是静默吞掉', () async {
      final r = await svc.setSetting('fontSize', 'large');
      expect(r.ok, isFalse);
      expect(r.error, contains('expected a number'));
    });

    test('enum 用 .name 解析，非法值被拒并列出可选项', () async {
      final r = await svc.setSetting('terminalTheme', 'NotATheme');
      expect(r.ok, isFalse);
      expect(r.error, contains('one of'));
    });

    test('合法 enum 写得进去', () async {
      // 不写死主题名 —— enum 成员会增删，挑一个「不等于当前值」的即可
      final target = AppTerminalTheme.values
          .firstWhere((e) => e != settings.terminalTheme)
          .name;
      final r = await svc.setSetting('terminalTheme', target);
      expect(r.ok, isTrue);
      expect(settings.terminalTheme.name, target);
    });

    test('clamp 之后记真值 —— 不是模型请求的值', () async {
      final r = await svc.setSetting('fontSize', 999);
      expect(r.ok, isTrue);
      // TerminalSettings 把它 clamp 到 maxFontSize
      expect(r.change!.newValue, equals(settings.fontSize));
      expect(r.change!.newValue, isNot(999.0));
    });
  });

  group('setSetting —— 记账', () {
    test('成功的写操作进撤销栈', () async {
      await svc.setSetting('fontSize', 16);
      expect(svc.changeLog.pending, hasLength(1));
      expect(svc.changeLog.pending.first.field, 'fontSize');
    });

    test('失败的写操作不进撤销栈', () async {
      await svc.setSetting('dangerousCommandGuard', true);
      expect(svc.changeLog.pending, isEmpty);
    });

    test('记录的 oldValue 是改动前的值', () async {
      await settings.setFontSize(14);
      await svc.setSetting('fontSize', 18);
      expect(svc.changeLog.pending.first.oldValue, 14.0);
    });

    test('撤销往返回到原值', () async {
      await settings.setFontSize(14);
      await svc.setSetting('fontSize', 18);
      await svc.changeLog.undoAll();
      expect(settings.fontSize, 14.0);
    });

    test('多项改动整批逆序回滚', () async {
      await settings.setFontSize(14);
      await settings.setLineHeight(1.2);
      await svc.setSetting('fontSize', 18);
      await svc.setSetting('lineHeight', 1.6);
      await svc.changeLog.undoAll();
      expect(settings.fontSize, 14.0);
      expect(settings.lineHeight, 1.2);
    });

    test('撤销本身不再记一条 —— 否则栈会自增长', () async {
      await settings.setFontSize(14);
      await svc.setSetting('fontSize', 18);
      await svc.changeLog.undoAll();
      expect(svc.changeLog.pending, isEmpty);
    });
  });

  group('readSection —— 依赖缺席时回 null 而非空列表', () {
    test('没注入 ServerRepository 时 servers 回 null', () async {
      expect(await svc.readSection('servers'), isNull);
    });

    test('没注入 SessionManager 时 sessions 回 null', () async {
      expect(await svc.readSection('sessions'), isNull);
    });

    test('没注入 TunnelManager 时 tunnels 回 null', () async {
      expect(await svc.readSection('tunnels'), isNull);
    });

    test('没注入 KeybarSettings 时 keybar 回 null', () async {
      expect(await svc.readSection('keybar'), isNull);
    });

    test('未知分区回 null', () async {
      expect(await svc.readSection('nope'), isNull);
    });

    // 这条是整组的要点：null 与「空列表」必须可区分。回空列表会让模型
    // 以为「真的一台服务器都没有」，然后基于这个错误前提往下推理。
    test('null 与空列表语义不同 —— 注入了空 repo 时回空列表', () async {
      final withRepo = AppControlService(
        settings: settings,
        keybar: KeybarSettings(),
      );
      final rows = await withRepo.readSection('keybar');
      expect(rows, isNotNull);
      expect(rows, isEmpty);
    });
  });
}

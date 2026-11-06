import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/ssh/keep_alive_controller.dart';

/// 后台保活的**接线**契约。
///
/// ## 背景：这个开关曾经是个摆设
///
/// 设置页里「后台保活」能拨、状态能存、重启能记住，但**没有任何消费者** ——
/// `main.dart` 里那段显式不再把 `TerminalSettings.backgroundKeepAlive` 同步进
/// `SshForegroundService`（当时是有意休眠）。而 `SshForegroundService._enabled`
/// 默认 false、`startOrUpdate()` 开头就 `if (!_enabled) return;`，于是所有调用
/// 点全部静默变成 no-op。
///
/// 后果：开关看着像工作，实际什么都不做；而刚做好的通知通道**依赖它**才能在
/// 后台收到推送（关着时 app 进后台连接被杀）。用户拨开关、读着「通知栏会常驻
/// 一条通知」的描述、然后发现什么都没有 —— 完全合理地判断成 bug。
///
/// 这里把「设置 → 服务」的同步抽成可注入的控制器，锁死接线真的存在，而不是
/// 靠人肉读 `main.dart` 里那几行。
void main() {
  group('后台保活接线', () {
    test('启动时设置为开 → 服务被启用', () async {
      final svc = _FakeService();
      final c = KeepAliveController(service: svc);
      await c.apply(keepAlive: true);
      expect(svc.enabledCalls, [true]);
      expect(c.enabled, isTrue);
    });

    test('启动时设置为关 → 服务被禁用（并停掉可能在跑的服务）', () async {
      final svc = _FakeService();
      final c = KeepAliveController(service: svc);
      await c.apply(keepAlive: false);
      expect(svc.enabledCalls, [false]);
      expect(c.enabled, isFalse);
    });

    test('反复应用同一个值 → 只同步一次（幂等，避免每次设置变动都重启服务）',
        () async {
      final svc = _FakeService();
      final c = KeepAliveController(service: svc);
      await c.apply(keepAlive: true);
      await c.apply(keepAlive: true);
      await c.apply(keepAlive: true);
      expect(svc.enabledCalls, [true]);
    });

    test('关→开→关 每次都同步', () async {
      final svc = _FakeService();
      final c = KeepAliveController(service: svc);
      await c.apply(keepAlive: false);
      await c.apply(keepAlive: true);
      await c.apply(keepAlive: false);
      expect(svc.enabledCalls, [false, true, false]);
    });

    test('打开时若已有会话 → 立即起服务，不等下一次连接', () async {
      // 用户在一段已连上的会话里打开开关，期望立刻生效；等到下次重连才
      // 起服务等于「我开了但它没反应」。
      final svc = _FakeService();
      final c = KeepAliveController(service: svc);
      c.setSessionStarter(() => 'my-server');
      await c.apply(keepAlive: true);
      expect(svc.startedWith, ['my-server']);
    });

    test('打开时若没有会话 → 不起服务（没东西可保活）', () async {
      final svc = _FakeService();
      final c = KeepAliveController(service: svc);
      c.setSessionStarter(() => null);
      await c.apply(keepAlive: true);
      expect(svc.startedWith, isEmpty);
    });

    test('关闭时不重复 stop —— 幂等路径不该触发任何服务调用', () async {
      final svc = _FakeService();
      final c = KeepAliveController(service: svc);
      await c.apply(keepAlive: false);
      svc.enabledCalls.clear();
      await c.apply(keepAlive: false);
      expect(svc.enabledCalls, isEmpty);
    });
  });

  // 端到端接线 —— 完全按 `main.dart` 的方式把 `TerminalSettings` 绑到控制器，
  // 证明「拨开关 → 服务被启用」这条链真的通。
  //
  // 这是本次修复的**核心回归**：接线曾经被拔掉，而各单元的测试都能过（控制器
  // 没被接线、服务没被调用，两边各自都「正确」）。只有把宿主装配方式也复制
  // 一份才能拦住。
  group('端到端：设置变更驱动服务（复现 main.dart 的装配）', () {
    late _FakeService svc;
    late KeepAliveController controller;
    late TerminalSettings settings;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      svc = _FakeService();
      controller = KeepAliveController(service: svc);
      settings = TerminalSettings(SecureStorageService());
      // main.dart 里的两行：通用 listener。`apply` 自己幂等。
      settings.addListener(() {
        controller.apply(keepAlive: settings.backgroundKeepAlive).ignore();
      });
    });

    test('用户在设置页打开开关 → 服务被启用', () async {
      await settings.setBackgroundKeepAlive(true);
      // listener 里是 fire-and-forget，等一轮微任务。
      await Future<void>.delayed(Duration.zero);
      expect(svc.enabledCalls, contains(true));
      expect(svc.enabled, isTrue);
    });

    test('用户在设置页关闭开关 → 服务被停掉', () async {
      await settings.setBackgroundKeepAlive(true);
      await Future<void>.delayed(Duration.zero);
      await settings.setBackgroundKeepAlive(false);
      await Future<void>.delayed(Duration.zero);
      expect(svc.enabled, isFalse);
      expect(svc.enabledCalls.last, isFalse);
    });

    test('改无关设置（字体）不会动服务 —— 通用 listener 下必须幂等', () async {
      await settings.setBackgroundKeepAlive(true);
      await Future<void>.delayed(Duration.zero);
      final before = List<bool>.from(svc.enabledCalls);
      await settings.setFontFamily('CourierPrime');
      await Future<void>.delayed(Duration.zero);
      expect(svc.enabledCalls, equals(before));
    });
  });
}

/// 假的 [KeepAliveServicePort]。记录调用而不是真的起 Android 前台服务 ——
/// 后者只能在真机上跑，但它**被没被调用**是纯逻辑，正是这里要锁的东西。
class _FakeService implements KeepAliveServicePort {
  final List<bool> enabledCalls = [];
  final List<String> startedWith = [];

  @override
  bool enabled = false;

  @override
  Future<void> setEnabled(bool v) async {
    enabledCalls.add(v);
    enabled = v;
  }

  @override
  Future<void> startOrUpdate(String serverName) async {
    startedWith.add(serverName);
  }
}

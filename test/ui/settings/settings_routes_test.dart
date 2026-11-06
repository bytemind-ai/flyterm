import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ui/settings/about_screen.dart';
import 'package:flyterm/ui/settings/agent_settings_screen.dart';
import 'package:flyterm/ui/settings/appearance_settings_screen.dart';
import 'package:flyterm/ui/settings/connection_advanced_screen.dart';
import 'package:flyterm/ui/settings/privacy_settings_screen.dart';
import 'package:flyterm/ui/settings/security_settings_screen.dart';
import 'package:flyterm/ui/settings/fet_settings_screen.dart';
import 'package:flyterm/ui/settings/keybar_editor_screen.dart';
import 'package:flyterm/ui/settings/known_hosts_screen.dart';

/// 这 9 条路由原先部分在 SettingsScreen 里内联构造，2026-10-07 统一为命名
/// 路由后集中注册在 app.dart。
///
/// 拆成两个互补的断言：
///   1. **路由确实注册在 app.dart**（本文件第 2 个 test）—— 从源码文本里
///      找 `case '/settings/xxx':`。app.dart 的 `onGenerateRoute` 是个
///      内联闭包，没法在测试里单独调用（它捕获了 App 的 build 上下文），
///      但它要匹配的路由名必然是 `switch (settings.name)` 里的字面量
///      `case`。解析源码文本正是"路由表能解析"这一事实的最直接证据，
///      比只断言字符串常量集合（常量写错了测试照样过）强。
///   2. **4 个 Screen 的构造器签名未变**（第 3 个 test）—— 编译期保证它们
///      仍是可 `const XxxScreen()` 构造的、无必需参数。app.dart 里
///      `const XxxScreen()` 一旦签名漂移会编译失败，这里提前在测试层锚住。
///
/// 不构造整棵 provider 依赖树（各屏自己的 widget 测试另有文件覆盖），也不
/// 做真实导航 —— 那需要 App + 全部 provider。
void main() {
  const routes = <String, Widget>{
    '/settings/known-hosts': KnownHostsScreen(),
    '/settings/keybar': KeybarEditorScreen(),
    '/settings/fet': FetSettingsScreen(),
    '/settings/agent': AgentSettingsScreen(),
    '/settings/appearance': AppearanceSettingsScreen(),
    '/settings/connection-advanced': ConnectionAdvancedScreen(),
    '/settings/security': SecuritySettingsScreen(),
    '/settings/privacy': PrivacySettingsScreen(),
    '/settings/about': AboutScreen(),
  };

  test('app.dart 里确实注册了这 9 条 case 路由', () {
    // 直接读源码文本做断言。相对路径以包根为基准（flutter test 的 cwd）。
    final source = File('lib/app.dart').readAsStringSync();

    for (final route in routes.keys) {
      expect(route.startsWith('/settings/'), isTrue,
          reason: '$route 应在 /settings/ 下');
      expect(source.contains("case '$route':"), isTrue,
          reason:
              "app.dart 的 onGenerateRoute 里缺少 `case '$route':` —— 路由名改了但测试没同步？");
    }
  });

  testWidgets('9 个 Screen 都能被构造（编译期 + 运行期双保证）', (tester) async {
    // 不 pump：只验证构造器签名未变（无必需参数）。若未来某个屏加了必需
    // 参数，这个 map 里的 `const XxxScreen()` 会编译失败 —— 那正是要提醒
    // 的信号。
    expect(routes['/settings/known-hosts'], isA<KnownHostsScreen>());
    expect(routes['/settings/keybar'], isA<KeybarEditorScreen>());
    expect(routes['/settings/fet'], isA<FetSettingsScreen>());
    expect(routes['/settings/agent'], isA<AgentSettingsScreen>());
    expect(routes['/settings/appearance'], isA<AppearanceSettingsScreen>());
    expect(routes['/settings/connection-advanced'],
        isA<ConnectionAdvancedScreen>());
    expect(routes['/settings/security'], isA<SecuritySettingsScreen>());
    expect(routes['/settings/privacy'], isA<PrivacySettingsScreen>());
    expect(routes['/settings/about'], isA<AboutScreen>());
  });
}

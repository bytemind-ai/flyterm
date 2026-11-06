// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'main.dart' show appNavigatorKey;
import 'data/models/server.dart';
import 'data/models/ai_provider_config.dart';
import 'consent/consent_manager.dart';
import 'ui/legal/consent_first_run_screen.dart';
import 'ui/home/home_screen.dart';
import 'ui/shell/app_shell.dart';
import 'ui/home/server_form_screen.dart';
import 'ui/settings/settings_screen.dart';
import 'ui/settings/appearance_settings_screen.dart';
import 'ui/settings/connection_advanced_screen.dart';
import 'ui/settings/security_settings_screen.dart';
import 'ui/settings/privacy_settings_screen.dart';
import 'ui/settings/about_screen.dart';
import 'ui/settings/key_manager_screen.dart';
import 'ui/settings/known_hosts_screen.dart';
import 'ui/settings/keybar_editor_screen.dart';
import 'ui/settings/fet_settings_screen.dart';
import 'ui/settings/agent_settings_screen.dart';
import 'ui/settings/ai_providers_screen.dart';
import 'ui/settings/ai_provider_form_screen.dart';
import 'ui/terminal/terminal_screen.dart';
import 'ui/tunnel/tunnel_list_screen.dart';
import 'ui/tunnel/tunnel_form_screen.dart';
import 'ui/jobs/job_board_screen.dart';
import 'ui/design/fly_tokens.dart';

/// App-wide RouteObserver.  TerminalScreen subscribes to it so that any route
/// pushed on top (dialogs, settings, SFTP…) triggers an immediate unfocus of
/// the active TerminalView, preventing xterm from auto-reopening the keyboard
/// when the route pops and Flutter restores focus.
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

class App extends StatefulWidget {
  /// Initial route determined at startup: '/terminal' when saved tabs exist,
  /// '/home' otherwise.
  final String initialRoute;
  const App({super.key, this.initialRoute = '/home'});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      navigatorObservers: [appRouteObserver],
      title: 'FlyTerm',
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // 皮肤全部由 `lib/ui/design/fly_tokens.dart` 装配 —— 那里是设计系统的
      // 唯一真相源。这里不再从 seedColor 现算：seed 生成法会按色相旋转出
      // 一批 FlyTerm 从未选过的颜色（卡片会泛绿/泛蓝），与「层级靠亮度差」
      // 直接冲突，是改造前视觉不统一的根源之一。
      theme: buildFlyTermTheme(),
      initialRoute: widget.initialRoute,
      // In restore mode ('/terminal') seed the stack with HomeScreen underneath
      // TerminalScreen so the system back button returns to the server list
      // instead of exiting the app.
      onGenerateInitialRoutes: (route) {
        if (route == '/terminal') {
          // 恢复会话：仍然直接落在终端页，老用户体感零变化。变的只是垫在
          // 底下的那层 —— 从 HomeScreen 换成 AppShell，于是按一次返回落到
          // 服务器 tab 而不是一个光秃秃的列表页。
          return [
            MaterialPageRoute(builder: (_) => const AppShell()),
            MaterialPageRoute(builder: (_) => const TerminalScreen()),
          ];
        }
        return [
          MaterialPageRoute(
            builder: (context) => Consumer<ConsentManager>(
              builder: (context, manager, _) {
                // 同意判断留在 AppShell **之外**：未同意时根本不构造 shell，
                // 首启流程的行为因此与改造前完全一致。
                if (manager.needsConsent) return const ConsentFirstRunScreen();
                return const AppShell();
              },
            ),
          ),
        ];
      },
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case '/home':
            final forceNew = settings.arguments == true;
            return MaterialPageRoute(
                builder: (_) => HomeScreen(forceNewTab: forceNew));
          case '/server-form':
            return MaterialPageRoute(
              builder: (_) => ServerFormScreen(
                  server: settings.arguments as Server?),
            );
          // 无调用方 —— AppBar 齿轮在底部 tab 落地时删掉了，设置现在是一个
          // 常驻 tab。**刻意保留**这条路由：留作深链入口，删了没有收益。
          case '/settings':
            return MaterialPageRoute(
                builder: (_) => const SettingsScreen());
          case '/settings/keys':
            return MaterialPageRoute(
                builder: (_) => const KeyManagerScreen());
          case '/settings/known-hosts':
            return MaterialPageRoute(
                builder: (_) => const KnownHostsScreen());
          case '/settings/keybar':
            return MaterialPageRoute(
                builder: (_) => const KeybarEditorScreen());
          case '/settings/fet':
            return MaterialPageRoute(
                builder: (_) => const FetSettingsScreen());
          case '/settings/agent':
            return MaterialPageRoute(
                builder: (_) => const AgentSettingsScreen());
          case '/settings/appearance':
            return MaterialPageRoute(
                builder: (_) => const AppearanceSettingsScreen());
          case '/settings/connection-advanced':
            return MaterialPageRoute(
                builder: (_) => const ConnectionAdvancedScreen());
          case '/settings/security':
            return MaterialPageRoute(
                builder: (_) => const SecuritySettingsScreen());
          case '/settings/privacy':
            return MaterialPageRoute(
                builder: (_) => const PrivacySettingsScreen());
          case '/settings/about':
            return MaterialPageRoute(
                builder: (_) => const AboutScreen());
          case '/settings/ai-providers':
            return MaterialPageRoute(
                builder: (_) => const AIProvidersScreen());
          case '/settings/ai-providers/form':
            return MaterialPageRoute(
              builder: (_) => AIProviderFormScreen(
                  existing:
                      settings.arguments as AIProviderConfig?),
            );
          case '/tunnels':
            return MaterialPageRoute(
                builder: (_) => const TunnelListScreen());
          case '/tunnels/form':
            return MaterialPageRoute(
              builder: (_) => TunnelFormScreen(
                args: (settings.arguments as TunnelFormArgs?) ??
                    const TunnelFormArgs(),
              ),
            );
          case '/jobs':
            return MaterialPageRoute(
                builder: (_) => const JobBoardHost());
          default:
            return null;
        }
      },
    );
  }
}

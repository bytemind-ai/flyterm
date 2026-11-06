// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

import 'package:provider/provider.dart';

import '../../app_control/app_control_service.dart';
import '../ai/global_ai_screen.dart';
import '../design/fly_tokens.dart';
import '../home/home_screen.dart';
import '../settings/settings_screen.dart';

const int kAiTab = 0;
const int kServersTab = 1;
const int kSettingsTab = 2;

/// 一次性通知，用来把「tab 切换」这个事件转给常驻的页面。
///
/// 做成 `ChangeNotifier` 而不是给 `HomeScreen` 开 `GlobalKey`：后者要把
/// `_HomeScreenState` 公开出去，等于把整个页面的内部状态暴露给 shell。
class ServerListRefreshSignal extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// App 的根：AI / 服务器 / 设置三个 tab。
///
/// ## 终端页为什么不在这里
///
/// 终端页仍然是整页 `push` 盖在 shell 之上。终端的垂直空间已经被顶部 tab 栏、
/// 底部 keybar、软键盘吃满，再塞一条 [kShellNavBarHeight] 高的导航栏会让可见
/// 行数再少 2-3 行。终端是本产品的主体，不为导航让位。
///
/// ## 为什么是 IndexedStack
///
/// 三页实例常驻，保住的是 **UI 状态**——服务器页的搜索框文本、列表滚动位置、
/// AI 聊天的滚动位置、设置页展开的分组。重建式容器（`PageView` / 条件渲染）
/// 会把这些全部丢掉。
///
/// 这**不是**为了省 DB 查询：[ServerListRefreshSignal] 本来就会在特定时机主动
/// 重查。两件事互不冲突——信号控制「数据何时重取」，`IndexedStack` 控制
/// 「UI 状态是否保留」。
class AppShell extends StatefulWidget {
  /// 覆盖设置页，**仅供测试**。
  ///
  /// 真实的 `SettingsScreen` 要十几个 provider 才能建起来，widget 测试里全
  /// 搭一遍既脆又慢。与 `JobBoardScreen.hasTabFor` 同一个性质的缝：默认值是
  /// 生产行为，测试传假的进来。
  final Widget? settingsPage;

  const AppShell({super.key, this.settingsPage});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = kServersTab;

  /// 重查服务器列表。只在**从设置 tab 切回**时 fire。
  final _reloadSignal = ServerListRefreshSignal();

  /// 重扫后台任务。**每次**切到服务器 tab 都 fire。
  final _visibilitySignal = ServerListRefreshSignal();

  /// 把「带用户去某个界面」的能力交给 AppControlService。
  ///
  /// 在这里注入而不是让 service 认识 Navigator：target → 动作的翻译是
  /// shell 的知识（哪个是 tab、哪个要 push），不该漏进数据层。
  ///
  /// `didChangeDependencies` 而非 `initState`：要 `context.read` 拿 provider。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final svc = context.read<AppControlService?>();
    if (svc == null) return;
    svc.onNavigate = _navigateTo;
    svc.currentLocationProvider = () => switch (_tab) {
      kAiTab => 'ai',
      kServersTab => 'servers',
      _ => 'settings',
    };
  }

  /// **这里的每一个 case 都必须覆盖 `AppControlService.navigationTargets`。**
  /// 漏一个的后果是「AI 说带你过去，然后什么都没发生」—— 比报错更难查，
  /// 所以 `app_control_navigation_test` 有一条断言锚定两边不漂移。
  void _navigateTo(String target) {
    if (!mounted) return;
    switch (target) {
      case 'ai':
        _select(kAiTab);
      case 'servers':
        _select(kServersTab);
      case 'settings':
        _select(kSettingsTab);
      case 'ssh_keys':
        Navigator.of(context).pushNamed('/settings/keys');
      case 'ai_providers':
        Navigator.of(context).pushNamed('/settings/ai-providers');
      case 'tunnels':
        Navigator.of(context).pushNamed('/tunnels');
      case 'agent_settings':
        Navigator.of(context).pushNamed('/settings/agent');
      case 'keybar':
        Navigator.of(context).pushNamed('/settings/keybar');
      case 'known_hosts':
        Navigator.of(context).pushNamed('/settings/known-hosts');
    }
  }

  @override
  void dispose() {
    _reloadSignal.dispose();
    _visibilitySignal.dispose();
    super.dispose();
  }

  void _select(int next) {
    if (next == _tab) return;
    // 在 setState 之前读旧值：setState 之后 `_tab` 已经是新的了。
    final cameFromSettings = _tab == kSettingsTab;
    setState(() => _tab = next);
    if (next != kServersTab) return;
    // 每次切到服务器 tab 都重扫 job（实时性信号）。
    _visibilitySignal.fire();
    // 只有从设置 tab 回来才重查 DB —— 配置导入是唯一会改服务器记录的路径，
    // 而它只发生在设置页。从 AI tab 切回去重查是白查。
    if (cameFromSettings) _reloadSignal.fire();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return PopScope(
      // 服务器 tab 是「家」：它是连接的起点，也是老用户肌肉记忆里根页该在的
      // 位置。在它上面按返回 = 退出 App（与改造前 HomeScreen 作为根页的行为
      // 一致）；在别的 tab 上按返回先切回它。
      canPop: _tab == kServersTab,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() => _tab = kServersTab);
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tab,
          children: [
            const GlobalAIScreen(),
            HomeScreen(
              reloadSignal: _reloadSignal,
              visibilitySignal: _visibilitySignal,
            ),
            widget.settingsPage ?? const SettingsScreen(embedded: true),
          ],
        ),
        bottomNavigationBar: ShellNavBar(
          selectedIndex: _tab,
          onSelected: _select,
          items: [
            ShellNavItem(
              icon: Icons.auto_awesome_outlined,
              activeIcon: Icons.auto_awesome,
              label: l.navAI,
            ),
            ShellNavItem(
              // 与 `_ServerTile` 的 leading 图标同源，保持一致。
              icon: Icons.dns_outlined,
              activeIcon: Icons.dns,
              label: l.navServers,
            ),
            ShellNavItem(
              icon: Icons.settings_outlined,
              activeIcon: Icons.settings,
              label: l.navSettings,
            ),
          ],
        ),
      ),
    );
  }
}

/// 导航条内容区高度（不含底部安全区）。
///
/// 52 是和 keybar 的 44（`key_bar.dart:202`）同一条尺度带上挑的：两者都贴底、
/// 在终端页会前后脚出现，差太多会让人觉得是两个 App 拼起来的。M3
/// `NavigationBar` 的默认 80 在这里几乎是 keybar 的两倍，正是「太高」的来源。
///
/// 不能再往下压：52 已经贴着 Material 的 48 最小可点区域，再矮就要牺牲命中率。
const double kShellNavBarHeight = 52;

/// [ShellNavBar] 的一项。
class ShellNavItem {
  const ShellNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// 底部三 tab 导航条。
///
/// ## 为什么自绘而不用 `NavigationBar`
///
/// M3 的默认皮肤和这个 App 的视觉语汇是拧的：它要 80dp 高、带药丸形
/// indicator、标签用 Material 默认字体常显。而本仓库首页那一套是
/// 0.5px hairline 分隔（`_RowDivider`）、JetBrains Mono 小号大写微标签
/// （`_GroupHeader`）、无 elevation、mint `#00C896` 点缀。
///
/// 只调 `NavigationBar` 的 `height` 能压下去，但字体、间距、indicator 形状
/// 还是 Material 那套 —— 拿不到「和首页是同一个产品」的观感。
///
/// ## 代价
///
/// 自绘要自己补 `NavigationBar` 免费给的无障碍语义，所以每一项都裹了
/// [Semantics]（`button` + `selected` + label）。改这个组件时别把它删掉。
class ShellNavBar extends StatelessWidget {
  const ShellNavBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.items,
  });

  /// 当前选中项。
  ///
  /// widget 测试靠读这个字段判断「现在在哪个 tab」——`IndexedStack` 把三页
  /// 都留在树里，`find.byType(HomeScreen)` 之类恒为真，用不了。
  final int selectedIndex;

  final ValueChanged<int> onSelected;
  final List<ShellNavItem> items;

  /// CJK 没有大写概念，也不该套等宽英文字体。判别逻辑与首页 `_GroupHeader`
  /// 同源：ASCII 走 JetBrains Mono + uppercase + 字距，其余走系统字体原样。
  static bool _isAscii(String s) {
    for (final c in s.codeUnits) {
      if (c > 0x7E) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 两个 accent 不再各写一份字面量：走 token，将来调色只改一处。
    final idle = cs.onSurface.withValues(alpha: kNavIdleOpacity);

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        // 底线用 divider token，与页面里其他 hairline 同源。
        border: Border(
          top: BorderSide(color: FlyColors.divider, width: kHairline),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: kShellNavBarHeight,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _ShellNavCell(
                    item: items[i],
                    selected: i == selectedIndex,
                    idle: idle,
                    onTap: () => onSelected(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShellNavCell extends StatelessWidget {
  const _ShellNavCell({
    required this.item,
    required this.selected,
    required this.idle,
    required this.onTap,
  });

  final ShellNavItem item;
  final bool selected;
  final Color idle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 选中态用品牌 mint（= 活动态）。这里的双重表达是刻意的：
    //
    //   1. **颜色** —— mint vs 灰（对比度见 `kNavIdleOpacity` 的文档）
    //   2. **形态** —— 顶部指示条 + 更重的字重
    //
    // 只靠颜色时实测两者只差 2.58:1（调到更亮反而更差），而且对色觉障碍
    // 用户完全无效。第二个维度不是锦上添花，是这条导航能不能用的前提。
    final accent = FlyColors.active;
    final color = selected ? accent : idle;
    final ascii = ShellNavBar._isAscii(item.label);

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        // 整格可点：52dp 高 × 1/3 宽，满足 48dp 最小命中区。
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 指示条占位**不管选中与否都占同样高度**：否则未选中时图标
            // 会往下掉 26px，切 tab 时整排图标跳一下。
            SizedBox(
              height: kNavIndicatorHeight + 4,
              child: selected
                  ? Center(
                      child: Container(
                        key: const Key('shellNav.activeIndicator'),
                        width: kNavIndicatorWidth,
                        height: kNavIndicatorHeight,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    )
                  : null,
            ),
            Icon(
              selected ? item.activeIcon : item.icon,
              size: 20,
              color: color,
            ),
            const SizedBox(height: 3),
            Text(
              ascii ? item.label.toUpperCase() : item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: ascii ? 'JetBrainsMono' : null,
                fontSize: ascii ? 9.5 : 10,
                // 选中更重：第三个可辨维度，且不依赖颜色。
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                letterSpacing: ascii ? 0.6 : 0,
                color: color,
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

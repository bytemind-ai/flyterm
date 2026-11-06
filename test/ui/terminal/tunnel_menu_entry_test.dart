import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/terminal/tunnel_menu_visibility.dart';

void main() {
  group('buildPlusMenuItems', () {
    test('无连接时只剩 newTab', () {
      // 隧道管理的家已迁到首页「服务器｜隧道」分段，
      // `+` 菜单不再承担"隧道入口常驻"的职责。
      final items = buildPlusMenuItems(
        canUseRemoteActions: false,
        isLocalAlive: false,
      );
      expect(items, [PlusMenuItem.newTab]);
    });

    test('有远端动作时按「创建类 → 视图类」排序', () {
      final items = buildPlusMenuItems(
        canUseRemoteActions: true,
        isLocalAlive: false,
      );
      // 分类：创建类（newTab / newTunnel）在前，视图类（sftp / layout）在后。
      // 类内按频率降序。
      expect(
        items,
        [
          PlusMenuItem.newTab,
          PlusMenuItem.newTunnel,
          PlusMenuItem.sftp,
          PlusMenuItem.layout,
        ],
      );
      // tunnelList 枚举值已删除，此处不再引用（用源码级断言守护，见下）。
    });

    test('仅本地 shell 时含 layout，不含 sftp / newTunnel', () {
      final items = buildPlusMenuItems(
        canUseRemoteActions: false,
        isLocalAlive: true,
      );
      expect(items, contains(PlusMenuItem.layout));
      expect(items, isNot(contains(PlusMenuItem.sftp)));
      expect(items, isNot(contains(PlusMenuItem.newTunnel)));
    });
  });

  group('分类与分隔线落点', () {
    test('创建类 / 视图类分组判据', () {
      expect(isCreateGroupItem(PlusMenuItem.newTab), isTrue);
      expect(isCreateGroupItem(PlusMenuItem.newTunnel), isTrue);
      expect(isCreateGroupItem(PlusMenuItem.sftp), isFalse);
      expect(isCreateGroupItem(PlusMenuItem.layout), isFalse);

      expect(isViewGroupItem(PlusMenuItem.sftp), isTrue);
      expect(isViewGroupItem(PlusMenuItem.layout), isTrue);
      expect(isViewGroupItem(PlusMenuItem.newTab), isFalse);
      expect(isViewGroupItem(PlusMenuItem.newTunnel), isFalse);
    });

    test('两类都非空时，第一个视图类项前插分隔线', () {
      // 已连接远端：创建类 + 视图类都非空 → 唯一的分隔线在 sftp 前。
      final items = buildPlusMenuItems(
        canUseRemoteActions: true,
        isLocalAlive: false,
      );
      expect(
        dividerBeforeIndex(items),
        items.indexOf(PlusMenuItem.sftp),
        reason: '分隔线应落在第一个视图类项（sftp）之前',
      );
    });

    test('只有创建类时不插分隔线', () {
      // 无连接：菜单只有 newTab，没有视图类项 → 无分隔线。
      final items = buildPlusMenuItems(
        canUseRemoteActions: false,
        isLocalAlive: false,
      );
      expect(dividerBeforeIndex(items), isNull);
    });
  });

  group('terminal_screen 接线', () {
    test('+ 走 onOpenMenu，且 ⋮ / tunnel_list 已删除', () {
      final src = File('lib/ui/terminal/terminal_screen.dart').readAsStringSync();

      expect(src.contains('Icons.more_vert'), isFalse,
          reason: '⋮ 应从 terminal_screen 彻底删除');
      expect(src.contains('shouldRenderOverflowMenu'), isFalse,
          reason: '旧闸门应已退场');
      expect(src.contains('onOpenMenu'), isTrue,
          reason: '+ 必须经 onOpenMenu 通知上层弹菜单');
      expect(src.contains('buildPlusMenuItems'), isTrue,
          reason: '菜单项必须由 buildPlusMenuItems 生成');
      expect(src.contains("'tunnel_list'"), isFalse,
          reason: '隧道管理项已从 + 菜单删除');
      expect(src.contains('PlusMenuItem.tunnelList'), isFalse,
          reason: 'tunnelList 枚举值应已删除');
    });

    test('tunnel_new 带 pro_tunnel 闸门', () {
      final src = File('lib/ui/terminal/terminal_screen.dart').readAsStringSync();
      expect(src.contains("reason: 'pro_tunnel'"), isTrue,
          reason: '新建隧道入口必须过 pro_tunnel 闸门，堵住付费墙漏洞');
    });

    test('+ 菜单渲染分隔线（分类边界）', () {
      final src = File('lib/ui/terminal/terminal_screen.dart').readAsStringSync();
      expect(src.contains('dividerBeforeIndex'), isTrue,
          reason: '菜单必须按 dividerBeforeIndex 的分类边界插分隔线');
      expect(src.contains('PopupMenuDivider'), isTrue,
          reason: '分隔线应由 PopupMenuDivider 渲染');
    });
  });
}

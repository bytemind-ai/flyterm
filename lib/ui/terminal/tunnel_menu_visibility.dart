// SPDX-License-Identifier: GPL-3.0-or-later
/// 终端页「+」菜单的可见项集合。
///
/// 2026-10-09 的入口合并把原来的 AppBar `⋮` 四项（SFTP / 布局 / 新建隧道 /
/// 隧道管理）并进了 tab 条尾部的 `+`，`⋮` 本身删除。
///
/// 2026-10-10 的入口重构把「隧道管理」从 `+` 菜单移出——隧道的家迁到首页「服务器｜隧道」分段，
/// 终端只保留带当前 tab 服务器上下文的「新建隧道」。因此菜单不再有"隧道
/// 入口常驻"这一项，`buildPlusMenuItems` 也不再无条件返回任何隧道项。
///
/// 判据抽成纯函数是为了可测：`TerminalScreen` 需要真实 SSH 才能建起来，
/// 仓库里没有它的轻量脚手架（`test/ui/terminal/` 下全是纯逻辑单测）。
///
/// 顺序即渲染顺序。
///
/// 2026-10-10 的排序 + 分类：menu 项按“动作性质”分两类——
/// 创建类（开新东西）在前，视图类（改当前呈现）在后；类内按频率降序。
/// enum 的声明顺序不再等于渲染顺序（见 [buildPlusMenuItems]）。
enum PlusMenuItem { newTab, sftp, layout, newTunnel }

/// 创建类：产生新资源。排在菜单上半区。
bool isCreateGroupItem(PlusMenuItem item) =>
    item == PlusMenuItem.newTab || item == PlusMenuItem.newTunnel;

/// 视图类：改变当前 tab 的呈现。排在菜单下半区。
bool isViewGroupItem(PlusMenuItem item) =>
    item == PlusMenuItem.sftp || item == PlusMenuItem.layout;

/// 分隔线落点：返回应在它**之前**插一条 [PopupMenuDivider] 的项下标；
/// 无需分隔线时返回 `null`。
///
/// 规则：只在创建类与视图类**都非空**时插入，且落在第一个视图类项前。
/// 由于 [PlusMenuItem.newTab] 恒显，创建类永不为空，因此实际等价于
/// “存在视图类项”时插线。
int? dividerBeforeIndex(List<PlusMenuItem> items) {
  final firstView = items.indexWhere(isViewGroupItem);
  if (firstView <= 0) return null; // 无视图类，或视图类排在最前（不会发生）
  return firstView;
}

/// 按顺序返回当前应显示的菜单项。不显示置灰项 —— 手机上置灰项既难点
/// 又难读，和原来 `⋮` 内部的做法一致（不可用就藏起来）。
List<PlusMenuItem> buildPlusMenuItems({
  required bool canUseRemoteActions,
  required bool isLocalAlive,
}) => [
  PlusMenuItem.newTab,
  if (canUseRemoteActions) PlusMenuItem.newTunnel,
  if (canUseRemoteActions) PlusMenuItem.sftp,
  if (canUseRemoteActions || isLocalAlive) PlusMenuItem.layout,
];

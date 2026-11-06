// SPDX-License-Identifier: GPL-3.0-or-later
import 'tool_models.dart';

/// 按需解锁的工具分组。**不在这里的工具都是 core，默认常驻。**
///
/// ## 分组判据
///
/// 「这一轮就要用」还是「整场会话可能一次都不用」。
///
/// `check_job` 刻意留在 core：它和 `run_background` 是一对，后者一调，前者
/// 必然紧接着要用，为此多一轮解锁往返不划算。`list_jobs` 进 jobs 组，因为
/// 它只在「我有哪些任务在跑」这种查询里用到。
///
/// ## 为什么按组而不是按单个工具
///
/// 传文件的场景通常 upload/download 一起用，分开解锁等于两轮往返。
const Map<String, List<String>> kToolGroups = {
  'transfer': ['upload_file', 'download_file', 'copy_between_servers'],
  // SFTP 管理与传输是一类场景（通常连着用），但分开成组：只想列个目录
  // 的会话不该背上三个传输工具的 schema。
  'sftp': [
    'sftp_list',
    'sftp_stat',
    'sftp_mkdir',
    'sftp_rename',
    'sftp_remove',
    'sftp_chmod',
  ],
  'web': ['web_fetch'],
  // `save_skill` 与 `save_note` 必须同组、一起解锁：两者是一对二选一
  // （「跨机套路」vs「这台机器的事」）。只解锁其中一个，模型手里没有另一个
  // 选项时会把机器事实硬塞进 skill —— 分组存在的意义就是不让这种情况发生。
  'skills': [
    'save_skill',
    'save_note',
    'skill_list',
    'skill_delete',
    'skill_set_enabled',
    'skill_update',
  ],
  // `list_jobs` 单独留在 jobs 组：符合本文件的分组判据 —— 它只在
  // 「我有哪些任务在跑」这种查询里用到。
  //
  // 与 `check_job` 留在 core 是同一条理由（见文件头）：工具一露头就会
  // 紧接着用，为此多一轮解锁往返不划算。
  'jobs': ['list_jobs'],
  // app 自身控制。分两组而不是一组：配置类操作通常成串出现（建条目→开
  // tunnel），会话类也成串（开会话→切布局），但两串之间不常交叉 —— 合成
  // 一组等于让只想改字体的会话也背上 layout_set 的 schema。
  //
  // Phase 1 只实现了 app_settings_set。其余工具在 Phase 2 补齐后加进来。
  'app_config': [
    'app_settings_set',
    'server_entry_create',
    'server_entry_update',
    'server_entry_delete',
    'tunnel_create',
    'tunnel_close',
    'keybar_item_add',
    'keybar_item_remove',
    'ssh_key_generate',
    'ssh_key_list',
    'saved_command_create',
    'saved_command_delete',
    'saved_command_list',
    'known_host_list',
    'known_host_forget',
  ],
  'app_session': [
    'session_open',
    'session_close',
    'layout_set',
    'navigate_to',
  ],
};

/// 某个工具属于哪个组；core 工具返回 null。
String? groupOf(String toolName) {
  for (final e in kToolGroups.entries) {
    if (e.value.contains(toolName)) return e.key;
  }
  return null;
}

/// 从全量 specs 里滤掉未解锁的 on-demand 工具。
///
/// **纯函数**：调用方（`AgentLoop`）传进来的 specs 已经过 `agentToolSpecsFor`
/// 的 conditional 筛选（`hasOtherServers` / `hasSkills`），这里只做第二道。
///
/// 顺序是刻意的：conditional 在前、解锁在后。反过来会让单机用户解锁
/// `transfer` 之后拿到一个没有第二个目标的 `copy_between_servers` ——
/// 解锁只能从「本来就该有的」里面放行，不能凭空造出来。
///
/// 未知组名被忽略而不是报错：它只会导致少放行几个工具，而调用方
/// (`MoreToolsExecutors`) 已经在入口校验过组名了。
List<ToolSpec> filterByUnlockedGroups(
  List<ToolSpec> specs,
  Set<String> unlocked,
) {
  return [
    for (final s in specs)
      if (groupOf(s.name) == null || unlocked.contains(groupOf(s.name))) s,
  ];
}

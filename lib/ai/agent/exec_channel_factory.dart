// SPDX-License-Identifier: GPL-3.0-or-later
import 'agent_exec_channel.dart';
import 'agent_session_manager.dart';
import '../../data/models/server.dart';
import '../../data/secure_storage.dart';
import '../../ssh/session_manager.dart';

/// 按 serverId 取/建一条 agent 专用 channel。
///
/// 缓存在 [AgentSessionManager] 里，所以同一台机器无论从哪条路径进来（终端的
/// AI 面板、多机调用的目标机器、后台任务看板）都是同一个实例、同一条连接。
///
/// **闭包只捕获 serverId，不捕获任何 tab。** channel 与 loop 的寿命都远长于
/// 单个 tab：捕获 tab 会让已关闭的会话永远回收不掉，也会让「在 tab A 开过
/// 面板、切到 tab B 再开」一直递出一个已经断开的 client（channel 拿着它去
/// 复用必然失败，而它本可以自己新开一条）。
///
/// 这条约束原先在 `terminal_screen` 的两个私有方法里各写了一遍，看板需要第
/// 三份 —— 所以提到这里，只维护一处。
///
/// （放在独立文件而不是 `agent_exec_channel.dart` 末尾：`agent_session_manager.dart`
/// 已经 import 了 `agent_exec_channel.dart`，反过来 import 会形成循环依赖。）
AgentExecChannel execChannelForServer({
  required AgentSessionManager mgr,
  required Server server,
  required SessionManager sessions,
  required SecureStorageService storage,
}) =>
    mgr.channelFor(
      server.id,
      () => AgentExecChannel(
        server: server,
        storage: storage,
        reuseProvider: () =>
            sessions.activeTabForServer(server.id)?.connection.client,
      ),
    );

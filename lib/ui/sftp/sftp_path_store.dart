// SPDX-License-Identifier: GPL-3.0-or-later
import '../../data/models/sftp_path.dart';
import '../../data/repositories/sftp_path_repository.dart';

/// 当前会话的目录历史 / 书签。
///
/// 存在的意义是**把「记录访问」和「列出目录」绑在一起**：调用方只要
/// `recordVisit`，不必记得每次 `listDirectory` 成功后都要写一条。
///
/// 它同时是 UI 与 repository 之间的**接缝** —— widget 测试里注入一个假
/// store，就不必在 FakeAsync 时钟下碰真实 sqflite。
class SftpPathStore {
  /// 底层 repository。**可为 null 只是为了给测试留缝** —— widget 测试跑在
  /// FakeAsync 时钟下，真实 sqflite 调用永远不会完成（实测：`ok=false`，
  /// 数据库随后被关掉时抛 `database_closed`）。子类覆写全部方法后传 null
  /// 即可绕开数据库。生产代码一律传真实 repository。
  final SftpPathRepository? repo;
  final String serverId;

  SftpPathStore({required this.repo, required this.serverId});

  SftpPathRepository get _repo {
    final r = repo;
    if (r == null) {
      throw StateError('SftpPathStore 未接 repository（仅测试子类可传 null）');
    }
    return r;
  }

  Future<void> recordVisit(String path) =>
      _repo.recordVisit(serverId: serverId, path: path);

  /// 目录历史，最近访问在前。缺省不限条数（repository 侧的自动淘汰已经
  /// 把未置顶项钉在 30 条以内）。
  Future<List<SftpPath>> recent() => _repo.recent(serverId: serverId);

  Future<List<SftpPath>> pinned() => _repo.pinned(serverId: serverId);

  Future<void> setPinned(String path, bool pinned) =>
      _repo.setPinned(serverId: serverId, path: path, pinned: pinned);

  Future<void> remove(String path) =>
      _repo.remove(serverId: serverId, path: path);

  /// 建议条数上限。
  ///
  /// 补全列表是给手指点的，超过一屏就失去「一眼扫完」的意义；而且它是
  /// 嵌在对话框下半部分的，条数多了会把 TextField 顶出视口。
  static const maxSuggestions = 8;

  /// 前缀匹配的补全建议。
  ///
  /// **只匹配本地历史，不做远端实时目录补全** —— 后者要每敲一个字符发一次
  /// `listdir`，移动网络的往返延迟明显，而且与输入法候选栏会打架。补全的
  /// 目的通常是「回到去过的地方」，历史足够覆盖。
  ///
  /// 匹配**大小写不敏感**：Unix 路径区分大小写，但用户搜索时不该被迫记住
  /// 是 `Var` 还是 `var` —— 这是补全，不是精确查找。
  Future<List<String>> suggest(String prefix) async {
    final all = await recent();
    final trimmed = prefix.trim();
    if (trimmed.isEmpty) {
      return all.take(maxSuggestions).map((e) => e.path).toList();
    }
    final lower = trimmed.toLowerCase();
    return all
        .where((e) => e.path.toLowerCase().startsWith(lower))
        .take(maxSuggestions)
        .map((e) => e.path)
        .toList();
  }
}

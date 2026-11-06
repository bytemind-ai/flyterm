// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:uuid/uuid.dart';

import 'app_change.dart';

/// 一轮 agent 运行里产生的全部 app 变更。
///
/// **批次是撤销的单位**，也是 UI 上一张卡片的单位 —— 两者必须对齐，否则
/// 会出现「点第一张卡的撤销，把第二张卡的改动也撤了」。
class AppChangeBatch {
  final String id;
  final List<AppChange> changes = [];

  bool _undone = false;

  AppChangeBatch({String? id}) : id = id ?? const Uuid().v4();

  /// 已经撤销过。卡片据此把按钮置灰并标注。
  bool get undone => _undone;

  /// 还能不能撤：没撤过、非空、且每一项都可逆。
  bool get canUndo =>
      !_undone && changes.isNotEmpty && changes.every((c) => c.reversible);

  /// 含不可逆项（`tunnel_create` / `session_close`）。卡片据此显示说明。
  bool get hasIrreversible => changes.any((c) => !c.reversible);

  /// 整批逆序回滚。
  ///
  /// 逆序而不是顺序：AI 一轮里往往改多项（字体+行高+主题），顺序回滚的中间
  /// 态没有意义，且若后一项改动依赖前一项，顺序退会得到不一致状态。
  ///
  /// 不可逆条目静默跳过 —— 它们已经前置确认过，不该因为混在同一批里就让
  /// 整个撤销失败。
  Future<void> undo() async {
    if (_undone) return;
    for (final c in changes.reversed) {
      final u = c.undo;
      if (u != null) await u();
    }
    _undone = true;
  }
}

/// 会话级撤销记录，**按批次组织**。**纯内存，不落盘。**
///
/// 撤销的价值窗口是「AI 刚改完我发现不对」。进程重启后用户可能已手动改过，
/// 回滚到旧值反而是破坏 —— 与 `AgentSessionManager._notified` 不落盘同理。
class AppChangeLog {
  final List<AppChangeBatch> _batches = [];

  /// 当前正在累积的批次。null = 这一轮还没有任何变更（懒创建）。
  AppChangeBatch? _current;

  /// 全部批次，含已撤销的（卡片要继续显示，只是按钮置灰）。
  List<AppChangeBatch> get batches => List.unmodifiable(_batches);

  AppChangeBatch? get currentBatch => _current;

  /// 开一轮新的。由 `AgentLoop` 在每次运行开始时调。
  ///
  /// **只是把指针清空，不预先建批次** —— 绝大多数轮次根本不碰 app 设置，
  /// 预建会在事件流里留下一堆空卡片。真有变更时 [record] 才建。
  void startBatch() => _current = null;

  void record(AppChange change) {
    final b = _current ??= AppChangeBatch();
    if (!_batches.contains(b)) _batches.add(b);
    b.changes.add(change);
  }

  AppChangeBatch? batchById(String id) {
    for (final b in _batches) {
      if (b.id == id) return b;
    }
    return null;
  }

  Future<void> undoBatch(String id) async => batchById(id)?.undo();

  // ───────── 跨批次的汇总视图 ─────────
  //
  // 保留这几个是为了让「不关心批次」的调用方（service 层测试、整体状态
  // 查询）不必遍历批次结构。它们看到的是「还没撤销的全部变更」。

  /// 所有未撤销批次里的全部变更，按发生顺序。
  List<AppChange> get pending => List.unmodifiable([
        for (final b in _batches)
          if (!b.undone) ...b.changes,
      ]);

  bool get isEmpty => pending.isEmpty;

  bool get canUndoAll =>
      pending.isNotEmpty && pending.every((c) => c.reversible);

  /// 撤销所有未撤销的批次，**从最新的批次往回退**。
  Future<void> undoAll() async {
    for (final b in _batches.reversed) {
      if (!b.undone) await b.undo();
    }
  }

  void clear() {
    _batches.clear();
    _current = null;
  }
}

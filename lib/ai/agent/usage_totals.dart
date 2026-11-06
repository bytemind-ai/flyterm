// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'tool_models.dart';

/// 跨会话的 token 累计，按 provider 分桶。
///
/// ## 为什么需要它（`AgentLoop.totalUsage` 不够）
///
/// `AgentLoop.totalUsage` 是**单条会话**的累计，给面板底部那行用量看；
/// 面板关掉、会话切走之后它就归零了。用户真正想知道的是「我这个月在这些
/// 模型上花了多少」—— 那需要一份活得比会话久的东西。
///
/// ## 为什么按 provider 分，而不是全局一个数
///
/// 「贵模型用得多还是便宜模型用得多」是唯一能**改变用户行为**的维度。
/// 全局总数看完只能「哦」一声。桶的 key 用 provider 的 `displayName`
/// （形如 `OpenAI (gpt-4o)`），它自带模型名 —— 换模型就是一个新桶，
/// 正是想要的粒度。
///
/// ## 存储
///
/// `shared_preferences` 里一条 JSON：`{displayName: {in, cached, out}}`。
/// 不建表：现在的需求只有「显示累计」，按时间维度查询等真需要了再说。
///
/// **纯内存不缓存**，每次读写都过 prefs。累计不是热路径（一次模型响应写
/// 一次），而缓存会引入「同一个 prefs 两个实例各持一份」的不一致 ——
/// 全局 AI 页与终端页 AI 面板各有一个 loop，正是这种情形。
class UsageTotals {
  static const _kKey = 'ai_usage_totals_v1';

  final SharedPreferences _prefs;

  UsageTotals(this._prefs);

  /// 读磁盘。损坏时按空处理 —— **不抛**：一个纯展示用的计数没有资格把
  /// 整个 AI 面板弄挂（与 `asTokenCount` 的取舍同理）。
  Map<String, TokenUsage> _load() {
    final raw = _prefs.getString(_kKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, TokenUsage>{};
      decoded.forEach((k, v) {
        if (k is! String || v is! Map) return;
        out[k] = TokenUsage(
          inputTokens: asTokenCount(v['in']),
          cachedTokens: asTokenCount(v['cached']),
          outputTokens: asTokenCount(v['out']),
        );
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  /// [providerKey] 目前的累计；从没用过时返回 null。
  TokenUsage? forProvider(String providerKey) => _load()[providerKey];

  /// 所有 provider 的 key（无序）。仅用于展示「有哪些」。
  Iterable<String> get providers => _load().keys;

  /// 所有 provider 相加。
  TokenUsage get total =>
      _load().values.fold(const TokenUsage(), (a, b) => a + b);

  /// 记一笔用量。
  ///
  /// **空用量直接跳过**：服务端不给 usage 时 `AIResponse.usage` 是全 0 的
  /// `TokenUsage`，记进去只会凭空多出一个全 0 的 provider 条目。
  Future<void> add(String providerKey, TokenUsage usage) async {
    if (usage.isEmpty) return;
    final all = _load();
    all[providerKey] = (all[providerKey] ?? const TokenUsage()) + usage;
    await _prefs.setString(
      _kKey,
      jsonEncode({
        for (final e in all.entries)
          e.key: {
            'in': e.value.inputTokens,
            'cached': e.value.cachedTokens,
            'out': e.value.outputTokens,
          },
      }),
    );
  }
}

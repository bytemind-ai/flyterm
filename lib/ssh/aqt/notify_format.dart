// SPDX-License-Identifier: GPL-3.0-or-later
/// 通知展示文案的纯格式化逻辑——独立于 flutter_local_notifications，
/// 方便 device-free 测试。
library;

class NotifyContent {
  final String title;
  final String body;
  const NotifyContent({required this.title, required this.body});
}

class NotifyFormat {
  /// 构造通知的标题（消息原文）与副标题（服务器名 · tab 名 · 绝对时间）。
  ///
  /// **刻意只用绝对时间，不用相对时间**（"5分钟前" 这类）：`tsUnixMs` 是
  /// 事件在远程服务器上发生的时间，不是这条通知投递到手机的时间——服务器和
  /// 手机的系统时钟可能没有同步，且重连补投场景下这条通知可能是几分钟甚至
  /// 更久之前的事件被延迟送达。如果按“投递时刻 - tsUnixMs”算相对时间，
  /// 遇到补投的旧事件会显示出类似"3 小时前"这种对用户没有意义、甚至因为
  /// 时钟误差而显示成负数或未来时间的荒谬结果。绝对时间不受这些影响。
  ///
  /// [now] 仅用于测试注入"当前时刻"（判断是否跨天，从而决定要不要带日期）；
  /// 生产环境调用方不传，走真实的 `DateTime.now()`。
  static NotifyContent build({
    required String text,
    required String serverName,
    required String? tabTitle,
    required int tsUnixMs,
    DateTime? now,
  }) {
    final ts = DateTime.fromMillisecondsSinceEpoch(tsUnixMs);
    final n = now ?? DateTime.now();
    final sameDay = ts.year == n.year && ts.month == n.month && ts.day == n.day;
    final timeStr = sameDay ? _hhmmss(ts) : '${_yyyyMMdd(ts)} ${_hhmm(ts)}';
    final parts = <String>[
      serverName,
      if (tabTitle != null && tabTitle.isNotEmpty) tabTitle,
      timeStr,
    ];
    return NotifyContent(title: text, body: parts.join(' · '));
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _hhmmss(DateTime t) =>
      '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
  static String _hhmm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';
  static String _yyyyMMdd(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}';
}

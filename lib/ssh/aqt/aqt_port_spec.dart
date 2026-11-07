// SPDX-License-Identifier: GPL-3.0-or-later
/// AQT daemon 监听的 UDP 端口：单个端口或闭区间。
///
/// 存在的理由是防火墙：随机端口没法在云安全组里提前放行，固定的一段可以。
/// 用范围而不是单个端口，是因为一台机器上每个用户各跑一个 daemon，范围让它们
/// 在段内自动错开（服务端从段内随机位置起找空闲端口，见 flyterm-server 的
/// `PortSpec`）。
///
/// 解析规则与服务端一致，另外要求 ≥ 1024：daemon 以普通用户身份运行，绑不了
/// 特权端口，在 App 里就拦下比让 daemon 启动失败友好。
class AqtPortSpec {
  final int start;
  final int end;

  const AqtPortSpec(this.start, this.end);

  /// 服务器没配置时用的范围。与 tsshd 的默认段一致，文档和连接失败提示里
  /// 直接让用户放行这一段。
  static const AqtPortSpec defaults = AqtPortSpec(61001, 61999);

  static const int _min = 1024;
  static const int _max = 65535;

  static AqtPortSpec? parse(String input) {
    final s = input.trim();
    final m = RegExp(r'^(\d{1,5})(?:-(\d{1,5}))?$').firstMatch(s);
    if (m == null) return null;
    final a = int.parse(m.group(1)!);
    final b = m.group(2) == null ? a : int.parse(m.group(2)!);
    if (a < _min || b > _max || a > b) return null;
    return AqtPortSpec(a, b);
  }

  /// [Server.aqtPorts] → 实际使用的端口段。空或非法（表单已校验，非法只可能
  /// 来自手改过的备份）都回落到 [defaults]。
  static AqtPortSpec forServer(String? configured) {
    if (configured == null || configured.trim().isEmpty) return defaults;
    return parse(configured) ?? defaults;
  }

  bool contains(int port) => port >= start && port <= end;

  /// 传给 `flyterm-server --listen` / `--once-port` 的写法。
  String get arg => start == end ? '$start' : '$start-$end';

  @override
  String toString() => arg;

  @override
  bool operator ==(Object other) =>
      other is AqtPortSpec && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

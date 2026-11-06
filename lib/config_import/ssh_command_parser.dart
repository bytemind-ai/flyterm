// SPDX-License-Identifier: GPL-3.0-or-later
import 'config_draft.dart';

/// 带值的短选项。`-p 2222` 与 `-p2222` 两种写法都要支持 —— 后者是 getopt
/// 的合法形式，真实世界里很常见。
const _valueFlags = {'p', 'i', 'J', 'l', 'L', 'R', 'D', 'o', 'F', 'b', 'c'};

/// 这个 token 看起来像主机名或 IP 吗？
///
/// 三种形态都要认（产品明确支持 IPv6，且文案说「可带可不带方括号」，见
/// `lib/l10n/app_zh.arb` 的 `labelHostHelper`，`Server` 也有 `addressFamily`
/// 字段）：
///   - 方括号包裹的 IPv6：`[2001:db8::1]`
///   - 裸 IPv6：`2001:db8::1` / `::1`
///   - 主机名或 IPv4：`example.com` / `10.0.0.5`
///
/// 没有这道校验的话，任意非选项 token 都会被当成 host —— 包括一句中文日志
/// 这样完全不是 ssh 命令的输入也会「解析成功」。
///
/// 注意：这道校验只挡得住*纯*非主机形状的 token，挡不住「中文夹一个合法 IP」
/// （例如「服务器在 1.2.3.4 端口 2222」）—— `1.2.3.4` 本身形状完全合法。
/// 这种情况由 [parseSshCommand] 末尾的「ssh 命令证据」闸门兜底，不是这个
/// 正则的职责。
///
/// 刻意宽松 —— 这里的职责只是「排除明显不是主机的东西」，不是做地址合法性
/// 校验。真正的校验在表单保存时由 `Server` 那边做，这里拦太严只会让用户的
/// 合法输入被判成「认不出」。普通主机名分支里特意不含 `:`：留着会让
/// `a:b:c` 这种垃圾也通过，而 IPv6 已经由前两支覆盖。
final RegExp _hostLike = RegExp(
  r'^(\[[0-9A-Fa-f:]+\]'            // [2001:db8::1]
  r'|[0-9A-Fa-f]*:[0-9A-Fa-f:]*'    // 裸 IPv6（含 ::1 这种以冒号开头的）
  r'|[A-Za-z0-9][A-Za-z0-9._-]*)$', // 主机名 / IPv4
);

/// 去掉 IPv6 字面量的方括号。`[::1]` → `::1`。
///
/// `ServerDraft.host` 存的是裸地址 —— `labelHostHelper` 里「可带可不带方
/// 括号」说的是用户*输入*时的宽容，不是存储格式；方括号只是 ssh 命令行里
/// 为了和 `user@host:port` 的冒号分隔符区分开而加的语法糖。
String _unbracket(String h) =>
    (h.startsWith('[') && h.endsWith(']')) ? h.substring(1, h.length - 1) : h;

/// 解析一行 `ssh` 命令。认不出返回 null。
///
/// ## 为什么手写而不用 args 包
///
/// `package:args` 要求预先声明全部选项，而 ssh 有几十个选项、还支持 `-o Key=Val`
/// 这种任意扩展。声明不全就会在遇到未知选项时抛异常 —— 而我们要的恰恰是「不认识
/// 的选项安静跳过，把认识的挑出来」。
///
/// ## 为什么开头的 `ssh` 可以省略
///
/// 用户常常只粘参数部分（从文档里复制一半），要求必须以 ssh 开头会让这类输入
/// 直接失败。多认一种形态的成本只有一行。
///
/// ## 已知限制：不处理带引号的参数
///
/// 分词按空白字符切分，不理解 shell 的引号语义。`ssh -i "my key.pem"
/// root@example.com` 这种路径带空格、用引号包起来的写法会被错误地切成
/// `-i` 吃到 `"my`、独立的 `key.pem"` 两个 token —— `identityFilePath` 会
/// 取到错误的值。刻意不修：这个字段唯一的用途是提示用户「这台机器是密钥
/// 认证，去手动选一个」，取值错了不改变这个提示本身，代价可控；而支持引号
/// 需要实现一个小型 shell 分词器，复杂度不值当。
ServerDraft? parseSshCommand(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  final tokens = text.split(RegExp(r'\s+'));
  var i = 0;
  // 开头的 ssh 可有可无。
  var sawSshPrefix = false;
  if (tokens.isNotEmpty && tokens[0] == 'ssh') {
    i = 1;
    sawSshPrefix = true;
  }

  String? host;
  String? user;
  int? port;
  String? jump;
  String? identity;
  final prov = <String, String>{};
  // 下面两个标志和 sawSshPrefix 一起构成「这确实是一条 ssh 命令」的证据——
  // 见函数末尾的闸门。
  var sawFlag = false; // 命中过任何一个被识别的选项（-p / -i / -J / -l …）
  var sawAt = false; // 目标 token 本身带 user@

  for (; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.startsWith('-') && t.length >= 2) {
      final flag = t[1];
      if (!_valueFlags.contains(flag)) continue; // 无值选项，跳过
      sawFlag = true;
      // 紧贴写法 `-p2222` 取后缀，否则吃下一个 token。
      final String? value;
      if (t.length > 2) {
        value = t.substring(2);
      } else if (i + 1 < tokens.length) {
        value = tokens[++i];
      } else {
        value = null;
      }
      if (value == null) continue;
      switch (flag) {
        case 'p':
          // 字段级降级：不是数字就丢掉，不毁掉整次解析。
          final p = int.tryParse(value);
          if (p != null) {
            port = p;
            prov['port'] = 'ssh 命令的 -p';
          }
        case 'i':
          identity = value;
          prov['identityFilePath'] = 'ssh 命令的 -i';
        case 'J':
          jump = value;
          prov['jumpHostAlias'] = 'ssh 命令的 -J';
        case 'l':
          user = value;
          prov['username'] = 'ssh 命令的 -l';
      }
      continue;
    }
    // 第一个非选项 token 就是目标。后面的都是远程命令，不关心。
    if (host != null) continue;
    final at = t.lastIndexOf('@');
    final candidateHost = at > 0 ? t.substring(at + 1) : t;
    if (!_hostLike.hasMatch(candidateHost)) continue;
    if (at > 0) {
      user = t.substring(0, at);
      prov['username'] = 'ssh 命令的 user@host';
      sawAt = true;
    }
    host = _unbracket(candidateHost);
    prov['host'] = 'ssh 命令的目标地址';
  }

  // 光有一个「形状像主机」的 token 不够 —— 它可能只是文本里恰好出现的 IP
  // （日志、中文说明里很常见，例如「服务器在 1.2.3.4 端口 2222」）。还要有
  // 至少一条「这确实是一条 ssh 命令」的证据：ssh 前缀、识别到的选项、或
  // user@host 结构。
  //
  // 没有这道闸时上面那句话会被解析「成功」，而分层编排那一层正是靠本函数
  // 返回 null 才会走到「认不出 → 问用户要不要用 AI」这条分支。
  if (host == null || host.isEmpty) return null;
  if (!sawSshPrefix && !sawFlag && !sawAt) return null;
  return ServerDraft(
    name: host,
    host: host,
    port: port,
    username: user,
    jumpHostAlias: jump,
    identityFilePath: identity,
    provenance: Map.unmodifiable(prov),
  );
}

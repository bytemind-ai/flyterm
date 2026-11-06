// SPDX-License-Identifier: GPL-3.0-or-later
/// 一次剥离的结果。
///
/// 带上**剥掉了什么**而不只是净化后的文本：UI 要据此告诉用户「你粘贴的内容里
/// 有一段私钥，已经被忽略了」。静默丢弃比不丢弃更糟 —— 用户会以为密钥导进去了。
class StripResult {
  /// 净化后的文本。
  final String text;

  /// 剥掉过至少一个 PEM 私钥块。
  final bool strippedPrivateKey;

  /// 剥掉过至少一行疑似密码。
  final bool strippedPassword;

  const StripResult({
    required this.text,
    required this.strippedPrivateKey,
    required this.strippedPassword,
  });

  bool get hasStripped => strippedPrivateKey || strippedPassword;
}

/// 成对出现的 PEM 私钥块。`[\w ]+` 覆盖 `RSA PRIVATE KEY` / `OPENSSH PRIVATE KEY` /
/// `PGP PRIVATE KEY BLOCK` 等所有变体。
///
/// **只匹配 PRIVATE**，不碰 `BEGIN CERTIFICATE` / `BEGIN PUBLIC KEY` —— 公钥和
/// 证书不是秘密，剥掉它们没有收益，反而可能丢掉有用的上下文。
final RegExp _pemPrivateBlock = RegExp(
  r'-----BEGIN [\w ]*PRIVATE[\w ]*-----[\s\S]*?-----END [\w ]*PRIVATE[\w ]*-----',
  multiLine: true,
);

/// 孤立的 BEGIN（用户只粘贴了半截私钥）。
///
/// **必须在成对匹配之后才跑**：先剥掉所有成对的块，剩下的 BEGIN 就一定是
/// 没有结尾的那种，此时从它一直剥到文本末尾。
///
/// 这是刻意的过度剥离 —— 半截私钥仍然是私钥材料，而它后面的内容既然跟
/// 密钥混在一起，多剥掉也比把密钥发出去强。
final RegExp _pemDanglingBegin = RegExp(
  r'-----BEGIN [\w ]*PRIVATE[\w ]*-----[\s\S]*$',
);

/// 这一行看起来是在给出密码吗？
///
/// 判据有意保守（宁可多剥一行）：下游是「把文本发给第三方 LLM」，漏掉一行
/// 密码的代价远高于多剥一行注释。
bool _looksLikePassword(String line) {
  // `PasswordAuthentication yes` 是 ssh config 的**开关项**，不是密码 ——
  // 但它自己含 password 这个词，会命中下面的关键词判断。
  //
  // 这里把它整段挖掉再判断剩下的部分，而不是「含这个子串就整行放行」：
  // 后者会让 `PasswordAuthentication yes  # 默认密码: hunter2` 这种一行里
  // 既有开关、又夹带真密码的写法完全逃过剥离。挖掉之后，前半截消失、后半
  // 截「# 默认密码: hunter2」照常被识别出来。
  final rest = line.replaceAll(
    RegExp(r'passwordauthentication\s*\w*', caseSensitive: false),
    '',
  );
  // 关键词可以带任意前缀（DB_PASSWORD / MYSQL_PWD / export PASSWORD），
  // 所以不锚定行首 —— 那正是旧实现漏掉它们的原因。
  if (!RegExp(r'(password|passwd|pwd|密码)', caseSensitive: false)
      .hasMatch(rest)) {
    return false;
  }
  // 光含关键词不够：「请把密码发我」这种句子不该被剥。要求关键词之后出现
  // 赋值符号或空格，且后面有非空内容 —— 那才像是真的在给出一个值。
  return RegExp(r'(password|passwd|pwd|密码)[^\n]*[:：=][ \t]*\S',
              caseSensitive: false)
          .hasMatch(rest) ||
      RegExp(r'(password|passwd|pwd|密码)[ \t]+\S', caseSensitive: false)
          .hasMatch(rest);
}

/// 把可能含密的内容从文本里剥掉。
///
/// **必须在任何解析之前调用**，尤其在把文本交给 LLM 之前 —— 第 2 层会把内容
/// 发给第三方服务，私钥一旦出去就收不回来了。
///
/// 剥离而不是拒绝：用户粘一整段 ssh config 里夹着私钥是很常见的，直接拒绝会
/// 让他无所适从。剥掉之后其余字段照常可用，再通过 [StripResult] 告诉他发生
/// 了什么。
///
/// ## 已知限制（刻意不做，而非遗漏）
///
/// - **跨行密码**：`password:` 和它的值分写两行（值在下一行）时不会被识别——
///   判断是逐行进行的，没有「这行是键、下一行是值」的跨行语义。改成跨行识别
///   会显著扩大误剥面（下一行可能是任意内容），而这种写法在 ssh config /
///   环境变量导出里并不常见，收益不抵风险。
/// - **PEM 标签大小写**：只认标准大写的 `BEGIN`/`PRIVATE`/`END`。PEM 格式本身
///   就规定全大写，小写变体不是合法 PEM，不在剥离范围内。
///
/// 这个函数的目标是堵住「粘贴 ssh config / 命令行时常见的私钥和密码写法」，
/// 不是做一个通用的密钥 / 密文扫描器（例如识别 AWS access key、JWT 之类任意
/// 格式的凭证）——那是另一个量级的问题，不属于这道闸要解决的范围。
StripResult stripSensitive(String input) {
  var text = input;

  // 先剥成对的块，再处理孤立的 BEGIN —— 顺序不能反：如果先跑孤立检测，
  // 一个正常、完整的块里的 BEGIN 也会被孤立正则捕获，从而吞掉它之后的
  // 全部文本（包括本该保留的其余字段）。
  final hadPairedKey = _pemPrivateBlock.hasMatch(text);
  if (hadPairedKey) text = text.replaceAll(_pemPrivateBlock, '');
  final hadDanglingKey = _pemDanglingBegin.hasMatch(text);
  if (hadDanglingKey) text = text.replaceAll(_pemDanglingBegin, '');
  final hadKey = hadPairedKey || hadDanglingKey;

  final lines = text.split('\n');
  var hadPwd = false;
  final keptLines = <String>[];
  for (final line in lines) {
    if (_looksLikePassword(line)) {
      hadPwd = true;
      continue;
    }
    keptLines.add(line);
  }
  if (hadPwd) text = keptLines.join('\n');

  return StripResult(
    text: text,
    strippedPrivateKey: hadKey,
    strippedPassword: hadPwd,
  );
}

// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

/// 剥离 ANSI 控制序列。`systemctl status` 默认带色，不剥离会把大量
/// 转义字节送进模型、白烧 token 且干扰理解。
///
/// **比 `terminal_screen.dart:_stripAnsi` 更宽**，是刻意的：那份只需要处理
/// 自己渲染时关心的序列，剩下的交给 xterm；这里没有下游，漏掉的字节会原样
/// 进模型的请求体。实测 UI 那份会漏 `\x1B[?25l`（隐藏光标）、`\x1B[3L`
/// （插入行）、`\x1B[?1049h`（切 alt buffer）、以 ST 而非 BEL 结尾的 OSC ——
/// 而这些在 `systemctl status` / `docker logs` 的输出里很常见。
///
/// 四条分别覆盖：CSI（含私有参数与中间字节）、OSC/DCS/PM/APC（BEL 或 ST
/// 终止）、字符集选择、以及若干双字节 ESC 序列。
String stripAnsi(String s) => s
    .replaceAll(RegExp(r'\x1B\[[0-9;?<>=]*[ -/]*[@-~]'), '')
    .replaceAll(RegExp(r'\x1B[\]P^_][^\x07\x1B]*(\x07|\x1B\\)'), '')
    .replaceAll(RegExp(r'\x1B[()][AB012]'), '')
    .replaceAll(RegExp(r'\x1B[=>NOc]'), '');

/// 把命令输出字节解码成给模型看的文本。
///
/// 二进制内容（`cat` 了个 ELF）不能塞进模型 —— 既烧 token 又毫无信息。
/// 判据：含 NUL 字节，或 UTF-8 严格解码失败。
String decodeOutput(Uint8List bytes) {
  if (bytes.isEmpty) return '';
  if (bytes.contains(0)) return '[binary output, ${bytes.length} bytes]';
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return '[binary output, ${bytes.length} bytes]';
  }
}

/// 截断方向。
///
/// **只有两种，不是头/尾/中三种。** `middle` 已经保住了尾巴；纯 `tail` 唯一的
/// 优势是尾巴能留满而不是留一半，代价是头部全丢 —— 没有工具值得这个交换。
/// 少一个选项也就少一处「在某个调用点选错方向」的机会，而选错的后果是安静地
/// 丢掉需要的那一半，不报错。
enum TruncateMode {
  /// 留头丢尾。文件内容、结果列表用它 —— 它们从头开始读才有意义。
  head,

  /// 头尾各留一半，挖掉中间。命令输出用它。
  ///
  /// `journalctl` 的错误在尾，`systemctl status` 的 `Active:` 在头，编译失败
  /// 两头都要 —— 没有可靠判据能事先知道哪一端重要，挖中间是唯一不需要猜的
  /// 做法。猜错的代价与不挖中间时完全一样：丢掉需要的那半，白跑一轮。
  middle,
}

/// 按 UTF-8 字节数截断，不切断多字节字符。
///
/// 标记是给模型看的 —— 它读到 "narrow" 会自己缩小范围重查，而不是以为输出
/// 就这么多。丢哪一段由 [mode] 决定，见 [TruncateMode]。
String truncateForModel(String s, int maxBytes,
    {TruncateMode mode = TruncateMode.head}) {
  final bytes = utf8.encode(s);
  if (bytes.length <= maxBytes) return s;
  return switch (mode) {
    TruncateMode.head => _truncateHead(bytes, maxBytes),
    TruncateMode.middle => _truncateMiddle(bytes, maxBytes),
  };
}

/// **既有行为，一个字节都没改。** 包括「标记不计入 `maxBytes`」这一点 ——
/// 结果因此会比 `maxBytes` 长出一个标记。这是既有的小失准，改它要动一批既有
/// 测试的期望值，与本次要解决的问题无关。middle 那边必须计入（不计就必然
/// 超，因为两半都按预算切满），两者的不对称是有意的。
String _truncateHead(List<int> bytes, int maxBytes) {
  var cut = maxBytes;
  // 回退到字符边界：UTF-8 continuation byte 是 10xxxxxx
  while (cut > 0 && (bytes[cut] & 0xC0) == 0x80) {
    cut--;
  }
  final head = utf8.decode(bytes.sublist(0, cut), allowMalformed: true);
  final omitted = bytes.length - cut;
  return '$head\n[truncated, $omitted bytes omitted — narrow your query]';
}

String _middleMarker(int omitted) =>
    '\n[truncated: $omitted bytes omitted from the middle — '
    'narrow the query if you need this part]\n';

String _truncateMiddle(List<int> bytes, int maxBytes) {
  // 标记的长度取决于 omitted 的位数，而 omitted 又取决于标记占掉多少预算 ——
  // 循环依赖。用 omitted 的**上界**（全文字节数 + 1，见下面 headTrimmed 那行
  // 为什么要 +1）先算出最长可能的标记来预留，实际标记只会更短或一样长，
  // 所以结果必然不超预算。一次算完，不用迭代。
  final reserve = utf8.encode(_middleMarker(bytes.length + 1)).length;
  final budget = maxBytes - reserve;
  // 预算连标记都装不下。真实调用（8 KiB）永远走不到这里，但这个函数是公开
  // 的，不能对小 maxBytes 崩掉。
  if (budget <= 0) return _truncateHead(bytes, maxBytes);

  final headBudget = budget ~/ 2;
  final headCut = _headCut(bytes, headBudget);
  final tailStart = _tailStart(bytes, bytes.length - (budget - headBudget));

  final head = utf8.decode(bytes.sublist(0, headCut), allowMalformed: true);
  // headCut 落在换行之后，head 因此以 `\n` 结尾，而标记自带前导 `\n` —— 不去
  // 掉就会多出一个空行。只删不加，预算不受影响 —— 但这一删多吃掉了 1 个字节
  // 的 `\n`，它不在 [headCut, tailStart) 这个区间里，`tailStart - headCut`
  // 因此少算了它。omitted 必须把这 1 个字节补回来，否则报给模型的丢失量比
  // 实际少 1。（这也是上面 reserve 用 `bytes.length + 1` 而不是
  // `bytes.length` 当上界的原因：修正后 omitted 最多能到 `bytes.length`，
  // 用 +1 多留一点余量，防止未来改动预算分配方式时又在这里踩一次。）
  final trimmedNewline = head.endsWith('\n');
  final headTrimmed =
      trimmedNewline ? head.substring(0, head.length - 1) : head;
  final omitted = (tailStart - headCut) + (trimmedNewline ? 1 : 0);
  final tail = utf8.decode(bytes.sublist(tailStart), allowMalformed: true);
  return '$headTrimmed${_middleMarker(omitted)}$tail';
}

/// 从 [limit] 往**前**退到一个完整行的末尾（某个 `\n` 的后一位）。
///
/// 整段没有换行时（一行超长的 JSON）退到最近的 UTF-8 字符边界。
int _headCut(List<int> bytes, int limit) {
  for (var i = limit; i > 0; i--) {
    if (bytes[i - 1] == 0x0A) return i;
  }
  var cut = limit;
  while (cut > 0 && (bytes[cut] & 0xC0) == 0x80) {
    cut--;
  }
  return cut;
}

/// 从 [from] 往**后**进到一个完整行的开头（某个 `\n` 的后一位）。
///
/// 往后而不是往前：往前会把尾段撑出预算。找不到换行就进到最近的字符边界。
int _tailStart(List<int> bytes, int from) {
  // 下界只夹一次，for 与 fallback 共用同一个夹过的值 —— 今天 `from` 恒 > 0
  // （budget~/2 的分配方式决定的，有证明），fallback 摸不到这条线，但两处
  // 标准必须一致：将来预算分配方式一变，fallback 里裸的 `from` 就可能带着
  // 负数直接冲进 `sublist` 炸 RangeError。
  final clamped = from < 1 ? 1 : from;
  for (var i = clamped; i < bytes.length; i++) {
    if (bytes[i - 1] == 0x0A) return i;
  }
  var start = clamped;
  while (start < bytes.length && (bytes[start] & 0xC0) == 0x80) {
    start++;
  }
  return start;
}

class RedactionResult {
  final String text;
  final int count;
  const RedactionResult(this.text, this.count);
}

/// 敏感值脱敏。三种形状分别用一条正则，因为它们在结构上不同类。
///
/// 1. **`key: value` / `key=value`** —— 最常见，键名匹配窄集
/// 2. **连接串 URL** —— `postgres://user:pw@host/db`。**没有键名**，键值正则
///    完全覆盖不到，而 DSN 出现在 env dump、报错信息里的频率极高
/// 3. **HTTP 认证头** —— `Authorization: Bearer <token>`。`curl -v` 的标准
///    输出形状，`authorization` 与 `bearer` 都不在键名词表里
///
/// 键名词表取窄集：裸 `key` 会误伤 `keyboard` / `pubkey` /
/// `ssh_key_path`，因此收窄为 `api_key` / `private_key` / `secret_key` /
/// `access_key`。`pass` 用 `(?<![a-z])...(?![a-z])` 夹住，否则 `bypass`、
/// `compass`、`tests passed` 全会被误伤；夹住之后 `DB_PASS=` 仍然命中，
/// 因为它前面是 `_` 不是字母。复数形式（`secrets` / `access_tokens`）收，
/// 代价是 `tokens: 42` 这类计数字段也会被脱敏 —— 可接受的 over-redact。
///
/// 正则里的 `\x27` 是单引号。Dart 原始字符串不处理转义，但 **RegExp 引擎
/// 自己会把 `\x27` 解析为十六进制转义** —— 这样写可以避免为了一个单引号
/// 去切换字符串定界符。`permission_rules.dart` 的 deny 清单用的是同一手法。
///
/// 键名与值**两侧都允许引号**，否则 JSON 输出整个漏掉 —— `{"password": "x"}`
/// 的键名是 `"password"`，去掉键名侧的引号支持后实测 count=0、原值原样透出，
/// 而 `kubectl get -o json` / `docker inspect` 的输出全是这个形状。
///
/// 值优先匹配成对引号内的完整内容，其次匹配到 `,` `;` `}` 或空白为止。
/// 前者保住带空格的值（`password: "my secret phrase"` 整体脱敏，否则只脱掉
/// `"my` 而泄露后半段），后者防止单行多字段时越界吃掉相邻字段。
///
/// **已知限制**（都需要解析具体格式才能处理，正则做不到）：
/// - 既无引号又含空格的值只脱掉第一个词（`password: my secret phrase`）
/// - YAML 块标量（`password: |` 后的缩进行）只脱掉首行
/// - `.pgpass` 的 `host:port:db:user:pw` 无键名，结构上无法匹配
///   （该文件本身已在 deny 清单里，读它会先弹审批）
/// - `mysql -phunter2` 这类紧贴 flag 的密码属于**命令**而非输出，由 deny
///   清单侧负责
const String _kRedacted = '[redacted by FlyTerm]';

final RegExp _secretKeyValRe = RegExp(
  r'(["\x27]?[\w.\-]*(?<![a-z])(?:pass(?:word|wd|phrase)?|tokens?|secrets?|'
  r'credentials?|dsn|api[_\-]?keys?|private[_\-]?keys?|secret[_\-]?keys?|'
  r'access[_\-]?keys?)(?![a-z])[\w.\-]*["\x27]?)(\s*[:=]\s*)'
  r'("[^"]*"|\x27[^\x27]*\x27|[^\s,;}]+)',
  caseSensitive: false,
);

/// 用户名部分用 `*` 而非 `+`：`redis://:pw@host` 是合法且常见的写法。
final RegExp _secretUrlCredRe =
    RegExp(r'([a-z][\w+.\-]*://[^:/\s@]*:)([^@\s]+)(@)', caseSensitive: false);

final RegExp _secretAuthHeaderRe = RegExp(
  r'((?:authorization|proxy-authorization)\s*:\s*'
  r'(?:bearer|basic|token|digest)\s+)(\S+)',
  caseSensitive: false,
);

RedactionResult redactSecrets(String s) {
  var count = 0;
  var out = s.replaceAllMapped(_secretKeyValRe, (m) {
    count++;
    return '${m.group(1)}${m.group(2)}$_kRedacted';
  });
  out = out.replaceAllMapped(_secretUrlCredRe, (m) {
    count++;
    return '${m.group(1)}$_kRedacted${m.group(3)}';
  });
  out = out.replaceAllMapped(_secretAuthHeaderRe, (m) {
    count++;
    return '${m.group(1)}$_kRedacted';
  });
  return RedactionResult(out, count);
}

/// 让模型知道有东西被挡了 —— 否则它会把 `[redacted]` 当成真实值去诊断。
String appendRedactionNotice(String s, int count) =>
    count == 0 ? s : '$s\n[FlyTerm: $count value(s) redacted]';

/// 折叠一段相同行至少要重复几次。
///
/// 实测（`flyterm-server.log`）≥2 / ≥3 / ≥4 的收益是 52% / 51% / 50% ——
/// 差一个百分点，那就选保守的。重复两次在视觉上算不上噪声，而短行
/// （`---`）折叠两次是净亏：标记比省下的还长。
const int kMinRepeatToFold = 3;

/// 去噪后至少要省下这个比例才采用，否则原样返回。
///
/// 系统日志（`dpkg.log` / `bootstrap.log`）每行带不同的时间戳与包名，
/// 没有可折叠的重复，而折叠标记本身占空间 —— 实测体积反而涨 1%。
/// 这条保护让去噪**永不净亏**。
///
/// 取 0.9 而不是 1.0：省 3% 换不回改动输出格式的代价（格式变化、行号
/// 错位）。要么明显有用，要么一个字节都不动。
const double kDenoiseGainThreshold = 0.9;

/// 挤掉工具输出里的水分：行尾空白、相邻重复行、连续空行。
///
/// **纯函数。** 只在 `bash` / `check_job` 这类输出上用 —— `read_file` 绝对
/// 不能用，见 `command_runner.dart` 里那段说明。
///
/// 折叠标记借用 rsyslog 的原话 `last message repeated N times`：模型在训练
/// 数据里见过无数次，不必解释。自造的措辞（`[8x]`）要它现场推断。
String denoiseOutput(String raw) {
  if (raw.isEmpty) return raw;

  final lines = raw.split('\n');
  final out = <String>[];

  // 相邻重复计数。只认**完全相同**：trim 后比较会把缩进不同的行误判成
  // 相同，模糊匹配会把时间戳不同的两条同类日志合并 —— 那是两件事。
  var i = 0;
  while (i < lines.length) {
    final line = lines[i].replaceAll(RegExp(r'[ \t]+$'), '');
    var run = 1;
    while (i + run < lines.length &&
        lines[i + run].replaceAll(RegExp(r'[ \t]+$'), '') == line) {
      run++;
    }
    // 空行不走 rsyslog 折叠标记：连续空行本来就该无条件压成一个，套用
    // 「repeated N times」marker 反而更占地方（`''` 折叠 4 次也要insert
    // 30+ 字节的标记），且空行不是「重复的一条消息」，读者不需要被告知
    // 「重复了 N 次」。留给下面的空行压缩统一处理。
    if (run >= kMinRepeatToFold && line.isNotEmpty) {
      out.add(line);
      // N 是**额外**次数：首行已经在上面输出过一次了。与 rsyslog 一致。
      out.add('[last message repeated ${run - 1} times]');
    } else {
      for (var k = 0; k < run; k++) {
        out.add(line);
      }
    }
    i += run;
  }

  // 连续空行（含刚被跳过折叠、原样搬过来的整段空行）压成一个。
  final squeezed = <String>[];
  for (final l in out) {
    if (l.isEmpty && squeezed.isNotEmpty && squeezed.last.isEmpty) continue;
    squeezed.add(l);
  }

  final result = squeezed.join('\n');
  return result.length < raw.length * kDenoiseGainThreshold ? result : raw;
}

// ───────────────────────── 列感知折叠 ─────────────────────────

/// 少于这么多行的组不折叠 —— 折叠三行省不下什么，反而多一行说明。
const int _kMinRowsToFold = 4;

/// 变化列占比超过这个值就不折叠。
///
/// 判据用「变化了几列」而不是「恒定了几列」：最典型的冗余形态是两列里
/// 恒定一列（`路径 + 常量`，实测 `stat -f` 那 58 行就是），按恒定占比算
/// 恰好 0.5，用任何「大部分列相同」的阈值都会把它挡在外面。
///
/// 只有一列在变时无条件折叠；多列在变才看占比。0.4 以上说明各列都在携带
/// 信息 —— `df -h` 那种 5 列全变的输出会被挡住，那里的噪音是语义性的
/// （tmpfs 与磁盘告警无关），不是结构性的，机械手段吃不掉也不该硬吃。
const double _kVaryColRatio = 0.4;

/// 变化值最多列出这么多个，其余折成 `(+N more)`。
const int _kMaxVaryingValuesShown = 8;

/// 折叠「结构相同、只有少数列不同」的连续行组。
///
/// ## 为什么 [denoiseOutput] 不够
///
/// 那个只认**整行完全相同**的相邻行（rsyslog 风格）。而真实的输出冗余几乎
/// 都是「结构相同、一列不同」—— 它一行都折不掉：
///
/// ```
/// /root/.z             9256788*4096
/// /root/.ssh           9256788*4096      ← 58 行，没有两行相同
/// /usr/bin/nvidia-smi  9256788*4096
/// ```
///
/// 这 58 行的信息量是 1 行加一个路径列表。实测现场里 `stat -f` 的 58 行、
/// `mount | grep` 的 50+ 行 nvidia 绑定挂载都是这个形态，两者都完整进了
/// 模型上下文。
///
/// ## 只折叠**连续**行组
///
/// 非连续的同构行（`df -h` 里夹在 tmpfs 中间的三行 overlay）不处理：跨行
/// 匹配要么需要全局聚类（代价高、易误伤），要么会把语义上分属不同段落的
/// 行合并。连续分组已经覆盖了实测现场里最严重的两处。
///
/// 空行是语义分段，不跨空行分组。
String foldColumnar(String raw) {
  if (raw.isEmpty) return raw;
  final lines = raw.split('\n');
  if (lines.length < _kMinRowsToFold) return raw;

  final out = <String>[];
  var i = 0;
  while (i < lines.length) {
    if (lines[i].trim().isEmpty) {
      out.add(lines[i]);
      i++;
      continue;
    }
    // 收集「列数相同」的连续非空行。
    final cols = _splitCols(lines[i]);
    var j = i + 1;
    while (j < lines.length &&
        lines[j].trim().isNotEmpty &&
        _splitCols(lines[j]).length == cols.length) {
      j++;
    }
    final group = lines.sublist(i, j);
    final folded = _foldGroup(group, cols.length);
    out.addAll(folded);
    i = j;
  }
  return out.join('\n');
}

List<String> _splitCols(String line) =>
    line.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();

/// 折叠一组列数相同的行。不满足条件时原样返回。
List<String> _foldGroup(List<String> group, int colCount) {
  if (group.length < _kMinRowsToFold || colCount < 2) return group;

  final rows = group.map(_splitCols).toList();
  // 哪些列在整组里恒定。
  final constCols = <int>[];
  final varyCols = <int>[];
  for (var c = 0; c < colCount; c++) {
    final first = rows.first[c];
    if (rows.every((r) => r[c] == first)) {
      constCols.add(c);
    } else {
      varyCols.add(c);
    }
  }

  // 全列恒定 = 整行重复，那是 denoiseOutput 的活，这里不插手。
  if (varyCols.isEmpty) return group;
  if (varyCols.length > 1 && varyCols.length / colCount > _kVaryColRatio) {
    return group;
  }

  // 用第一行作结构样本，变化列替换成占位符。
  final sample = [
    for (var c = 0; c < colCount; c++)
      varyCols.contains(c) ? '<…>' : rows.first[c],
  ].join(' ');

  final out = <String>[sample];
  for (final c in varyCols) {
    final values = rows.map((r) => r[c]).toList();
    final shown = values.take(_kMaxVaryingValuesShown).join(', ');
    final rest = values.length - _kMaxVaryingValuesShown;
    out.add('  [${group.length} rows, field ${c + 1}] $shown'
        '${rest > 0 ? ', … (+$rest more)' : ''}');
  }
  return out;
}

/// 折叠压缩比超过这个倍数，就认为输出高度同质。
const double _kHomogeneousRatio = 2.0;

/// 按内容的同质度挑截断模式。
///
/// `TruncateMode.middle` 的前提是「两端比中间重要」—— 对一份命令输出，
/// 开头是表头、结尾是结论，中间是明细，这个假设通常成立。
///
/// 但当内容高度同质时它就失效了：`mount | grep` 那 50 行 nvidia 绑定挂载，
/// 从中间挖掉一块，两端留下的还是同样的噪音。实测现场里那次截断提示
/// 「850 bytes omitted from the middle」，而保留下来的 7 KB 没有一行提供了
/// 新信息。
///
/// 判据用**折叠后的压缩比**：能被 [foldColumnar] 压掉一半以上，说明这些行
/// 彼此结构相同、信息高度重复。这时 `head` 更好 —— 保留开头的结构样本和
/// 折叠摘要，而不是在噪音中间挖个洞。
TruncateMode pickTruncateMode({
  required String original,
  required String folded,
  required TruncateMode requested,
}) {
  if (requested == TruncateMode.head) return requested;
  if (folded.isEmpty) return requested;
  final ratio = original.length / folded.length;
  return ratio >= _kHomogeneousRatio ? TruncateMode.head : requested;
}

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/output_sanitizer.dart';

/// 「应用日志形状」：照 `flyterm-server.log` 构造 —— 时间戳前缀 + 一段在同一秒内
/// 高频重试打出的相同错误行（同一时刻，消息与时间戳都不变）+ 少量不重复的
/// 状态行。40 行，两段可折叠的重复（18 次 + 12 次）。
final String _realisticAppLog = '${[
  '2026-09-14T03:11:58Z INFO flyterm-server starting on 0.0.0.0:4433',
  '2026-09-14T03:11:58Z INFO QUIC transport initialized, cert=self-signed',
  '2026-09-14T03:11:59Z INFO waiting for client handshake',
  '2026-09-14T03:11:59Z INFO listening on udp/4433',
  ...List.filled(18,
      '2026-09-14T03:12:03Z ERROR handshake failed: peer closed connection, retrying in 200ms'),
  '2026-09-14T03:12:07Z INFO client connected from 100.64.0.3:51422',
  '2026-09-14T03:12:07Z INFO session established, mux streams=4',
  ...List.filled(
      12, '2026-09-14T03:12:40Z WARN keepalive missed, peer may be unreachable'),
  '2026-09-14T03:13:00Z INFO client disconnected, reason=idle timeout',
  '2026-09-14T03:13:00Z INFO session closed, bytes_in=48213 bytes_out=91022',
  '2026-09-14T03:13:01Z INFO waiting for next client',
  '2026-09-14T03:13:30Z INFO shutdown signal received, draining sessions',
].join('\n')}\n';

/// 「系统日志形状」：照 `dpkg.log` 构造 —— 每行都带不同的时间戳与包名，没有
/// 两条相邻行完全相同，因此没有可折叠的重复。40 行。
final String _realisticSystemLog = '${List.generate(40, (i) {
  final minute = 10 + i ~/ 60;
  final second = i % 60;
  final ts = '2026-09-14 03:${minute.toString().padLeft(2, '0')}:'
      '${second.toString().padLeft(2, '0')}';
  return '$ts status half-installed pkg-$i:amd64 1.0.$i-1ubuntu$i';
}).join('\n')}\n';

void main() {
  group('stripAnsi', () {
    test('剥离 SGR 颜色', () {
      expect(stripAnsi('\x1B[32mactive\x1B[0m'), equals('active'));
    });

    test('剥离 OSC 标题序列（BEL 与 ST 两种终止）', () {
      expect(stripAnsi('\x1B]0;title\x07text'), equals('text'));
      expect(stripAnsi('\x1B]0;title\x1B\\text'), equals('text'));
    });

    test('剥离 UI 层那份会漏的序列', () {
      // 这几种在 systemctl status / docker logs 的输出里很常见，
      // terminal_screen 的正则漏掉它们没关系（xterm 会吃），但这里没有下游。
      expect(stripAnsi('\x1B[?25lhidden\x1B[?25h'), equals('hidden'));
      expect(stripAnsi('\x1B[3Lrow'), equals('row'));
      expect(stripAnsi('\x1B[?1049htext'), equals('text'));
      expect(stripAnsi('\x1B[2J\x1B[Hcleared'), equals('cleared'));
    });

    test('普通文本原样', () {
      expect(stripAnsi('hello world'), equals('hello world'));
    });
  });

  group('decodeOutput', () {
    test('合法 UTF-8 正常解码', () {
      final bytes = Uint8List.fromList(utf8.encode('你好 nginx'));
      expect(decodeOutput(bytes), equals('你好 nginx'));
    });

    test('含 NUL 字节判为二进制', () {
      final bytes = Uint8List.fromList([0x7f, 0x45, 0x4c, 0x46, 0x00, 0x01]);
      expect(decodeOutput(bytes), equals('[binary output, 6 bytes]'));
    });

    test('非法 UTF-8 判为二进制', () {
      final bytes = Uint8List.fromList([0xff, 0xfe, 0xfd]);
      expect(decodeOutput(bytes), equals('[binary output, 3 bytes]'));
    });

    test('空输入返回空串', () {
      expect(decodeOutput(Uint8List(0)), equals(''));
    });
  });

  group('truncateForModel — head 模式（既有行为，回归锁）', () {
    test('短文本原样返回', () {
      expect(truncateForModel('short', 100), equals('short'));
    });

    test('超长文本被截断并带提示', () {
      final long = 'x' * 200;
      final out = truncateForModel(long, 100);
      expect(out.length, lessThan(200));
      expect(out, contains('[truncated'));
      expect(out, contains('narrow your query'));
      expect(out, startsWith('x' * 100));
    });

    test('截断不会切断多字节字符', () {
      final long = '你' * 100; // 每个 3 字节
      final out = truncateForModel(long, 50);
      expect(() => utf8.encode(out), returnsNormally);
      expect(out, contains('[truncated'));
    });

    test('显式传 head 与不传等价 —— 既有调用方一个字节都不该受影响', () {
      final long = 'x' * 200;
      expect(truncateForModel(long, 100),
          equals(truncateForModel(long, 100, mode: TruncateMode.head)));
    });
  });

  group('truncateForModel — middle 模式', () {
    /// 造一段有行结构的长文本。每行自带序号，方便断言头尾各留了哪些行、
    /// 以及切口有没有留下半行。
    String linesOf(int n) =>
        List.generate(n, (i) => 'line-$i ${'x' * 40}').join('\n');

    test('总字节数不超过 maxBytes —— 标记本身也要算进预算', () {
      final out =
          truncateForModel(linesOf(500), 2000, mode: TruncateMode.middle);
      expect(utf8.encode(out).length, lessThanOrEqualTo(2000));
    });

    test('头尾都保留，标记落在中间', () {
      final out =
          truncateForModel(linesOf(500), 2000, mode: TruncateMode.middle);
      expect(out, startsWith('line-0 '));
      expect(out, contains('line-499'));
      expect(out, contains('omitted from the middle'));
      final markerAt = out.indexOf('[truncated:');
      expect(markerAt, greaterThan(0), reason: '标记不该在开头');
      expect(markerAt, lessThan(out.length - 20), reason: '标记不该在末尾');
    });

    test('两个切口都不切断多字节字符', () {
      final cjk =
          List.generate(300, (i) => '第$i行：${'中' * 20}').join('\n');
      final out = truncateForModel(cjk, 2000, mode: TruncateMode.middle);
      expect(out, isNot(contains('�')));
    });

    // 上面那条样本带换行：_headCut/_tailStart 一定先走「退到最近换行」的
    // 分支提前 return，字符边界那个 while 回退循环是死代码，删掉它这条
    // 测试也全绿（变异测试验证过）。这里换成完全不带换行的纯 CJK，
    // 逼两处都真正走到字符边界回退。
    //
    // 800 个 '中'（每个 3 字节）= 2400 字节，maxBytes=600：
    //   reserve=92 → budget=508 → headBudget=254、tailFrom=2146。
    //   254 % 3 == 2，2146 % 3 == 1 —— 两个切口都恰好落在续字节
    //   （continuation byte，10xxxxxx）中间，不是字符起始字节，
    //   两处 while 循环都必须真正执行（不是查一次条件就退出）才能不出乱码。
    //   数字是用脚本枚举 headBudget/tailFrom 模 3 的结果反推出来的，
    //   不是拍脑袋——改样本或 maxBytes 前请重新算一遍，不要蒙。
    test('两个切口都不切断多字节字符——纯 CJK 无换行，真正走到字符边界回退', () {
      final out =
          truncateForModel('中' * 800, 600, mode: TruncateMode.middle);
      expect(out, isNot(contains('�')));
    });

    test('两个切口都落在行边界 —— 不留半行', () {
      final out =
          truncateForModel(linesOf(500), 2000, mode: TruncateMode.middle);
      final parts = out.split(RegExp(r'\n\[truncated:[^\]]*\]\n'));
      expect(parts, hasLength(2), reason: '标记应恰好把输出分成头尾两段');
      final lastOfHead = parts[0].split('\n').last;
      final firstOfTail = parts[1].split('\n').first;
      for (final line in [lastOfHead, firstOfTail]) {
        expect(line, matches(RegExp(r'^line-\d+ x{40}$')),
            reason: '切口留下了半行：$line');
      }
    });

    test('整段没有换行时退化到字符边界，不炸也不出乱码', () {
      // 用 502 而不是「更整齐」的 500：500 是数字巧合，不是真覆盖。
      // 2000 个 '中'（每个 3 字节）= 6000 字节，maxBytes=500 时
      // reserve=92 → budget=408 → headBudget=204、tailFrom=5796，
      // 204 和 5796 都恰好是 3 的倍数——两个切口天然落在字符起始字节上，
      // 字符边界的 while 回退循环一次都不会执行，删掉它们这条测试照样绿
      // （变异测试验证过，删完两处 while 依然全绿）。
      // 换成 502：budget=410 → headBudget=205（% 3 == 1）、
      // tailFrom=5795（% 3 == 2），两个切口都落在续字节中间，
      // while 循环这次是真被执行到的。数字来自脚本枚举，不是心算，
      // 改动前务必重新用脚本核一遍 headBudget/tailFrom 模 3 的值。
      final out = truncateForModel('中' * 2000, 502, mode: TruncateMode.middle);
      expect(utf8.encode(out).length, lessThanOrEqualTo(502));
      expect(out, isNot(contains('�')));
    });

    // headTrimmed 那步会多吃掉 head 末尾一个 `\n`（见 _truncateMiddle 里的
    // 注释），这个字节不在 [headCut, tailStart) 区间里，若不补回来，标记里
    // 报的 omitted 就会比实际丢的少 1。
    //
    // 构造：'H'*500 + '\n' + 'M'*998（无换行）+ '\n' + 'T'*500，共 2000
    // 字节。maxBytes=1094 时 reserve=92、budget=1002、headBudget=501、
    // tailBudget=501 —— 精确让 headCut 落在第一个 '\n' 之后（=501）、
    // tailStart 落在第二个 '\n' 之后（=1500），中间挖空的 raw 差值恰好是
    // 999（3 位数），加上被吃掉的那 1 个 '\n' 之后变成 1000（4 位数）——
    // 特意选在十的幂次边界上：不加这 1，标记会印错误的 999；加错方向或漏加
    // 都会在这条断言上现形。数字来自脚本枚举 headCut/tailStart，不是心算。
    test('omitted 计入被吃掉的换行——恰好跨过 999→1000 这个位数边界', () {
      final s = '${'H' * 500}\n${'M' * 998}\n${'T' * 500}';
      final out = truncateForModel(s, 1094, mode: TruncateMode.middle);
      expect(out, contains('1000 bytes omitted'),
          reason: '漏加这 1 的话会印成 999，而实际丢的是 1000 字节');
      // 补这 1 之后总字节数仍不超预算。
      //
      // **这一条钉不住 `reserve` 那行的 `+ 1`**，别指望它：`headCut == 0`
      // 时不会 trim 换行，`headCut >= 1` 时 `tailStart - headCut <= n - 1`
      // —— 两种情况下 omitted 都 <= n，所以 `bytes.length` 本身就已经是合法
      // 上界，`+ 1` 纯属余量、在行为上不可观测，任何测试都拦不住删掉它。
      // 写在这里是为了让下一个人别再花时间找「那条测试在哪」。
      expect(utf8.encode(out).length, lessThanOrEqualTo(1094));
    });

    test('未超限时原样返回，不插标记', () {
      expect(truncateForModel('short', 100, mode: TruncateMode.middle),
          equals('short'));
    });

    test('maxBytes 小到装不下标记时退回 head 模式', () {
      final out = truncateForModel(linesOf(100), 20, mode: TruncateMode.middle);
      expect(out, contains('[truncated'));
      expect(out, startsWith('line-0'));
    });
  });

  group('redactSecrets', () {
    test('脱敏 key: value 形式', () {
      final r = redactSecrets('DB_PASSWORD: hunter2');
      expect(r.text, contains('[redacted by FlyTerm]'));
      expect(r.text, isNot(contains('hunter2')));
      expect(r.count, equals(1));
    });

    test('脱敏 key=value 形式', () {
      final r = redactSecrets('API_TOKEN=abc123def');
      expect(r.text, isNot(contains('abc123def')));
      expect(r.count, equals(1));
    });

    test('多处命中都被计数', () {
      final r = redactSecrets('password: a\nDB_SECRET: b\n');
      expect(r.count, equals(2));
    });

    test('不误伤无关字段', () {
      final r = redactSecrets('keyboard: qwerty\nmonkey=banana\npubkey: ssh-rsa AAA');
      expect(r.count, equals(0));
      expect(r.text, contains('qwerty'));
    });

    test('api_key / private_key 命中', () {
      expect(redactSecrets('api_key: xyz').count, equals(1));
      expect(redactSecrets('PRIVATE-KEY = xyz').count, equals(1));
    });

    test('JSON 形式的带引号键名 —— kubectl -o json / docker inspect 的形状', () {
      final r = redactSecrets('{"password": "hunter2", "user": "alice"}');
      expect(r.count, equals(1));
      expect(r.text, isNot(contains('hunter2')));
      // 不能越界吃掉相邻字段
      expect(r.text, contains('"user": "alice"'));
    });

    test('带空格的值必须整体脱敏，不能只脱前半段', () {
      final r = redactSecrets('password: "my secret phrase"');
      expect(r.text, isNot(contains('secret phrase')));
      expect(r.count, equals(1));
      final r2 = redactSecrets("db_password = 'p@ss word'");
      // 断言 `p@ss` 而不是 `word` —— 键名 `db_password` 自己就含 "word"
      // （pass+word），拿 'word' 做否定断言永远为假。
      expect(r2.text, isNot(contains('p@ss')));
      expect(r2.text, startsWith('db_password = '));
    });

    test('已知限制：无引号且带空格的值只脱第一个词', () {
      // 不解析具体格式就判不出这类值的边界。配置文件里带空格的密码
      // 通常是有引号的，上一条已覆盖。
      final r = redactSecrets('password: my secret phrase');
      expect(r.count, equals(1));
      expect(r.text, contains('secret phrase'));
    });

    test('连接串 URL —— 没有键名，键值正则完全覆盖不到', () {
      final r = redactSecrets('postgres://appuser:hunter2@db:5432/mydb');
      expect(r.text, isNot(contains('hunter2')));
      expect(r.text, contains('postgres://appuser:'));
      expect(r.text, contains('@db:5432/mydb'));
      expect(r.count, equals(1));
      // 空用户名是合法且常见的写法。密码里的 @ 在 URL 里必须百分号编码，
      // 所以值侧用 [^@\s]+ 是对的。
      final r2 = redactSecrets('redis://:p%40ss@cache:6379');
      expect(r2.count, equals(1));
      expect(r2.text, isNot(contains('p%40ss')));
    });

    test('不误伤没有凭据的 URL', () {
      expect(redactSecrets('https://example.com/path').count, equals(0));
      expect(redactSecrets('url: http://host:8080/api').count, equals(0));
    });

    test('HTTP 认证头 —— curl -v 的标准输出形状', () {
      final r = redactSecrets('Authorization: Bearer sk-abcdef1234567890');
      expect(r.text, isNot(contains('sk-abcdef1234567890')));
      expect(r.text, contains('Authorization: Bearer '));
      expect(redactSecrets('authorization: basic dXNlcjpwYXNz').count, equals(1));
    });

    test('pass 必须夹在非字母之间，否则误伤一大片', () {
      // bypass / compass / passed 里都含 pass
      expect(redactSecrets('bypass: false').count, equals(0));
      expect(redactSecrets('compass: north').count, equals(0));
      expect(redactSecrets('tests passed: 21').count, equals(0));
      expect(redactSecrets('passing: true').count, equals(0));
      // 夹住之后 DB_PASS 仍命中 —— 它前面是 `_` 不是字母
      expect(redactSecrets('DB_PASS=hunter2').count, equals(1));
      expect(redactSecrets('MYSQL_PASSWD=hunter2').count, equals(1));
      expect(redactSecrets('passphrase: correct-horse').count, equals(1));
    });

    test('复数形式也收，代价是计数字段被误伤', () {
      expect(redactSecrets('access_tokens: tok1').count, equals(1));
      expect(redactSecrets('secrets: hunter2').count, equals(1));
      // 可接受的 over-redact：宁可让模型看不到一个数字
      expect(redactSecrets('tokens: 42').count, equals(1));
      // 但 tokenizer 不是复数形式，不该命中
      expect(redactSecrets('tokenizer: bpe').count, equals(0));
    });
  });

  group('appendRedactionNotice', () {
    test('有脱敏时追加说明', () {
      final out = appendRedactionNotice('x', 2);
      expect(out, contains('[FlyTerm: 2 value(s) redacted]'));
    });

    test('无脱敏时原样', () {
      expect(appendRedactionNotice('x', 0), equals('x'));
    });
  });

  group('denoiseOutput', () {
    test('去掉行尾空白', () {
      expect(denoiseOutput('a   \nb\t\n'), 'a\nb\n');
    });

    test('连续空行压成一个', () {
      expect(denoiseOutput('a\n\n\n\n\nb'), 'a\n\nb');
    });

    // 3 是实测定的：≥2/≥3/≥4 的收益是 52%/51%/50%，差一个百分点，
    // 那就选保守的。重复两次算不上噪声，短行折叠两次还是净亏。
    //
    // 用单字符行（'x'）当 fixture 会踩到 kDenoiseGainThreshold：折叠标记
    // `[last message repeated N times]` 固定 30+ 字节，而单字符行折叠 3 次
    // 总共只省 4 字节，净亏保护会正确地拒绝这次折叠，导致断言必然失败——
    // 这不是保护挡过头，是这条 fixture 本身不够真实（真实日志行远长于此）。
    // 换成有代表性长度的行，两条机制才不会互相矛盾。
    test('连续 3 行相同才折叠', () {
      final out = denoiseOutput('connection timed out\n' * 3 + 'y\n');
      expect(out, contains('last message repeated 2 times'));
    });

    test('只有 2 行相同时不折叠', () {
      expect(denoiseOutput('x\nx\ny\n'), 'x\nx\ny\n');
    });

    // N 是**额外**次数，与 rsyslog 语义一致：首行已经打印过一次。
    // 差一个会让模型把「失败 8 次」读成 7 次或 9 次。
    // 同上，行内容换成有实际长度的 token，避免被净亏保护正确拦下。
    test('N 是额外次数：出现 8 次 → repeated 7 times', () {
      final out = denoiseOutput(('ERROR\n' * 8));
      expect(out, contains('repeated 7 times'));
      expect(out, isNot(contains('repeated 8 times')));
    });

    test('首行保留，不是只剩标记', () {
      final out = denoiseOutput('ERR connection refused\n' * 5);
      expect(out, startsWith('ERR connection refused\n'));
    });

    // 全局去重会打乱时序：a,b,a 折叠成 a,b 会让模型以为 a 只发生过一次
    // 且在 b 之前。只认相邻。
    //
    // 同样换成有代表性长度的行：这里有两处独立折叠，标记开销翻倍
    // （60+ 字节），单字符行无论如何都无法在净亏保护下折叠两次。
    test('不相邻的重复行不折叠', () {
      const src = 'ERR connection refused\n'
          'ERR connection refused\n'
          'ERR connection refused\n'
          'y\n'
          'ERR connection refused\n'
          'ERR connection refused\n'
          'ERR connection refused\n';
      final out = denoiseOutput(src);
      expect('last message repeated'.allMatches(out).length, 2,
          reason: '两段各自折叠，不合并');
    });

    test('缩进不同的行不算相同', () {
      const src = 'x\n x\nx\n';
      expect(denoiseOutput(src), src);
    });

    // dpkg.log 那类输出：每行带不同时间戳，没有可折叠的重复，而标记本身
    // 占空间 —— 实测会让体积涨 1%。这条保护让去噪永不净亏。
    test('完全没有可去的噪声时返回原文', () {
      const src = 'aaa\nbbb\nccc\nddd\n';
      expect(denoiseOutput(src), src);
    });

    // 上面那条**测不出阈值**：它的 fixture 去噪后长度完全没变，走的是 `<`
    // 比较的自然结果，阈值改成 0.9 还是 1.0 都照样绿。破坏性验证时发现的。
    //
    // 这条才钉得住：确实省了，但省不到 10%。
    //   raw = 20 行 × 40 字节 + 3 行各 10 个行尾空格 = 830
    //   去噪后 = 800，省 30 / 830 ≈ 3.6% < 10% → 必须返回原文
    // 阈值一旦放宽到 1.0（「只要变小就采用」），这条立刻红。
    test('确实省了但省不到 10% —— 仍然返回原文', () {
      final lines = <String>[];
      for (var i = 0; i < 20; i++) {
        // 39 字符的内容，凑成每行 40 字节（含换行）
        final body = 'line $i'.padRight(39, '.');
        lines.add(i < 3 ? '$body          ' : body); // 前 3 行带行尾空格
      }
      final src = '${lines.join('\n')}\n';
      final out = denoiseOutput(src);

      // 先确认这个 fixture 真的处在「有收益但不够」的区间里 —— 否则这条
      // 测试会因为「压根没收益」而平凡通过，退化成上面那条。
      final wouldSave = src.length - src.replaceAll(RegExp(r'[ ]+\n'), '\n').length;
      expect(wouldSave, greaterThan(0), reason: 'fixture 必须确实有可省的空间');
      expect(wouldSave / src.length, lessThan(0.1), reason: '但要少于 10%');

      expect(out, src, reason: '省不到阈值就必须一个字节都不动');
    });

    test('空输入返回空', () {
      expect(denoiseOutput(''), '');
    });

    test('单行输入原样返回', () {
      expect(denoiseOutput('only one line'), 'only one line');
    });

    test('全是空行', () {
      expect(denoiseOutput('\n\n\n\n\n\n\n\n'), isNotNull);
    });

    // 前面每条规则的单测都只覆盖自己构造的最小样本；三条规则合起来在真实
    // 输入上退化成空操作是可能的，而那些单测仍会全绿——这条测试堵住这个口子。
    test('真实形状的日志：去噪收益 > 40%', () {
      final out = denoiseOutput(_realisticAppLog);
      final ratio = out.length / _realisticAppLog.length;
      expect(ratio, lessThan(0.6),
          reason: '实测 flyterm-server.log 省 56%，这个 fixture 同形状；'
              '若这条红了，说明三条规则在真实输入上退化了');
    });

    test('真实形状的系统日志（每行都不同）：原样返回', () {
      expect(denoiseOutput(_realisticSystemLog), _realisticSystemLog,
          reason: '没有可折叠的重复时必须走净亏保护，一个字节都不动');
    });
  });
}

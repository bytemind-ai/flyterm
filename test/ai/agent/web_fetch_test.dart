import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/ai/agent/web_fetch.dart';

void main() {
  group('isPrivateHost', () {
    test('IPv4 私有段边界', () {
      // 172.16/12 的两侧边界 —— 写错成 172.16–172.32 或 172.0–172.31 都能
      // 通过「随手试一个 172.20」的测试，所以必须锁边界。
      expect(isPrivateHost('172.15.0.1'), isFalse);
      expect(isPrivateHost('172.16.0.1'), isTrue);
      expect(isPrivateHost('172.31.255.254'), isTrue);
      expect(isPrivateHost('172.32.0.1'), isFalse);
    });

    test('其余私有 IPv4 段', () {
      expect(isPrivateHost('10.0.0.1'), isTrue);
      expect(isPrivateHost('192.168.1.1'), isTrue);
      expect(isPrivateHost('127.0.0.1'), isTrue);
      expect(isPrivateHost('169.254.1.1'), isTrue);
    });

    test('公网 IPv4 不算私有', () {
      expect(isPrivateHost('8.8.8.8'), isFalse);
      expect(isPrivateHost('1.1.1.1'), isFalse);
      expect(isPrivateHost('11.0.0.1'), isFalse);
      expect(isPrivateHost('192.169.1.1'), isFalse);
    });

    test('IPv6 回环与 fc00::/7', () {
      expect(isPrivateHost('::1'), isTrue);
      expect(isPrivateHost('fc00::1'), isTrue);
      expect(isPrivateHost('fd12:3456::1'), isTrue);
      expect(isPrivateHost('2001:4860:4860::8888'), isFalse);
    });

    test('无点主机名算私有 —— 内网短名', () {
      expect(isPrivateHost('grafana'), isTrue);
      expect(isPrivateHost('prometheus'), isTrue);
      expect(isPrivateHost('docs.nginx.org'), isFalse);
    });

    test('内网保留后缀', () {
      expect(isPrivateHost('nas.local'), isTrue);
      expect(isPrivateHost('wiki.internal'), isTrue);
      expect(isPrivateHost('git.lan'), isTrue);
    });

    test('大写 host 一样判定', () {
      expect(isPrivateHost('192.168.1.1'), isTrue);
      expect(isPrivateHost('NAS.LOCAL'), isTrue);
      expect(isPrivateHost('GRAFANA'), isTrue);
    });

    test('空 host 不算私有', () {
      expect(isPrivateHost(''), isFalse);
    });
  });

  group('resolveWebTarget', () {
    test('公网 URL 走手机', () {
      expect(resolveWebTarget('https://docs.nginx.org/en/docs/'),
          WebTarget.phone);
    });

    test('私有地址走远端', () {
      expect(resolveWebTarget('http://192.168.1.10:3000/api/health'),
          WebTarget.server);
      expect(resolveWebTarget('http://grafana:3000/'), WebTarget.server);
    });

    test('带端口与路径不影响判定', () {
      expect(resolveWebTarget('http://10.0.0.5:9090/metrics'),
          WebTarget.server);
    });

    test('解析不了的 URL 退回手机档 —— 后续的 scheme 校验会拦掉它', () {
      expect(resolveWebTarget('not a url at all'), WebTarget.phone);
    });
  });

  group('isSupportedCharset', () {
    test('未声明 content-type 或未声明 charset —— 假定 UTF-8', () {
      expect(isSupportedCharset(null), isTrue);
      expect(isSupportedCharset('text/html'), isTrue);
    });

    test('UTF-8 各种写法', () {
      expect(isSupportedCharset('text/html; charset=utf-8'), isTrue);
      expect(isSupportedCharset('text/html; charset=UTF-8'), isTrue);
      expect(isSupportedCharset('text/html;charset="utf8"'), isTrue);
    });

    test('ASCII 与 latin-1 系放行 —— 它们的 ASCII 子集与 UTF-8 重合', () {
      expect(isSupportedCharset('text/plain; charset=us-ascii'), isTrue);
      expect(isSupportedCharset('text/html; charset=iso-8859-1'), isTrue);
      expect(isSupportedCharset('text/html; charset=windows-1252'), isTrue);
    });

    test('GBK / Big5 / Shift_JIS 拒绝 —— Dart 标准库解不了，硬解是整段乱码',
        () {
      expect(isSupportedCharset('text/html; charset=gbk'), isFalse);
      expect(isSupportedCharset('text/html; charset=GB2312'), isFalse);
      expect(isSupportedCharset('text/html; charset=big5'), isFalse);
      expect(isSupportedCharset('text/html; charset=shift_jis'), isFalse);
    });
  });

  group('decodeWebBody', () {
    test('空字节返回空串', () {
      expect(decodeWebBody(Uint8List(0)), '');
    });

    test('含 NUL 判成二进制，不进上下文', () {
      final b = Uint8List.fromList([0x48, 0x00, 0x49]);
      expect(decodeWebBody(b), contains('binary content'));
      expect(decodeWebBody(b), contains('3 bytes'));
    });

    test('正常 UTF-8 原样解出', () {
      expect(decodeWebBody(Uint8List.fromList(utf8.encode('你好 world'))),
          '你好 world');
    });

    test('多字节字符被切断仍返回可读正文', () {
      // **这条锁死截断后的解码行为。** 远端路径用 `head -c` 做字节截断，必然
      // 在多字节字符中间切开；用 output_sanitizer 的 decodeOutput 处理，
      // 严格解码失败会让整段变成 [binary output]，一篇中文文档全丢。
      final full = utf8.encode('配置文件在 /etc/nginx 目录下');
      final cut = Uint8List.fromList(full.sublist(0, full.length - 1));
      final out = decodeWebBody(cut);
      expect(out, contains('配置文件在'));
      expect(out, isNot(contains('binary')));
    });
  });

  group('htmlToText', () {
    test('剥掉 script 与 style 的内容', () {
      const src = '''
<html><head>
<style>.a{color:red}</style>
<script>var x = 1; alert("hi");</script>
</head><body><p>真正的正文</p></body></html>
''';
      final out = htmlToText(src);
      expect(out, contains('真正的正文'));
      expect(out, isNot(contains('color:red')));
      expect(out, isNot(contains('alert')));
    });

    test('剥掉导航与页脚 —— 它们在每一页重复，纯烧 token', () {
      const src = '<html><body>'
          '<nav>首页 文档 下载</nav>'
          '<p>正文段落</p>'
          '<footer>版权所有</footer>'
          '</body></html>';
      final out = htmlToText(src);
      expect(out, contains('正文段落'));
      expect(out, isNot(contains('版权所有')));
      expect(out, isNot(contains('下载')));
    });

    test('嵌套标签展平，文字不丢', () {
      const src = '<body><div><p>前<em>中</em>后</p></div></body>';
      expect(htmlToText(src).replaceAll(RegExp(r'\s+'), ''), '前中后');
    });

    test('连续空行压成一行', () {
      const src = '<body><p>a</p><p></p><p></p><p></p><p>b</p></body>';
      expect(htmlToText(src), isNot(contains('\n\n\n')));
    });

    test('畸形 HTML 不抛异常', () {
      // html 包对畸形输入很宽容，但这条守的是「万一它抛了也不能让工具炸」。
      expect(() => htmlToText('<div><p>unclosed'), returnsNormally);
      expect(() => htmlToText(''), returnsNormally);
    });
  });

  group('curlCommand', () {
    test('curl 与 wget 二选一 —— Alpine 默认只有 wget', () {
      final c = curlCommand('https://example.com/a');
      expect(c, contains('command -v curl'));
      expect(c, contains('curl -sSL'));
      expect(c, contains('wget -qO-'));
    });

    test('带输出上限', () {
      expect(curlCommand('https://example.com/a'), contains('head -c'));
    });

    test('带超时与重定向上限', () {
      final c = curlCommand('https://example.com/a');
      expect(c, contains('--max-time'));
      expect(c, contains('--max-redirs'));
    });

    test('管道接在整个子 shell 上，不是只接在 wget 上', () {
      // `a && b || c | head` 会把 head 只接到 c 上 —— curl 成功那条路
      // 就没有上限了，而那是最常走的一条。括号不是装饰。
      final c = curlCommand('https://example.com/a');
      expect(c.indexOf('('), lessThan(c.indexOf('curl')));
      expect(c.indexOf(')'), lessThan(c.indexOf('head -c')));
    });

    test('URL 被 shellQuote —— 注入拿不到执行', () {
      final c = curlCommand("https://x.com/a'; rm -rf / #");
      // shellQuote 把单引号变成 '\'' 序列，闭合的引号内没有裸的 `;`
      expect(c, isNot(contains("a'; rm")));
      expect(c, contains(r"'\''"));
    });

    test('URL 含空格与命令替换字符仍被引住', () {
      final c = curlCommand(r'https://x.com/$(whoami)/a b');
      expect(c, contains(r"'https://x.com/$(whoami)/a b'"));
    });
  });

  group('looksLikeHtml', () {
    test('doctype 与裸 html 标签都认', () {
      expect(looksLikeHtml('<!DOCTYPE html><html><body>x'), isTrue);
      expect(looksLikeHtml('<html lang="en">'), isTrue);
      expect(looksLikeHtml('  \n <!doctype HTML>'), isTrue);
    });

    test('JSON 与纯文本不认 —— 远端的主场景是内网 API', () {
      expect(looksLikeHtml('{"status":"ok"}'), isFalse);
      expect(looksLikeHtml('# nginx.conf\nworker_processes 4;'), isFalse);
      expect(looksLikeHtml('<?xml version="1.0"?><rss>'), isFalse);
    });
  });
}

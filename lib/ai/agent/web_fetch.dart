// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import 'command_runner.dart' show kMaxOutputBytes;
import 'shell_guard.dart' show shellQuote;

/// 一次 `web_fetch` 从哪里取。
///
/// 不叫 `local`/`remote`：这个文件里 `remote` 已经被 SSH 那一侧的语义占了，
/// 而工具参数暴露给模型的字面量就是 `phone` / `server`，两边同名省一层翻译。
enum WebTarget { phone, server }

/// [host] 是否落在「手机大概率到不了、只能让远端取」的地址段。
///
/// 判定只看 host 的**形态**，不做 DNS 解析 —— 解析要网络往返，而这个函数
/// 在分桶路径上被每条调用同步调用一次。
///
/// 代价是 `wiki.corp.example.com` 这类「公网形态、内网解析」的域名会被判成
/// phone，先在手机端超时一次才回退（见 `_executeWebFetch` 的回退分支）。
/// 这是明确接受的代价，手机端连接超时因此设成 8 秒。
///
/// 同时用于**重定向逐跳校验**：那里防的是「公网页面 302 到
/// 内网地址，借用户的手机去打内网设备」。两处共用一个判据不是巧合 —— 它们
/// 问的是同一个问题「这个地址属于内网吗」，分成两份必然有一天不一致。
bool isPrivateHost(String host) {
  final h = host.trim().toLowerCase();
  if (h.isEmpty) return false;

  // IPv6：`Uri.host` 对 `[::1]` 返回不带方括号的 `::1`。
  if (h.contains(':')) {
    if (h == '::1') return true;
    // fc00::/7 = fc00 … fdff，即首段前两位是 fc 或 fd。
    final first = h.split(':').first;
    if (first.length >= 2) {
      final p = first.substring(0, 2);
      if (p == 'fc' || p == 'fd') return true;
    }
    return false;
  }

  // 内网保留后缀。
  if (h.endsWith('.local') || h.endsWith('.internal') || h.endsWith('.lan')) {
    return true;
  }

  final v4 =
      RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(h);
  if (v4 != null) {
    final a = int.parse(v4.group(1)!);
    final b = int.parse(v4.group(2)!);
    if (a == 10 || a == 127) return true;
    if (a == 192 && b == 168) return true;
    if (a == 169 && b == 254) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }

  // 无点主机名 —— `grafana`、`prometheus` 这类内网短名。放在 IPv4 判定
  // **之后**：`10.0.0.1` 含点，走不到这里；但顺序反了会让不完整的 IP
  // 字面量（`10.0`）落进这一档，判定理由就错了。
  if (!h.contains('.')) return true;

  return false;
}

/// 默认路由。`via` 参数可以覆盖它。
///
/// URL 解析不了时返回 [WebTarget.phone] 而不是抛异常：调用方在这之后还有
/// 一道 scheme 校验会把它拦掉并返回 `isError`，在这里抛只是让同一个错误有
/// 两条路径。
WebTarget resolveWebTarget(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return WebTarget.phone;
  return isPrivateHost(uri.host) ? WebTarget.server : WebTarget.phone;
}

/// 能安全解码的 charset 白名单。
///
/// **用白名单而不是黑名单**：黑名单漏掉一个冷门编码的后果是整段乱码进上下
/// 文（付了 token 拿到零信息，模型还会拿乱码去做诊断），白名单漏掉一个的
/// 后果只是多返一次错、模型换个来源。两边的代价不对称。
///
/// latin-1 系（`iso-8859-1` / `windows-1252`）放行是有意的：它们的 ASCII
/// 子集与 UTF-8 完全重合，而声明它们的站点绝大多数正文是英文；非 ASCII
/// 部分会变成替换字符，那比 GBK 的整段乱码轻得多。
const Set<String> _kDecodableCharsets = {
  'utf-8',
  'utf8',
  'us-ascii',
  'ascii',
  'iso-8859-1',
  'latin-1',
  'latin1',
  'windows-1252',
};

/// content-type 里声明的 charset 是否解得了。
///
/// 未声明时返回 true —— HTTP 的历史默认是 latin-1，但现实里未声明的几乎
/// 都是 UTF-8，而这个判断的下游是 `allowMalformed` 解码，猜错也不会抛。
bool isSupportedCharset(String? contentType) {
  if (contentType == null || contentType.isEmpty) return true;
  final m = RegExp(r'charset\s*=\s*"?([\w.:-]+)', caseSensitive: false)
      .firstMatch(contentType);
  if (m == null) return true;
  return _kDecodableCharsets.contains(m.group(1)!.toLowerCase());
}

/// 把取回的字节解成给模型看的文本。
///
/// **不能用 `output_sanitizer.dart` 的 `decodeOutput`。** 那个函数在 UTF-8
/// 严格解码失败时整段返回 `[binary output, N bytes]`，而远端路径用
/// `head -c` 做字节截断 —— 必然在多字节字符中间切开，于是一篇中文文档会
/// 整段变成一句 `[binary output, 8192 bytes]`，正文全丢。
///
/// NUL 检测保留：那是「这真是二进制」与「这只是被截断了」之间唯一便宜可靠
/// 的判据。
String decodeWebBody(Uint8List bytes) {
  if (bytes.isEmpty) return '';
  if (bytes.contains(0)) return '[binary content, ${bytes.length} bytes]';
  return utf8.decode(bytes, allowMalformed: true);
}

/// 每一页都重复、对排查零信息的容器。
///
/// HTML→文本的质量直接决定 token 消耗（能力缺口评估对这一项标注的主要
/// 风险），而导航条、页脚、侧栏在文档站上往往比正文还长。
const List<String> _kStripSelectors = [
  'script',
  'style',
  'noscript',
  'nav',
  'footer',
  'aside',
  'svg',
  'iframe',
];

/// HTML → 纯文本。
///
/// **否决过「正则剥标签」**：零依赖、几十行，但 `script`/`style` 的内容、
/// 导航菜单、cookie 横幅会一起进上下文。这里用 `html` 包真的解析 DOM，
/// 才能按容器剔除。
String htmlToText(String source) {
  try {
    final doc = html_parser.parse(source);
    for (final sel in _kStripSelectors) {
      for (final e in doc.querySelectorAll(sel)) {
        e.remove();
      }
    }
    final root = doc.body ?? doc.documentElement;
    return _collapseBlanks(root?.text ?? '');
  } catch (_) {
    // 解析失败不能让整次调用炸 —— 退回原文，让模型自己判断。前缀是给
    // 模型的信号：它看到标记就知道这段可能夹着标签，而不是文档写成这样。
    return '[HTML parse failed, raw source follows]\n${_collapseBlanks(source)}';
  }
}

/// 行尾空白去掉，三个以上连续换行压成两个。
///
/// DOM 的 `text` 会把每个块级元素的换行都留下来，一个表格能产出几十行空
/// 行 —— 而空行照样算 token。
String _collapseBlanks(String s) => s
    .split('\n')
    .map((l) => l.trimRight())
    .join('\n')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

/// 远端取数命令。
///
/// ## 为什么是 curl 与 wget 二选一
///
/// **Alpine / BusyBox 默认有 `wget` 没有 `curl`**，而容器化的生产环境里
/// Alpine 占比很高。只发 curl 会在这类机器上直接失败。
///
/// ## 为什么套一层子 shell
///
/// `a && b || c | head` 的优先级会让 `head` 只接在 `c` 上 —— curl 成功
/// 那条路（最常走的一条）就没有输出上限了。括号不是装饰。
///
/// ## URL 必须 shellQuote
///
/// 与 `glob`/`grep` 的 `pattern` 完全同理：这条命令由我们拼，元字符检测
/// 的对象是 `checkTarget` 而不是它，少一个引号模型就能在 URL 里塞
/// `'; rm -rf / #` 拿到任意执行。
///
/// ## `head -c` 与 command_runner 的截断不冗余
///
/// 这里的上限是为了**不把几 MB 经 SSH 传回手机**（省流量与时间）；
/// `kMaxOutputBytes` 在 runner 侧的截断是最后防线。
String curlCommand(String url) {
  final q = shellQuote(url);
  return '( command -v curl >/dev/null 2>&1 '
      '&& curl -sSL --max-time 15 --max-redirs 3 -- $q '
      '|| wget -qO- $q ) | head -c $kMaxOutputBytes';
}

/// 远端拿不到 content-type，靠内容嗅探决定要不要转文本。
///
/// 对内网 JSON API（远端路径的主场景）天然正确：JSON 不以 `<html` 开头。
bool looksLikeHtml(String body) {
  final head = body.trimLeft();
  if (head.length > 512) {
    return _kHtmlHead.hasMatch(head.substring(0, 512));
  }
  return _kHtmlHead.hasMatch(head);
}

final RegExp _kHtmlHead =
    RegExp(r'^\s*(<!doctype\s+html|<html|<\?xml[^>]*\?>\s*<html)',
        caseSensitive: false);

/// 手机端一次取数的结果。
class PhoneFetchResult {
  final Uint8List bytes;

  /// 原始 content-type 头。null = 服务器没给。
  final String? contentType;
  final int statusCode;

  const PhoneFetchResult({
    required this.bytes,
    required this.contentType,
    required this.statusCode,
  });
}

/// 手机端取数的失败分类。
///
/// **分类存在的唯一理由是回退判据**：只有 [connection] 会让调用改走远端。
/// 其余两种在远端也一样会失败，回退只是白烧一次往返。
enum PhoneFetchFailure {
  /// DNS 解析失败、连接超时、拒连、重定向次数超限。
  connection,

  /// 重定向落进私有地址段，被逐跳校验拦下。
  redirectBlocked,

  /// 超过 [DioWebFetcher.kMaxPhoneBytes]。
  tooLarge,
}

class PhoneFetchException implements Exception {
  final PhoneFetchFailure kind;
  final String message;
  const PhoneFetchException(this.kind, this.message);

  @override
  String toString() => 'PhoneFetchException(${kind.name}): $message';
}

/// 手机端取数的注入点。
///
/// 存在的理由是可测性：整个 `web_fetch` 除了这个类之外全是纯函数，所以
/// loop 层的测试用一个 fake 就能跑完路由、回退、审批的全部路径，不需要
/// 真网络也不需要真设备。
abstract class WebFetcher {
  Future<PhoneFetchResult> get(String url);
}

/// `dio` 实现。**这是整个功能里唯一碰网络库的地方。**
class DioWebFetcher implements WebFetcher {
  /// 超过就放弃。
  ///
  /// 上限卡在这里而不是只靠事后截断：8 KiB 是**给模型的**上限，2 MB 是
  /// **给手机流量的**上限。一个 50 MB 的 tarball 截断后只进 8 KiB 上下文，
  /// 但流量已经花掉了。
  static const int kMaxPhoneBytes = 2 * 1024 * 1024;

  /// 与远端 `--max-redirs 3` 对齐。
  static const int kMaxRedirects = 3;

  final Dio _dio;

  /// `followRedirects: false` 是**必须的**，不是偏好：逐跳校验私有地址
  /// 要求我们自己跟跳，而 dio 跟随重定向时不给任何 hook。
  ///
  /// `validateStatus: (_) => true` 让 4xx/5xx 正常返回而不抛 —— 它们要原样
  /// 回给模型（404 的 body 常常就是答案），不是连接层失败，**不该触发回退**。
  DioWebFetcher({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
              followRedirects: false,
              validateStatus: (_) => true,
              responseType: ResponseType.stream,
              headers: const {'Accept-Encoding': 'identity'},
            ));

  @override
  Future<PhoneFetchResult> get(String url) async {
    var current = url;
    for (var hop = 0; hop <= kMaxRedirects; hop++) {
      final Response<ResponseBody> resp;
      try {
        resp = await _dio.getUri<ResponseBody>(Uri.parse(current),
            options: Options(responseType: ResponseType.stream));
      } on DioException catch (e) {
        throw PhoneFetchException(
            PhoneFetchFailure.connection, e.message ?? e.type.name);
      }

      final code = resp.statusCode ?? 0;
      if (code >= 300 && code < 400) {
        final loc = resp.headers.value('location');
        if (loc == null || loc.isEmpty) {
          throw const PhoneFetchException(
              PhoneFetchFailure.connection, 'redirect without location');
        }
        final next = Uri.parse(current).resolve(loc);
        // **每一跳**都校验，初始 URL 不校验。
        if (isPrivateHost(next.host)) {
          throw PhoneFetchException(
              PhoneFetchFailure.redirectBlocked,
              'redirect to a private address was blocked: ${next.host}');
        }
        current = next.toString();
        continue;
      }

      final declared =
          int.tryParse(resp.headers.value(Headers.contentLengthHeader) ?? '');
      if (declared != null && declared > kMaxPhoneBytes) {
        throw PhoneFetchException(
            PhoneFetchFailure.tooLarge, 'content-length $declared bytes');
      }

      final chunks = <int>[];
      final stream = resp.data?.stream;
      if (stream != null) {
        // 边读边数：分块传输没有 content-length，光靠上面那道检查拦不住。
        // `await for` 里 throw 会自动取消订阅，不需要手动 cancel。
        await for (final chunk in stream) {
          chunks.addAll(chunk);
          if (chunks.length > kMaxPhoneBytes) {
            throw const PhoneFetchException(PhoneFetchFailure.tooLarge,
                'stream exceeded the size limit');
          }
        }
      }

      return PhoneFetchResult(
        bytes: Uint8List.fromList(chunks),
        contentType: resp.headers.value(Headers.contentTypeHeader),
        statusCode: code,
      );
    }
    throw const PhoneFetchException(
        PhoneFetchFailure.connection, 'too many redirects');
  }
}

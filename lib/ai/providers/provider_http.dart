// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// 连接空闲多久后被回收。
///
/// Dart 的默认值是 **15 秒**（`dart-sdk/lib/_http/http_impl.dart` 的
/// `_HttpClient._idleTimeout`）。移动端用户读完一屏输出、再在手机上慢慢
/// 打下一句，超过 15 秒是常态 —— 而每一次超过，下一轮就要重走
/// DNS + TCP + TLS。实测 TTFT 占单轮墙钟 66%，且与请求体大小无关，
/// 这段握手正是那个固定开销的一部分。
///
/// **为什么是 3 分钟而不是更长**：拉长会放大一个已知竞态 —— 服务端已经
/// 关闭连接、客户端仍认为可用，表现为偶发的
/// `Connection closed before full header was received`。各家 keep-alive
/// 通常在 5 分钟内，设更长换不来更多复用，只是把那个窗口开得更大。
const Duration kProviderIdleTimeout = Duration(minutes: 3);

/// 新建 TCP 连接的累计次数。仅在 [debugCountConnections] 为 true 时增长。
///
/// 用途是验证 [kProviderIdleTimeout] 真的生效：发一轮 → 等 20 秒 → 再发
/// 一轮，改动前这个数必然 +1，改动后必然不变。**测机制而不是测 TTFT**——
/// 直接测 TTFT 会被移动网络 ±300ms 的抖动淹掉（实测 11 轮里 TTFT 极差
/// 584ms，而那还是连续跑、无重连的）。
///
/// **全 app 共一个计数，不分 tab**：所有 `AgentLoop` 共用同一个 provider
/// 实例（同一个 Dio/HttpClient），而每个 tab 可以并发发起请求。如果诊断
/// 期间有多个 tab 同时在跑，差值会把别的 tab 的连接也算进来，「+1 还是
/// 不变」这个二值信号就不准了。这在「操作者手动控制单一变量」的一次性
/// 诊断场景下可以接受，但不要在多 tab 同时活跃时读这个数。
int debugNewConnectionCount = 0;

/// 是否统计新建连接。**必须在 provider 构造之前设置** —— Dio 的
/// `IOHttpClientAdapter` 会缓存 HttpClient 实例，运行时翻转这个开关不会让
/// 已存在的 provider 改变行为。
///
/// 跟随 `TerminalSettings.debugOverlay`（`main.dart` 启动装配时读一次，
/// `provider_switch.dart` 的 `switchProvider()` 每次切模型时再读一次），
/// 但 `debugOverlay` 本身不持久化、纯内存——所以**打开 developer mode 后
/// 必须切一次模型才会生效**，重启 app 不算（重启后 `debugOverlay` 又是
/// false 了）。
bool debugCountConnections = false;

/// 被丢弃的流分片计数（SSE / NDJSON 解析失败）。
///
/// 三个 provider 的解析循环都把 `jsonDecode` 包在 `catch (_) {}` 里：一个
/// 畸形分片会被静默丢掉，用户看到的是「回复少了半句」，而日志里什么都没有。
///
/// **为什么不用 `dlog`**：它被 `kDebugMode` 守卫，release 构建整个 tree-shake
/// 掉，而本项目禁止 debug 构建（见 CLAUDE.md）—— dlog 在生产包里等于不存在。
/// 同一个陷阱在 SFTP 的排序诊断里有详细记录（那里的结论是自建可见通道）。
///
/// 所以沿用 [debugNewConnectionCount] 那条现成的路：release 可见的计数器，
/// 只在 [debugCountConnections]（跟随 `TerminalSettings.debugOverlay`）
/// 打开时增长。
///
/// 判读：非 0 就说明这家 provider 的流里真的有分片没能解析 —— 而不是
/// 「模型话没说完」。它区分开了这两种在 UI 上长得一样的情况。
int debugDroppedStreamChunks = 0;

/// 记一次被丢弃的流分片。守卫与 [debugNewConnectionCount] 同一条。
void noteDroppedStreamChunk() {
  if (debugCountConnections) debugDroppedStreamChunks++;
}

/// 所有 AI provider 共用的 Dio 构造。
///
/// 三个 provider（anthropic / openai / ollama）原先各自 `Dio(BaseOptions(...))`
/// 且一个都没配 `httpClientAdapter`，因此全都吃 Dart 那个 15 秒默认值。
/// `GeminiProvider extends OpenAIProvider`，没有自己的 Dio，自动继承。
///
/// [receiveTimeout] 必须可覆盖：三家的取值**并不一致**，`ollama_provider.dart`
/// 用的是 60 秒（「Ollama 本地推理较慢」）。写死 30 秒的话，接入时会把那个
/// 有意为之的差异静默抹平——不报错、不失败，只是本地模型从此更容易超时。
Dio createProviderDio({
  Duration receiveTimeout = const Duration(seconds: 30),
}) =>
    Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: receiveTimeout,
    ))
      ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
        final client = HttpClient()..idleTimeout = kProviderIdleTimeout;
        if (debugCountConnections) {
          // proxyHost/proxyPort 必须照顾到 —— 忽略它们会让代理环境下的
          // 所有请求直连目标，这正是这个钩子默认关闭的原因。
          client.connectionFactory = (uri, proxyHost, proxyPort) {
            debugNewConnectionCount++;
            return Socket.startConnect(
                proxyHost ?? uri.host, proxyPort ?? uri.port);
          };
        }
        return client;
      });

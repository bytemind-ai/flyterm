// SPDX-License-Identifier: GPL-3.0-or-later

import 'openai_provider.dart';

/// Gemini，走 Google 官方的 **OpenAI 兼容端点**而不是原生 wire format。
///
/// ## 为什么是继承 [OpenAIProvider]，而且一行协议代码都没有
///
/// `https://generativelanguage.googleapis.com/v1beta/openai/` 这个端点接受
/// OpenAI 的请求格式，且支持 aipanel 依赖的全部三件事：tool calling
/// （`tools` + `tool_choice`）、流式（`stream=true`）、图片输入
/// （`image_url` + base64 data URI）。兼容层不支持的那些（batch 文件上下载、
/// 图像/视频生成参数、grounding）本项目一件都不用。
///
/// 于是请求体拼装、SSE 解析、tool call 的流式累积、图片 data URI、
/// `Retry-After` 解析、`isContextOverflow` 判定全部从父类继承。
///
/// **这个耦合是有意的**：兼容层在协议层面就是 OpenAI 格式，两者本该一起
/// 演进。父类改了请求体拼装，这里应当自动拿到同一个改动，而不是依赖有人
/// 记得来同步。组合写法要转发 6 个成员（`complete` / `completeStream` /
/// `completeWithTools` / `completeWithToolsStream` / `supportsTools` /
/// `noteVisionFailure`），且父类每加一个能力都要补一次转发，漏一个就是静默
/// 的行为差异。
///
/// ## 退路
///
/// 兼容层标着 beta，Google 自己建议「若非已绑定 OpenAI 库，请直连 Gemini
/// API」。真到那一天，把父类换成自行实现的原生 wire format 即可 —— 本类
/// 已经是独立类 + 独立 `providerType`，factory、表单、品牌色、用户已保存的
/// 配置全都不用动。
class GeminiProvider extends OpenAIProvider {
  /// 官方 OpenAI 兼容端点。**不带尾部 `/`**，也不以 `/v1` 结尾 ——
  /// [OpenAIProvider] 拼的是 `$baseUrl/chat/completions`，不硬塞版本段，
  /// 所以这种形状能正常工作（智谱的 `/api/paas/v4` 同理）。
  static const defaultBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta/openai';

  GeminiProvider({
    required super.apiKey,
    required super.model,
    String? baseUrl,
    super.extraParamsJson,
    super.dio,
  }) : super(
          baseUrl: (baseUrl?.trim().isNotEmpty ?? false)
              ? baseUrl!.trim()
              : defaultBaseUrl,
        );

  @override
  String get displayName => 'Gemini ($model)';

  @override
  String get providerType => 'gemini';
}

// SPDX-License-Identifier: GPL-3.0-or-later
import '../data/models/ai_provider_config.dart';
import '../data/repositories/ai_provider_repository.dart';
import '../data/secure_storage.dart';
import 'ai_provider.dart';
import 'ai_provider_service.dart';
import 'providers/provider_http.dart';

/// 切换当前生效的 AI provider。设置页与 AI 面板共用这一份。
///
/// **持久化为默认**（`isDefault = true`）而不是只改内存：用户在面板里切了
/// 模型，退出再进应该还是那个。否则每次开面板都弹回旧模型，反直觉。
///
/// 与 `main.dart` 启动时的装配保持同一条路径（`AIProviderFactory.create`），
/// 避免出现「设置页切的和启动时装的不是一回事」。
///
/// [debugOverlay] 用于同步 `debugCountConnections`（见 `provider_http.dart`
/// 的文档注释）：developer mode 打开后本身不会让已存在的 provider 改变
/// 行为，必须像这样在重建 provider 之前重新设置一次这个开关，切模型才是
/// 让它生效的唯一运行期路径。
Future<void> switchProvider({
  required AIProviderConfig config,
  required AIProviderRepository repo,
  required SecureStorageService storage,
  required AIProviderService svc,
  bool debugOverlay = false,
}) async {
  await repo.update(config.copyWith(isDefault: true));
  final apiKey = await storage.loadAIKey(config.id) ?? '';
  // 必须在 provider 构造之前设置：IOHttpClientAdapter 会缓存 HttpClient
  // 实例，之后再翻转这个开关对已存在的 provider 无效。
  debugCountConnections = debugOverlay;
  svc.setProvider(AIProviderFactory.create(config, apiKey));
}

/// 这个配置现在能不能用。
///
/// ollama 不需要 key（`main.dart` 启动装配处就是这么判的），其余类型没有 key
/// 就是一个必然失败的 provider —— 切过去只会得到一次 401。
Future<bool> providerUsable(
  AIProviderConfig config,
  SecureStorageService storage,
) async {
  if (config.type == 'ollama') return true;
  final key = await storage.loadAIKey(config.id) ?? '';
  return key.isNotEmpty;
}

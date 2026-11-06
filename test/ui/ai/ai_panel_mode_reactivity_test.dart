// 回归测试：用户在设置里改了权限档之后，**已经打开**的 agent 面板必须跟上。
//
// 曾经不跟上：`ai_panel.dart` 的 `_buildBody` 用 `context.read` 取
// `modeFor(serverId)`，注释写的是「现读而不是缓存：用户可能在会话中途去设置
// 里改了档」，但 read 不建立依赖 —— `_buildBody` 不会因改档而重建，planMode
// 就冻在打开面板那一刻的值上。表现是「改了权限模式没反应，退出重进才看到
// 新值」：设置页自己刷新得好好的，值也确实存了，只有这个面板没跟上。
//
// 现在用 `Selector` 订阅那一个 bool。测双向翻转 —— 单向只能证明「碰巧算对
// 了一次」，双向才能证明订阅是活的。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/agent/agent_exec_channel.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/agent_view.dart';
import 'package:flyterm/ui/ai/ai_panel.dart';

import '../../ai/agent/_fakes.dart';

/// 只有 `AgentExecChannel.isAvailable()`/`obtain()` 会用到 `loadPassword`。
class _FakeStorage implements SecureStorageService {
  @override
  Future<String?> loadPassword(String serverId) async => 'fake-password';
  @override
  Future<String?> loadPrivateKey(String keyId) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _server = Server(
  id: 'srv-1',
  name: 'test-server',
  host: 'example.com',
  port: 22,
  username: 'root',
  authType: 'password',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('设置里改权限档，已打开的面板 planMode 双向跟随', (tester) async {
    // 'agent_rules_reviewed_global' 预置成 true，否则 _maybeForceRuleReview
    // 会弹出 AgentSettingsScreen 盖住面板。
    SharedPreferences.setMockInitialValues({
      'agent_rules_reviewed_global': true,
      'agent_mode_default': 'ask',
    });
    final prefs = await SharedPreferences.getInstance();
    final aiSvc = AIProviderService(prefs);
    final provider = FakeProvider([const AIResponse(text: 'ok')]);
    aiSvc.setProvider(provider);
    final agentMgr = AgentSessionManager(prefs);
    final channel = AgentExecChannel(server: _server, storage: _FakeStorage());

    // 记忆化：与生产代码 `_agentLoopFor` 复用已注册 loop 的行为一致。面板
    // 重建时 loopFactory 会被再调一次，复用才不会凭空换掉会话。
    AgentLoop? capturedLoop;
    AgentLoop loopFactory() => capturedLoop ??= makeLoop(provider: provider);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AIProviderService>.value(value: aiSvc),
          ChangeNotifierProvider<AgentSessionManager>.value(value: agentMgr),
          // AgentView 接了语音输入（Consumer<VoiceInputService>），不提供会在
          // build 时抛 ProviderNotFoundException。未初始化的实例即可：
          // isAvailable/isListening 默认 false，不碰平台通道。
          ChangeNotifierProvider<VoiceInputService>.value(
            value: VoiceInputService(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: AIPanel(
              engine: AIEngine(prefs, serverId: _server.id),
              contextProvider: () => 'buffer',
              execChannel: channel,
              loopFactory: loopFactory,
            ),
          ),
        ),
      ),
    );
    // 等 _resolveMode 的 await channel.isAvailable() 落地、模式切到 agent。
    await tester.pumpAndSettle();

    expect(capturedLoop, isNotNull, reason: '应已进入 agent 模式');

    // 用 `bypassMode` 观察档位是否真的传到了面板。`planMode` 参数已随
    // 审批卡的按钮瘦身（2026-10-13）删除 —— 卡片不再需要知道是不是 plan 档。
    // 本用例真正要钉的性质是「改档后面板立即跟上」，与观察哪个字段无关。
    bool bypassMode() =>
        tester.widget<AgentView>(find.byType(AgentView)).bypassMode;

    expect(bypassMode(), isFalse, reason: '默认档（ask）下 bypassMode 应为 false');

    // ask -> bypass
    agentMgr.defaultMode = PermissionMode.bypass;
    await tester.pumpAndSettle();
    expect(bypassMode(), isTrue, reason: '改成 bypass 后面板应立即跟上');

    // bypass -> ask（再翻回去，证明订阅是活的而不是碰巧算对一次）
    agentMgr.defaultMode = PermissionMode.ask;
    await tester.pumpAndSettle();
    expect(bypassMode(), isFalse, reason: '改回 ask 后面板应立即跟上');

    // per-server 覆盖也该被 modeFor 反映出来
    agentMgr.setModeOverride(_server.id, PermissionMode.bypass);
    await tester.pumpAndSettle();
    expect(bypassMode(), isTrue, reason: 'per-server 覆盖成 bypass 后面板应立即跟上');
  });
}

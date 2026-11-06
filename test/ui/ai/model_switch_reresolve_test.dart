// 守「面板内切模型」接线的一个隐患：切换 provider 之后必须重算模式
// （_resolveMode），否则会出现「面板还在 agent 模式、provider 已经不支持
// 工具调用」的错位——旧流程里换 provider 得退出面板再进才会走一遍这个判定。
//
// 三种真实 provider（openai/anthropic/ollama）在 `AIProviderFactory.create`
// 构造出来的那一刻 `supportsTools` 全部是 true（ollama 要等第一次工具调用
// 失败才会翻转，见 `ollama_provider.dart`），没有任何真实类型能在“刚切换”
// 这一刻就报不支持。所以这里用一个包一层的 `AIProviderService` 测试替身：
// 真实的 `repo.update` / `storage.loadAIKey` / `AIProviderFactory.create` /
// `svc.setProvider` 全部照真实路径跑一遍（验证接线没断），只在第二次真实
// 切换发生之后，把 `provider` getter 换成读一个 `supportsTools: false` 的
// FakeProvider——单独把“判定条件”这一步摘出来测，而不需要一个本不存在的
// 真实 provider 类型。
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/agent/agent_exec_channel.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/ai/ai_provider.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/ai_provider_config.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/repositories/ai_provider_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/agent_view.dart';
import 'package:flyterm/ui/ai/ai_panel.dart';

import '../../ai/agent/_fakes.dart';

/// 头两次 `setProvider` 之后才把 `provider` 换成 `supportsTools: false`——
/// 第一次是面板打开前的初始装配，第二次才是本测试要触发的那次真实切换。
class _SwitchAwareProviderService extends AIProviderService {
  _SwitchAwareProviderService(super.prefs);

  int _setCount = 0;
  AIProvider? _forceAfterSwitch;

  @override
  void setProvider(AIProvider provider) {
    _setCount++;
    super.setProvider(provider);
  }

  @override
  AIProvider? get provider {
    if (_setCount >= 2) {
      return _forceAfterSwitch ??= FakeProvider([], supportsTools: false);
    }
    return super.provider;
  }

  @override
  bool get hasProvider => provider != null;
}

const _server = Server(
  id: 'srv-switch',
  name: 'switch-server',
  host: 'example.com',
  port: 22,
  username: 'root',
  authType: 'password',
);

/// 在 `runAsync` 里把真实异步推到静止，**不要赌一个固定时长**。
///
/// 这里等的是 `_switchModel` 那条链：`repo.findAll()`（真实 sqflite）→ 每个
/// 候选一次 `providerUsable()`（读 secure storage）→ `switchProvider()`
/// （又一次 sqflite 写）→ `_resolveMode()`。原先写的是
/// `Future.delayed(50ms)`，单独跑机器闲、跑得完，全量跑机器忙就跑不完 ——
/// 表现为一条随机变红的用例，而且红的地方在断言处，看上去像功能坏了。
///
/// 让出足够多次事件循环而不是睡固定时长：任务真跑完了就不必等满，没跑完
/// 也还有余量。总上限约 2 秒，比赌 50ms 稳，也不会把测试拖慢 —— 正常情况
/// 前几次让出就已经完成了。
Future<void> _tapAndSettleUntil(
  WidgetTester tester,
  Finder target,
  Finder until, {
  bool expectPresent = true,
}) async {
  // tap 必须和真实异步一起裹进 runAsync：`_switchModel` 里的 repo.findAll()
  // 走真实 sqflite，那个 Future 在 flutter_test 的 fake-async zone 里永远不会
  // 完成（见项目 memory feedback_widget_test_sqflite_hang）。
  await tester.runAsync(() async {
    await tester.tap(target);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await tester.pumpAndSettle();

  // 然后**轮询到条件成立**，不赌一个固定时长。
  //
  // 这里等的是 `_switchModel` 那条链：findAll（sqflite）→ 每个候选一次
  // providerUsable（secure storage）→ switchProvider（又一次 sqflite 写）
  // → _resolveMode。原先写死 `Future.delayed(50ms)`，单独跑机器闲、跑得完，
  // 全量跑机器忙就跑不完 —— 一条随机变红的用例，而且红在断言处，看上去像
  // 功能坏了而不是测试脆。
  //
  // runAsync 让真实异步前进，pumpAndSettle 把结果刷进 widget 树，两者必须
  // 交替：只 runAsync 树不更新，只 pump 真实 Future 不前进。
  for (var i = 0; i < 100; i++) {
    if (until.evaluate().isNotEmpty == expectPresent) return;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late AIProviderRepository repo;
  const currentId = 'current';
  const targetId = 'target';

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    repo = AIProviderRepository(db);
    await repo.insert(const AIProviderConfig(
      id: currentId,
      name: 'Current Model',
      type: 'anthropic',
      model: 'claude-current',
      isDefault: true,
    ));
    await repo.insert(const AIProviderConfig(
      id: targetId,
      name: 'Target Model',
      type: 'anthropic',
      model: 'claude-target',
      isDefault: false,
    ));

    // 两条配置都要有 key，否则 sheet 里那一项会被置灰、点不动。
    FlutterSecureStorage.setMockInitialValues({
      'ai_key_$currentId': 'sk-current',
      'ai_key_$targetId': 'sk-target',
      'server_pw_${_server.id}': 'fake-password',
    });
    SharedPreferences.setMockInitialValues({
      'agent_rules_reviewed_global': true,
    });
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('切模型之后重算模式：从 agent 降级到 direct', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final storage = SecureStorageService();
    final aiSvc = _SwitchAwareProviderService(prefs);
    // 第一次 setProvider：面板打开前的初始装配，_setCount == 1，
    // provider getter 仍走真的（supportsTools: true）。
    aiSvc.setProvider(FakeProvider([const AIResponse(text: 'ok')]));

    final agentMgr = AgentSessionManager(prefs);
    final channel = AgentExecChannel(server: _server, storage: storage);
    final loopProvider = FakeProvider([const AIResponse(text: 'ok')]);
    AgentLoop? captured;
    AgentLoop loopFactory() => captured ??= makeLoop(provider: loopProvider);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AIProviderService>.value(value: aiSvc),
          ChangeNotifierProvider<AgentSessionManager>.value(value: agentMgr),
          ChangeNotifierProvider<VoiceInputService>.value(
            value: VoiceInputService(),
          ),
          Provider<AIProviderRepository>.value(value: repo),
          Provider<SecureStorageService>.value(value: storage),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
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
    await tester.pumpAndSettle();
    expect(captured, isNotNull, reason: '应已进入 agent 模式');
    expect(find.byType(AgentView), findsOneWidget);

    final l = await AppLocalizations.delegate.load(const Locale('zh'));

    // 点标题区打开切模型 sheet。
    //
    // _switchModel 里的 repo.findAll() 走真实 sqflite —— testWidgets 的回调跑
    // 在 flutter_test 的 fake-async zone 里，sqflite_common_ffi 的异步靠真实
    // timer/microtask 实现，那个 Future 在这个 zone 里永远不会完成。必须把
    // **触发它的 tap 一起**裹进 tester.runAsync，事后再 runAsync 一段 delay
    // 推不动已经排进 fake zone 队列的 continuation（见项目 memory
    // feedback_widget_test_sqflite_hang）。
    await _tapAndSettleUntil(
      tester,
      find.text(l.aiAssistant).first,
      find.text(l.aiSwitchModel),
    );
    expect(find.text(l.aiSwitchModel), findsOneWidget);

    // 选另一条模型——触发第二次真实 setProvider（_setCount == 2），
    // 之后 provider getter 就固定返回 supportsTools:false 的 FakeProvider。
    // onPick 里的 switchProvider() 同样会写 sqflite（repo.update），tap 同理
    // 要裹进 runAsync。
    await _tapAndSettleUntil(
      tester,
      find.text('Target Model'),
      find.byType(AgentView),
      expectPresent: false,
    );

    expect(find.byType(AgentView), findsNothing,
        reason: '切到不支持 tools 的模型后必须降级，不能停留在 agent 模式');
    expect(find.text(l.agentNoToolSupport), findsOneWidget,
        reason: '降级横幅要说明原因');
  });
}

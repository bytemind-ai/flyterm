// 键盘弹出时面板该占多大，以及顶部哪些地方能拖着伸缩。
//
// 这两件事在同一个文件里，因为用户是一起报的：「输入时上拉的面积被缩小了，
// 而且必须在输出屏幕上点上滑才能上拉」。前半句是 sheet 尺寸算错，后半句是
// 除了消息列表之外没有别的地方接得住拖拽手势。
//
// 关键前提（也是尺寸算错的根源）：`showModalBottomSheet` 的 route **不**避让
// 键盘，Flutter 的 bottom_sheet.dart 里没有任何 viewInsets 处理。sheet 的高度
// 永远是从屏幕底边往上量的，键盘盖住的是它自己的下半截；顶开输入框那一下由
// `PanelInputRow` 自己的 `viewInsets.bottom` padding 完成。所以 sheet 尺寸公式
// 里再减一次键盘高度，等于把键盘扣了两遍。
//
// 测试里用 `resizeToAvoidBottomInset: false` 就是为了复现这个前提 —— 默认的
// Scaffold 会把 body 压到键盘上方，那是真机上不存在的行为，照着它写测试会
// 得出「公式没问题」的假结论。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flyterm/ai/agent/agent_exec_channel.dart';
import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/ai_engine.dart';
import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/ai/voice_input_service.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/ai_panel.dart';
import 'package:flyterm/ui/ai/widgets/panel_chrome.dart';

import '../../ai/agent/_fakes.dart';

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

/// 逻辑像素下的测试视口：400×800，键盘 330 —— 常见手机的量级。
const _screenH = 800.0;
const _keyboardH = 330.0;
const _dpr = 3.0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'agent_rules_reviewed_global': true,
    });
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400 * _dpr, _screenH * _dpr);
    tester.view.devicePixelRatio = _dpr;
    addTearDown(tester.view.reset);

    final prefs = await SharedPreferences.getInstance();
    final aiSvc = AIProviderService(prefs);
    final provider = FakeProvider([const AIResponse(text: 'ok')]);
    aiSvc.setProvider(provider);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AIProviderService>.value(value: aiSvc),
          ChangeNotifierProvider<AgentSessionManager>.value(
            value: AgentSessionManager(prefs),
          ),
          ChangeNotifierProvider<VoiceInputService>.value(
            value: VoiceInputService(),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            // 见文件头注释：modal bottom sheet 的 route 不避让键盘，这里必须
            // 关掉 Scaffold 的自动避让才是真机上的布局。
            resizeToAvoidBottomInset: false,
            body: AIPanel(
              engine: AIEngine(prefs, serverId: _server.id),
              contextProvider: () => 'MARKER',
              execChannel:
                  AgentExecChannel(server: _server, storage: _FakeStorage()),
              loopFactory: () => makeLoop(provider: provider),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 键盘弹起（`didChangeDependencies` 靠 viewInsets 变化触发）。
  Future<void> raiseKeyboard(WidgetTester tester) async {
    tester.view.viewInsets = const FakeViewPadding(bottom: _keyboardH * _dpr);
    await tester.pumpAndSettle();
  }

  /// 面板「拉出来的面积」= 对话列表的高度。
  ///
  /// 量的是高度而不是 sheet 顶边：`expand: false` 的 sheet 在这个测试装配里
  /// （直接挂在 Scaffold body 上）是顶对齐的，顶边恒为 0，长高表现在底边；
  /// 真机上它挂在 modal route 里底对齐，长高表现在顶边。高度对两种装配都成立。
  double chatHeight(WidgetTester tester) =>
      tester.getSize(find.byType(ListView)).height;

  testWidgets('键盘弹出后对话区仍看得见 —— 键盘高度只许扣一次', (tester) async {
    await pumpPanel(tester);
    await raiseKeyboard(tester);

    // 键盘 inset 是逐帧涨上来的，sheet 的尺寸动画跟在后面，中间必然有那么
    // 一帧「输入行已经顶到 330px 高、面板还没长大」—— RenderFlex 会为此报一次
    // overflow。真机 release 下就是那一帧被裁掉，220ms 后自愈；这里显式吃掉，
    // 免得它盖过下面那条真正要守的断言。
    tester.takeException();

    // 对话列表上面是 32+46px 的把手与头部，下面是自己已经顶到键盘上方的输入行。
    expect(
      chatHeight(tester),
      greaterThan(200),
      reason: '键盘扣两遍的版本这里是 0 —— Expanded 被输入行整个挤没',
    );
  });

  testWidgets('顶部拖拽条够手指点 —— 4px 的条子不是触摸目标', (tester) async {
    await pumpPanel(tester);

    expect(
      tester.getSize(find.byType(PanelHandle)).height,
      greaterThanOrEqualTo(32),
      reason: '视觉上是 4px 的细条，但可命中区域得撑到能盲点的尺寸',
    );
  });

  testWidgets('拖住把手能伸缩面板', (tester) async {
    await pumpPanel(tester);
    final before = chatHeight(tester);

    await tester.drag(find.byType(PanelHandle), const Offset(0, -150));
    await tester.pump();

    // 「差不多同样多」是有意义的上下界：分母若取成 sheet 自己的当前高度而不是
    // 父容器高度，同样的 150px 会被放大成 250px 上下，手感直接失真。
    expect(
      chatHeight(tester) - before,
      inInclusiveRange(110, 190),
      reason: '上滑 150 应该跟手拉大 150（起手的 touch slop 吃掉一小截）',
    );
  });

  testWidgets('拖头部那一行也能伸缩面板 —— 不必非得去消息列表上滑', (tester) async {
    await pumpPanel(tester);
    final before = chatHeight(tester);

    // 按坐标拖而不是按 finder：手势本来就该由包在头部外面的那层
    // GestureDetector 接住，`drag(find.byType(PanelHeader))` 会因为命中的不是
    // PanelHeader 自己的 RenderBox 而报一条噪音警告。
    await tester.dragFrom(
      tester.getCenter(find.byType(PanelHeader)),
      const Offset(0, -150),
    );
    await tester.pump();

    expect(
      chatHeight(tester),
      greaterThan(before + 100),
      reason: '用户报的就是这个：除了输出区域没别的地方拉得动面板',
    );
  });
}

import 'package:flyterm/ai/agent/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flyterm/ai/agent/tool_executors/app_executors.dart';
import 'package:flyterm/ai/agent/tool_executors/sftp_executors.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/app_control/app_control_service.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import '_fakes.dart';
import '../../sftp/sftp_transfer_task_test.dart' show FakeTransferOps;

/// 参数错误只有**一套措辞**。
///
/// 收口之前是两套：app / sftp 侧写 `Missing required argument \`X\`.`，
/// file / job / web / skill 侧写 `Invalid arguments: \`X\` is required.`。
/// 两者描述的是同一件事，模型却收到两种格式 —— 更糟的是前者不说「这是参数
/// 问题」，模型容易把它当成执行期失败去排查，而不是回头补参数。
///
/// 这个文件守两件事：
///   1. 措辞统一（都带 `Invalid arguments` 前缀）
///   2. 不止一个 executor 真的走到统一路径上（不是只把 app 改对了）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TerminalSettings settings;
  late AppControlService svc;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    settings = TerminalSettings(SecureStorageService());
    svc = AppControlService(settings: settings);
  });

  AppExecutors appExecs() => AppExecutors(makeLoop(
        provider: FakeProvider([]),
        appControl: svc,
        mode: PermissionMode.bypass,
      ));

  group('参数错误措辞统一', () {
    test('app executor 缺 key 时说 Invalid arguments，不说 Missing required',
        () async {
      final r = await appExecs().settingsSet(const ToolCall(
        id: '1',
        name: 'app_settings_set',
        args: {'value': 'x'}, // 缺 key
      ));
      expect(r.isError, isTrue);
      expect(r.content, contains('Invalid arguments'));
      expect(r.content, isNot(contains('Missing required argument')));
      // 仍然点名是哪个参数 —— 统一措辞不等于丢掉可操作性。
      expect(r.content, contains('key'));
    });

    test('app executor 缺 name 时同样走统一措辞', () async {
      final r = await appExecs().serverEntry(const ToolCall(
        id: '1',
        name: 'server_entry_create',
        args: {'host': 'h', 'username': 'u'}, // 缺 name
      ));
      expect(r.isError, isTrue);
      expect(r.content, contains('Invalid arguments'));
      expect(r.content, isNot(contains('Missing required argument')));
      expect(r.content, contains('name'));
    });

    test('sftp executor 缺 path 时同样走统一措辞', () async {
      final execs = SftpExecutors(makeLoop(
        provider: FakeProvider([]),
        sftpOpsProvider: () async => FakeTransferOps(),
      ));
      final r = await execs.run(const ToolCall(
        id: '1',
        name: 'sftp_stat',
        args: {}, // 缺 path
      ));
      expect(r.isError, isTrue);
      expect(r.content, contains('Invalid arguments'));
      expect(r.content, isNot(contains('Missing required argument')));
    });
  });
}

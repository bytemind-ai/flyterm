import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/repositories/ssh_key_repository.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/ssh/reconnect_service.dart';
import 'package:flyterm/ssh/session_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late ReconnectService svc;

  Future<ReconnectService> build({
    void Function(String newType, String? oldType)? onNetworkTypeChanged,
    void Function()? onForegroundResumedForSftp,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    return ReconnectService.forTest(
      SessionManager(prefs: prefs),
      ServerRepository(db),
      SSHKeyRepository(db),
      SecureStorageService(const FlutterSecureStorage()),
      onNetworkTypeChanged: onNetworkTypeChanged,
      onForegroundResumedForSftp: onForegroundResumedForSftp,
    );
  }

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
  });

  tearDown(() async {
    await db.close();
  });

  group('ReconnectService 的 SFTP 回调', () {
    test('网络类型变化时才触发，信号强度变化不触发', () async {
      // 这条约束来自既有实现：_lastConnectivityType 只比较「类型」，
      // wifi 信号强弱不该触发重连。
      String? seen;
      String? seenOld;
      var calls = 0;
      svc = await build(onNetworkTypeChanged: (n, o) {
        seen = n;
        seenOld = o;
        calls++;
      });

      svc.debugFeedNetworkType('wifi');
      expect(seen, 'wifi');
      expect(seenOld, isNull);
      expect(calls, 1);

      svc.debugFeedNetworkType('wifi'); // 同类型 —— 不重复触发
      expect(calls, 1);
      expect(seenOld, isNull); // old 仍是第一次的对比值

      svc.debugFeedNetworkType('cellular'); // 类型变化 —— 再触发
      expect(calls, 2);
      expect(seen, 'cellular');
      expect(seenOld, 'wifi');
    });

    test('回前台触发 SFTP 探活回调', () async {
      var calls = 0;
      svc = await build(onForegroundResumedForSftp: () => calls++);

      svc.onForegroundResumed();
      expect(calls, 1);
    });

    test('未注入回调时不会崩溃', () async {
      svc = await build();
      expect(() => svc.debugFeedNetworkType('wifi'), returnsNormally);
      expect(() => svc.onForegroundResumed(), returnsNormally);
    });

    test('纯判据 shouldNotifyNetworkTypeChange 只在类型变化时为真', () {
      expect(ReconnectService.shouldNotifyNetworkTypeChange(null, 'wifi'), isTrue);
      expect(ReconnectService.shouldNotifyNetworkTypeChange('wifi', 'wifi'), isFalse);
      expect(ReconnectService.shouldNotifyNetworkTypeChange('wifi', 'cellular'), isTrue);
      expect(ReconnectService.shouldNotifyNetworkTypeChange('none', 'wifi'), isTrue);
    });
  });
}

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/agent/agent_session_manager.dart';
import 'package:flyterm/ai/agent/exec_channel_factory.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/ssh/session_manager.dart';
import 'package:flyterm/ssh/transport/composite_transport_factory.dart';

/// [execChannelForServer] 承载一条**生命周期不变量**，此前没有任何测试。
///
/// 它的注释写着：*闭包只捕获 serverId，不捕获任何 tab*。原因是 channel 与
/// loop 的寿命都远长于单个 tab：
///
/// - 捕获 tab → 已关闭的会话永远回收不掉；
/// - 捕获 tab → 「在 tab A 开过面板、切到 tab B 再开」会一直递出一个**已经
///   断开的 client**（channel 拿它去复用必然失败，而它本可以自己新开一条）。
///
/// 这个文件守的是第二条：reuse 拿到的东西必须反映**此刻**的状态，而不是
/// channel 第一次被创建时的状态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late SessionManager sessions;
  late SharedPreferences prefs;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
    prefs = await SharedPreferences.getInstance();
    // **不接 tabSessionRepo。** 这些测试不关心持久化，而
    // `SessionManager._persist()` 是 fire-and-forget 的异步写入 —— 接上它
    // 就多一条与断言无关的竞态（写入落在 tearDown 关库之后 →
    // database_closed）。不接时 `_persist()` 直接短路（见其实现：
    // `if (_tabSessionRepo == null ...) return;`），测试因此只盯住要守的
    // 那条不变量。
    sessions = SessionManager(
      prefs: prefs,
      transportFactory: CompositeTransportFactory(),
    );
  });

  tearDown(() async {
    await pumpEventQueue();
    await db.close();
  });

  Server server(String id) => Server(
        id: id,
        name: 'web-$id',
        host: '10.0.0.5',
        port: 22,
        username: 'root',
        authType: 'password',
      );

  test('同一台机器无论建几次都拿到同一个 channel（按 serverId 缓存）', () {
    final mgr = AgentSessionManager(prefs);
    final ch1 = execChannelForServer(
      mgr: mgr,
      server: server('s1'),
      sessions: sessions,
      storage: SecureStorageService(),
    );
    final ch2 = execChannelForServer(
      mgr: mgr,
      server: server('s1'),
      sessions: sessions,
      storage: SecureStorageService(),
    );

    expect(identical(ch1, ch2), isTrue,
        reason: '按 serverId 缓存，不该每调一次造一条新连接');
  });

  test('不同机器拿到不同 channel', () {
    final mgr = AgentSessionManager(prefs);
    final ch1 = execChannelForServer(
      mgr: mgr,
      server: server('s1'),
      sessions: sessions,
      storage: SecureStorageService(),
    );
    final ch2 = execChannelForServer(
      mgr: mgr,
      server: server('s2'),
      sessions: sessions,
      storage: SecureStorageService(),
    );

    expect(identical(ch1, ch2), isFalse);
  });

  // ─────────────────────────────────────────────────────────────────────
  // 这里**没有**测「reuse 闭包不冻结 tab」那条不变量，这是有意的。
  //
  // 我试了三版，每版都做了变异验证（把实现改成创建时 `activeTabForServer`
  // 冻结），**三版全都在冻结版下照样绿** —— 因为 unit test 里没有真实 SSH
  // 服务器，两个 tab 的 `connection.client` 恒为 null，而 `identical(null,
  // null) == true`，拿它做断言没有任何区分度。`SSHConnection._client` 是
  // 私有字段且无 setter，注不进去假值。
  //
  // 一条抓不到 bug 的测试比没有测试更糟 —— 它给出虚假的安全感。所以宁可
  // 不写，把局限记在这里，而不是留一条自我感觉良好的绿。
  //
  // 要真正覆盖它需要：给 `SSHConnection` 开一个 `@visibleForTesting` 的
  // client 注入口（生产代码改动，不属于本次加测试的范围），或者一条带真实
  // sshd 的集成测试。两条都超出「补测试」的成本档位。
  //
  // 能被 unit test 守住的部分已经在上面的缓存／按 serverId 区分两条里了。
}


import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/ssh/aqt/aqt_session_state.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late AqtSessionStateRepository repo;
  late FakeSecureStore secure;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    secure = FakeSecureStore();
    repo = AqtSessionStateRepository(db, secure);
  });

  tearDown(() async => db.close());

  test('token 存 Keychain，其余存 SQLite —— 但读写只有一个入口', () async {
    await repo.save(AqtSessionState(
      tabId: 'tab-1',
      port: 4433,
      spki: [1, 2, 3],
      sessionToken: List.filled(32, 7),
      scrollbackCursor: 900,
      serverTtlSecs: 604800,
      savedAt: DateTime.now(),
    ));
    final got = await repo.load('tab-1');
    expect(got, isNotNull);
    expect(got!.port, 4433);
    expect(got.spki, [1, 2, 3]);
    expect(got.sessionToken, List.filled(32, 7));
    expect(got.scrollbackCursor, 900);
    // secure store 现在有两个 key（token + aqtTabId，见 AqtSessionState.aqtTabId
    // 的 dartdoc），不再是单一 key——断言改成"token key 确实在里面"，不再要求
    // 只有一个 key。
    expect(secure.keys, contains('aqt_token_tab-1'),
        reason: 'token 必须在 secure store 里，不能进明文 DB');
  });

  test('过期判定用服务端下发的 TTL，不用本地常量', () async {
    final old = DateTime.now().subtract(const Duration(hours: 3));
    final shortTtl = AqtSessionState(
      tabId: 't',
      port: 1,
      spki: const [],
      sessionToken: List.filled(32, 0),
      scrollbackCursor: 0,
      serverTtlSecs: 3600,
      savedAt: old,
    );
    expect(shortTtl.isExpired, isTrue, reason: 'TTL 1 小时，存了 3 小时');

    final longTtl = AqtSessionState(
      tabId: 't',
      port: 1,
      spki: const [],
      sessionToken: List.filled(32, 0),
      scrollbackCursor: 0,
      serverTtlSecs: 604800,
      savedAt: old,
    );
    expect(longTtl.isExpired, isFalse, reason: 'TTL 7 天，存了 3 小时');
  });

  test('过期即清掉 token，不留悬空凭据', () async {
    await repo.save(AqtSessionState(
      tabId: 'gone',
      port: 1,
      spki: const [],
      sessionToken: List.filled(32, 1),
      scrollbackCursor: 0,
      serverTtlSecs: 60,
      savedAt: DateTime.now().subtract(const Duration(hours: 2)),
    ));
    expect(await repo.load('gone'), isNull);
    expect(secure.keys, isEmpty);
    expect(await db.query('aqt_session_state'), isEmpty,
        reason: '过期后 DB 那一行也要清掉，不留没有凭据的僵尸行');
  });

  test('拿不到服务端 TTL 时用 7 天兜底', () {
    final s = AqtSessionState(
      tabId: 't',
      port: 1,
      spki: const [],
      sessionToken: List.filled(32, 0),
      scrollbackCursor: 0,
      serverTtlSecs: null,
      savedAt: DateTime.now().subtract(const Duration(days: 3)),
    );
    expect(s.isExpired, isFalse);
  });

  test('DB 有行但 Keychain 没 token —— 卸载重装/清了 Keychain，清掉那一行', () async {
    await repo.save(AqtSessionState(
      tabId: 'orphan',
      port: 1,
      spki: const [],
      sessionToken: List.filled(32, 3),
      scrollbackCursor: 0,
      serverTtlSecs: 604800,
      savedAt: DateTime.now(),
    ));
    // 模拟用户单独清了 Keychain：DB 那行还在，secure store 里没了。
    await secure.delete('aqt_token_orphan');

    expect(await repo.load('orphan'), isNull);
    expect(await db.query('aqt_session_state'), isEmpty,
        reason: '没有凭据的行留着只会让下次又白查一遍 DB');
  });

  test('不同 tab 互不干扰', () async {
    await repo.save(AqtSessionState(
      tabId: 'a',
      port: 1,
      spki: const [1],
      sessionToken: List.filled(32, 1),
      scrollbackCursor: 0,
      serverTtlSecs: 604800,
      savedAt: DateTime.now(),
    ));
    await repo.save(AqtSessionState(
      tabId: 'b',
      port: 2,
      spki: const [2],
      sessionToken: List.filled(32, 2),
      scrollbackCursor: 0,
      serverTtlSecs: 604800,
      savedAt: DateTime.now(),
    ));

    await repo.remove('a');

    expect(await repo.load('a'), isNull);
    final b = await repo.load('b');
    expect(b, isNotNull);
    expect(b!.port, 2);
  });

  test('copyWith 刷新 serverTtlSecs 与 savedAt —— 服务端 TTL 是从最后一次 touch 算起的',
      () async {
    final base = AqtSessionState(
      tabId: 't',
      port: 1,
      spki: const [],
      sessionToken: List.filled(32, 0),
      scrollbackCursor: 0,
      serverTtlSecs: 3600,
      savedAt: DateTime.now().subtract(const Duration(hours: 3)),
    );
    expect(base.isExpired, isTrue);

    // 一次新的 ResumeAck 到达：TTL 与 savedAt 都要刷新，否则即使服务端刚
    // 续过期，客户端仍会拿着旧的 savedAt 误判过期。
    final refreshed = base.copyWith(
      serverTtlSecs: 604800,
      savedAt: DateTime.now(),
    );
    expect(refreshed.isExpired, isFalse);
  });

  test('aqtTabId 走 SQL 列往返 —— 它是协议元数据，不是凭据', () async {
    // RESUME 帧靠这个数字点名恢复哪个 tab，服务端查不到就判 TabGone。
    // 它一度被放进 secure storage 的第二个 key，那样有两个问题：Keychain
    // 走 IPC 慢，且两个 key 之间没有事务性 —— token 写成功而它写失败，
    // 就得到「有凭据但不知道恢复哪个 tab」的状态。
    await repo.save(AqtSessionState(
      tabId: 'tab-x',
      aqtTabId: 7,
      port: 4433,
      spki: const [1, 2, 3],
      sessionToken: List.filled(32, 3),
      scrollbackCursor: 0,
      serverTtlSecs: 604800,
      savedAt: DateTime.now(),
    ));
    expect((await repo.load('tab-x'))!.aqtTabId, 7);
    expect(secure.keys.length, 1,
        reason: 'secure storage 只该放 token 这一个凭据');
  });
}

class FakeSecureStore implements AqtSecureStore {
  final Map<String, String> _m = {};
  Iterable<String> get keys => _m.keys;
  @override
  Future<void> write(String k, String v) async => _m[k] = v;
  @override
  Future<String?> read(String k) async => _m[k];
  @override
  Future<void> delete(String k) async => _m.remove(k);
}

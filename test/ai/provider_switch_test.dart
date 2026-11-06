import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:flyterm/ai/ai_provider_service.dart';
import 'package:flyterm/ai/provider_switch.dart';
import 'package:dio/io.dart';
import 'package:flyterm/ai/providers/openai_provider.dart';
import 'package:flyterm/ai/providers/provider_http.dart';
import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/ai_provider_config.dart';
import 'package:flyterm/data/repositories/ai_provider_repository.dart';
import 'package:flyterm/data/secure_storage.dart';

/// `switchProvider` 里有一条**顺序不变量**，此前零测试覆盖。
///
/// `debugCountConnections` 必须在 `AIProviderFactory.create()` **之前**设置。
/// 原因写在 `provider_http.dart`：Dio 的 `IOHttpClientAdapter` 会缓存
/// HttpClient 实例，之后再翻转这个开关对已构造的 provider 无效。
///
/// 这条约束的危险之处在于**违反它不会有任何报错**：只是连接计数永远为 0，
/// 表现为「诊断功能坏了」，而不是「代码错了」。靠读代码维持不变量是不够的
/// —— 后来者重排两行（比如把赋值挪到 create 之后，看着更「整洁」）就断了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late AIProviderRepository repo;
  late SecureStorageService storage;
  late AIProviderService svc;

  setUp(() async {
    // `TestWidgetsFlutterBinding` 会装一个拦截真实 HTTP 的 override
    // （“all HTTP requests will return status code 400”）。下面的顺序
    // 不变量测试靠**真发一次连接**来观察 factory 是否装上，所以要把那个
    // override 拆掉。storage / prefs 的 mock 仍然需要 binding，两件事不冲突。
    final savedOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = savedOverrides);

    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    db = await AppDatabase.open(inMemory: true);
    repo = AIProviderRepository(db);
    storage = SecureStorageService();
    svc = AIProviderService(await SharedPreferences.getInstance());
  });

  tearDown(() async {
    await db.close();
    debugCountConnections = false;
  });

  AIProviderConfig cfg({String type = 'openai'}) => AIProviderConfig(
        id: 'p1',
        name: 'n',
        type: type,
        model: 'm',
      );

  test('切换时把 debugOverlay 同步到 debugCountConnections', () async {
    debugCountConnections = false;

    await switchProvider(
      config: cfg(),
      repo: repo,
      storage: storage,
      svc: svc,
      debugOverlay: true,
    );

    expect(debugCountConnections, isTrue);
  });

  test('debugOverlay 关闭时同步关闭', () async {
    debugCountConnections = true;

    await switchProvider(
      config: cfg(),
      repo: repo,
      storage: storage,
      svc: svc,
      debugOverlay: false,
    );

    expect(debugCountConnections, isFalse);
  });

  /// `debugOverlay` 要同步到 `debugCountConnections`，切模型是唯一的运行期
  /// 生效路径（developer mode 打开不会让已存在的 provider 改变行为）。
  ///
  /// **关于“必须在 create 之前设置”那条注释：已证实当前实现下顺序无关。**
  /// `createProviderDio` 把 `IOHttpClientAdapter(createHttpClient: ...)` 的
  /// 回调写成**惰性**的 —— 它在第一次真发请求时才跑，那时开关早已置位，
  /// 跟赋值在 create 前还是后无关（实测：两种顺序 count 都是 1）。
  ///
  /// 保留这条测试是为了钉住**行为**（切完真的能计数），而不是钉住顺序 ——
  /// 因为那个顺序现在不承载任何语义。若将来把 `createHttpClient` 改成
  /// 急构（或复用已缓存的 HttpClient），顺序才会真的变得关键，那时这条
  /// 应该升级成真正的顺序断言。当前不要写一条会被变异测试戳穿的假断言。
  test('切换后新 provider 的连接计数真的生效', () async {
    debugCountConnections = false;
    debugNewConnectionCount = 0;

    await switchProvider(
      config: cfg(),
      repo: repo,
      storage: storage,
      svc: svc,
      debugOverlay: true,
    );

    final provider = svc.provider! as OpenAIProvider;
    final adapter = provider.debugDio.httpClientAdapter as IOHttpClientAdapter;
    final client = adapter.createHttpClient!();
    addTearDown(client.close);
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:1'));
      await req.close();
    } catch (_) {
      // 连不上是预期的 —— 要的是 connectionFactory 被调用过。
    }

    expect(debugNewConnectionCount, equals(1),
        reason: 'debugOverlay 开了但连接计数没动 —— 开关没同步到 '
            'debugCountConnections，或 provider 没走 createProviderDio');
  });

  /// 与上一条对照：不开 developer mode 时不该计数。两条合起来才区分了
  /// 「装了 factory」和「没装」。
  test('debugOverlay 关闭时连接不计数', () async {
    debugCountConnections = true; // 先打开，验证确实被关掉
    debugNewConnectionCount = 0;

    await switchProvider(
      config: cfg(),
      repo: repo,
      storage: storage,
      svc: svc,
      debugOverlay: false,
    );

    final provider = svc.provider! as OpenAIProvider;
    final adapter = provider.debugDio.httpClientAdapter as IOHttpClientAdapter;
    final client = adapter.createHttpClient!();
    addTearDown(client.close);
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:1'));
      await req.close();
    } catch (_) {}

    expect(debugNewConnectionCount, equals(0));
  });

  test('切换会把配置持久化为默认 —— 下次进面板还是这个模型', () async {
    // 真实前置：配置条目先由「新建/编辑」页 insert 进库，之后才会被切到。
    // `switchProvider` 只做 update —— 对一条不存在的行是 no-op。
    await repo.insert(cfg());

    await switchProvider(
      config: cfg(),
      repo: repo,
      storage: storage,
      svc: svc,
    );

    final saved = await repo.findDefault();
    expect(saved, isNotNull);
    expect(saved!.id, equals('p1'));
    expect(saved.isDefault, isTrue);
  });

  test('ollama 不需要 key 也可用；其余类型没 key 不可用', () async {
    expect(await providerUsable(cfg(type: 'ollama'), storage), isTrue);
    expect(await providerUsable(cfg(type: 'openai'), storage), isFalse);

    await storage.saveAIKey('p1', 'sk-x');
    expect(await providerUsable(cfg(type: 'openai'), storage), isTrue);
  });
}

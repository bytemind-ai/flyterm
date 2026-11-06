import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:flyterm/data/database.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/data/models/tunnel_config.dart';
import 'package:flyterm/data/repositories/server_repository.dart';
import 'package:flyterm/data/repositories/tunnel_repository.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/tunnel/tunnel_entry.dart';
import 'package:flyterm/tunnel/tunnel_manager.dart';
import 'package:flyterm/ui/tunnel/tunnel_list_screen.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  late Database db;
  late ServerRepository serverRepo;
  late TunnelRepository tunnelRepo;
  late Server server;

  setUp(() async {
    db = await AppDatabase.open(inMemory: true);
    serverRepo = ServerRepository(db);
    tunnelRepo = TunnelRepository(db);
    server = Server(
      id: const Uuid().v4(),
      name: 'db-prod',
      host: 'db.example.com',
      port: 22,
      username: 'root',
      authType: 'password',
    );
    await serverRepo.insert(server);
    await tunnelRepo.insert(TunnelConfig(
      id: const Uuid().v4(),
      serverId: server.id,
      direction: TunnelDirection.local,
      localPort: 3306,
      remoteHost: 'localhost',
      remotePort: 3306,
      label: 'MySQL',
      autoStart: false,
    ));
  });

  tearDown(() async {
    await db.close();
  });

  Future<TunnelManager> seededManager() async {
    // autoStart=false → restoreFromDb 只把条目加进来，不建 SSH 连接。
    final mgr = TunnelManager(repository: tunnelRepo, serverRepo: serverRepo);
    await mgr.restoreFromDb(serverRepo, null);
    return mgr;
  }

  Widget app(TunnelManager mgr) => MultiProvider(
        providers: [ChangeNotifierProvider<TunnelManager>.value(value: mgr)],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: TunnelListView()),
        ),
      );

  testWidgets('长按隧道行弹动作面板；行尾 ⋮ 已移除', (tester) async {
    late TunnelManager mgr;
    // 只在 runAsync 里做真实异步（DB）；手势与 pump 放到外面，
    // 否则长按手势在 runAsync 下会退化成 tap。
    await tester.runAsync(() async {
      mgr = await seededManager();
    });
    await tester.pumpWidget(app(mgr));
    await tester.pump();

    // 行已渲染，且行尾不再有 ⋮（与首页服务器行一致）。
    expect(find.text('MySQL'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);

    await tester.longPress(find.text('MySQL'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 面板项：已停止 → "启动"；已保存 → 自动连接 / 编辑 / 删除。
    expect(find.text('启动'), findsOneWidget);
    expect(find.text('启用自动连接'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flyterm/l10n/app_localizations.dart';
import 'package:flyterm/ui/ai/mention.dart';
import 'package:flyterm/ui/ai/widgets/mention_overlay.dart';
import 'package:flyterm/ai/agent/builtin_skill_manager.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/data/models/favorite_command.dart';
import 'package:flyterm/data/models/server.dart';
import 'package:flyterm/sftp/sftp_entry.dart';
import 'package:flyterm/ui/ai/widgets/mention_field.dart';

/// `MentionField` 从 provider 里读内置技能，拼在用户技能之前。
///
/// **刻意不 `load()`**：这个文件测的是补全的渲染、匹配与插入，内置技能空着
/// 就行 —— 保持既有用例的候选集不变。「内置技能进补全且排在最前」那件事由
/// `test/ui/ai/mention_builtin_test.dart` 单独钉住。
late BuiltinSkillManager _builtin;

/// 裹一层 MaterialApp + l10n delegate。本文件所有用例共用。
Widget _host(Widget child) => ChangeNotifierProvider.value(
      value: _builtin,
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _builtin = BuiltinSkillManager(await SharedPreferences.getInstance());
  });

  group('MentionOverlay', () {
    testWidgets('同类聚在一起，靠图标区分而不是分组标题', (t) async {
      await t.pumpWidget(_host(MentionOverlay(
        candidates: const [
          MentionCandidate(
              kind: MentionKind.server,
              label: 'prod-1',
              insertText: 'prod-1',
              subtitle: '10.0.0.1'),
          MentionCandidate(
              kind: MentionKind.skill,
              label: 'nginx-tuning',
              insertText: 'nginx-tuning'),
        ],
        onPick: (_) {},
      )));

      // 分组标题已去掉（与每条的类型图标是同一件事，而两行标题要吃掉
      // 240px 上限的五分之一）。类型现在只由图标表达。
      expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
      expect(find.byIcon(Icons.school_outlined), findsOneWidget);
      expect(find.text('prod-1'), findsOneWidget);
      expect(find.text('10.0.0.1'), findsOneWidget);
      expect(find.text('nginx-tuning'), findsOneWidget);
    });

    testWidgets('点条目回调 onPick 并带上那条候选', (t) async {
      MentionCandidate? picked;
      await t.pumpWidget(_host(MentionOverlay(
        candidates: const [
          MentionCandidate(
              kind: MentionKind.skill,
              label: 'pg-restore',
              insertText: 'pg-restore'),
        ],
        onPick: (c) => picked = c,
      )));

      await t.tap(find.text('pg-restore'));
      await t.pump();
      expect(picked?.insertText, 'pg-restore');
    });

    testWidgets('fileState = unavailable 时显示提示，且不影响本地类', (t) async {
      await t.pumpWidget(_host(MentionOverlay(
        candidates: const [
          MentionCandidate(
              kind: MentionKind.skill, label: 'a', insertText: 'a'),
        ],
        fileState: MentionFileState.unavailable,
        onPick: (_) {},
      )));

      expect(find.text('文件浏览不可用'), findsOneWidget);
      expect(find.text('a'), findsOneWidget);
    });

    testWidgets('fileState = loading 时显示进度条', (t) async {
      await t.pumpWidget(_host(MentionOverlay(
        candidates: const [],
        fileState: MentionFileState.loading,
        onPick: (_) {},
      )));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('errorText 渲染成一行，不吞掉候选', (t) async {
      await t.pumpWidget(_host(MentionOverlay(
        candidates: const [
          MentionCandidate(
              kind: MentionKind.skill, label: 'a', insertText: 'a'),
        ],
        errorText: '读取目录失败：permission denied',
        onPick: (_) {},
      )));
      expect(find.text('读取目录失败：permission denied'), findsOneWidget);
      expect(find.text('a'), findsOneWidget);
    });

    testWidgets('moreCount > 0 时显示「还有 N 条」', (t) async {
      await t.pumpWidget(_host(MentionOverlay(
        candidates: const [],
        moreCount: 12,
        onPick: (_) {},
      )));
      expect(find.textContaining('还有 12 条'), findsOneWidget);
    });
  });

  // ── MentionField ─────────────────────────────────────────────────────────
  Server srv(String name) => Server(
        id: 'id-$name',
        name: name,
        host: '10.0.0.9',
        port: 22,
        username: 'root',
        authType: 'password',
      );

  SftpEntry entry(String name, String parent, {bool isDir = false}) =>
      SftpEntry(
        name: name,
        path: parent == '/' ? '/$name' : '$parent/$name',
        isDir: isDir,
        size: 0,
        modTime: DateTime.fromMillisecondsSinceEpoch(0),
      );

  group('MentionField —— 本地三类', () {
    testWidgets('敲 @ 弹出浮层，且不发任何远端请求', (t) async {
      final ctrl = TextEditingController();
      var listCalls = 0;

      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: [srv('prod-1')],
        skills: const [
          SkillIndexEntry(name: 'nginx-tuning', description: '调 worker')
        ],
        commands: const [],
        hasOtherServers: true,
        listRemoteDir: (dir, {String? serverId}) async {
          listCalls++;
          return const [];
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@');
      await t.pump();

      // `@` 只出服务器 —— 技能与收藏命令已经搬去 `/` 了（本次触发符拆分）。
      expect(find.byType(MentionOverlay), findsOneWidget);
      expect(find.text('prod-1'), findsOneWidget);
      expect(find.text('nginx-tuning'), findsNothing);
      expect(listCalls, 0,
          reason: '敲 @ 的那一刻只列本地三类 —— 文件要等一个 / 才拉');
    });

    testWidgets('点候选写回输入框、不补空格、浮层不关', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: [srv('staging')],
        skills: const [],
        commands: const [],
        hasOtherServers: true,
        listRemoteDir: (dir, {String? serverId}) async => const [],
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '看下 @sta');
      await t.pump();
      await t.tap(find.text('staging'));
      await t.pump();

      // 服务器候选**不补空格**、浮层**不关**——这是让 `@机器:路径` 那条路
      // 走得通的机制（补了空格 `parseMention` 就不再 active）。
      expect(ctrl.text, '看下 @staging');
      expect(find.byType(MentionOverlay), findsOneWidget);
    });

    testWidgets('没有 @ 时浮层不存在', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: [srv('prod-1')],
        skills: const [],
        commands: const [],
        hasOtherServers: true,
        listRemoteDir: (dir, {String? serverId}) async => const [],
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), 'restart nginx');
      await t.pump();
      expect(find.byType(MentionOverlay), findsNothing);
    });

    testWidgets('hasOtherServers 为 false 时浮层里没有服务器分组', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: [srv('prod-1')],
        skills: const [
          SkillIndexEntry(name: 'nginx-tuning', description: '调 worker')
        ],
        commands: const [],
        hasOtherServers: false,
        listRemoteDir: (dir, {String? serverId}) async => const [],
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@');
      await t.pump();
      // 断言的是**服务器条目本身**不出现，不是分组标题——标题已经删掉了，
      // 对它断言 findsNothing 是恒真的，守不住任何东西。
      expect(find.text('prod-1'), findsNothing);
      expect(find.byIcon(Icons.dns_outlined), findsNothing);
      // 技能不再挂在 `@` 下（已搬去 `/`），`hasOtherServers` 对它没有影响。
      expect(find.text('nginx-tuning'), findsNothing);
    });
  });

  group('MentionField —— 文件分组', () {
    testWidgets('打到含 / 才发请求，且连续打字只发一次', (t) async {
      final ctrl = TextEditingController();
      final calls = <String>[];

      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async {
          calls.add(dir);
          return [entry('nginx', '/etc', isDir: true), entry('hosts', '/etc')];
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      // 逐字符输入，模拟真实打字：防抖必须把这几下合成一次请求。
      await t.enterText(find.byType(TextField), '@/e');
      await t.pump(const Duration(milliseconds: 80));
      await t.enterText(find.byType(TextField), '@/et');
      await t.pump(const Duration(milliseconds: 80));
      await t.enterText(find.byType(TextField), '@/etc/');
      // 推过防抖窗口（250ms）再让 Future 落地。
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(calls.first, '/etc',
          reason: '三次输入合成一次请求，且目录取 / 之前那段');
      // ⚠️ 不断言 `calls == ['/etc']`：单层加载落地后，后台索引会接着往下
      // 递归（这个 fixture 对任何路径都返回一个叫 nginx 的目录，所以会多一层）。
      // 防抖保证的是「用户那一下只发一发」，所以断言落在第一发上。
      expect(calls.where((d) => d == '/etc'), hasLength(1),
          reason: '同一目录不得因连续打字被列两次');
      expect(find.text('nginx'), findsOneWidget);
      expect(find.text('hosts'), findsOneWidget);
    });

    testWidgets('同一目录再过滤不重发请求（缓存命中）', (t) async {
      final ctrl = TextEditingController();
      var calls = 0;

      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async {
          calls++;
          return [entry('nginx.conf', '/etc'), entry('hosts', '/etc')];
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@/etc/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(calls, 1);

      await t.enterText(find.byType(TextField), '@/etc/ngi');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(calls, 1, reason: '同一目录只是换前缀 —— 本地过滤即可');
      expect(find.text('nginx.conf'), findsOneWidget);
      expect(find.text('hosts'), findsNothing);
    });

    testWidgets('点目录是下钻：再发一次请求且浮层不关', (t) async {
      final ctrl = TextEditingController();
      final calls = <String>[];

      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async {
          calls.add(dir);
          if (dir == '/etc') return [entry('nginx', '/etc', isDir: true)];
          return [entry('nginx.conf', '/etc/nginx')];
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@/etc/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      await t.tap(find.text('nginx'));
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(calls, ['/etc', '/etc/nginx']);
      expect(ctrl.text, '@/etc/nginx/', reason: '下钻不补空格，否则浮层会关');
      expect(find.byType(MentionOverlay), findsOneWidget);
      expect(find.text('nginx.conf'), findsOneWidget);
    });

    testWidgets('点文件插入绝对路径并关闭浮层', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async => [entry('nginx.conf', '/etc/nginx')],
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@/etc/nginx/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      await t.tap(find.text('nginx.conf'));
      await t.pump();

      expect(ctrl.text, '@/etc/nginx/nginx.conf ');
      expect(find.byType(MentionOverlay), findsNothing);
    });

    testWidgets('~ 起头先解析成绝对路径，再拿绝对路径去 listdir', (t) async {
      final ctrl = TextEditingController();
      final listed = <String>[];
      final resolved = <String>[];

      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async {
          listed.add(dir);
          return [entry('id_rsa.pub', '/root/.ssh')];
        },
        resolveRemotePath: (p, {String? serverId}) async {
          resolved.add(p);
          return '/root/.ssh';
        },
      )));

      await t.enterText(find.byType(TextField), '@~/.ssh/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(resolved, ['~/.ssh']);
      expect(listed, ['/root/.ssh'],
          reason: '不能拿未展开的 ~/… 去 listdir —— 那会得到「目录不存在」的二次错误');
      expect(find.text('id_rsa.pub'), findsOneWidget);
    });
  });

  group('MentionField —— 错误边界', () {
    testWidgets('listRemoteDir 为 null：无文件分组，本地三类照常可选', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [
          SkillIndexEntry(name: 'nginx-tuning', description: '调 worker')
        ],
        commands: const [],
        listRemoteDir: null,
        resolveRemotePath: null,
      )));

      await t.enterText(find.byType(TextField), '@/etc/');
      await t.pump(const Duration(milliseconds: 300));

      expect(find.text('文件浏览不可用'), findsOneWidget);
      expect(find.byType(MentionOverlay), findsOneWidget);
    });

    testWidgets('listRemoteDir 抛异常：显示错误行，浮层不关、不崩', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async => throw Exception('permission denied'),
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@/root/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(find.textContaining('permission denied'), findsOneWidget);
      expect(find.byType(MentionOverlay), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('resolveRemotePath 缺失时提示用绝对路径，不拿 ~ 去 listdir',
        (t) async {
      final ctrl = TextEditingController();
      final listed = <String>[];
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async {
          listed.add(dir);
          return const [];
        },
        resolveRemotePath: null,
      )));

      await t.enterText(find.byType(TextField), '@~/.ssh/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(find.textContaining('绝对路径'), findsOneWidget);
      expect(listed, isEmpty);
    });

    testWidgets('resolveRemotePath 抛异常时提示用绝对路径，不拿 ~ 去 listdir',
        (t) async {
      // 错误边界：resolveRemotePath 抛异常或超时（~/ 展开失败）
      // 与 resolveRemotePath == null 同样处理——退化为「不可解析」，提示改用
      // 绝对路径，而不是走通用的 mentionDirLoadFailed 文案。
      final ctrl = TextEditingController();
      final listed = <String>[];
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async {
          listed.add(dir);
          return const [];
        },
        resolveRemotePath: (p, {String? serverId}) async => throw Exception('timeout'),
      )));

      await t.enterText(find.byType(TextField), '@~/.ssh/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(find.textContaining('绝对路径'), findsOneWidget);
      expect(listed, isEmpty,
          reason: '不能拿未展开的 ~/… 去 listdir —— 那会得到一个「目录不存在」的二次错误');
    });

    testWidgets('超过渲染上限时显示「还有 N 条」', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async =>
            [for (var i = 0; i < 62; i++) entry('f$i', '/var/log')],
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@/var/log/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(find.textContaining('还有 12 条'), findsOneWidget);
    });

    testWidgets('旧请求后到不覆盖新目录的结果', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async {
          // 第一个目录故意慢：它落地时用户已经打到第二个目录了。
          if (dir == '/slow') {
            await Future<void>.delayed(const Duration(milliseconds: 400));
            return [entry('STALE', '/slow')];
          }
          return [entry('FRESH', '/fast')];
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@/slow/');
      await t.pump(const Duration(milliseconds: 300));
      await t.enterText(find.byType(TextField), '@/fast/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle(const Duration(milliseconds: 600));

      expect(find.text('FRESH'), findsOneWidget);
      expect(find.text('STALE'), findsNothing);
    });

    testWidgets('cwd 为 null 时 ./ 提示用绝对路径，且不发请求', (t) async {
      final ctrl = TextEditingController();
      final listed = <String>[];
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        cwd: null,
        listRemoteDir: (dir, {String? serverId}) async {
          listed.add(dir);
          return const [];
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@./log/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(find.textContaining('绝对路径'), findsOneWidget);
      expect(listed, isEmpty);
    });

    testWidgets('cwd 存在时 ./ 以它为基准，不走 resolveRemotePath', (t) async {
      final ctrl = TextEditingController();
      final listed = <String>[];
      var resolverCalls = 0;
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        cwd: '/srv/app',
        listRemoteDir: (dir, {String? serverId}) async {
          listed.add(dir);
          return [entry('app.log', '/srv/app/log')];
        },
        resolveRemotePath: (p, {String? serverId}) async {
          resolverCalls++;
          return p;
        },
      )));

      await t.enterText(find.byType(TextField), '@./log/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(listed, ['/srv/app/log']);
      expect(resolverCalls, 0,
          reason: 'absolutePath(".") 返回的是 SFTP 会话初始目录，与终端 cwd 无关');
      expect(find.text('app.log'), findsOneWidget);
    });

    testWidgets('IME composing 期间不发远端请求', (t) async {
      final ctrl = TextEditingController();
      var calls = 0;
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async {
          calls++;
          return const [];
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      // 拼音输入法未确认的中间态：composing 区间非空。
      ctrl.value = const TextEditingValue(
        text: '@/etc/ngi',
        selection: TextSelection.collapsed(offset: 9),
        composing: TextRange(start: 6, end: 9),
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();

      expect(calls, 0, reason: '拼音串的每个字母都会触发 listener，中间态不该发请求');
      expect(find.byType(MentionOverlay), findsOneWidget);
    });
  });

  group('MentionField —— @机器:路径 跨机浏览', () {
    testWidgets('打服务器名的全程（@ → @w → … → @web-02）一个远端请求都不发',
        (t) async {
      final ctrl = TextEditingController();
      var calls = 0;

      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: [srv('web-01'), srv('web-02')],
        skills: const [],
        commands: const [],
        hasOtherServers: true,
        listRemoteDir: (dir, {String? serverId}) async {
          calls++;
          return const [];
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      for (final s in ['@', '@w', '@we', '@web', '@web-0', '@web-02']) {
        await t.enterText(find.byType(TextField), s);
        await t.pump(const Duration(milliseconds: 50));
      }

      expect(calls, 0, reason: '冒号之前——哪怕已经把机器名打全了——都不建连');
      expect(find.text('web-02'), findsOneWidget);
    });

    testWidgets('打出冒号之后才发请求，且 serverId 传的是那台机的 id', (t) async {
      final ctrl = TextEditingController();
      final calls = <({String dir, String? serverId})>[];

      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: [srv('web-01'), srv('web-02')],
        skills: const [],
        commands: const [],
        hasOtherServers: true,
        listRemoteDir: (dir, {String? serverId}) async {
          calls.add((dir: dir, serverId: serverId));
          return [entry('nginx', '/root', isDir: true)];
        },
        resolveRemotePath: (p, {String? serverId}) async => '/root',
      )));

      await t.enterText(find.byType(TextField), '@web-02');
      await t.pump(const Duration(milliseconds: 50));
      expect(calls, isEmpty, reason: '冒号之前不该发请求');

      await t.enterText(find.byType(TextField), '@web-02:');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      // 第一发是单层加载那一次，后面的都是后台索引（同一个 serverId）。
      expect(calls, isNotEmpty);
      expect(calls.first.dir, '/root');
      expect(calls.first.serverId, 'id-web-02',
          reason: 'serverId 必须是 web-02 这台机的 id，不是当前会话那台机');
      expect(calls.every((c) => c.serverId == 'id-web-02'), isTrue,
          reason: '索引也不得把请求漏到别的机器上去');
    });

    testWidgets('跨机文件候选的 insertText 带机器名前缀', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: [srv('web-01'), srv('web-02')],
        skills: const [],
        commands: const [],
        hasOtherServers: true,
        listRemoteDir: (dir, {String? serverId}) async =>
            [entry('nginx.conf', '/var')],
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@web-02:/var/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      await t.tap(find.text('nginx.conf'));
      await t.pump();

      expect(ctrl.text, startsWith('@web-02:'),
          reason: '插出来的路径必须还指向 web-02，否则会静默写到当前机');
      expect(ctrl.text, '@web-02:/var/nginx.conf ');
    });

    testWidgets('跨机 listRemoteDir 抛异常：只出一行错误文案，不弹任何对话框',
        (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: [srv('web-02')],
        skills: const [],
        commands: const [],
        hasOtherServers: true,
        listRemoteDir: (dir, {String? serverId}) async =>
            throw Exception('connect failed'),
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@web-02:/var/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(find.textContaining('connect failed'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('机器名匹配不上任何服务器时零请求，提示没有这台机器', (t) async {
      final ctrl = TextEditingController();
      var calls = 0;
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: [srv('web-01')],
        skills: const [],
        commands: const [],
        hasOtherServers: true,
        listRemoteDir: (dir, {String? serverId}) async {
          calls++;
          return const [];
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@nope:/var/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(calls, 0);
      // `find.textContaining` 也会命中输入框里回显的原文 `@nope:/var/`——
      // 用精确匹配只认错误提示行本身。
      expect(find.text('没有这台机器：nope'), findsOneWidget);
    });

    testWidgets('文件候选缓存按 serverId 隔离 —— 两台机器都发请求', (t) async {
      // 这条守的是一个后果极隐蔽的 bug：两台机器上都有 /var/log，缓存键不带
      // serverId 会让第二台机直接命中第一台的缓存——用户看到的是另一台机器
      // 的文件，而路径看起来完全正确。
      final ctrl = TextEditingController();
      final calls = <({String dir, String? serverId})>[];

      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: [srv('web-01'), srv('web-02')],
        skills: const [],
        commands: const [],
        hasOtherServers: true,
        listRemoteDir: (dir, {String? serverId}) async {
          calls.add((dir: dir, serverId: serverId));
          return [entry('log', dir, isDir: true)];
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@web-01:/var/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      await t.enterText(find.byType(TextField), '@web-02:/var/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      // 每台机都必须对 /var 各发一次 —— 缓存键不带 serverId 时，第二台机
      // 会直接命中第一台的，用户看到的是另一台机器的文件而路径看起来
      // 完全正确。后台索引会额外递归出更多请求（这个 fixture 对任何路径
      // 都返回一个叫 log 的目录），所以按 serverId 分组断言。
      bool hasVar(String id) => calls.any(
          (c) => c.dir == '/var' && c.serverId == id);
      expect(hasVar('id-web-01'), isTrue,
          reason: '两台机器同一路径都要各发一次请求 —— 缓存键必须带 serverId');
      expect(hasVar('id-web-02'), isTrue,
          reason: 'web-02 不得命中 web-01 的缓存');
      expect(calls.where((c) => c.dir == '/var' && c.serverId == 'id-web-01'),
          hasLength(1));
      expect(calls.where((c) => c.dir == '/var' && c.serverId == 'id-web-02'),
          hasLength(1));
    });
  });

  group('MentionField —— 后台索引（一次取全，下钻零往返）', () {
    /// 一棵两层的假树：`/etc` 下有 `nginx/` 和 `hosts`，`/etc/nginx` 下有
    /// `nginx.conf`。未登记的目录返回空。
    List<SftpEntry> tree(String dir) => switch (dir) {
          '/etc' => [entry('nginx', '/etc', isDir: true), entry('hosts', '/etc')],
          '/etc/nginx' => [entry('nginx.conf', '/etc/nginx')],
          _ => const [],
        };

    testWidgets('索引建好后，点进子目录**不再发请求**', (t) async {
      final ctrl = TextEditingController();
      final calls = <String>[];
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async {
          calls.add(dir);
          return tree(dir);
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@/etc/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      // 索引已经把 /etc/nginx 也列了。
      expect(calls, containsAll(['/etc', '/etc/nginx']));
      final beforeDrill = calls.length;

      await t.tap(find.text('nginx'));
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      // **本项的全部价值就在这一行。** 逐层模式下这里必然多一次 /etc/nginx。
      expect(calls.length, beforeDrill,
          reason: '索引命中的目录下钻必须零往返');
      expect(find.text('nginx.conf'), findsOneWidget);
      expect(ctrl.text, '@/etc/nginx/');
    });

    testWidgets('索引命中后，同一个目录换前缀也是零往返', (t) async {
      final ctrl = TextEditingController();
      final calls = <String>[];
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [],
        commands: const [],
        listRemoteDir: (dir, {String? serverId}) async {
          calls.add(dir);
          return tree(dir);
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '@/etc/');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      final n = calls.length;

      await t.enterText(find.byType(TextField), '@/etc/ng');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();

      expect(calls.length, n, reason: '同一目录只是换过滤前缀');
      expect(find.text('nginx'), findsOneWidget);
    });
  });

  group('MentionField —— / 触发符（技能与命令）', () {
    testWidgets('/ 只出技能与命令，不出服务器，且零远端请求', (t) async {
      final ctrl = TextEditingController();
      var calls = 0;
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: [srv('web-01')],
        skills: const [
          SkillIndexEntry(name: 'disk-check', description: '排查磁盘')
        ],
        commands: const [
          FavoriteCommand(
              id: 'c1',
              name: 'tail-err',
              command: 'tail -f err.log',
              sortOrder: 0,
              aiEnabled: true),
        ],
        hasOtherServers: true,
        listRemoteDir: (dir, {String? serverId}) async {
          calls++;
          return const [];
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '/');
      await t.pump();

      expect(find.text('disk-check'), findsOneWidget);
      expect(find.text('tail-err'), findsOneWidget);
      expect(find.text('web-01'), findsNothing);
      expect(calls, 0);
    });

    testWidgets('消息以路径开头（/var/log/nginx）时浮层不出现', (t) async {
      final ctrl = TextEditingController();
      var calls = 0;
      await t.pumpWidget(_host(MentionField(
        ctrl: ctrl,
        onSubmit: () {},
        servers: const [],
        skills: const [
          SkillIndexEntry(name: 'disk-check', description: '排查磁盘')
        ],
        commands: const [],
        hasOtherServers: false,
        listRemoteDir: (dir, {String? serverId}) async {
          calls++;
          return const [];
        },
        resolveRemotePath: (p, {String? serverId}) async => p,
      )));

      await t.enterText(find.byType(TextField), '/var/log/nginx');
      await t.pump();

      expect(find.byType(MentionOverlay), findsNothing,
          reason: '路径匹配不到任何技能/命令，浮层必须关，否则会一直赖在屏幕上');
      expect(calls, 0);
    });
  });

  group('MentionField —— 句中的 / 触发符', () {
    Widget host({required TextEditingController ctrl}) =>
        _host(MentionField(
          ctrl: ctrl,
          onSubmit: () {},
          servers: const [],
          skills: const [
            SkillIndexEntry(name: 'disk-check', description: '排查磁盘')
          ],
          commands: const [
            FavoriteCommand(
                id: 'c1',
                name: 'tail-err',
                command: 'tail -f err.log',
                sortOrder: 0,
                aiEnabled: true),
          ],
          hasOtherServers: false,
          listRemoteDir: (dir, {String? serverId}) async => const [],
          resolveRemotePath: (p, {String? serverId}) async => p,
        ));

    testWidgets('句中精确命中技能名时弹浮层', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(host(ctrl: ctrl));

      await t.enterText(find.byType(TextField), '磁盘满了 /disk-check');
      await t.pump();

      expect(find.text('disk-check'), findsOneWidget);
    });

    testWidgets('句中只打了前缀时**不**弹 —— 这正是与消息开头的差别', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(host(ctrl: ctrl));

      // 消息开头打 `/disk` 会弹（「挑一个」的入口）；句中不行，因为
      // `/disk` 和 `/var` 一类路径段在语法上分不开。
      await t.enterText(find.byType(TextField), '磁盘满了 /disk');
      await t.pump();

      expect(find.byType(MentionOverlay), findsNothing);
    });

    testWidgets('句中路径不弹浮层 —— 运维消息里最常见的误报源', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(host(ctrl: ctrl));

      for (final text in ['看下 /var/log', 'ls /etc', '把 /a 拷到 /b']) {
        await t.enterText(find.byType(TextField), text);
        await t.pump();
        expect(find.byType(MentionOverlay), findsNothing, reason: text);
      }
    });

    testWidgets('句中精确命中收藏命令名时弹浮层', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(host(ctrl: ctrl));

      await t.enterText(find.byType(TextField), '帮我 /tail-err');
      await t.pump();

      expect(find.text('tail-err'), findsOneWidget);
    });

    testWidgets('句中打中后点候选，插回原位置并补空格', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(host(ctrl: ctrl));

      await t.enterText(find.byType(TextField), '磁盘满了 /disk-check');
      await t.pump();
      await t.tap(find.text('disk-check'));
      await t.pump();

      expect(ctrl.text, '磁盘满了 /disk-check ');
      expect(find.byType(MentionOverlay), findsNothing);
    });

    testWidgets('消息开头仍然照弹（回归：句中那一档没把开头掐掉）', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(host(ctrl: ctrl));

      // 开头只打一个「/」就该列出全部——不像句中要求精确命中。
      await t.enterText(find.byType(TextField), '/');
      await t.pump();

      expect(find.text('disk-check'), findsOneWidget);
      expect(find.text('tail-err'), findsOneWidget);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/ai/mention.dart';
import 'package:flyterm/ai/agent/skill.dart';
import 'package:flyterm/data/models/favorite_command.dart';
import 'package:flyterm/data/models/server.dart';

Server _server(String name, {String host = '10.0.0.1'}) => Server(
      id: 'id-$name',
      name: name,
      host: host,
      port: 22,
      username: 'root',
      authType: 'password',
    );

const _skills = [
  SkillIndexEntry(name: 'nginx-tuning', description: '调 worker 数'),
  SkillIndexEntry(name: 'pg-restore', description: '从备份恢复'),
];

const _commands = [
  FavoriteCommand(
      id: 'c1', name: 'restart-api', command: 'systemctl restart api',
      sortOrder: 0, aiEnabled: true),
];

void main() {
  group('parseMention', () {
    test('行首的 @ 触发，query 为其后内容', () {
      final q = parseMention('@ngi', 4);
      expect(q, isNotNull);
      expect(q!.query, 'ngi');
      expect(q.start, 0);
      expect(q.end, 4);
    });

    test('空白之后的 @ 触发', () {
      final q = parseMention('看下 @prod', 8);
      expect(q, isNotNull);
      expect(q!.query, 'prod');
      expect(q.start, 3);
    });

    test('@ 后为空也算 active —— 此时该列本地三类', () {
      final q = parseMention('@', 1);
      expect(q, isNotNull);
      expect(q!.query, '');
    });

    test('user@host 不触发 —— @ 前面是字母', () {
      // 邮箱与 SSH 写法是运维日常输入，误触发会让浮层不停乱弹。
      expect(parseMention('root@10.0.0.1', 13), isNull);
      expect(parseMention('me@example.com', 14), isNull);
    });

    test('多个 @ 取离光标最近的那个', () {
      final q = parseMention('@a @b', 5);
      expect(q, isNotNull);
      expect(q!.query, 'b');
      expect(q.start, 3);
    });

    test('@ 与光标之间出现空白 → 不再 active', () {
      expect(parseMention('@a b', 4), isNull);
      expect(parseMention('@a\nb', 4), isNull);
    });

    test('光标为 0 时不触发（不会越界）', () {
      expect(parseMention('@abc', 0), isNull);
    });

    test('光标在 @ 左侧时不触发', () {
      expect(parseMention('x @abc', 1), isNull);
    });

    test('光标越界时返回 null 而不是抛异常', () {
      expect(parseMention('@a', 99), isNull);
      expect(parseMention('@a', -1), isNull);
    });

    test('消息开头的 / 触发 slash，且 atStart 为真', () {
      final q = parseMention('/排查', 3);
      expect(q, isNotNull);
      expect(q!.kind, TriggerKind.slash);
      expect(q.query, '排查');
      expect(q.start, 0);
      expect(q.end, 3);
      expect(q.atStart, isTrue);
    });

    test('只打一个 / 也算 active —— 此时该列全部技能与命令', () {
      final q = parseMention('/', 1);
      expect(q, isNotNull);
      expect(q!.kind, TriggerKind.slash);
      expect(q.query, '');
      expect(q.atStart, isTrue);
    });

    test('路径给出的是 slash 上下文，但 atStart 为假 —— 是否弹由名字表决定', () {
      // **这三条不再断言 null。** 句中 slash 与路径语法同形，纯函数分不开；
      // 它只负责报告「光标落在一个句中 slash 上下文里」，结论交给
      // `slashExactMatch`（下面单独一组）。
      for (final (text, cursor) in [
        ('看下 /var', 7),
        ('ls /etc', 7),
        ('把 /a 拷到 /b', 10),
      ]) {
        final q = parseMention(text, cursor);
        expect(q, isNotNull, reason: text);
        expect(q!.kind, TriggerKind.slash, reason: text);
        expect(q.atStart, isFalse, reason: text);
      }
    });

    test('斜杠前面没有空白时不触发 —— 中文常常不打空格', () {
      // **这条才真正钉住「空白边界」这个判据。** 上面那三条看着像在守位置，
      // 其实是被「第一个空格之前」挡下的：把实现改成 `text.contains('/')`
      // 它们照样全绿（实测过）。只有斜杠前面连空格都没有时，两条判据才分
      // 得开——而中文用户恰恰经常不打空格。
      expect(parseMention('看下/var/log', 11), isNull);
      expect(parseMention('abc/def', 7), isNull);
    });

    test('句中的 / 触发 slash，atStart 为假', () {
      final q = parseMention('帮我 /排查磁盘', 8);
      expect(q, isNotNull);
      expect(q!.kind, TriggerKind.slash);
      expect(q.query, '排查磁盘');
      expect(q.start, 3);
      expect(q.atStart, isFalse);
    });

    test('第一个空格之后不再触发 —— 那时用户在打 args', () {
      // `/排查磁盘 web-02`：光标移到 args 里，浮层就该关。
      expect(parseMention('/排查磁盘 web-02', 11), isNull);
    });

    test('句中 slash 的 query 在遇到空白处同样收住', () {
      // `帮我 /排查 磁盘` 光标停在「磁盘」后面：最近的空白之后的脚本里
      // 没有 slash，落到 @ 那条路，也没有 @ → null。
      expect(parseMention('帮我 /排查 磁盘', 9), isNull);
    });

    test('句中 slash 与 @ 比谁离光标更近', () {
      // `/排查 @web`：光标在 web 后面，@ 更近，该赢。
      final q = parseMention('/排查 @web', 8);
      expect(q!.kind, TriggerKind.at);
    });

    test('slash 与 at 互不干扰：/ 开头的消息里，空格后的 @ 仍然触发', () {
      final q = parseMention('/排查磁盘 @web', 10);
      expect(q, isNotNull);
      expect(q!.kind, TriggerKind.at);
      expect(q.query, 'web');
    });

    test('既有的 @ 用例现在带 kind = at', () {
      final q = parseMention('@ngi', 4);
      expect(q!.kind, TriggerKind.at);
    });
  });

  group('slashExactMatch', () {
    bool run(String q, {List<SkillIndexEntry> skills = _skills}) =>
        slashExactMatch(query: q, skills: skills, commands: _commands);

    test('精确命中技能名 → 真', () {
      expect(run('nginx-tuning'), isTrue);
    });

    test('精确命中收藏命令名 → 真', () {
      expect(run('restart-api'), isTrue);
    });

    test('大小写不敏感', () {
      expect(run('NGINX-TUNING'), isTrue);
    });

    test('只是前缀 → 假 —— 这正是句中和消息开头的差别', () {
      // `/nginx` 前缀能匹配到技能，但不够具体。句中用户点不出名字就不该
      // 弹浮层；消息开头则照弹（那是「挑一个」的入口）。
      expect(run('nginx'), isFalse);
    });

    test('路径段不是任何名字 → 假', () {
      expect(run('var'), isFalse);
      expect(run('etc'), isFalse);
    });

    test('空 query → 假 —— 句中只打一个 / 不弹全部列表', () {
      expect(run(''), isFalse);
    });

    test('大小写不敏感地对路径同样成立 —— 不因大小写而误弹', () {
      expect(run('VAR'), isFalse);
    });
  });

  group('splitDirPrefix', () {
    test('中间有前缀', () {
      final r = splitDirPrefix('/etc/ng');
      expect(r.dir, '/etc');
      expect(r.prefix, 'ng');
    });

    test('以 / 结尾 → 前缀为空，列整个目录', () {
      final r = splitDirPrefix('/etc/');
      expect(r.dir, '/etc');
      expect(r.prefix, '');
    });

    test('根目录不能被切成空串', () {
      // '/'.substring(0, 0) == '' —— 拿空串去 listdir 会得到「目录不存在」，
      // 掩盖真正的原因。
      final r = splitDirPrefix('/');
      expect(r.dir, '/');
      expect(r.prefix, '');
    });

    test('~ 与 . 起头各自保留，交给上层解析成绝对路径', () {
      expect(splitDirPrefix('~/').dir, '~');
      expect(splitDirPrefix('~/.ssh/con').dir, '~/.ssh');
      expect(splitDirPrefix('~/.ssh/con').prefix, 'con');
      expect(splitDirPrefix('./log').dir, '.');
      expect(splitDirPrefix('./log').prefix, 'log');
    });

    test('不含 / 时 dir 为空 —— 调用方据此判断「还没进文件模式」', () {
      final r = splitDirPrefix('nginx');
      expect(r.dir, '');
      expect(r.prefix, 'nginx');
    });
  });

  group('splitServerPath', () {
    test('无冒号 —— 机器名为空，整段都是 path', () {
      final r = splitServerPath('/var/log');
      expect(r.server, isEmpty);
      expect(r.path, '/var/log');
      expect(r.hasColon, isFalse);
    });

    test('有冒号 —— 按首个冒号切', () {
      final r = splitServerPath('web-02:/var/log');
      expect(r.server, 'web-02');
      expect(r.path, '/var/log');
      expect(r.hasColon, isTrue);
    });

    test('冒号后为空 —— path 是空串，但 hasColon 为真', () {
      // 这两者必须分得开：hasColon 决定「要不要列这台机的目录」，
      // path 为空决定「列哪个目录（home）」。
      final r = splitServerPath('web-02:');
      expect(r.server, 'web-02');
      expect(r.path, isEmpty);
      expect(r.hasColon, isTrue);
    });

    test('多个冒号 —— 只按首个切，路径里带冒号是合法的', () {
      final r = splitServerPath('web-02:/a:b');
      expect(r.server, 'web-02');
      expect(r.path, '/a:b');
    });

    test('冒号在首位 —— 机器名为空，当作没指定机器', () {
      final r = splitServerPath(':/var/log');
      expect(r.server, isEmpty);
      expect(r.path, '/var/log');
      expect(r.hasColon, isTrue);
    });
  });

  group('matchLocal', () {
    List<MentionCandidate> run(TriggerKind kind, String q,
            {bool others = true}) =>
        matchLocal(
          kind: kind,
          query: q,
          servers: [_server('prod-1'), _server('staging')],
          skills: _skills,
          commands: _commands,
          hasOtherServers: others,
        );

    test('at 的空 query 列出全部服务器 —— 敲下 @ 的那一刻就有东西可选', () {
      final r = run(TriggerKind.at, '');
      expect(r.where((c) => c.kind == MentionKind.server), hasLength(2));
    });

    test('slash 的空 query 列出全部技能与命令', () {
      final r = run(TriggerKind.slash, '');
      expect(r.where((c) => c.kind == MentionKind.skill), hasLength(2));
      expect(r.where((c) => c.kind == MentionKind.command), hasLength(1));
    });

    test('slash 内技能与命令共享同一个前缀匹配', () {
      final r = run(TriggerKind.slash, 'n');
      // nginx-tuning 含 'n'，pg-restore 不含。
      expect(r.map((c) => c.label), contains('nginx-tuning'));
      expect(r.map((c) => c.label), isNot(contains('pg-restore')));
    });

    test('大小写不敏感', () {
      expect(run(TriggerKind.slash, 'NGINX').map((c) => c.label),
          contains('nginx-tuning'));
    });

    test('hasOtherServers 对 slash 类没有影响 —— 服务器已经不在这条触发符下', () {
      // hasOtherServers 原本是给 server 类用的开关（对齐 buildToolSpecs 同名
      // 参数）。拆分之后 slash 永远不含 server，所以这个开关对 slash 结果
      // 不该有任何影响——传 false 技能与命令照样都在。
      final r = run(TriggerKind.slash, '', others: false);
      expect(r.where((c) => c.kind == MentionKind.skill), isNotEmpty);
      expect(r.where((c) => c.kind == MentionKind.command), isNotEmpty);
    });

    test('at 类的 perKindLimit 限制服务器数量', () {
      final many = [for (var i = 0; i < 20; i++) _server('srv-$i')];
      final r = matchLocal(
        kind: TriggerKind.at,
        query: '',
        servers: many,
        skills: _skills,
        commands: _commands,
        hasOtherServers: true,
        perKindLimit: 8,
      );
      expect(r, hasLength(8));
      expect(r.every((c) => c.kind == MentionKind.server), isTrue);
    });

    test('slash 类里技能与命令各自独立受 perKindLimit 限制，不是合起来共享一个上限', () {
      final manySkills = [
        for (var i = 0; i < 20; i++)
          SkillIndexEntry(name: 'skill-$i', description: 'd$i'),
      ];
      final manyCommands = [
        for (var i = 0; i < 20; i++)
          FavoriteCommand(
              id: 'c$i',
              name: 'cmd-$i',
              command: 'echo $i',
              sortOrder: i,
              aiEnabled: true),
      ];
      final r = matchLocal(
        kind: TriggerKind.slash,
        query: '',
        servers: const [],
        skills: manySkills,
        commands: manyCommands,
        perKindLimit: 8,
      );
      // 若是「合起来共享一个上限 8」，两类总数就该是 8；实际各自独立截到 8，
      // 总数是 16。
      expect(r.where((c) => c.kind == MentionKind.skill), hasLength(8));
      expect(r.where((c) => c.kind == MentionKind.command), hasLength(8));
    });

    test('副标题取各自已有的字段，不额外查询', () {
      final srv =
          run(TriggerKind.at, '').firstWhere((c) => c.kind == MentionKind.server);
      expect(srv.subtitle, '10.0.0.1');
      final slashR = run(TriggerKind.slash, '');
      final skill = slashR.firstWhere((c) => c.kind == MentionKind.skill);
      expect(skill.subtitle, '调 worker 数');
      final cmd = slashR.firstWhere((c) => c.kind == MentionKind.command);
      expect(cmd.subtitle, 'systemctl restart api');
    });

    test('insertText 不含 @ —— 那个记号由 applyMention 负责补', () {
      expect(run(TriggerKind.at, 'prod').first.insertText, 'prod-1');
    });

    test('serverType 为 local 的条目不出现在候选里 —— 模型侧只认 ssh 列表', () {
      // resolveServerTarget（server_targets.dart）匹配的名字来自
      // serverListProvider（terminal_screen.dart:1889），那里过滤掉了
      // serverType != 'ssh' 的条目。如果这里的候选列表混进了本地 shell
      // profile，用户点了插进输入框、模型当 server 参数传出去，
      // resolveServerTarget 找不到同名的 ssh 服务器，必然报错——
      // 白烧一轮对话。
      final r = matchLocal(
        kind: TriggerKind.at,
        query: '',
        servers: [
          _server('prod-1'),
          Server(
            id: 'id-local-shell',
            name: 'local-shell',
            host: '',
            port: 0,
            username: '',
            authType: 'password',
            serverType: 'local',
          ),
        ],
        skills: _skills,
        commands: _commands,
        hasOtherServers: true,
      );
      final names = r
          .where((c) => c.kind == MentionKind.server)
          .map((c) => c.label)
          .toList();
      expect(names, contains('prod-1'));
      expect(names, isNot(contains('local-shell')));
    });
  });

  group('matchLocal 按触发符分流', () {
    test('slash 只出技能与命令，一个服务器都不出', () {
      final out = matchLocal(
        kind: TriggerKind.slash,
        query: '',
        servers: [_server('web-01')],
        skills: _skills,
        commands: _commands,
        hasOtherServers: true,
      );
      expect(out.every((c) => c.kind != MentionKind.server), isTrue);
      expect(out.any((c) => c.kind == MentionKind.skill), isTrue);
      expect(out.any((c) => c.kind == MentionKind.command), isTrue);
    });

    test('at 只出服务器，技能与命令已经搬去 slash 了', () {
      final out = matchLocal(
        kind: TriggerKind.at,
        query: '',
        servers: [_server('web-01')],
        skills: _skills,
        commands: _commands,
        hasOtherServers: true,
      );
      expect(out.every((c) => c.kind == MentionKind.server), isTrue);
      expect(out, hasLength(1));
    });

    test('at 的 hasOtherServers=false 仍然什么都不出', () {
      final out = matchLocal(
        kind: TriggerKind.at,
        query: '',
        servers: [_server('web-01')],
        skills: _skills,
        commands: _commands,
        hasOtherServers: false,
      );
      expect(out, isEmpty);
    });
  });

  group('applyMention', () {
    test('替换 @…光标 那一段，尾随一个空格', () {
      final q = parseMention('@prod', 5)!;
      final r = applyMention(text: '@prod', q: q, insertText: 'prod-1');
      expect(r.text, '@prod-1 ');
      expect(r.cursor, 8);
    });

    test('光标在文本中间时，后续文本原样保留', () {
      const text = '看 @ng 的日志';
      final q = parseMention(text, 5)!; // 光标在 'ng' 之后
      final r = applyMention(
          text: text, q: q, insertText: '/etc/nginx/nginx.conf');
      expect(r.text, '看 @/etc/nginx/nginx.conf  的日志');
      // 新光标落在插入内容后的那个空格之后，用户接着打字不会掉进旧文本里。
      expect(r.cursor, '看 @/etc/nginx/nginx.conf '.length);
    });

    test('trailingSpace: false 用于目录下钻 —— 不能加空格', () {
      // 加了空格 parseMention 就不再 active，浮层会关掉，下钻直接断掉。
      final q = parseMention('@/et', 4)!;
      final r = applyMention(
          text: '@/et', q: q, insertText: '/etc/', trailingSpace: false);
      expect(r.text, '@/etc/');
      expect(r.cursor, 6);
      // 关键：结果仍然是 active 的，浮层得以继续。
      expect(parseMention(r.text, r.cursor), isNotNull);
      expect(parseMention(r.text, r.cursor)!.query, '/etc/');
    });

    test('前面已有文本时不动它', () {
      const text = 'check @sta';
      final q = parseMention(text, 10)!;
      final r = applyMention(text: text, q: q, insertText: 'staging');
      expect(r.text, 'check @staging ');
    });
  });

  group('applyMention 用触发符对应的前缀', () {
    test('slash 插入 / 开头', () {
      final q = parseMention('/排查', 3)!;
      final r = applyMention(text: '/排查', q: q, insertText: '排查磁盘');
      expect(r.text, '/排查磁盘 ');
      expect(r.cursor, r.text.length);
    });

    test('at 插入 @ 开头', () {
      final q = parseMention('@web', 4)!;
      final r = applyMention(text: '@web', q: q, insertText: 'web-02');
      expect(r.text, '@web-02 ');
    });

    test('trailingSpace=false 时不补空格 —— 服务器与目录下钻都靠它', () {
      final q = parseMention('@web', 4)!;
      final r = applyMention(
          text: '@web', q: q, insertText: 'web-02', trailingSpace: false);
      expect(r.text, '@web-02');
      expect(r.cursor, 7);
    });
  });
}

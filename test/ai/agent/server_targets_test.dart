import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/server_targets.dart';

ServerListEntry e(String id, String name,
        {String? group, String host = '10.0.0.1', bool creds = true}) =>
    ServerListEntry(
      id: id,
      name: name,
      groupName: group,
      host: host,
      credsOk: creds,
    );

void main() {
  final servers = [
    e('id-1', 'web-1', group: 'prod'),
    e('id-10', 'web-10', group: 'prod'),
    e('id-db', 'db', group: 'prod', creds: false),
  ];

  group('resolveServerTarget', () {
    test('不给 server 参数 = 当前会话那台', () {
      final t = resolveServerTarget(null, servers);
      expect(t.ok, isTrue);
      expect(t.isRemote, isFalse);
      expect(t.serverId, isNull);
    });

    test('精确匹配拿到 id 与 name', () {
      final t = resolveServerTarget('web-1', servers);
      expect(t.ok, isTrue);
      expect(t.isRemote, isTrue);
      expect(t.serverId, equals('id-1'));
      expect(t.serverName, equals('web-1'));
    });

    test('web-1 不会匹配到 web-10 —— 不做前缀/模糊匹配', () {
      expect(resolveServerTarget('web-1', servers).serverId, equals('id-1'));
      expect(resolveServerTarget('web-10', servers).serverId, equals('id-10'));
      // 选错机器的后果与选错命令同级，宁可报错也不猜。
      expect(resolveServerTarget('web', servers).ok, isFalse);
    });

    test('找不到时错误消息必须附可用名字列表', () {
      final t = resolveServerTarget('nope', servers);
      expect(t.ok, isFalse);
      expect(t.error, contains('nope'));
      expect(t.error, contains('web-1'));
      expect(t.error, contains('web-10'));
      expect(t.error, contains('db'));
    });

    test('空字符串与非字符串都报错，不当成「当前会话」', () {
      expect(resolveServerTarget('', servers).ok, isFalse);
      expect(resolveServerTarget('   ', servers).ok, isFalse);
      expect(resolveServerTarget(42, servers).ok, isFalse);
    });

    test('前后空白被裁掉', () {
      expect(resolveServerTarget('  web-1  ', servers).serverId, equals('id-1'));
    });
  });

  group('ServerListEntry.toJson', () {
    test('给模型的字段里不含内部 id —— 它不需要 UUID，只会浪费 token', () {
      final j = servers.first.toJson();
      expect(j['name'], equals('web-1'));
      expect(j['group'], equals('prod'));
      expect(j['host'], equals('10.0.0.1'));
      expect(j['creds_ok'], isTrue);
      expect(j.containsKey('id'), isFalse);
    });

    test('没有分组时不输出 group 键', () {
      expect(e('x', 'solo').toJson().containsKey('group'), isFalse);
    });

    test('credsOk=false 如实输出', () {
      expect(servers.last.toJson()['creds_ok'], isFalse);
    });
  });
}

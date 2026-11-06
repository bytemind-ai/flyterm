import 'package:flutter_test/flutter_test.dart';

import 'package:flyterm/config_import/config_draft.dart';
import 'package:flyterm/ui/home/server_form_screen.dart';

void main() {
  test('applyServerDraft 把草稿映射成控制器文本', () {
    // 纯函数测试：不搭 widget 树，只验字段映射与 provenance 透传。
    const draft = ServerDraft(
      name: 'web-1',
      host: '10.0.0.5',
      port: 2222,
      username: 'deploy',
      provenance: {'host': 'ssh config 的 HostName'},
    );
    final applied = ServerDraftApplication.from(draft);

    expect(applied.name, 'web-1');
    expect(applied.host, '10.0.0.5');
    expect(applied.port, '2222');
    expect(applied.username, 'deploy');
    expect(applied.highlightedFields, contains('host'));
  });

  test('port 缺省时填 22 且不算高亮字段', () {
    const draft = ServerDraft(host: '10.0.0.5');
    final applied = ServerDraftApplication.from(draft);

    expect(applied.port, '22');
    // 默认值不该高亮 —— 高亮的意义是「这是从你粘的东西里读出来的」。
    expect(applied.highlightedFields, isNot(contains('port')));
  });

  test('name 缺省时回落到 host', () {
    const draft = ServerDraft(host: '10.0.0.5');
    final applied = ServerDraftApplication.from(draft);
    expect(applied.name, '10.0.0.5');
  });

  test('needsManualKey 被透传', () {
    const draft =
        ServerDraft(host: '10.0.0.5', identityFilePath: '~/.ssh/id_rsa');
    final applied = ServerDraftApplication.from(draft);
    expect(applied.needsManualKey, isTrue);
  });

  test('jumpHostAlias 被透传，供 UI 去匹配已存服务器', () {
    const draft = ServerDraft(host: '10.0.0.5', jumpHostAlias: 'bastion');
    final applied = ServerDraftApplication.from(draft);
    expect(applied.jumpHostAlias, 'bastion');
  });
}

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ui/ai/widgets/launchpad_data.dart';

String archiveWith(List<Map<String, dynamic>> events) =>
    jsonEncode({'events': events, 'history': [], 'planQueue': [], 'pendingInputs': []});

void main() {
  test('抽出 targetServerName，去重保序', () {
    final j = archiveWith([
      {'t': 'tool', 'seq': 1, 'callId': 'c1', 'toolName': 'bash',
       'displayCommand': 'ls', 'description': '', 'targetServerName': 'web-01'},
      {'t': 'tool', 'seq': 2, 'callId': 'c2', 'toolName': 'bash',
       'displayCommand': 'ls', 'description': '', 'targetServerName': 'db-02'},
      {'t': 'tool', 'seq': 3, 'callId': 'c3', 'toolName': 'bash',
       'displayCommand': 'ls', 'description': '', 'targetServerName': 'web-01'},
    ]);
    expect(machinesFromArchive(j), ['web-01', 'db-02']);
  });

  test('没有 targetServerName 的记录被跳过', () {
    final j = archiveWith([
      {'t': 'tool', 'seq': 1, 'callId': 'c1', 'toolName': 'bash',
       'displayCommand': 'ls', 'description': ''},
    ]);
    expect(machinesFromArchive(j), isEmpty);
  });

  test('畸形 JSON 返回空列表而不是抛', () {
    expect(machinesFromArchive('{not json'), isEmpty);
    expect(machinesFromArchive('[]'), isEmpty);
    expect(machinesFromArchive(''), isEmpty);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ai/agent/agent_loop.dart';
import 'package:flyterm/ai/agent/agent_tools.dart';
import 'package:flyterm/ai/agent/command_runner.dart';
import 'package:flyterm/ai/agent/file_edit.dart';
import 'package:flyterm/ai/agent/tool_models.dart';
import 'package:flyterm/ai/agent/tool_registry.dart';

import '_fakes.dart';

AIResponse writeCall(String id, String path, String content) =>
    AIResponse(toolCalls: [
      ToolCall(id: id, name: 'write_file', args: {
        'path': path,
        'content': content,
        'description': 'write it',
      })
    ]);

void main() {
  test('写文件成功后事件带上备份路径', () async {
    final p = FakeProvider([
      writeCall('c1', '/etc/app.conf', 'x=1'),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
    );

    await loop.send('write it');

    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.status, equals(ToolCallStatus.done));
    expect(ev.backupPath, equals(dotBackupPathForSeq('/etc/app.conf', ev.seq)));
    expect(ev.undone, isFalse);
    expect(ev.backupMissing, isFalse);
  });

  test('写文件失败时不记备份路径——没成功就没有可回退的东西', () async {
    final p = FakeProvider([
      writeCall('c1', '/etc/app.conf', 'x=1'),
      const AIResponse(text: 'done'),
    ]);
    final r = FakeRunner(
      result: const CommandOutput(
          stdout: '', stderr: 'Permission denied', exitCode: 1),
    );
    final loop = makeLoop(
      provider: p,
      runner: r,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
    );

    await loop.send('write it');

    final ev = loop.events.whereType<ToolCallEvent>().single;
    expect(ev.status, equals(ToolCallStatus.failed));
    expect(ev.backupPath, isNull);
  });

  test('撤销跑 cp 并把事件标成已撤销', () async {
    final p = FakeProvider([
      writeCall('c1', '/etc/app.conf', 'x=1'),
      const AIResponse(text: 'done'),
    ]);
    final r = FakeRunner();
    final loop = makeLoop(
      provider: p,
      runner: r,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
    );
    await loop.send('write it');
    final ev = loop.events.whereType<ToolCallEvent>().single;

    final ok = await loop.undoEdit(ev.seq);

    expect(ok, isTrue);
    expect(ev.undone, isTrue);
    expect(r.ran.last, contains('cp -p'));
    expect(r.ran.last, contains('.app.conf.flyterm.bak.'));
  });

  test('备份不存在时返回 false 并标记 backupMissing', () async {
    final p = FakeProvider([
      writeCall('c1', '/etc/app.conf', 'x=1'),
      const AIResponse(text: 'done'),
    ]);
    final r = FakeRunner(results: [
      // 第一条是写入本身
      const CommandOutput(stdout: '', stderr: '', exitCode: 0),
      // 第二条是撤销
      CommandOutput(stdout: '', stderr: '', exitCode: kMissingBackupExitCode),
    ]);
    final loop = makeLoop(
      provider: p,
      runner: r,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
    );
    await loop.send('write it');
    final ev = loop.events.whereType<ToolCallEvent>().single;

    final ok = await loop.undoEdit(ev.seq);

    expect(ok, isFalse);
    expect(ev.undone, isFalse);
    expect(ev.backupMissing, isTrue);
  });

  test('cp 因权限失败时不标 backupMissing——用户修好可以重试', () async {
    final p = FakeProvider([
      writeCall('c1', '/etc/app.conf', 'x=1'),
      const AIResponse(text: 'done'),
    ]);
    final r = FakeRunner(results: [
      const CommandOutput(stdout: '', stderr: '', exitCode: 0),
      const CommandOutput(
          stdout: '', stderr: 'cp: cannot create regular file', exitCode: 1),
    ]);
    final loop = makeLoop(
      provider: p,
      runner: r,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
    );
    await loop.send('write it');
    final ev = loop.events.whereType<ToolCallEvent>().single;

    final ok = await loop.undoEdit(ev.seq);

    expect(ok, isFalse);
    expect(ev.undone, isFalse);
    expect(ev.backupMissing, isFalse, reason: '权限问题修好后应该还能重试');
    // 失败原因必须摆到卡片上。这曾是整个功能里唯一一条完全无反馈的路径：
    // 用户点撤销、cp 因权限失败 → 界面上一个像素都不变，只能理解成
    // 「这按钮坏了」。隔壁那行（备份丢失）特意做了「不静默失败」，两者是
    // 同一个意图。
    expect(ev.output, contains('cannot create'));
  });

  test('已撤销过的不再重复跑', () async {
    final p = FakeProvider([
      writeCall('c1', '/etc/app.conf', 'x=1'),
      const AIResponse(text: 'done'),
    ]);
    final r = FakeRunner();
    final loop = makeLoop(
      provider: p,
      runner: r,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
    );
    await loop.send('write it');
    final ev = loop.events.whereType<ToolCallEvent>().single;
    await loop.undoEdit(ev.seq);
    final count = r.ran.length;

    await loop.undoEdit(ev.seq);

    expect(r.ran.length, equals(count));
  });

  test('对不存在的 seq 撤销返回 false，不抛', () async {
    final p = FakeProvider([const AIResponse(text: 'ok')]);
    final loop = makeLoop(provider: p, mode: PermissionMode.bypass);
    await loop.send('hi');

    expect(await loop.undoEdit(999), isFalse);
  });

  test('对 bash 工具卡撤销返回 false——它没有备份', () async {
    final p = FakeProvider([
      bashCall('c1', 'systemctl status nginx'),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(provider: p, mode: PermissionMode.bypass);
    await loop.send('check');
    final ev = loop.events.whereType<ToolCallEvent>().single;

    expect(await loop.undoEdit(ev.seq), isFalse);
  });

  test('备份路径与撤销状态进归档', () async {
    final p = FakeProvider([
      writeCall('c1', '/etc/app.conf', 'x=1'),
      const AIResponse(text: 'done'),
    ]);
    final loop = makeLoop(
      provider: p,
      mode: PermissionMode.bypass,
      toolSpecs: () => fullToolSpecs,
    );
    await loop.send('write it');
    await loop.undoEdit(loop.events.whereType<ToolCallEvent>().single.seq);

    final restored = makeLoop(
      provider: FakeProvider([]),
      toolSpecs: () => fullToolSpecs,
      restoreFrom: loop.toArchive(),
    );

    final ev = restored.events.whereType<ToolCallEvent>().single;
    expect(ev.backupPath, isNotNull);
    expect(ev.undone, isTrue);
  });
}

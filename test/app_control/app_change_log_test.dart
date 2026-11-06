import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/app_control/app_change.dart';
import 'package:flyterm/app_control/app_change_log.dart';

void main() {
  group('AppChangeLog', () {
    test('记一条就能读到', () {
      final log = AppChangeLog();
      log.record(AppChange(
        toolName: 'app_settings_set',
        field: 'fontSize',
        oldValue: 13.0,
        newValue: 15.0,
        undo: () async {},
      ));
      expect(log.pending, hasLength(1));
      expect(log.pending.first.field, 'fontSize');
    });

    test('undoAll 逆序执行', () async {
      final log = AppChangeLog();
      final order = <String>[];
      for (final f in ['a', 'b', 'c']) {
        log.record(AppChange(
          toolName: 't',
          field: f,
          oldValue: null,
          newValue: null,
          undo: () async => order.add(f),
        ));
      }
      await log.undoAll();
      // 逆序：中间态没有意义，必须倒着退
      expect(order, equals(['c', 'b', 'a']));
    });

    test('undoAll 之后栈清空', () async {
      final log = AppChangeLog();
      log.record(AppChange(
        toolName: 't',
        field: 'x',
        oldValue: 1,
        newValue: 2,
        undo: () async {},
      ));
      await log.undoAll();
      expect(log.pending, isEmpty);
    });

    test('不可逆的条目（undo == null）跳过但不报错', () async {
      final log = AppChangeLog();
      var ran = false;
      log.record(const AppChange(
        toolName: 'tunnel_create',
        field: 'tunnel',
        oldValue: null,
        newValue: '8080',
        undo: null,
      ));
      log.record(AppChange(
        toolName: 'app_settings_set',
        field: 'fontSize',
        oldValue: 13.0,
        newValue: 15.0,
        undo: () async => ran = true,
      ));
      await log.undoAll();
      expect(ran, isTrue);
    });

    test('canUndoAll —— 含不可逆条目时为 false', () {
      final log = AppChangeLog();
      log.record(const AppChange(
        toolName: 'tunnel_create',
        field: 'tunnel',
        oldValue: null,
        newValue: '8080',
        undo: null,
      ));
      expect(log.canUndoAll, isFalse);
    });

    test('pending 是只读副本 —— 外部改不动内部栈', () {
      final log = AppChangeLog();
      log.record(AppChange(
        toolName: 't',
        field: 'x',
        oldValue: 1,
        newValue: 2,
        undo: () async {},
      ));
      expect(() => log.pending.clear(), throwsUnsupportedError);
    });
  });

  group('分批 —— 一张卡一个批次', () {
    AppChange mk(String f, void Function() onUndo) => AppChange(
          toolName: 't',
          field: f,
          oldValue: null,
          newValue: null,
          undo: () async => onUndo(),
        );

    test('startBatch 之后的变更进新批次', () {
      final log = AppChangeLog();
      log.record(mk('a', () {}));
      final first = log.currentBatch!.id;

      log.startBatch();
      log.record(mk('b', () {}));

      expect(log.batches, hasLength(2));
      expect(log.currentBatch!.id, isNot(first));
    });

    test('startBatch 不预建空批次 —— 没变更的轮次不留空卡', () {
      final log = AppChangeLog();
      log.startBatch();
      log.startBatch();
      log.startBatch();
      expect(log.batches, isEmpty);
    });

    test('同一批次内多次 record 累积', () {
      final log = AppChangeLog();
      log.record(mk('a', () {}));
      log.record(mk('b', () {}));
      expect(log.batches, hasLength(1));
      expect(log.batches.single.changes, hasLength(2));
    });

    // 这条是选方案 B 的全部理由：撤第一批不能动到第二批。
    test('撤销一个批次不影响另一个', () async {
      final log = AppChangeLog();
      final undone = <String>[];
      log.record(mk('a', () => undone.add('a')));
      final firstId = log.currentBatch!.id;
      log.startBatch();
      log.record(mk('b', () => undone.add('b')));

      await log.undoBatch(firstId);

      expect(undone, equals(['a']), reason: '撤第一批把第二批也撤了');
      expect(log.batchById(firstId)!.undone, isTrue);
      expect(log.batches.last.undone, isFalse);
    });

    test('重复撤销同一批次是 no-op', () async {
      final log = AppChangeLog();
      var count = 0;
      log.record(mk('a', () => count++));
      final id = log.currentBatch!.id;

      await log.undoBatch(id);
      await log.undoBatch(id);

      expect(count, 1, reason: '重复点撤销把 undo 跑了两遍');
    });

    test('已撤销的批次不再出现在 pending 里', () async {
      final log = AppChangeLog();
      log.record(mk('a', () {}));
      final id = log.currentBatch!.id;
      log.startBatch();
      log.record(mk('b', () {}));

      await log.undoBatch(id);

      expect(log.pending, hasLength(1));
      expect(log.pending.single.field, 'b');
    });

    test('batches 保留已撤销的 —— 卡片要继续显示，只是按钮置灰', () async {
      final log = AppChangeLog();
      log.record(mk('a', () {}));
      await log.undoBatch(log.currentBatch!.id);

      expect(log.batches, hasLength(1));
      expect(log.batches.single.undone, isTrue);
      expect(log.batches.single.canUndo, isFalse);
    });

    test('undoAll 从最新批次往回退', () async {
      final log = AppChangeLog();
      final order = <String>[];
      log.record(mk('a', () => order.add('a')));
      log.startBatch();
      log.record(mk('b', () => order.add('b')));

      await log.undoAll();
      expect(order, equals(['b', 'a']));
    });

    test('hasIrreversible 标出含不可逆项的批次', () {
      final log = AppChangeLog();
      log.record(const AppChange(
        toolName: 'tunnel_create',
        field: 'tunnel',
        oldValue: null,
        newValue: '8080',
        undo: null,
      ));
      expect(log.currentBatch!.hasIrreversible, isTrue);
      expect(log.currentBatch!.canUndo, isFalse);
    });

    test('未知 batchId 的撤销是 no-op，不抛', () async {
      final log = AppChangeLog();
      await log.undoBatch('no-such-id');
    });
  });
}

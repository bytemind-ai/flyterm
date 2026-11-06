import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/sftp_entry.dart';
import 'package:flyterm/sftp/sftp_name_sort.dart';

SftpEntry _e(String name, {bool isDir = false, int size = 0, int mtime = 0}) =>
    SftpEntry(
      name: name,
      path: '/$name',
      isDir: isDir,
      size: size,
      modTime: DateTime.fromMillisecondsSinceEpoch(mtime),
    );

void main() {
  group('naturalCompare 自然序', () {
    test('file2 排在 file10 前面（纯字典序会输）', () {
      expect(naturalCompare('file2', 'file10'), lessThan(0));
    });

    test('v1.9 排在 v1.10 前面', () {
      expect(naturalCompare('v1.9', 'v1.10'), lessThan(0));
    });

    test('大小写不敏感 —— Zoo 不排在 apple 前面', () {
      expect(naturalCompare('Zoo.txt', 'apple.txt'), greaterThan(0),
          reason: 'ASCII 序会让 Z 排在 a 前，那是 bug');
      expect(naturalCompare('README', 'build'), greaterThan(0));
    });

    test('相同名字返回 0', () {
      expect(naturalCompare('a.txt', 'a.txt'), 0);
    });

    test('数字段与非数字段比较不抛', () {
      expect(() => naturalCompare('a1', 'ab'), returnsNormally);
    });

    test('前导数字', () {
      expect(naturalCompare('2foo', '10foo'), lessThan(0));
    });
  });

  group('排序：目录恒优先', () {
    test('无论升降序，目录都在文件前', () {
      final items = [
        _e('zzz.txt', size: 999),
        _e('aaa', isDir: true),
        _e('bbb', isDir: true),
      ];
      for (final key in SortKey.values) {
        for (final asc in [true, false]) {
          final sorted = sortEntries(items, key: key, ascending: asc);
          final lastDirIdx = sorted.lastIndexWhere((e) => e.isDir);
          final firstFileIdx = sorted.indexWhere((e) => !e.isDir);
          expect(lastDirIdx, lessThan(firstFileIdx),
              reason: '$key asc=$asc：目录必须全在文件前');
        }
      }
    });

    test('按大小时目录区退回名称序 —— 但仍跟随升降序', () {
      // 目录的 attr.size 往往是块大小（4096）而非内容真实大小，拿它比较
      // 没有意义，所以「按大小」时目录区退回名称序。但**方向必须跟随** ——
      // 见下面「目录区必须跟随排序」那一组的根因说明。
      final items = [
        _e('b.txt', size: 1),
        _e('a.txt', size: 2),
        _e('zzz', isDir: true),
        _e('aaa', isDir: true),
      ];
      final desc = sortEntries(items, key: SortKey.size, ascending: false);
      expect(desc.map((e) => e.name).toList(),
          ['zzz', 'aaa', 'a.txt', 'b.txt']);
      final asc = sortEntries(items, key: SortKey.size, ascending: true);
      expect(asc.map((e) => e.name).toList(),
          ['aaa', 'zzz', 'b.txt', 'a.txt']);
    });
  });

  // ── 回归：目录区必须跟随排序维度与方向 ──────────────────────────────
  //
  // 真实缺陷：目录分支曾经硬编码成 `..sort((a, b) => naturalCompare(a.name,
  // b.name))` —— `key` 和 `ascending` 一个都没参与。于是在**目录占满首屏**的
  // 路径（home、项目根、`/`、按日期分的备份目录）下，用户点任何排序项，
  // 屏幕上都是零变化，表现就是「排序不生效」。
  //
  // 注意这不是「目录优先」那条规则的代价：目录优先只要求目录排在文件前，
  // 不要求目录之间的顺序对排序免疫。
  group('目录区必须跟随排序', () {
    final dirs = [
      _e('alpha', isDir: true, mtime: 3000),
      _e('beta', isDir: true, mtime: 1000),
      _e('gamma', isDir: true, mtime: 2000),
    ];

    test('按时间：目录区按时间排，不是按名称', () {
      final desc = sortEntries(dirs, key: SortKey.time, ascending: false);
      expect(desc.map((e) => e.name).toList(), ['alpha', 'gamma', 'beta'],
          reason: '按日期分的备份目录找最新的，是最常见的需求之一');
      final asc = sortEntries(dirs, key: SortKey.time, ascending: true);
      expect(asc.map((e) => e.name).toList(), ['beta', 'gamma', 'alpha']);
    });

    test('按名称降序：目录区要反转', () {
      final sorted = sortEntries(dirs, key: SortKey.name, ascending: false);
      expect(sorted.map((e) => e.name).toList(), ['gamma', 'beta', 'alpha']);
    });

    test('全目录的列表里，不同排序必须给出不同顺序', () {
      // 这条直接复刻用户看到的现象：一个只有目录的路径，六种
      // key×方向组合曾经输出完全相同的顺序。
      final orders = <String>{};
      for (final k in SortKey.values) {
        for (final asc in [true, false]) {
          orders.add(
            sortEntries(dirs, key: k, ascending: asc)
                .map((e) => e.name)
                .join(','),
          );
        }
      }
      expect(orders.length, greaterThan(1),
          reason: '六种组合给出同一个顺序 —— 这就是「点排序没反应」');
    });

    test('目录区按时间排时，缺失时间的也恒排最后', () {
      final items = [
        _e('known', isDir: true, mtime: 5000),
        _e('unknown', isDir: true, mtime: 0),
      ];
      for (final asc in [true, false]) {
        final sorted = sortEntries(items, key: SortKey.time, ascending: asc);
        expect(sorted.map((e) => e.name).toList(), ['known', 'unknown'],
            reason: 'asc=$asc：「不知道时间」既不是最新也不是最旧');
      }
    });
  });

  group('排序维度', () {
    test('按大小降序', () {
      final items = [_e('a', size: 1), _e('b', size: 100), _e('c', size: 50)];
      final sorted = sortEntries(items, key: SortKey.size, ascending: false);
      expect(sorted.map((e) => e.name).toList(), ['b', 'c', 'a']);
    });

    test('按时间升序：缺失时间的也排最后，不能被翻到最前', () {
      // 回归：原先用 `ascending ? cmp : -cmp` 统一处理，升序时缺失项
      // （epoch 0，最小）会被排到最前面 —— 「不知道时间」冒充了最旧。
      final items = [
        _e('old', mtime: 1000),
        _e('new', mtime: 9000),
        _e('unknown', mtime: 0),
      ];
      final asc = sortEntries(items, key: SortKey.time, ascending: true);
      expect(asc.map((e) => e.name).toList(), ['old', 'new', 'unknown'],
          reason: '升序时缺失项仍应在末尾');
      final desc = sortEntries(items, key: SortKey.time, ascending: false);
      expect(desc.map((e) => e.name).toList(), ['new', 'old', 'unknown']);
    });

    test('全部缺失时间时不崩且保持稳定', () {
      final items = [_e('a', mtime: 0), _e('b', mtime: 0)];
      expect(() => sortEntries(items, key: SortKey.time, ascending: true),
          returnsNormally);
    });

    test('按时间降序，改为 epoch 0 的排最后', () {
      final items = [
        _e('old', mtime: 1000),
        _e('new', mtime: 9000),
        _e('unknown', mtime: 0),
      ];
      final sorted = sortEntries(items, key: SortKey.time, ascending: false);
      expect(sorted.map((e) => e.name).toList(), ['new', 'old', 'unknown'],
          reason: '时间缺失的不该冒充「最旧」挤到一端');
    });

    test('按名称升序用自然序', () {
      final items = [_e('f10'), _e('f2'), _e('f1')];
      final sorted = sortEntries(items, key: SortKey.name, ascending: true);
      expect(sorted.map((e) => e.name).toList(), ['f1', 'f2', 'f10']);
    });
  });
}

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/sftp_upload_plan.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('upload_plan_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('扫描本地目录', () {
    test('收集所有文件与其相对路径', () async {
      await Directory('${tmp.path}/a/b').create(recursive: true);
      await File('${tmp.path}/root.txt').writeAsString('x' * 10);
      await File('${tmp.path}/a/one.txt').writeAsString('y' * 20);
      await File('${tmp.path}/a/b/two.txt').writeAsString('z' * 30);

      final plan = await SftpUploadPlan.scan(tmp.path);
      final rels = plan.files.map((f) => f.relativePath).toList()..sort();
      expect(rels, ['a/b/two.txt', 'a/one.txt', 'root.txt']);
      expect(plan.totalBytes, 60);
    });

    test('空目录被记录下来（否则上传后远端缺目录）', () async {
      await Directory('${tmp.path}/empty').create(recursive: true);
      await File('${tmp.path}/f.txt').writeAsString('x');
      final plan = await SftpUploadPlan.scan(tmp.path);
      expect(plan.directories, contains('empty'));
    });

    test('空目录树也给得出结果，不抛', () async {
      final plan = await SftpUploadPlan.scan(tmp.path);
      expect(plan.files, isEmpty);
      expect(plan.totalBytes, 0);
    });

    test('取消回调为真时中断扫描', () async {
      await Directory('${tmp.path}/d').create();
      for (var i = 0; i < 50; i++) {
        await File('${tmp.path}/d/f$i.txt').writeAsString('x');
      }
      var calls = 0;
      expect(
        () => SftpUploadPlan.scan(
          tmp.path,
          isCancelled: () => ++calls > 5,
        ),
        throwsA(isA<UploadScanCancelled>()),
      );
    });

    test('软链被跳过（followLinks: false）', () async {
      await File('${tmp.path}/real.txt').writeAsString('x' * 5);
      await Link('${tmp.path}/link.txt').create('${tmp.path}/real.txt');

      final plan = await SftpUploadPlan.scan(tmp.path);
      final rels = plan.files.map((f) => f.relativePath).toList();
      expect(rels, ['real.txt'], reason: '软链既不是 File 也不是 Directory，跳过');
      expect(plan.totalBytes, 5);
    });
  });

  group('requiredDirectories', () {
    test('由文件与空目录共同推导中间层，含空目录', () async {
      await Directory('${tmp.path}/a/b').create(recursive: true);
      await Directory('${tmp.path}/empty/deep').create(recursive: true);
      await File('${tmp.path}/a/b/two.txt').writeAsString('z' * 30);

      final plan = await SftpUploadPlan.scan(tmp.path);
      final dirs = plan.requiredDirectories();
      expect(dirs, containsAll(['a', 'a/b', 'empty', 'empty/deep']));
    });

    test('根目录下的文件不产生任何目录', () async {
      await File('${tmp.path}/root.txt').writeAsString('x');
      final plan = await SftpUploadPlan.scan(tmp.path);
      expect(plan.requiredDirectories(), isEmpty);
    });
  });
}

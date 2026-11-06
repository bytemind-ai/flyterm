// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

/// 扫描被取消。
class UploadScanCancelled implements Exception {
  const UploadScanCancelled();
  @override
  String toString() => 'Upload scan cancelled';
}

/// 一个待上传的本地文件。
class UploadFile {
  final String localPath;

  /// 相对扫描根的路径，用 `/` 分隔。远端路径 = remoteRoot + '/' + 它。
  final String relativePath;
  final int size;

  const UploadFile({
    required this.localPath,
    required this.relativePath,
    required this.size,
  });
}

/// 一次文件夹上传的扫描结果。
///
/// ## 为什么扫描不需要像下载那样有独立 UI 状态
///
/// 下载的扫描要走**网络往返**（逐层 listdir），所以有 `isScanning` 和
/// 「已发现 N 个文件」的增量提示。上传的扫描是**纯本地文件系统**，
/// `File.length()` 极快 —— 几百个文件几十毫秒就完，用户感知不到停顿。
/// 照抄下载那套扫描 UI 只会让用户多看一次无意义的闪烁。
class SftpUploadPlan {
  final List<UploadFile> files;

  /// 相对路径形式的目录列表（含空目录 —— 不记的话上传后远端缺目录）。
  final List<String> directories;
  final int totalBytes;

  const SftpUploadPlan({
    required this.files,
    required this.directories,
    required this.totalBytes,
  });

  /// 递归扫描 [root]。
  ///
  /// [isCancelled] 每个条目检查一次。**不引 isolate**：用户从手机选目录上传，
  /// 规模通常几百到几千个文件，扫描是毫秒级；真扫几万个也是用户主动选了一个
  /// 巨大目录，取消检查足够兜底。为边缘情况引 isolate 不值得。
  static Future<SftpUploadPlan> scan(
    String root, {
    bool Function()? isCancelled,
  }) async {
    final files = <UploadFile>[];
    final dirs = <String>[];
    final rootDir = Directory(root);
    if (!await rootDir.exists()) {
      throw FileSystemException('Directory not found', root);
    }

    await for (final entity
        in rootDir.list(recursive: true, followLinks: false)) {
      if (isCancelled?.call() ?? false) throw const UploadScanCancelled();
      final rel = _relative(entity.path, root);
      if (rel.isEmpty) continue;
      if (entity is Directory) {
        dirs.add(rel);
      } else if (entity is File) {
        files.add(UploadFile(
          localPath: entity.path,
          relativePath: rel,
          size: await entity.length(),
        ));
      }
      // 软链既不是 Directory 也不是 File（followLinks: false 时是 Link），
      // 跳过 —— 上传软链目标的内容语义不清，且可能形成环。
    }

    return SftpUploadPlan(
      files: files,
      directories: dirs,
      totalBytes: files.fold<int>(0, (s, f) => s + f.size),
    );
  }

  static String _relative(String path, String root) {
    var p = path;
    var r = root;
    if (r.endsWith('/')) r = r.substring(0, r.length - 1);
    if (p.startsWith('$r/')) p = p.substring(r.length + 1);
    return p;
  }

  /// 远端根目录下所有需要存在的目录（含中间层）。
  ///
  /// 从 [files] 和 [directories] 一起推导 —— 只靠前者会漏掉空目录。
  Set<String> requiredDirectories() {
    final out = <String>{};
    for (final d in directories) {
      out.add(d);
      // 补出所有祖先
      final parts = d.split('/');
      for (var i = 1; i < parts.length; i++) {
        out.add(parts.sublist(0, i).join('/'));
      }
    }
    for (final f in files) {
      final parts = f.relativePath.split('/');
      for (var i = 1; i < parts.length; i++) {
        out.add(parts.sublist(0, i).join('/'));
      }
    }
    return out;
  }
}

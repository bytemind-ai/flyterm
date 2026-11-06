// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/material.dart';

/// 本地图片全屏查看。
///
/// **不复用 `SFTPImageViewerScreen`**：那个要 `SftpEntry` + `SFTPService` 并
/// 自带下载与进度逻辑，而这里的图已经在本地。照搬它内部 `InteractiveViewer`
/// + `Image.file` + `errorBuilder` 那段模式即可。
Future<void> showImageViewer(BuildContext context, File file) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black),
        body: InteractiveViewer(
          minScale: 0.5,
          maxScale: 8,
          child: Center(
            child: Image.file(
              file,
              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                  color: Colors.red, size: 48),
            ),
          ),
        ),
      ),
    ));

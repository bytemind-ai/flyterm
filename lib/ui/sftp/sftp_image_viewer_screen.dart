// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../l10n/l10n.dart';
import '../../sftp/sftp_entry.dart';
import '../../sftp/sftp_service.dart';

/// Full-screen image viewer for remote SFTP images.
/// Downloads to the system temp directory on first open (cached by filename),
/// then renders with pinch-to-zoom via InteractiveViewer.
class SFTPImageViewerScreen extends StatefulWidget {
  const SFTPImageViewerScreen({
    super.key,
    required this.entry,
    required this.svc,
  });

  final SftpEntry entry;
  final SFTPService svc;

  @override
  State<SFTPImageViewerScreen> createState() => _SFTPImageViewerScreenState();
}

class _SFTPImageViewerScreenState extends State<SFTPImageViewerScreen> {
  File? _file;
  String? _error;
  int _received = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _download();
  }

  Future<void> _download() async {
    try {
      final tmpDir = await getTemporaryDirectory();
      final savePath =
          '${tmpDir.path}/sftp_preview_${widget.entry.name}';

      final path = await widget.svc.downloadToPath(
        widget.entry.path,
        savePath,
        onProgress: (received, total) {
          if (mounted) setState(() { _received = received; _total = total; });
        },
      );
      if (mounted) setState(() => _file = File(path));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.entry.name,
          style: const TextStyle(fontSize: 14),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image, color: Colors.red, size: 48),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: Text(context.l10n.retry),
                onPressed: () => setState(() {
                  _error = null;
                  _received = 0;
                  _total = 0;
                  _file = null;
                  _download();
                }),
              ),
            ],
          ),
        ),
      );
    }

    if (_file == null) {
      final progress = _total > 0 ? _received / _total : null;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 140,
              child: LinearProgressIndicator(value: progress),
            ),
            const SizedBox(height: 10),
            Text(
              progress != null
                  ? '${(progress * 100).toStringAsFixed(0)}%'
                  : context.l10n.loading,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 8.0,
      child: Center(
        child: Image.file(
          _file!,
          errorBuilder: (_, __, ___) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image, color: Colors.red, size: 48),
              const SizedBox(height: 8),
              Text(context.l10n.imageDecodeFailed,
                  style: const TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ),
    );
  }
}

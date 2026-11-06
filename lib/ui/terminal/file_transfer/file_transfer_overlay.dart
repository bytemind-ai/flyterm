// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import '../../../ssh/transport/remote_transport.dart';
import 'file_progress_widget.dart';

typedef FileTransferEntry = ({
  String filename,
  Stream<FileTransferProgress> progress,
  int totalBytes,
  VoidCallback onCancel,
});

class FileTransferOverlay extends StatelessWidget {
  final List<FileTransferEntry> transfers;

  const FileTransferOverlay({super.key, required this.transfers});

  @override
  Widget build(BuildContext context) {
    if (transfers.isEmpty) return const SizedBox.shrink();
    return Positioned(
      right: 8,
      bottom: 80,
      width: 280,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final t in transfers)
                FileProgressWidget(
                  filename: t.filename,
                  progress: t.progress,
                  totalBytes: t.totalBytes,
                  onCancel: t.onCancel,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

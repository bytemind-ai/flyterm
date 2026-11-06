// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';

class FilePickerSheet extends StatefulWidget {
  final Future<void> Function(File local, String remotePath) onUpload;
  final Future<void> Function(String remotePath) onDownload;

  const FilePickerSheet({
    super.key,
    required this.onUpload,
    required this.onDownload,
  });

  @override
  State<FilePickerSheet> createState() => _FilePickerSheetState();
}

class _FilePickerSheetState extends State<FilePickerSheet> {
  final _remoteCtl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _remoteCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        top: 16,
        left: 16,
        right: 16,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
          context.l10n.transferFileTitle,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _remoteCtl,
          decoration: InputDecoration(
            labelText: context.l10n.transferRemotePathHint,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              icon: const Icon(Icons.upload),
              label: Text(context.l10n.transferUpload),
              onPressed: _loading ? null : _pickAndUpload,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.download),
              label: Text(context.l10n.transferDownload),
              onPressed: _loading ? null : _download,
            ),
          ),
        ]),
        const SizedBox(height: 16),
      ]),
    );
  }

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || !mounted) return;
    final path = result.files.single.path;
    if (path == null) return;
    setState(() => _loading = true);
    if (mounted) Navigator.of(context).pop();
    await widget.onUpload(File(path), _remoteCtl.text);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _download() async {
    final remote = _remoteCtl.text.trim();
    if (remote.isEmpty) return;
    setState(() => _loading = true);
    if (mounted) Navigator.of(context).pop();
    await widget.onDownload(remote);
    if (mounted) setState(() => _loading = false);
  }
}

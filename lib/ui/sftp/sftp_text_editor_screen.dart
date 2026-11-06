// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import '../../l10n/l10n.dart';
import '../../sftp/sftp_entry.dart';
import '../../sftp/sftp_service.dart';

class SFTPTextEditorScreen extends StatefulWidget {
  final SftpEntry entry;
  final SFTPService svc;

  const SFTPTextEditorScreen(
      {super.key, required this.entry, required this.svc});

  @override
  State<SFTPTextEditorScreen> createState() => _SFTPTextEditorScreenState();
}

class _SFTPTextEditorScreenState extends State<SFTPTextEditorScreen> {
  late final TextEditingController _ctrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  bool _truncated = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onTextChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _onTextChanged() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  Future<void> _load() async {
    // 截断结论来自读取结果本身，不再用 widget.entry.size 猜 ——
    // 那个值是列表快照，过期时会漏判，导致截断内容可被保存回远端。
    final result = await widget.svc.readTextFile(widget.entry.path);
    if (!mounted) return;
    setState(() {
      _ctrl.text = result?.content ?? '';
      _loading = false;
      _truncated = result?.truncated ?? false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok =
        await widget.svc.writeTextFile(widget.entry.path, _ctrl.text);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.fileSaved)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.fileSaveFailed('${widget.svc.error}'))),
      );
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.name),
        actions: [
          if (_dirty && !_saving && !_truncated)
            IconButton(
              icon: const Icon(Icons.save),
              tooltip: context.l10n.save,
              onPressed: _save,
            ),
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_truncated)
                  Container(
                    width: double.infinity,
                    color: Colors.orange.shade900.withAlpha(180),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    child: Text(
                      context.l10n.fileTooLargeReadonly,
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    maxLines: null,
                    expands: true,
                    readOnly: _truncated,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../l10n/l10n.dart';
import '../../sftp/sftp_entry.dart';
import '../../sftp/sftp_read_result.dart';
import '../../sftp/sftp_service.dart';
import '../ai/widgets/code_block.dart';
import '../design/fly_tokens.dart';
import 'sftp_text_editor_screen.dart';

/// Rendered read-only view of a remote Markdown file.
///
/// ## Why this exists
///
/// Markdown is the one common text format whose **source and rendered forms
/// look completely different**. Opening `README.md` in the editor shows
/// `# Title`, `**bold**`, `| a | b |` as literal punctuation — technically the
/// file, but not the thing the author wrote. Every other text-like format
/// (JSON, YAML, source code) is read *as* its source, so the editor is already
/// the right view for them.
///
/// ## Read-only, with a way back to the source
///
/// This is a **default view, not a replacement**. `.md` stays in
/// `FileKind.text`, so `isEditableText` still routes it to the editor — the
/// user can flip to source from the AppBar and edit as before. Rendering that
/// could not be escaped from would be a capability regression, not an
/// improvement: editing a config-adjacent `.md` is a real workflow.
class SftpMarkdownPreviewScreen extends StatefulWidget {
  const SftpMarkdownPreviewScreen({
    super.key,
    required this.entry,
    required this.svc,
  });

  final SftpEntry entry;
  final SFTPService svc;

  /// Reading a *document* rather than scanning a chat log, so the shared AI
  /// prose style is scaled up from its 12.5 default.
  static const previewBaseFontSize = 14.0;

  @override
  State<SftpMarkdownPreviewScreen> createState() =>
      _SftpMarkdownPreviewScreenState();
}

class _SftpMarkdownPreviewScreenState extends State<SftpMarkdownPreviewScreen> {
  ReadResult? _result;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final result = await widget.svc.readTextFile(widget.entry.path);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result == null) {
        _error = widget.svc.error ?? context.l10n.loading;
      } else {
        _result = result;
      }
    });
  }

  void _openSource() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            SFTPTextEditorScreen(entry: widget.entry, svc: widget.svc),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final truncated = _result?.truncated ?? false;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.entry.name,
          style: const TextStyle(fontSize: 14),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_result != null)
            IconButton(
              icon: const Icon(Icons.code),
              tooltip: context.l10n.sftpViewSource,
              onPressed: _openSource,
            ),
        ],
      ),
      body: _buildBody(truncated: truncated),
    );
  }

  Widget _buildBody({required bool truncated}) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(FlySpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: FlySpace.lg),
              TextButton(
                onPressed: _openSource,
                child: Text(context.l10n.sftpViewSource),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        if (truncated)
          Container(
            width: double.infinity,
            color: FlyColors.pending.withValues(alpha: 0.18),
            padding: const EdgeInsets.symmetric(
              horizontal: FlySpace.md,
              vertical: FlySpace.xs + 2,
            ),
            child: Text(
              context.l10n.sftpMarkdownTruncated,
              style: FlyText.secondary.copyWith(color: FlyColors.pending),
            ),
          ),
        Expanded(
          child: Markdown(
            data: _result!.content,
            padding: const EdgeInsets.fromLTRB(
              FlySpace.lg,
              FlySpace.md,
              FlySpace.lg,
              FlySpace.xxl,
            ),
            styleSheet: aiProseStyle(
              context,
              baseFontSize: SftpMarkdownPreviewScreen.previewBaseFontSize,
            ),
            // No action chips: "run / explain / save to favourites" are AI-panel
            // affordances and mean nothing for a file the user is reading.
            builders: aiMarkdownBuilders(showActions: false),
            // Remote images would require downloading arbitrary URLs from
            // inside a file browser. Out of scope — show the alt text, which
            // the library already does for unresolved images.
            imageBuilder: (uri, title, alt) => _MarkdownImagePlaceholder(
              label: (alt != null && alt.isNotEmpty)
                  ? alt
                  : uri.toString(),
            ),
          ),
        ),
      ],
    );
  }
}

/// Stand-in for images in a previewed Markdown file.
///
/// Rendering remote images would mean fetching arbitrary URLs (and relative
/// paths would have to be resolved against the remote directory) — a feature,
/// not a rendering detail. This keeps the layout honest instead: the reader
/// sees that an image belongs here, without a network fetch happening.
class _MarkdownImagePlaceholder extends StatelessWidget {
  const _MarkdownImagePlaceholder({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: FlySpace.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: FlySpace.md,
        vertical: FlySpace.sm,
      ),
      decoration: BoxDecoration(
        color: FlyColors.panelElevated,
        borderRadius: FlyRadius.controlRadius,
        border: Border.all(color: FlyColors.divider, width: kHairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.image_outlined,
            size: 14,
            color: FlyColors.textTertiary,
          ),
          const SizedBox(width: FlySpace.xs + 2),
          Flexible(
            child: Text(
              label,
              style: FlyText.secondary.copyWith(color: FlyColors.textTertiary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

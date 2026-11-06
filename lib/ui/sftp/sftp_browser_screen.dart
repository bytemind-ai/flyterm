// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import '../../data/models/server.dart';
import '../../sftp/sftp_service.dart';
import 'sftp_inline_view.dart';

/// Legacy fullscreen entry — wraps SftpInlineView in a Scaffold+AppBar.
/// New code uses SftpInlineView directly inside TerminalScreen.
class SFTPBrowserScreen extends StatelessWidget {
  final Server server;
  final SFTPService svc;

  /// Directory to open on first load. Defaults to '/' when not provided.
  final String initialPath;

  const SFTPBrowserScreen({
    super.key,
    required this.server,
    required this.svc,
    this.initialPath = '/',
  });

  @override
  Widget build(BuildContext context) {
    return SftpInlineView(
      server: server,
      svc: svc,
      initialPath: initialPath,
      onCloseRequested: () => Navigator.of(context).maybePop(),
    );
  }
}

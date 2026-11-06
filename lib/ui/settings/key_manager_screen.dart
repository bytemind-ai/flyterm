// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/ssh_key.dart';
import '../../data/repositories/ssh_key_repository.dart';
import '../../data/secure_storage.dart';
import '../../ssh/key_service.dart';
import '../../l10n/l10n.dart';

class KeyManagerScreen extends StatefulWidget {
  const KeyManagerScreen({super.key});

  @override
  State<KeyManagerScreen> createState() => _KeyManagerScreenState();
}

class _KeyManagerScreenState extends State<KeyManagerScreen> {
  late Future<List<SSHKey>> _keysFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final future = context.read<SSHKeyRepository>().findAll();
    setState(() { _keysFuture = future; });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final cs = Theme.of(context).colorScheme;
    // FutureBuilder wraps the whole Scaffold so both the body and the FAB can
    // read [keys] — the empty state shows its own centered "add key" CTA, so
    // the FAB must be hidden there to avoid two identical entries (see a.jpg).
    return FutureBuilder<List<SSHKey>>(
      future: _keysFuture,
      builder: (context, snap) {
        final loading = snap.connectionState != ConnectionState.done;
        final keys = snap.data ?? [];
        final isEmpty = !loading && keys.isEmpty;
        return Scaffold(
          appBar: AppBar(
            title: Text(l.sshKeys),
            elevation: 0,
            scrolledUnderElevation: 0,
          ),
          body: loading
              ? const Center(child: CircularProgressIndicator())
              : isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.vpn_key_outlined,
                            size: 48,
                            color: cs.onSurface.withValues(alpha: 0.3),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l.noKeys,
                            style: TextStyle(
                                color: cs.onSurface.withValues(alpha: 0.6)),
                          ),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _showAddOptions,
                            icon: const Icon(Icons.add, size: 18),
                            label: Text(l.addKey),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF00C896),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(top: 8, bottom: 80),
                      itemCount: keys.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 0.5,
                        thickness: 0.5,
                        indent: 64,
                        color: cs.onSurface.withValues(alpha: 0.08),
                      ),
                      itemBuilder: (context, i) =>
                          _buildRow(context, l, cs, keys[i]),
                    ),
          // Hidden in the empty state (the centered CTA covers that case) and
          // while loading; shown only once there are keys to sit alongside.
          floatingActionButton: (loading || isEmpty)
              ? null
              : FloatingActionButton.extended(
                  onPressed: _showAddOptions,
                  icon: const Icon(Icons.add),
                  label: Text(l.addKey),
                ),
        );
      },
    );
  }

  Widget _buildRow(
      BuildContext context, AppLocalizations l, ColorScheme cs, SSHKey key) {
    const accent = Color(0xFF00C896);
    final isEd25519 = key.type == 'ed25519';
    final typeLabel = isEd25519 ? 'ED25519' : 'RSA';
    // Show last ~28 chars of public key as fingerprint preview
    final pub = key.publicKey.trim();
    final preview = pub.length > 28 ? '…${pub.substring(pub.length - 28)}' : pub;

    return InkWell(
      onTap: () => _copyPublicKey(key),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 左侧 icon box
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: cs.surfaceVariant.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: cs.onSurface.withValues(alpha: 0.08),
                  width: 0.5,
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.key_outlined,
                size: 18,
                color: cs.onSurface.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(width: 12),
            // 中间两行
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    key.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11.5,
                      color: cs.onSurface.withValues(alpha: 0.6),
                      height: 1.25,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 右侧 key type chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                border: Border.all(color: accent, width: 0.8),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(
                typeLabel,
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  color: accent,
                  height: 1.0,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            // 三点菜单
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_vert,
                size: 20,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'copy',
                  child: Row(
                    children: [
                      const Icon(Icons.copy_outlined, size: 18),
                      const SizedBox(width: 8),
                      Text(l.copyPublicKey),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline,
                          size: 18, color: cs.error),
                      const SizedBox(width: 8),
                      Text(l.delete,
                          style: TextStyle(color: cs.error)),
                    ],
                  ),
                ),
              ],
              onSelected: (v) {
                if (v == 'copy') _copyPublicKey(key);
                if (v == 'delete') _deleteKey(key);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyPublicKey(SSHKey key) async {
    await Clipboard.setData(ClipboardData(text: key.publicKey));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.publicKeyCopied)),
      );
    }
  }

  Future<void> _deleteKey(SSHKey key) async {
    final l = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.deleteKeyTitle),
        content: Text(l.confirmDeleteKey(key.name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.delete)),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final repo = context.read<SSHKeyRepository>();
      final storage = context.read<SecureStorageService>();
      await repo.delete(key.id);
      await storage.deletePrivateKey(key.id);
      _reload();
    }
  }

  Future<void> _showAddOptions() async {
    final l = context.l10n;
    await showModalBottomSheet(
      context: context,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.auto_awesome),
            title: Text(l.generateEd25519),
            onTap: () { Navigator.pop(context); _generateKey('ed25519'); },
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome),
            title: Text(l.generateRsa4096),
            onTap: () { Navigator.pop(context); _generateKey('rsa'); },
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: Text(l.importFromPem),
            onTap: () { Navigator.pop(context); _importKey(); },
          ),
        ],
      ),
    );
  }

  Future<void> _generateKey(String type) async {
    final name = await _promptName();
    if (name == null || name.isEmpty) return;

    final result = type == 'ed25519'
        ? await KeyService.generateEd25519()
        : await KeyService.generateRSA();

    await _saveKey(name: name, type: type, result: result);
  }

  Future<void> _importKey() async {
    final input = await _promptPem();
    if (input == null || input.pem.isEmpty) return;
    final name = await _promptName();
    if (name == null || name.isEmpty) return;

    try {
      final result = await KeyService.importFromPem(
        input.pem,
        passphrase: input.passphrase.isEmpty ? null : input.passphrase,
      );
      final keyType = input.pem.contains('ED25519') ? 'ed25519' : 'rsa';
      await _saveKey(name: name, type: keyType, result: result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.keyImportFailed('$e'))),
        );
      }
    }
  }

  Future<void> _saveKey({
    required String name,
    required String type,
    required SSHKeyPairResult result,
  }) async {
    final id = const Uuid().v4();
    final key = SSHKey(
        id: id,
        name: name,
        type: type,
        publicKey: result.publicKeyOpenSSH);
    final repo = context.read<SSHKeyRepository>();
    final storage = context.read<SecureStorageService>();
    await repo.insert(key);
    await storage.savePrivateKey(id, result.privateKeyPem);
    if (mounted) _reload();
  }

  Future<String?> _promptName() {
    final l = context.l10n;
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.keyName),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: l.keyNameHint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: Text(l.confirm)),
        ],
      ),
    );
  }

  Future<({String pem, String passphrase})?> _promptPem() {
    final l = context.l10n;
    final pemCtrl = TextEditingController();
    final ppCtrl = TextEditingController();
    return showDialog<({String pem, String passphrase})>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.pastePem),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pemCtrl,
              maxLines: 6,
              decoration: const InputDecoration(
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY-----\n...'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ppCtrl,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l.labelPassword,
                hintText: l.keyPassphraseEmptyHint,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(
                    context,
                    (pem: pemCtrl.text.trim(), passphrase: ppCtrl.text),
                  ),
              child: Text(l.importAction)),
        ],
      ),
    );
  }
}

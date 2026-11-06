// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import '../../util/dlog.dart';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'aqt_bootstrap.dart' show kAqtCongestion;

/// Three-state install result; success/declined/error are mutually exclusive.
enum AqtInstallStatus { success, declined, error }

class AqtInstallResult {
  final AqtInstallStatus status;
  final String? errorReason;

  const AqtInstallResult.success()
      : status = AqtInstallStatus.success,
        errorReason = null;

  const AqtInstallResult.declined()
      : status = AqtInstallStatus.declined,
        errorReason = null;

  const AqtInstallResult.error(String reason)
      : status = AqtInstallStatus.error,
        errorReason = reason;
}

/// Server-side install path: ~/.flyterm-server/bin/flyterm-server
/// String constants kept here so other modules (bootstrap) can reference them
/// without duplicating literals.
const String kRemoteServerDir = r'$HOME/.flyterm-server';
const String kRemoteServerBin = r'$HOME/.flyterm-server/bin/flyterm-server';
const String kRemoteInstallLog = r'$HOME/.flyterm-server/install.log';

/// Parsed outcome of `flyterm-server --install`. One of three cases.
class SelfInstallOutcome {
  final bool success;
  final int? port;
  final int? pid;
  final String? version;
  final String? errorReason;
  final int exitCode;

  const SelfInstallOutcome._({
    required this.success,
    this.port,
    this.pid,
    this.version,
    this.errorReason,
    required this.exitCode,
  });

  /// Parse stdout. Looks for INSTALL_OK port=N pid=N version=V or
  /// INSTALL_ERR reason=...
  factory SelfInstallOutcome.parse({
    required String stdout,
    required String stderr,
    required int exitCode,
  }) {
    final okRe = RegExp(
      r'INSTALL_OK\s+port=(\d+)\s+pid=(\d+)\s+version=(\S+)');
    final m = okRe.firstMatch(stdout);
    if (m != null) {
      return SelfInstallOutcome._(
        success: true,
        port: int.tryParse(m.group(1)!),
        pid: int.tryParse(m.group(2)!),
        version: m.group(3),
        exitCode: exitCode,
      );
    }
    final errRe = RegExp(r'INSTALL_ERR\s+reason=(.+)$', multiLine: true);
    final em = errRe.firstMatch(stdout);
    final reason = em?.group(1)?.trim()
        ?? (stderr.trim().isNotEmpty
            ? 'no INSTALL_* line; stderr=${stderr.trim()}'
            : 'no INSTALL_* line; stdout=${stdout.trim()}');
    return SelfInstallOutcome._(
      success: false,
      errorReason: reason,
      exitCode: exitCode,
    );
  }
}

/// Pure data + SSH/SFTP operations. UI (dialog) lives in aqt_install_dialog.dart.
/// Caller is responsible for showing the dialog before calling installBinary().
class AqtServerInstaller {
  /// Detect remote machine architecture via `uname -m`.
  /// Returns canonical name "x86_64" | "aarch64", or null if unsupported.
  static Future<String?> detectArch(SSHClient client) async {
    try {
      final session = await client.execute('uname -m');
      final out = StringBuffer();
      await for (final chunk in session.stdout) {
        out.write(String.fromCharCodes(chunk));
      }
      await session.done;
      return parseArch(out.toString());
    } catch (e) {
      dlog('Installer', 'detectArch failed: $e');
      return null;
    }
  }

  /// Pure function — testable without SSH.
  /// Maps uname -m output to canonical arch name; returns null if unsupported.
  static String? parseArch(String unameOutput) {
    final raw = unameOutput.trim().toLowerCase();
    switch (raw) {
      case 'x86_64':
      case 'amd64':
        return 'x86_64';
      case 'aarch64':
      case 'arm64':
        return 'aarch64';
      default:
        return null;
    }
  }

  /// Asset path within APK for a given canonical arch.
  /// APK asset path for a given canonical arch.
  /// Binary is stored gzipped (~65% smaller) and decompressed on the remote
  /// after SFTP upload, saving install bandwidth — especially helpful on 4G.
  static String assetPathFor(String arch) =>
      'assets/flyterm-server/flyterm-server-linux-$arch.gz';

  /// Load binary bytes from APK assets.
  static Future<Uint8List> loadBinaryAsset(String arch) async {
    final bd = await rootBundle.load(assetPathFor(arch));
    return bd.buffer.asUint8List();
  }

  /// Load VERSION string from APK assets (e.g. "0.2.0-fa9c589").
  /// Caller MUST .trim() if comparing; we return raw (may have trailing newline).
  static Future<String> loadVersionString() async {
    final bd = await rootBundle.load('assets/flyterm-server/VERSION');
    return String.fromCharCodes(bd.buffer.asUint8List()).trim();
  }

  /// Upload binary via SFTP to ~/.flyterm-server/bin/flyterm-server.
  /// Uses atomic .tmp + rename pattern to avoid leaving partial files.
  /// chmod 755 + appends an audit line to ~/.flyterm-server/install.log.
  ///
  /// Throws Exception with detailed message on any failure.
  /// Caller wraps in AqtInstallResult.error.
  ///
  /// [bytes] is the pre-loaded binary content (caller uses
  /// [loadBinaryAsset] to get this — pre-loading lets the install dialog
  /// display the precise size before user consents to the upload).
  /// [arch] is recorded in the install.log audit line.
  static Future<void> uploadBinary(
    SSHClient client,
    Uint8List bytes,
    String arch, {
    required String flytermVersion, // app version, e.g. "2.3.10"
    required String binaryVersion, // from VERSION asset
    void Function(double progress)? onProgress,
  }) async {
    final sftp = await client.sftp();

    // mkdir -p ~/.flyterm-server/bin (atomic w/ chmod for safety)
    final mkdirSession = await client.execute(
      'mkdir -p ~/.flyterm-server/bin 2>&1; chmod 700 ~/.flyterm-server',
    );
    await mkdirSession.done;
    if (mkdirSession.exitCode != 0) {
      throw Exception('mkdir failed (exit ${mkdirSession.exitCode})');
    }

    // Resolve $HOME because SFTP paths don't expand env vars
    final homeSession = await client.execute(r'echo $HOME');
    final homeBuf = StringBuffer();
    await for (final chunk in homeSession.stdout) {
      homeBuf.write(String.fromCharCodes(chunk));
    }
    await homeSession.done;
    final home = homeBuf.toString().trim();
    if (homeSession.exitCode != 0 || home.isEmpty) {
      throw Exception(
        'failed to resolve \$HOME (exit ${homeSession.exitCode})',
      );
    }

    // Upload as .tmp.gz; remote gunzip will produce .tmp; then rename to final.
    final remoteTmpGz = '$home/.flyterm-server/bin/flyterm-server.tmp.gz';
    final remoteTmp = '$home/.flyterm-server/bin/flyterm-server.tmp';
    final remoteFinal = '$home/.flyterm-server/bin/flyterm-server';

    // SFTP open + chunked write + close (uploading the GZIPPED bytes)
    final file = await sftp.open(
      remoteTmpGz,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.truncate |
          SftpFileOpenMode.write,
    );
    try {
      // dartssh2 SftpFile.writeBytes(data, {offset = 0}) — offset MUST be
      // supplied per chunk; without it every chunk overwrites the file at
      // position 0, leaving only the last 64 KB visible (and corrupt).
      const chunkSize = 64 * 1024;
      var sent = 0;
      while (sent < bytes.length) {
        final end = (sent + chunkSize) > bytes.length
            ? bytes.length
            : sent + chunkSize;
        final chunk = bytes.sublist(sent, end);
        await file.writeBytes(chunk, offset: sent);
        sent = end;
        onProgress?.call(sent / bytes.length);
      }
      await file.close();
    } catch (e) {
      // Best-effort: close file handle then remove orphan .tmp.gz file on
      // remote. Both ops swallow errors so original exception propagates.
      try { await file.close(); } catch (_) {}
      try {
        final cleanup = await client.execute('rm -f "$remoteTmpGz"');
        await cleanup.done;
      } catch (_) {}
      rethrow;
    }

    // Decompress + chmod 755 + atomic rename + install.log
    // gunzip -f overwrites .tmp if present; produces remoteTmp from remoteTmpGz
    // (and removes the .gz). Final mv is atomic on same filesystem.
    final installSession = await client.execute(
      'gunzip -f "$remoteTmpGz" && '
      'chmod 755 "$remoteTmp" && '
      'mv "$remoteTmp" "$remoteFinal" && '
      'echo "[\$(date -Iseconds)] installed v$binaryVersion by FlyTerm v$flytermVersion arch=$arch" '
      '>> "$home/.flyterm-server/install.log"',
    );
    await installSession.done;
    if (installSession.exitCode != 0) {
      throw Exception(
        'install finalize failed (exit ${installSession.exitCode})',
      );
    }
  }

  /// Verify the just-installed binary is executable by checking --version exits 0.
  /// Returns the version string (stdout, trimmed) or null if non-zero exit.
  /// Empty stdout with exit 0 returns an empty string (not null) — null is
  /// reserved exclusively for non-zero exit / failure.
  static Future<String?> verifyInstall(SSHClient client) async {
    final session = await client.execute(
      r'$HOME/.flyterm-server/bin/flyterm-server --version 2>&1',
    );
    final out = StringBuffer();
    await for (final chunk in session.stdout) {
      out.write(String.fromCharCodes(chunk));
    }
    await session.done;
    if (session.exitCode != 0) {
      dlog('Installer',
        '--version exit ${session.exitCode}: ${out.toString()}',
      );
      return null;
    }
    return out.toString().trim();
  }

  /// Upload + run `--install` flow. Replaces the gunzip+chmod+mv+pkill+
  /// spawn dance with a single SSH exec to `flyterm-server.new --install`.
  /// The newly-uploaded binary handles its own kill-old + atomic-rename
  /// + spawn-new + poll-daemon.info, then prints
  /// `INSTALL_OK port=N pid=N version=V` or `INSTALL_ERR reason=...`.
  ///
  /// Returns the parsed install result. Throws Exception on transport
  /// errors (SFTP, SSH exec); INSTALL_ERR is returned as a non-success
  /// result (not thrown).
  static Future<SelfInstallOutcome> uploadAndSelfInstall(
    SSHClient client,
    Uint8List gzippedBytes,
    String arch, {
    required String flytermVersion,
    required String binaryVersion,
    void Function(double progress)? onProgress,
  }) async {
    final sftp = await client.sftp();
    final mkdir = await client.execute(
      'mkdir -p ~/.flyterm-server/bin 2>&1; chmod 700 ~/.flyterm-server',
    );
    await mkdir.done;

    final homeSession = await client.execute(r'echo $HOME');
    final homeBuf = StringBuffer();
    await for (final chunk in homeSession.stdout) {
      homeBuf.write(String.fromCharCodes(chunk));
    }
    await homeSession.done;
    final home = homeBuf.toString().trim();
    if (home.isEmpty) {
      throw Exception('failed to resolve \$HOME');
    }
    final remoteNewGz = '$home/.flyterm-server/bin/flyterm-server.new.gz';
    final remoteNew   = '$home/.flyterm-server/bin/flyterm-server.new';

    // SFTP upload (same chunked-with-offset pattern as uploadBinary).
    final file = await sftp.open(
      remoteNewGz,
      mode: SftpFileOpenMode.create
          | SftpFileOpenMode.truncate
          | SftpFileOpenMode.write,
    );
    try {
      const chunkSize = 64 * 1024;
      var sent = 0;
      while (sent < gzippedBytes.length) {
        final end = (sent + chunkSize) > gzippedBytes.length
            ? gzippedBytes.length
            : sent + chunkSize;
        await file.writeBytes(gzippedBytes.sublist(sent, end), offset: sent);
        sent = end;
        onProgress?.call(sent / gzippedBytes.length);
      }
      await file.close();
    } catch (e) {
      try { await file.close(); } catch (_) {}
      try {
        final cleanup = await client.execute('rm -f "$remoteNewGz"');
        await cleanup.done;
      } catch (_) {}
      rethrow;
    }

    // Single SSH exec: gunzip + chmod + invoke --install.
    // The .new binary handles everything else internally.
    //
    // `--congestion` 必须在这里也给一遍：`--install` 会**自己**杀掉旧 daemon
    // 再拉起新的，而 App 随后的 bootstrap 探到 daemon.info 就直接复用它 ——
    // 也就是说升级路径上，`bootstrapDaemonStrict` 里那条带 flag 的启动命令
    // 根本没机会执行。装的时候要求什么配置，起起来就得是什么配置。
    final installSession = await client.execute(
      'gunzip -f "$remoteNewGz" && '
      'chmod 755 "$remoteNew" && '
      '"$remoteNew" --install --congestion $kAqtCongestion',
    );
    final outBuf = StringBuffer();
    final errBuf = StringBuffer();
    await Future.wait([
      installSession.stdout.cast<List<int>>().forEach(
        (b) => outBuf.write(String.fromCharCodes(b))),
      installSession.stderr.cast<List<int>>().forEach(
        (b) => errBuf.write(String.fromCharCodes(b))),
    ]);
    await installSession.done;
    final exitCode = installSession.exitCode ?? -1;
    return SelfInstallOutcome.parse(
      stdout: outBuf.toString(),
      stderr: errBuf.toString(),
      exitCode: exitCode,
    );
  }

  /// Check the version of the already-installed binary on the remote.
  ///
  /// 1. If daemon is running: parse `AQT_VERSION=` from `--status` output.
  ///    This is the version of the live process — most authoritative.
  /// 2. Otherwise: run `--version` on the binary (disk version).
  /// 3. Returns null if no binary is found.
  ///
  /// All sources now use the same "cargo_ver-git_sha" format (e.g.
  /// "0.2.0-52c42fd"), enabling a plain string comparison against the
  /// APK-bundled VERSION asset.
  static Future<String?> checkRemoteVersion(SSHClient client) async {
    try {
      final session = await client.execute(
        r'BIN="$HOME/.flyterm-server/bin/flyterm-server"; '
        r'[ -x "$BIN" ] || BIN=/usr/local/bin/flyterm-server; '
        r'if ! [ -x "$BIN" ]; then exit 0; fi; '
        // Prefer running daemon version (in-memory, most accurate).
        r'STATUS=$($BIN --status 2>/dev/null || true); '
        r'VER=$(echo "$STATUS" | grep "^AQT_VERSION=" | cut -d= -f2); '
        r'if [ -n "$VER" ]; then echo "$VER"; exit 0; fi; '
        // No daemon running — fall back to binary --version (disk version).
        r'"$BIN" --version 2>/dev/null || true',
      );
      final out = StringBuffer();
      await for (final chunk in session.stdout) {
        out.write(String.fromCharCodes(chunk));
      }
      await session.done;
      final v = out.toString().trim();
      return v.isEmpty ? null : v;
    } catch (e) {
      dlog('Installer', 'checkRemoteVersion error: $e');
      return null;
    }
  }
}

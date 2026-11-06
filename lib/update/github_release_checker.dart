// SPDX-License-Identifier: GPL-3.0-or-later
// lib/update/github_release_checker.dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_checker.dart';
import 'version_compare.dart';

/// internal — public 只是为了让 test 能 import。
class GitHubLatestRelease {
  const GitHubLatestRelease({
    required this.tagName,
    required this.releaseNotes,
    required this.isMandatory,
  });
  final String tagName;
  final String releaseNotes;
  final bool isMandatory;
}

/// iOS 更新检查：GET https://api.github.com/repos/{owner}/{repo}/releases/latest
/// 用 release 的 tag_name 和当前 PackageInfo.version 比对。
class GitHubReleaseChecker implements UpdateChecker {
  GitHubReleaseChecker({
    required this.owner,
    required this.repo,
    required this.appStoreUrl,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// 默认值。Owner/repo 改了在这里调。appStoreUrl 的 id 要等上架拿到
  /// 才能填 —— 在那之前 home_screen 不会走到这个分支。
  factory GitHubReleaseChecker.iosDefault() => GitHubReleaseChecker(
        owner: 'bytemind-ai',
        repo: 'flyterm',
        appStoreUrl: 'https://apps.apple.com/app/flyterm/idTBD',
      );

  final String owner;
  final String repo;
  final String appStoreUrl;
  final http.Client _client;

  static GitHubLatestRelease? parseLatestRelease(String body) {
    try {
      final j = jsonDecode(body);
      if (j is! Map) return null;
      final tag = j['tag_name'];
      if (tag is! String || tag.isEmpty) return null;
      if (j['prerelease'] == true) return null;
      final notes = (j['body'] is String) ? j['body'] as String : '';
      return GitHubLatestRelease(
        tagName: tag,
        releaseNotes: notes,
        isMandatory: notes.contains('[MANDATORY]'),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<UpdateInfo?> check() async {
    try {
      final url = Uri.parse(
          'https://api.github.com/repos/$owner/$repo/releases/latest');
      final resp = await _client
          .get(url, headers: {'Accept': 'application/vnd.github+json'}).timeout(
              const Duration(seconds: 5));
      if (resp.statusCode != 200) return null;
      final latest = parseLatestRelease(resp.body);
      if (latest == null) return null;

      final info = await PackageInfo.fromPlatform();
      final current = info.version;
      if (!VersionCompare.isNewer(latest.tagName, current: current)) {
        return null;
      }
      return UpdateInfo(
        latestVersion: latest.tagName,
        currentVersion: current,
        isMandatory: latest.isMandatory,
        releaseNotes: latest.releaseNotes,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> launchUpdateFlow() async {
    final url = Uri.parse(appStoreUrl);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }
}

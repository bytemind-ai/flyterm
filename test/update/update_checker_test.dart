import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/update/github_release_checker.dart';

void main() {
  group('GitHubReleaseChecker.parseLatestRelease', () {
    test('extracts tag_name and body', () {
      final json = jsonEncode({
        'tag_name': 'v2.3.11',
        'body': 'Bug fixes and improvements.',
        'prerelease': false,
      });
      final r = GitHubReleaseChecker.parseLatestRelease(json);
      expect(r, isNotNull);
      expect(r!.tagName, 'v2.3.11');
      expect(r.releaseNotes, contains('Bug fixes'));
      expect(r.isMandatory, isFalse);
    });
    test('detects [MANDATORY] tag', () {
      final json = jsonEncode({
        'tag_name': 'v2.3.12',
        'body': '[MANDATORY] Critical security fix. Update immediately.',
      });
      final r = GitHubReleaseChecker.parseLatestRelease(json)!;
      expect(r.isMandatory, isTrue);
    });
    test('returns null for prerelease', () {
      final json = jsonEncode({
        'tag_name': 'v2.3.11-beta.1',
        'body': 'beta',
        'prerelease': true,
      });
      expect(GitHubReleaseChecker.parseLatestRelease(json), isNull);
    });
    test('returns null for malformed JSON', () {
      expect(GitHubReleaseChecker.parseLatestRelease('not json'), isNull);
      expect(GitHubReleaseChecker.parseLatestRelease('{}'), isNull);
    });
  });
}

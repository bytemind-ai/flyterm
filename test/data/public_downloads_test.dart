import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/public_downloads.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('sh.flyterm.app/media_store');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late File tmpFile;
  late List<MethodCall> calls;

  setUp(() async {
    calls = [];
    tmpFile = File('${Directory.systemTemp.path}/pd_test_${identityHashCode(calls)}.txt');
    await tmpFile.writeAsString('hello');
    PublicDownloads.debugIsAndroid = true;
    PublicDownloads.debugRequestStorage = null;
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    PublicDownloads.debugIsAndroid = null;
    PublicDownloads.debugRequestStorage = null;
    if (await tmpFile.exists()) await tmpFile.delete();
  });

  void mock(Future<Object?>? Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  test('non-Android platform is a no-op returning null', () async {
    PublicDownloads.debugIsAndroid = false;
    final r = await PublicDownloads.publish(source: tmpFile, fileName: 'a.txt');
    expect(r, isNull);
  });

  test('API 33: publishes and parses the native result + sends correct args',
      () async {
    mock((call) async {
      if (call.method == 'getAndroidSdkInt') return 33;
      if (call.method == 'publishToDownloads') {
        return {
          'uri': 'content://media/external/downloads/42',
          'displayName': 'a.txt',
          'publicPath': 'Download/FlyTerm/a.txt',
        };
      }
      return null;
    });

    final r = await PublicDownloads.publish(
      source: tmpFile,
      fileName: 'a.txt',
      mimeType: 'text/plain',
    );

    expect(r, isNotNull);
    expect(r!.publicPath, 'Download/FlyTerm/a.txt');
    expect(r.uri, 'content://media/external/downloads/42');

    final publishCall =
        calls.firstWhere((c) => c.method == 'publishToDownloads');
    final args = publishCall.arguments as Map;
    expect(args['sourcePath'], tmpFile.path);
    expect(args['fileName'], 'a.txt');
    expect(args['mimeType'], 'text/plain');
    // On API >= 29 the storage permission must NOT be requested.
    // (debugRequestStorage stays null; if it were called it would throw.)
  });

  test('API 28: requests storage permission before publishing', () async {
    var requested = false;
    PublicDownloads.debugRequestStorage = () async {
      requested = true;
      return true;
    };
    mock((call) async {
      if (call.method == 'getAndroidSdkInt') return 28;
      if (call.method == 'publishToDownloads') {
        return {'uri': null, 'displayName': 'a.txt', 'publicPath': '/sdcard/Download/FlyTerm/a.txt'};
      }
      return null;
    });

    final r = await PublicDownloads.publish(source: tmpFile, fileName: 'a.txt');
    expect(requested, true);
    expect(r!.publicPath, '/sdcard/Download/FlyTerm/a.txt');
    expect(r.uri, isNull);
  });

  test('API 28: denied permission throws PublicDownloadsPermissionException',
      () async {
    PublicDownloads.debugRequestStorage = () async => false;
    mock((call) async {
      if (call.method == 'getAndroidSdkInt') return 28;
      return null;
    });

    expect(
      () => PublicDownloads.publish(source: tmpFile, fileName: 'a.txt'),
      throwsA(isA<PublicDownloadsPermissionException>()),
    );
  });

  test('PERMISSION_REQUIRED native error triggers request + retry', () async {
    var attempts = 0;
    PublicDownloads.debugRequestStorage = () async => true;
    mock((call) async {
      if (call.method == 'getAndroidSdkInt') return 33; // skip up-front request
      if (call.method == 'publishToDownloads') {
        attempts++;
        if (attempts == 1) {
          throw PlatformException(code: 'PERMISSION_REQUIRED');
        }
        return {'uri': null, 'displayName': 'a.txt', 'publicPath': 'Download/FlyTerm/a.txt'};
      }
      return null;
    });

    final r = await PublicDownloads.publish(source: tmpFile, fileName: 'a.txt');
    expect(attempts, 2);
    expect(r!.publicPath, 'Download/FlyTerm/a.txt');
  });
}

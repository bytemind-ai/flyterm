import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('keyboardTrigger defaults to singleTap', () async {
    final settings = TerminalSettings(SecureStorageService());
    await settings.load();
    expect(settings.keyboardTrigger, KeyboardTriggerMode.singleTap);
  });

  test('setKeyboardTrigger persists and reloads correctly', () async {
    final storage = SecureStorageService();
    final settings = TerminalSettings(storage);
    await settings.load();

    await settings.setKeyboardTrigger(KeyboardTriggerMode.doubleTap);
    expect(settings.keyboardTrigger, KeyboardTriggerMode.doubleTap);

    final settings2 = TerminalSettings(storage);
    await settings2.load();
    expect(settings2.keyboardTrigger, KeyboardTriggerMode.doubleTap);
  });

  test('setKeyboardTrigger is no-op when value unchanged', () async {
    final settings = TerminalSettings(SecureStorageService());
    await settings.load();
    var notified = false;
    settings.addListener(() => notified = true);

    await settings.setKeyboardTrigger(KeyboardTriggerMode.singleTap);
    expect(notified, isFalse);
  });

  test('load falls back to singleTap for unrecognized stored value', () async {
    FlutterSecureStorage.setMockInitialValues(
        {'keyboard_trigger_mode': 'completely_unknown'});
    final settings = TerminalSettings(SecureStorageService());
    await settings.load();
    expect(settings.keyboardTrigger, KeyboardTriggerMode.singleTap);
  });
}

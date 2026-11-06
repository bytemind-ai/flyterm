import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/ssh/multiplexer/multiplexer_backend.dart';
import 'package:flyterm/ssh/multiplexer/none_backend.dart';
import 'package:flyterm/ssh/multiplexer/tmux_backend.dart';

void main() {
  group('MultiplexerBackend.sessionName', () {
    test('tmux prefix is t-', () {
      expect(
        MultiplexerBackend.sessionName(MultiplexerType.tmux, 'abcd1234efgh5678'),
        equals('t-abcd1234'),
      );
    });
    test('none returns empty string', () {
      expect(
        MultiplexerBackend.sessionName(MultiplexerType.none, 'abcd1234efgh5678'),
        equals(''),
      );
    });
    test('short id uses full id', () {
      expect(
        MultiplexerBackend.sessionName(MultiplexerType.tmux, 'abc'),
        equals('t-abc'),
      );
    });
  });

  group('NoneBackend', () {
    late NoneBackend backend;
    setUp(() => backend = NoneBackend());

    test('all capabilities are false', () {
      expect(backend.capabilities.copyModeScroll, isFalse);
      expect(backend.capabilities.mousePassthrough, isFalse);
      expect(backend.capabilities.persistSession, isFalse);
    });
    test('detect always returns true', () async {
      expect(await backend.detect(null), isTrue);
    });
    test('onNotFound always returns true', () async {
      expect(await backend.onNotFound(null, null), isTrue);
    });
    test('attachOrCreateCommand returns empty string', () {
      expect(backend.attachOrCreateCommand('t-abc1234'), equals(''));
    });
    test('isActive is always false', () {
      expect(backend.isActive, isFalse);
    });
    test('needsControlPipeReinit is always false', () {
      expect(backend.needsControlPipeReinit, isFalse);
    });
  });

  group('TmuxBackend', () {
    late TmuxBackend backend;
    setUp(() => backend = TmuxBackend());

    test('capabilities: copyModeScroll=true, persistSession=true', () {
      expect(backend.capabilities.copyModeScroll, isTrue);
      expect(backend.capabilities.mousePassthrough, isTrue);
      expect(backend.capabilities.persistSession, isTrue);
    });
    test('isActive starts false', () {
      expect(backend.isActive, isFalse);
    });
    test('attachOrCreateCommand uses flyterm- session name format', () {
      const key = 'bc1981a4-724b-4022-ad39-1fd05ae2379c';
      final cmd = backend.attachOrCreateCommand(key);
      expect(cmd, contains('flyterm-bc1981a4-724')); // TmuxHelper.sessionName format
      expect(cmd, contains('tmux'));
    });
    test('attachOrCreateCommand contains history-limit 1000', () {
      final cmd = backend.attachOrCreateCommand('bc1981a4-724b-4022-ad39-1fd05ae2379c');
      expect(cmd, contains('history-limit 1000'));
    });
  });

  // ShpoolBackend was removed (DB v22); see commit history if you need the
  // implementation for archeological reasons. tmux covers process persistence
  // with wider distro coverage; QUIC ring buffer covers the mobile-friendly
  // scrollback-without-copy-mode advantage that shpool used to provide.
}

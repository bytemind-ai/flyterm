import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/data/keybar_config.dart';

void main() {
  group('KeyToken JSON', () {
    test('TextToken roundtrips through JSON', () {
      final original = TextToken('ls -la');
      final json = original.toJson();
      expect(json, {'type': 'text', 'text': 'ls -la'});
      final decoded = KeyToken.fromJson(json) as TextToken;
      expect(decoded.text, 'ls -la');
    });

    test('SpecialToken roundtrips through JSON', () {
      final original = SpecialToken(SpecialKey.esc);
      final json = original.toJson();
      expect(json, {'type': 'special', 'key': 'esc'});
      final decoded = KeyToken.fromJson(json) as SpecialToken;
      expect(decoded.key, SpecialKey.esc);
    });

    test('SpecialToken roundtrips for every SpecialKey enum value', () {
      for (final key in SpecialKey.values) {
        final encoded = SpecialToken(key).toJson();
        final decoded = KeyToken.fromJson(encoded) as SpecialToken;
        expect(decoded.key, key, reason: 'key=$key');
      }
    });

    test('fromJson throws ArgumentError on unknown type', () {
      expect(() => KeyToken.fromJson({'type': 'nope'}),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('encodeSequence', () {
    test('TextToken passes through verbatim', () {
      expect(encodeSequence([TextToken('hello')]), 'hello');
    });

    test('special control keys map to standard bytes', () {
      expect(encodeSequence([SpecialToken(SpecialKey.esc)]), '\x1b');
      expect(encodeSequence([SpecialToken(SpecialKey.tab)]), '\t');
      expect(encodeSequence([SpecialToken(SpecialKey.enter)]), '\r');
      expect(encodeSequence([SpecialToken(SpecialKey.backspace)]), '\x7f');
    });

    test('arrow keys use xterm CSI A/B/C/D in default cursor mode', () {
      expect(encodeSequence([SpecialToken(SpecialKey.up)]), '\x1b[A');
      expect(encodeSequence([SpecialToken(SpecialKey.down)]), '\x1b[B');
      expect(encodeSequence([SpecialToken(SpecialKey.right)]), '\x1b[C');
      expect(encodeSequence([SpecialToken(SpecialKey.left)]), '\x1b[D');
    });

    test('arrow keys use SS3 OA/OB/OC/OD when cursorKeysAppMode is true', () {
      String enc(SpecialKey k) =>
          encodeSequence([SpecialToken(k)], cursorKeysAppMode: true);
      expect(enc(SpecialKey.up), '\x1bOA');
      expect(enc(SpecialKey.down), '\x1bOB');
      expect(enc(SpecialKey.right), '\x1bOC');
      expect(enc(SpecialKey.left), '\x1bOD');
    });

    test('Tier 1 editing/paging keys map to standard CSI sequences', () {
      expect(encodeSequence([SpecialToken(SpecialKey.delete)]), '\x1b[3~');
      expect(encodeSequence([SpecialToken(SpecialKey.insert)]), '\x1b[2~');
      expect(encodeSequence([SpecialToken(SpecialKey.pageUp)]), '\x1b[5~');
      expect(encodeSequence([SpecialToken(SpecialKey.pageDown)]), '\x1b[6~');
      expect(encodeSequence([SpecialToken(SpecialKey.shiftTab)]), '\x1b[Z');
    });

    test('Ctrl-modified arrows use CSI 1;5 form regardless of DECCKM', () {
      for (final appCursor in [false, true]) {
        expect(
            encodeSequence([SpecialToken(SpecialKey.ctrlUp)],
                cursorKeysAppMode: appCursor),
            '\x1b[1;5A');
        expect(
            encodeSequence([SpecialToken(SpecialKey.ctrlDown)],
                cursorKeysAppMode: appCursor),
            '\x1b[1;5B');
        expect(
            encodeSequence([SpecialToken(SpecialKey.ctrlRight)],
                cursorKeysAppMode: appCursor),
            '\x1b[1;5C');
        expect(
            encodeSequence([SpecialToken(SpecialKey.ctrlLeft)],
                cursorKeysAppMode: appCursor),
            '\x1b[1;5D');
      }
    });

    test('ctrlBackspace sends Ctrl+W (\\x17) for readline word-delete', () {
      expect(encodeSequence([SpecialToken(SpecialKey.ctrlBackspace)]), '\x17');
    });

    test('ctrlSpace sends NUL byte', () {
      expect(encodeSequence([SpecialToken(SpecialKey.ctrlSpace)]), '\x00');
    });

    test('non-arrow keys are unaffected by cursorKeysAppMode', () {
      expect(
          encodeSequence([SpecialToken(SpecialKey.esc)],
              cursorKeysAppMode: true),
          '\x1b');
      expect(
          encodeSequence([SpecialToken(SpecialKey.home)],
              cursorKeysAppMode: true),
          '\x1b[H');
      expect(
          encodeSequence([SpecialToken(SpecialKey.f1)],
              cursorKeysAppMode: true),
          '\x1bOP');
      expect(
          encodeSequence([SpecialToken(SpecialKey.ctrlC)],
              cursorKeysAppMode: true),
          '\x03');
    });

    test('home / end use CSI H / F', () {
      expect(encodeSequence([SpecialToken(SpecialKey.home)]), '\x1b[H');
      expect(encodeSequence([SpecialToken(SpecialKey.end)]), '\x1b[F');
    });

    test('F1..F4 use SS3 P/Q/R/S', () {
      expect(encodeSequence([SpecialToken(SpecialKey.f1)]), '\x1bOP');
      expect(encodeSequence([SpecialToken(SpecialKey.f2)]), '\x1bOQ');
      expect(encodeSequence([SpecialToken(SpecialKey.f3)]), '\x1bOR');
      expect(encodeSequence([SpecialToken(SpecialKey.f4)]), '\x1bOS');
    });

    test('F5..F12 use CSI N~ with the standard skip pattern', () {
      expect(encodeSequence([SpecialToken(SpecialKey.f5)]), '\x1b[15~');
      expect(encodeSequence([SpecialToken(SpecialKey.f6)]), '\x1b[17~');
      expect(encodeSequence([SpecialToken(SpecialKey.f7)]), '\x1b[18~');
      expect(encodeSequence([SpecialToken(SpecialKey.f8)]), '\x1b[19~');
      expect(encodeSequence([SpecialToken(SpecialKey.f9)]), '\x1b[20~');
      expect(encodeSequence([SpecialToken(SpecialKey.f10)]), '\x1b[21~');
      expect(encodeSequence([SpecialToken(SpecialKey.f11)]), '\x1b[23~');
      expect(encodeSequence([SpecialToken(SpecialKey.f12)]), '\x1b[24~');
    });

    test('ctrlA..ctrlZ map to \\x01..\\x1a', () {
      expect(encodeSequence([SpecialToken(SpecialKey.ctrlA)]), '\x01');
      expect(encodeSequence([SpecialToken(SpecialKey.ctrlC)]), '\x03');
      expect(encodeSequence([SpecialToken(SpecialKey.ctrlZ)]), '\x1a');
    });

    test('macro: ESC + :w + ENTER concatenates to one string', () {
      final seq = [
        SpecialToken(SpecialKey.esc),
        TextToken(':w'),
        SpecialToken(SpecialKey.enter),
      ];
      expect(encodeSequence(seq), '\x1b:w\r');
    });

    test('empty sequence encodes to empty string', () {
      expect(encodeSequence([]), '');
    });
  });

  group('KeyBarItem', () {
    test('roundtrips through JSON', () {
      final original = KeyBarItem(
        id: 'abc',
        label: 'Save',
        sequence: [
          SpecialToken(SpecialKey.esc),
          TextToken(':w'),
          SpecialToken(SpecialKey.enter),
        ],
        sticky: false,
        repeatable: false,
      );
      final j = original.toJson();
      final back = KeyBarItem.fromJson(j);
      expect(back.id, 'abc');
      expect(back.label, 'Save');
      expect(back.sequence.length, 3);
      expect(back.sticky, false);
      expect(back.repeatable, false);
    });

    test('sticky CTRL has empty sequence', () {
      final ctrl = KeyBarItem(
        id: 'ctrl',
        label: 'CTRL',
        sequence: const [],
        sticky: true,
        repeatable: false,
      );
      expect(ctrl.sequence, isEmpty);
      expect(ctrl.sticky, isTrue);
    });
  });

  group('defaultKeyBarItems', () {
    // 这一条**故意**保留完整的字面列表：它守的是顺序和成员，而顺序就是用户
    // 看到的键位排布，换成 length 之类的间接断言就守不住了。加键时照着改这里
    // 是预期成本。
    test('returns the seed items in bar order', () {
      final items = defaultKeyBarItems();
      expect(items.map((e) => e.label).toList(), [
        'ESC', 'TAB', 'CTRL', 'ALT', '⇧',
        '↑', '↓', '←', '→',
        '⌫',
        '|', '~', '/', '-',
      ]);
    });

    test('CTRL and ⇧ are the sticky defaults', () {
      final items = defaultKeyBarItems();
      final sticky = items.where((e) => e.sticky).map((e) => e.label).toList();
      expect(sticky, ['CTRL', '⇧']);
    });

    test('arrows and backspace are the only repeatable defaults', () {
      final items = defaultKeyBarItems();
      final repeatable =
          items.where((e) => e.repeatable).map((e) => e.label).toSet();
      expect(repeatable, {'↑', '↓', '←', '→', '⌫'});
    });

    test('default ESC encodes to \\x1b', () {
      final esc = defaultKeyBarItems().firstWhere((e) => e.label == 'ESC');
      expect(encodeSequence(esc.sequence), '\x1b');
    });

    test('every default has a unique id', () {
      final items = defaultKeyBarItems();
      final ids = items.map((e) => e.id).toSet();
      // 与 items.length 比，而不是与一个写死的数字比 —— 这一条测的是「有没有
      // 重复 id」，钉住数字只会让每次加键都在这里假红一次。
      expect(ids.length, items.length);
    });
  });

  group('RightButtonItem', () {
    test('roundtrips through JSON', () {
      final original = const RightButtonItem(
          type: RightButton.ai, enabled: false);
      final j = original.toJson();
      expect(j, {'type': 'ai', 'enabled': false});
      final back = RightButtonItem.fromJson(j);
      expect(back.type, RightButton.ai);
      expect(back.enabled, false);
    });

    test('roundtrips for every RightButton enum value', () {
      for (final t in RightButton.values) {
        final encoded = RightButtonItem(type: t, enabled: true).toJson();
        final decoded = RightButtonItem.fromJson(encoded);
        expect(decoded.type, t, reason: 'type=$t');
        expect(decoded.enabled, true);
      }
    });

    test('fromJson defaults enabled to true on missing key', () {
      final back = RightButtonItem.fromJson({'type': 'keyboard'});
      expect(back.enabled, true);
    });

    test('fromJson throws ArgumentError on unknown type', () {
      expect(
          () => RightButtonItem.fromJson({'type': 'nope', 'enabled': true}),
          throwsA(isA<ArgumentError>()));
    });

    test('copyWith updates only the specified fields', () {
      const original =
          RightButtonItem(type: RightButton.ai, enabled: true);
      final disabled = original.copyWith(enabled: false);
      expect(disabled.type, RightButton.ai);
      expect(disabled.enabled, false);
      final reTyped = original.copyWith(type: RightButton.microphone);
      expect(reTyped.type, RightButton.microphone);
      expect(reTyped.enabled, true);
    });
  });

  group('defaultRightButtons', () {
    test('returns 4 items (favorites, microphone, ai, attachFile) all enabled',
        () {
      final items = defaultRightButtons();
      expect(items.map((e) => e.type).toList(), [
        RightButton.favorites,
        RightButton.microphone,
        RightButton.ai,
        // 追加在末尾而不是插在中间：已有用户的按钮顺序不该因为新增功能而变。
        RightButton.attachFile,
      ]);
      expect(items.every((e) => e.enabled), isTrue);
    });

    test('does not include the deprecated keyboard right-button', () {
      expect(
          defaultRightButtons().any((e) => e.type == RightButton.keyboard),
          isFalse);
    });
  });
}

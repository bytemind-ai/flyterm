import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flyterm/sftp/sftp_entry.dart';
import 'package:flyterm/ui/design/fly_tokens.dart';
import 'package:flyterm/ui/sftp/file_kind_style.dart';

/// Luminance of a colour as perceived by the eye — the property the grayscale
/// scheme actually encodes. Used to assert *relative* ordering rather than
/// hardcoded hex values, so retuning `FlyColors` doesn't break these tests.
double _luminance(Color c) => c.computeLuminance();

void main() {
  group('iconFor', () {
    test('every FileKind has an icon', () {
      for (final kind in FileKind.values) {
        expect(iconFor(kind), isNotNull, reason: kind.name);
      }
    });

    test('directory is visually distinct from every file kind', () {
      for (final kind in FileKind.values.where((k) => k != FileKind.directory)) {
        expect(iconFor(FileKind.directory), isNot(iconFor(kind)),
            reason: kind.name);
      }
    });

    test('well-known kinds map to their expected glyph', () {
      expect(iconFor(FileKind.image), Icons.image_outlined);
      expect(iconFor(FileKind.video), Icons.movie_outlined);
      expect(iconFor(FileKind.audio), Icons.audiotrack_outlined);
      expect(iconFor(FileKind.pdf), Icons.picture_as_pdf_outlined);
      expect(iconFor(FileKind.archive), Icons.folder_zip_outlined);
      expect(iconFor(FileKind.code), Icons.code);
      expect(iconFor(FileKind.database), Icons.storage_outlined);
    });

    test('unknown uses a deliberately empty-looking outline', () {
      expect(iconFor(FileKind.unknown), Icons.insert_drive_file_outlined);
    });
  });

  group('colorFor — grayscale tiers', () {
    test('directory is gray, not the theme primary', () {
      // Regression: directories were mint (`scheme.primary`) on the reasoning
      // that they are "interactive, not a file type". That spent the `active`
      // colour on a constant and collided with its meaning in the home list.
      expect(colorFor(FileKind.directory), FlyColors.textPrimary);
      expect(colorFor(FileKind.directory), isNot(const ColorScheme.dark().primary));
    });

    test('directory is told apart by shape, not colour', () {
      // The whole mechanism that replaces the colour.
      expect(iconFor(FileKind.directory), Icons.folder);
      for (final kind in FileKind.values.where((k) => k != FileKind.directory)) {
        expect(iconFor(kind).fontFamily, 'MaterialIcons',
            reason: '${kind.name} should be a Material glyph');
      }
    });

    test('no file kind uses a saturated hue, directories included', () {
      // The design system's立场: colour encodes state, never decoration.
      // A file *type* is not a state, so no kind may be tinted.
      for (final kind in FileKind.values) {
        final c = colorFor(kind);
        final max = [c.r, c.g, c.b].reduce((a, b) => a > b ? a : b);
        final min = [c.r, c.g, c.b].reduce((a, b) => a < b ? a : b);
        expect(max - min, lessThan(0.15),
            reason: '${kind.name} is tinted: $c');
      }
    });

    test('every file kind resolves to a FlyColors gray token', () {
      final grays = <Color>[
        FlyColors.textPrimary,
        FlyColors.textSecondary,
        FlyColors.textTertiary,
      ];
      for (final kind in FileKind.values) {
        expect(grays, contains(colorFor(kind)), reason: kind.name);
      }
    });

    test('mint is reserved for state, never used for a file kind', () {
      for (final kind in FileKind.values) {
        expect(colorFor(kind), isNot(FlyColors.active), reason: kind.name);
      }
    });

    test('user-openable types outrank the ones they never touch', () {
      double lum(FileKind k) => _luminance(colorFor(k));

      // code/text/config/markdown: highest tier — these are what the user came for.
      for (final k in [
        FileKind.code,
        FileKind.text,
        FileKind.config,
        FileKind.markdown,
      ]) {
        expect(colorFor(k), FlyColors.textPrimary, reason: k.name);
      }
      // media & documents: middle tier.
      for (final k in [
        FileKind.image,
        FileKind.video,
        FileKind.audio,
        FileKind.pdf,
        FileKind.font,
        FileKind.database,
      ]) {
        expect(colorFor(k), FlyColors.textSecondary, reason: k.name);
      }
      // archives & opaque binaries: lowest tier — "not your business".
      for (final k in [FileKind.archive, FileKind.binary, FileKind.unknown]) {
        expect(colorFor(k), FlyColors.textTertiary, reason: k.name);
      }

      expect(lum(FileKind.code), greaterThan(lum(FileKind.image)));
      expect(lum(FileKind.image), greaterThan(lum(FileKind.archive)));
    });

    test('tier ordering is preserved, not just the token names', () {
      expect(_luminance(FlyColors.textPrimary),
          greaterThan(_luminance(FlyColors.textSecondary)));
      expect(_luminance(FlyColors.textSecondary),
          greaterThan(_luminance(FlyColors.textTertiary)));
    });

    test('gray tiers stay readable against the page background', () {
      // Lowest tier must still clear the 3:1 icon minimum.
      double contrast(Color a, Color b) {
        final l1 = _luminance(a), l2 = _luminance(b);
        final hi = l1 > l2 ? l1 : l2, lo = l1 > l2 ? l2 : l1;
        return (hi + 0.05) / (lo + 0.05);
      }

      expect(contrast(FlyColors.textPrimary, FlyColors.background),
          greaterThan(4.5));
      expect(contrast(FlyColors.textSecondary, FlyColors.background),
          greaterThan(4.5));
      expect(contrast(FlyColors.textTertiary, FlyColors.background),
          greaterThan(3.0));
    });

    test('colourFor needs no ColorScheme, so results cannot drift with theme', () {
      // Structural guarantee rather than a value comparison: the function has
      // no theme input, so a file's colour cannot change when the user swaps
      // terminal palettes. (An earlier signature took a ColorScheme and used
      // it only for directories, which made this property hard to see.)
      final results = <Color>{};
      for (final kind in FileKind.values) {
        results.add(colorFor(kind));
      }
      // Calling twice must give identical values.
      for (final kind in FileKind.values) {
        expect(colorFor(kind), colorFor(kind), reason: kind.name);
      }
      expect(results.length, lessThanOrEqualTo(3),
          reason: 'at most three gray tiers should exist');
    });

    test('code, config and text are not distinguishable by colour alone', () {
      // Intentional: they share a tier. Distinction comes from the icon.
      expect(colorFor(FileKind.code), colorFor(FileKind.config));
      expect(colorFor(FileKind.code), colorFor(FileKind.text));
      expect(iconFor(FileKind.code), isNot(iconFor(FileKind.config)));
      expect(iconFor(FileKind.code), isNot(iconFor(FileKind.text)));
      expect(iconFor(FileKind.markdown), isNot(iconFor(FileKind.text)));
    });
  });

  group('软链角标', () {
    test('软链角标图标独立于文件类型图标', () {
      expect(symlinkBadgeIcon, isNotNull);
      for (final kind in FileKind.values) {
        expect(iconFor(kind), isNot(symlinkBadgeIcon), reason: kind.name);
      }
    });

    test('软链角标走低亮度灰，与灰阶方案一致', () {
      expect(symlinkBadgeColor, FlyColors.textTertiary);
    });
  });

  group('fileIcon / fileIconColor helpers', () {
    SftpEntry e(String name, {bool isDir = false}) => SftpEntry(
          name: name,
          path: '/$name',
          isDir: isDir,
          size: 10,
          modTime: DateTime(2024, 1, 1),
        );

    test('resolve through the entry classification', () {
      expect(fileIcon(e('a.png')), iconFor(FileKind.image));
      expect(fileIcon(e('a.mp4')), iconFor(FileKind.video));
      expect(fileIcon(e('a.dart')), iconFor(FileKind.code));
      expect(fileIcon(e('dir', isDir: true)), iconFor(FileKind.directory));
      expect(fileIcon(e('mystery')), iconFor(FileKind.unknown));
    });

    test('colour follows the same classification', () {
      expect(fileIconColor(e('a.png')), FlyColors.textSecondary);
      expect(fileIconColor(e('a.zip')), FlyColors.textTertiary);
      expect(fileIconColor(e('a.dart')), FlyColors.textPrimary);
      expect(fileIconColor(e('dir', isDir: true)), FlyColors.textPrimary);
    });
  });
}

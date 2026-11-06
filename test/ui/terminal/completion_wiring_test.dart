import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import 'package:flyterm/data/secure_storage.dart';
import 'package:flyterm/data/terminal_settings.dart';
import 'package:flyterm/l10n/l10n.dart';
import 'package:flyterm/ssh/completion_suggestion.dart';
import 'package:flyterm/ui/terminal/completion_popup.dart';
import 'package:flyterm/ui/terminal/terminal_widget.dart';

/// Covers the wiring of [CompletionPopup] into [TerminalWidget]'s own Stack —
/// not the popup's pixel-perfect anchor positioning, just that a non-empty
/// `completions` + a non-null `onAcceptCompletion` renders it, and either
/// being absent renders nothing. Mirrors the minimal provider setup from
/// `selection_enter_test.dart`.
Widget _wrap(
  Terminal terminal,
  TerminalSettings settings, {
  List<CompletionSuggestion> completions = const [],
  void Function(CompletionSuggestion)? onAcceptCompletion,
}) =>
    MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChangeNotifierProvider<TerminalSettings>.value(
        value: settings,
        child: Scaffold(
          body: SizedBox(
            width: 400,
            height: 800,
            child: TerminalWidget(
              terminal: terminal,
              shell: null,
              completions: completions,
              onAcceptCompletion: onAcceptCompletion,
              completionInput: 'gi',
            ),
          ),
        ),
      ),
    );

void main() {
  late Terminal terminal;
  late TerminalSettings settings;

  setUp(() {
    terminal = Terminal(maxLines: 1000);
    terminal.resize(80, 24);
    terminal.write('user@host:~\$ gi');
    settings = TerminalSettings(SecureStorageService());
  });

  testWidgets('非空 completions + onAcceptCompletion 时渲染浮层', (tester) async {
    await tester.pumpWidget(
      _wrap(
        terminal,
        settings,
        completions: const [
          CompletionSuggestion(
            text: 'git status',
            source: CompletionSource.history,
          ),
          CompletionSuggestion(text: 'git push', source: CompletionSource.shell),
        ],
        onAcceptCompletion: (_) {},
      ),
    );
    // The anchor rect is computed in a post-frame callback (see
    // _scheduleCompletionAnchorSync); one more pump is needed for the
    // ValueNotifier update it triggers to actually rebuild the popup.
    await tester.pump();

    expect(find.byType(CompletionPopup), findsOneWidget);
  });

  testWidgets('空 completions 时不渲染浮层', (tester) async {
    await tester.pumpWidget(_wrap(terminal, settings));
    await tester.pump();

    expect(find.byType(CompletionPopup), findsNothing);
  });

  testWidgets('completions 非空但 onAcceptCompletion 为 null 时不渲染', (tester) async {
    await tester.pumpWidget(
      _wrap(
        terminal,
        settings,
        completions: const [
          CompletionSuggestion(
            text: 'git status',
            source: CompletionSource.history,
          ),
        ],
      ),
    );
    await tester.pump();

    expect(find.byType(CompletionPopup), findsNothing);
  });
}

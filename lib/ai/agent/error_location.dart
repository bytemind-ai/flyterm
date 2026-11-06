// SPDX-License-Identifier: GPL-3.0-or-later
/// Turns a caught error + optional [StackTrace] into a short, actionable
/// string for the user-facing error banner (`_StoppedBanner` in
/// `agent_view.dart`).
///
/// ## Why this exists
///
/// `AgentLoop._run()` used to do `_errorMessage = e.toString();` and stop
/// there. For a `TypeError` (e.g. "Null check operator used on a null
/// value"), `toString()` carries **no location** — not even which of the
/// dozens of `!` in the codebase threw. The user sees the same one-line
/// message no matter which bug they hit, so a real-device repro can't be
/// turned into "which file, which line" without attaching a debugger.
///
/// ## Why only the first `package:flyterm/` frame
///
/// The banner (`_StoppedBanner`) renders `errorMessage` as a single line of
/// `bodySmall` text — there's no room for a full stack, and dumping one in
/// would bury the sentence that actually explains what happened (see
/// `AgentLoop._errorMessage`'s doc comment). Everything above the first
/// `package:flyterm/` frame in a caught exception's trace is Flutter/Dart
/// SDK plumbing (`dart:async`, `package:flutter/...`) that doesn't say
/// anything about *our* bug; the first frame that *does* name this package
/// is, almost always, the line the developer needs to open next.
library;

/// Package prefix used to recognise "our" frames in a stack trace.
const String kAppPackagePrefix = 'package:flyterm/';

/// One stack-trace line naming a `package:flyterm/...` frame.
///
/// Matches both the common JIT/debug shape —
/// `#3      Foo.bar (package:flyterm/ai/agent/agent_loop.dart:520:14)` —
/// and shapes missing the column number, which some AOT/release traces
/// produce.
final RegExp _frameRe =
    RegExp('${RegExp.escape(kAppPackagePrefix)}([\\w/.\\-]+\\.dart):(\\d+)');

/// Returns `lib/<path>:<line>` for the first stack frame under
/// `package:flyterm/`, or `null` if [stack] is `null`, empty, or — as can
/// happen with a release build whose traces have been stripped of
/// file/line info — contains no frame naming this package at all.
///
/// Picks the **first** match, not the last: the first `package:flyterm/`
/// frame from the top of the trace is the innermost one, i.e. the one
/// closest to where the exception was actually thrown. A later frame would
/// just point at whichever caller happened to invoke it.
String? extractProjectFrame(StackTrace? stack) {
  if (stack == null) return null;
  final text = stack.toString();
  if (text.isEmpty) return null;
  final match = _frameRe.firstMatch(text);
  if (match == null) return null;
  return 'lib/${match.group(1)}:${match.group(2)}';
}

/// Builds the string shown in the agent's stopped banner: [message], plus
/// one appended line naming the first project stack frame in [stack] if
/// one can be found.
///
/// Degrades to just [message] (unchanged) when no project frame is
/// found — e.g. an error with no stack trace at all, or a release build
/// whose traces have had file/line info stripped
/// (`--split-debug-info` without shipping `flutter symbolize` alongside
/// it). This repo's release build config does neither `--obfuscate` nor
/// `--split-debug-info` (see `CLAUDE.md` build commands), so in practice
/// `package:flyterm/...dart:LINE` frames are expected to survive into
/// release stack traces too — but this function must not assume that,
/// since a future build-flag change could silently take it away.
String describeError(String message, StackTrace? stack) {
  final frame = extractProjectFrame(stack);
  if (frame == null) return message;
  return '$message\n（at $frame）';
}

// SPDX-License-Identifier: GPL-3.0-or-later
// mirrors mosh::TimestampedState<UserStream> in src/network/transportstate.h
import 'dart:typed_data';

class SentState {
  final int num;
  final DateTime timestamp;
  /// Cumulative user input stream up to this state.
  /// mosh's UserStream::diff_from(prev) derives the on-wire diff from this.
  final Uint8List userInput;

  SentState({
    required this.num,
    required this.timestamp,
    required this.userInput,
  });
}

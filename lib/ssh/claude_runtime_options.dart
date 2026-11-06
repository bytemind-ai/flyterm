// SPDX-License-Identifier: GPL-3.0-or-later
class ClaudeRuntimeOptions {
  const ClaudeRuntimeOptions({
    this.noFlicker = true,
    this.disableMouse = false,
    this.scrollSpeed,
    this.forceSyncOutput = false,
    this.disableAlternateScreen = false,
    this.disableFastMode = false,
  });

  factory ClaudeRuntimeOptions.auto({required bool isMosh}) =>
      ClaudeRuntimeOptions(scrollSpeed: isMosh ? null : 3);

  final bool noFlicker;
  final bool disableMouse;
  final int? scrollSpeed;
  final bool forceSyncOutput;
  final bool disableAlternateScreen;
  final bool disableFastMode;

  List<String> toEnvAssignments() => [
    if (disableAlternateScreen)
      'CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1'
    else if (noFlicker)
      'CLAUDE_CODE_NO_FLICKER=1',
    if (disableMouse) 'CLAUDE_CODE_DISABLE_MOUSE=1',
    if (!disableMouse && scrollSpeed != null && scrollSpeed! > 1)
      'CLAUDE_CODE_SCROLL_SPEED=$scrollSpeed',
    if (forceSyncOutput) 'CLAUDE_CODE_FORCE_SYNC_OUTPUT=1',
    if (disableFastMode) 'CLAUDE_CODE_DISABLE_FAST_MODE=1',
  ];
}

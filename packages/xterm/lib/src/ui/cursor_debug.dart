import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/ui/cursor_type.dart';

/// Lightweight global cursor diagnostics for the app debug overlay.
///
/// This intentionally does not notify listeners.  The app overlay already
/// refreshes on a timer, and notifying from RenderObject.paint would risk
/// feedback loops.
final cursorDebug = CursorDebugState();

class CursorDebugState {
  TerminalCursorType? type;
  bool cursorVisibleMode = false;
  bool forceAppCursor = false;
  bool legacyCursor = false;
  bool usesOverlay = false;
  bool shouldShow = false;
  bool blinkVisible = true;
  bool menuActive = false;
  bool resizeForce = false;
  bool heightGrewScan = false;
  bool blockBypassBlink = false;
  bool composing = false;
  bool hasFocus = false;
  int cursorX = 0;
  int cursorY = 0;
  int absoluteCursorY = 0;
  CellOffset? forcedCell;
  CellOffset? currentCell;
  CellOffset? recoveryCell;
  CellOffset? lastCell;
  String source = '--';
  String forcedCellInfo = '--';
  String terminalCellInfo = '--';
  String currentCellInfo = '--';
  String recoveryCellInfo = '--';
  String lastCellInfo = '--';
  int suppressLineCount = 0;
  int suppressCellCount = 0;

  String get typeName => type?.name ?? '--';
  String get forcedCellText =>
      forcedCell == null ? '--' : '${forcedCell!.x},${forcedCell!.y}';
  String get currentCellText =>
      currentCell == null ? '--' : '${currentCell!.x},${currentCell!.y}';
  String get recoveryCellText =>
      recoveryCell == null ? '--' : '${recoveryCell!.x},${recoveryCell!.y}';
  String get lastCellText =>
      lastCell == null ? '--' : '${lastCell!.x},${lastCell!.y}';
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CustomTextEdit extends StatefulWidget {
  CustomTextEdit({
    super.key,
    required this.child,
    required this.onInsert,
    required this.onDelete,
    required this.onComposing,
    required this.onAction,
    required this.onKeyEvent,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    // this.initEditingState = TextEditingValue.empty,
    this.inputType = TextInputType.text,
    this.inputAction = TextInputAction.newline,
    this.keyboardAppearance = Brightness.light,
    this.deleteDetection = false,
  });

  final Widget child;

  final void Function(String) onInsert;

  final void Function(int count) onDelete;

  final void Function(String?) onComposing;

  final void Function(TextInputAction) onAction;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  final FocusNode focusNode;

  final bool autofocus;

  final bool readOnly;

  final TextInputType inputType;

  final TextInputAction inputAction;

  final Brightness keyboardAppearance;

  final bool deleteDetection;


  @override
  CustomTextEditState createState() => CustomTextEditState();
}

class CustomTextEditState extends State<CustomTextEdit> with TextInputClient {
  TextInputConnection? _connection;

  @override
  void initState() {
    widget.focusNode.addListener(_onFocusChange);
    super.initState();
  }

  @override
  void didUpdateWidget(CustomTextEdit oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }

    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else {
      if (oldWidget.readOnly && widget.focusNode.hasFocus) {
        _openInputConnection();
      }
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }

  bool get hasInputConnection => _connection != null && _connection!.attached;

  void requestKeyboard() {
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
  }

  void setEditingState(TextEditingValue value) {
    _currentEditingState = value;
    _connection?.setEditingState(value);
  }

  void setEditableRect(Rect rect, Rect caretRect) {
    if (!hasInputConnection) {
      return;
    }

    _connection?.setEditableSizeAndTransform(
      rect.size,
      Matrix4.translationValues(0, 0, 0),
    );

    _connection?.setCaretRect(caretRect);
  }

  void _onFocusChange() {
    _openOrCloseInputConnectionIfNeeded();
  }

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (_currentEditingState.composing.isCollapsed) {
      return widget.onKeyEvent(focusNode, event);
    }

    return KeyEventResult.skipRemainingHandlers;
  }

  void _openOrCloseInputConnectionIfNeeded() {
    if (widget.focusNode.hasFocus && widget.focusNode.consumeKeyboardToken()) {
      _openInputConnection();
    } else if (!widget.focusNode.hasFocus) {
      _closeInputConnectionIfNeeded();
    }
  }

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _openInputConnection() {
    if (!_shouldCreateInputConnection) {
      return;
    }

    if (hasInputConnection) {
      _connection!.show();
    } else {
      final config = TextInputConfiguration(
        inputType: widget.inputType,
        inputAction: widget.inputAction,
        keyboardAppearance: widget.keyboardAppearance,
        autocorrect: false,
        // FLYTERM: 必须保持 false —— 终端要的是「原始按键」，不是「文本编辑」。
        //
        // 引擎的 `inputTypeFromTextInputType` 在 `enableSuggestions == false`
        // 时会把 inputType 标成 `TYPE_TEXT_VARIATION_VISIBLE_PASSWORD` +
        // `TYPE_TEXT_FLAG_NO_SUGGESTIONS`，中文输入法于是把终端当成「不可联想
        // 的原始输入框」：拼音不建组合区、每个键直接以 `sendKeyEvent` 发出。
        // 这正是终端需要的语义（keystroke 原样送到远端）。
        //
        // **2026-10-26 实测反面教材，别再把这一行改成 true：**
        // 小爱超级输入法（9 键拼音）在 `enableSuggestions: true` 之后会把终端
        // 当成普通文本框，一切输入都先进 composing 组合区。于是
        //   • 按住退格只在删组合区的拼音，`updateEditingValue` 里 text 长度
        //     不缩（被下面的 composing 分支拦下），终端一个字节都收不到；
        //   • 真机读数：`ime del:0/0 hold:0 gap:0ms` —— 三条通道全空。
        // 换句话说：打开 suggestions 会把「退格能不能连发」换成了「退格根本
        // 不生效」，对中文输入法是净损失。
        enableSuggestions: false,
        // 终端输入是私密内容，不喂给输入法的个性化学习。
        enableIMEPersonalizedLearning: false,
      );

      _connection = TextInput.attach(this, config);

      _connection!.show();

      // setEditableRect(Rect.zero, Rect.zero);

      _connection!.setEditingState(_initEditingState);
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_connection != null && _connection!.attached) {
      _connection!.close();
      _connection = null;
    }
  }

  /// 删除缓冲的长度。上游是 2，FlyTerm 加大到 256 —— 见 [updateEditingValue]
  /// 里「长按退格删不动」那一节。缓冲越长，能扛住的连发越长（输入法只在缓冲
  /// 见底时才需要被补一次，而每次补都是一次可能打断连发的外部重置）。
  static const _kDeleteBufferLength = 256;
  static final String _kDeleteBuffer = ' ' * _kDeleteBufferLength;

  /// 缓冲剩这么少时才补回满值。越低 → 打断输入法连发的次数越少，
  /// 但留给「补充尚未送达」那段窗口的余量也越少。
  static const _kRefillThreshold = 32;

  /// 单次回调最多补发几个退格。
  ///
  /// 这**不是**为了保守，只用来兜一个竞态：`setEditingState` 异步送达，补缓冲
  /// 那一刻输入法可能还在按旧内容删，下一个回调的 text 会远短于我们刚写回的
  /// 满值 —— 差值被算成几十上百，一口气发出去就把用户的命令行清空了。
  ///
  /// 旧值 8 是个错误：平台通道回传慢于输入法连发时，Gboard 长按加速会把十几次
  /// 删除合并成一次回调，差值本来就常常超过 8，于是「少发」变成系统性丢删除。
  /// 48 远高于正常合并的上界（几十毫秒 × 二三十次/秒），只在竞态里才会命中。
  static const _kMaxDeletePerUpdate = 48;

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? TextEditingValue(
          text: _kDeleteBuffer,
          selection:
              const TextSelection.collapsed(offset: _kDeleteBufferLength),
        )
      : const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );

  late var _currentEditingState = _initEditingState.copyWith();

  /// 把缓冲补回满值，并同步本地镜像。
  ///
  /// 两件事必须一起做：[_currentEditingState] 是下一次算长度差的基准，
  /// 只发 `setEditingState` 而不更新它，下一次就会拿旧值当基准。
  void _resetEditingState() {
    _currentEditingState = _initEditingState;
    _connection?.setEditingState(_initEditingState);
  }

  @override
  TextEditingValue? get currentTextEditingValue {
    return _currentEditingState;
  }

  @override
  AutofillScope? get currentAutofillScope {
    return null;
  }

  /// ## FLYTERM: 长按输入法退格删不动的修复
  ///
  /// 上游实现有两处让长按连发失效：
  ///
  /// 1. **每删一次就把输入框重置回初始值。** Android 输入法在长按连发删除
  ///    时，一旦发现 InputConnection 被外部重置就会中止连发、重新开始 ——
  ///    于是无论缓冲多大，长按都只删掉一个字符。这是主因。
  /// 2. **无论删了几个字符都只发一个退格。** 平台通道的回传慢于输入法的
  ///    连发，多次删除会被合并成一次回调，中间那几次被悄悄丢掉。
  ///
  /// 对应的三项改动：缓冲从 2 加大到 [_kDeleteBufferLength]、只在见底
  /// （[_kRefillThreshold]）时才补、按长度差补发**同样多**的退格（以前无论
  /// 差多少都只发一个）。
  ///
  /// 长度差的基准是**上一次的状态**而不是 [_initEditingState]：不再每次
  /// 重置之后，输入法是从「上次删剩的内容」继续删的，拿初始缓冲当基准会
  /// 把差值算错。
  @override
  void updateEditingValue(TextEditingValue value) {
    final previous = _currentEditingState;
    _currentEditingState = value;


    // Get input after composing is done
    if (!_currentEditingState.composing.isCollapsed) {
      final text = _currentEditingState.text;
      final composingText = _currentEditingState.composing.textInside(text);
      widget.onComposing(composingText);
      return;
    }

    widget.onComposing(null);

    final shrunk = previous.text.length - _currentEditingState.text.length;
    if (shrunk > 0) {
      // 见 [_kMaxDeletePerUpdate]：截断只为兜「补缓冲尚未送达」的竞态，
      // 正常连发合并的差值远在其下界之内。
      final count =
          shrunk > _kMaxDeletePerUpdate ? _kMaxDeletePerUpdate : shrunk;
      widget.onDelete(count);

      if (_currentEditingState.text.length <= _kRefillThreshold) {
        _resetEditingState();
      }
      return;
    }

    if (shrunk < 0) {
      widget.onInsert(
        _currentEditingState.text.substring(previous.text.length),
      );
    }

    // 插入路径仍然每次重置：不复位的话 text 会一直增长，下一次的 substring
    // 基准跟着漂。只有删除路径需要「不打断」那条特殊待遇。
    if (_currentEditingState.text != _initEditingState.text) {
      _resetEditingState();
    }
  }

  @override
  void performAction(TextInputAction action) {
    // print('performAction $action');
    widget.onAction(action);
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // print('updateFloatingCursor $point');
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // print('showAutocorrectionPromptRect');
  }

  @override
  void connectionClosed() {
    // print('connectionClosed');
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // print('performPrivateCommand $action');
  }

  @override
  void insertTextPlaceholder(Size size) {
    // print('insertTextPlaceholder');
  }

  @override
  void removeTextPlaceholder() {
    // print('removeTextPlaceholder');
  }

  @override
  void showToolbar() {
    // print('showToolbar');
  }
}

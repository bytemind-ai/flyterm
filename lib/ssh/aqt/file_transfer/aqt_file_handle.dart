// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ffi';

import '../../transport/remote_transport.dart';
import '../aqt_ffi.dart';

class AqtFileHandle implements FileTransferHandle {
  final Pointer<Void> _sessionHandle;
  final int _requestId;
  final int _totalBytes;
  final StreamController<FileTransferProgress> _progressCtrl =
      StreamController.broadcast();

  AqtFileHandle({
    required Pointer<Void> sessionHandle,
    required int requestId,
    required int totalBytes,
  })  : _sessionHandle = sessionHandle,
        _requestId = requestId,
        _totalBytes = totalBytes;

  @override
  int get totalBytes => _totalBytes;

  @override
  Stream<FileTransferProgress> get progress => _progressCtrl.stream;

  @override
  Future<void> cancel() async {
    AqtFfi.fileCancel(_sessionHandle, _requestId);
    _progressCtrl.add(const FileTransferProgress(
      bytesDone: 0,
      state: FileTransferState.cancelled,
    ));
    await _progressCtrl.close();
  }

  void notifyProgress(int bytesDone, int? throughputBps) {
    if (_progressCtrl.isClosed) return;
    _progressCtrl.add(FileTransferProgress(
      bytesDone: bytesDone,
      throughputBps: throughputBps,
      state: FileTransferState.running,
    ));
  }

  void notifyDone({required FileTransferState state, String? error}) {
    if (_progressCtrl.isClosed) return;
    _progressCtrl.add(FileTransferProgress(
      bytesDone: _totalBytes,
      state: state,
      errorMessage: error,
    ));
    _progressCtrl.close();
  }
}

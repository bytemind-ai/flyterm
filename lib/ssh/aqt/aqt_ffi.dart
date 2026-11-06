// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import '../../util/dlog.dart';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// Load native library — errors here propagate into AqtTransport.connect()
// and appear in the QUIC fallback SnackBar with the real cause.
final DynamicLibrary _lib = () {
  if (Platform.isAndroid) {
    try {
      return DynamicLibrary.open('libaqt_client_ffi.so');
    } catch (e) {
      throw StateError('Failed to load libaqt_client_ffi.so: $e');
    }
  } else if (Platform.isIOS) {
    return DynamicLibrary.process();
  }
  throw UnsupportedError('AQT FFI only supported on Android/iOS');
}();

// Struct for connection params
final class AqtConnectParams extends Struct {
  external Pointer<Utf8> host;
  @Uint16()
  external int port;
  external Pointer<Uint8> spkiPtr;
  @IntPtr()
  external int spkiLen;
  external Pointer<Uint8> tokenPtr;
  external Pointer<Utf8> sni;
}

// FFI type aliases — existing
typedef _ConnectNative = Int32 Function(
    Pointer<AqtConnectParams>, Pointer<Pointer<Void>>);
typedef _ConnectDart = int Function(
    Pointer<AqtConnectParams>, Pointer<Pointer<Void>>);
typedef _CloseSig = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);
typedef _PollNative = Int32 Function(Pointer<Void>, Pointer<Uint8>,
    Pointer<Uint32>, Pointer<Uint8>, IntPtr, Pointer<IntPtr>);
typedef _PollDart = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>,
    Pointer<Uint8>, int, Pointer<IntPtr>);
typedef _StateSig = Int32 Function(Pointer<Void>);
typedef _StateDart = int Function(Pointer<Void>);
typedef _VoidSig = Int32 Function(Pointer<Void>);
typedef _VoidDart = int Function(Pointer<Void>);
typedef _BoolSig = Int32 Function(Pointer<Void>, Uint8);
typedef _BoolDart = int Function(Pointer<Void>, int);
typedef _FileCancelNative = Int32 Function(Pointer<Void>, Uint32);
typedef _FileCancelDart = int Function(Pointer<Void>, int);

// FFI type aliases — new tab/PTY functions
typedef _OpenTabNative = Int32 Function(
    Pointer<Void>, Uint16, Uint16, Pointer<Utf8>);
typedef _OpenTabDart = int Function(
    Pointer<Void>, int, int, Pointer<Utf8>);
typedef _WritePtyNative = Int32 Function(
    Pointer<Void>, Uint32, Pointer<Uint8>, IntPtr);
typedef _WritePtyDart = int Function(
    Pointer<Void>, int, Pointer<Uint8>, int);
typedef _ResizeTabNative = Int32 Function(
    Pointer<Void>, Uint32, Uint16, Uint16);
typedef _ResizeTabDart = int Function(
    Pointer<Void>, int, int, int);

// FFI type aliases — 0-RTT resume / session token
typedef _GetTokenNative = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _GetTokenDart = int Function(Pointer<Void>, Pointer<Uint8>);
typedef _ResumeNative = Int32 Function(
    Pointer<Pointer<Void>>, // out_handle — NEW
    Pointer<Utf8>, Uint16, Pointer<Uint8>, IntPtr,
    Pointer<Uint8>, Uint32, Uint64, Uint64, Uint64); // last arg = ring_tail_hash
typedef _ResumeDart = int Function(
    Pointer<Pointer<Void>>, // out_handle — NEW
    Pointer<Utf8>, int, Pointer<Uint8>, int,
    Pointer<Uint8>, int, int, int, int); // last arg = ring_tail_hash

// Lookup FFI functions — existing
final _ConnectDart _aqtConnect =
    _lib.lookup<NativeFunction<_ConnectNative>>('aqt_connect').asFunction();
final _CloseDart _aqtClose =
    _lib.lookup<NativeFunction<_CloseSig>>('aqt_close').asFunction();
final _PollDart _aqtPollEvent =
    _lib.lookup<NativeFunction<_PollNative>>('aqt_poll_event').asFunction();
final _StateDart _aqtState =
    _lib.lookup<NativeFunction<_StateSig>>('aqt_state').asFunction();
final _VoidDart _aqtHeartbeat =
    _lib.lookup<NativeFunction<_VoidSig>>('aqt_heartbeat').asFunction();
final _VoidDart _aqtRoam =
    _lib.lookup<NativeFunction<_VoidSig>>('aqt_roam').asFunction();
final _VoidDart _aqtRebind =
    _lib.lookup<NativeFunction<_VoidSig>>('aqt_rebind').asFunction();
final _BoolDart _aqtSetForeground =
    _lib.lookup<NativeFunction<_BoolSig>>('aqt_set_foreground').asFunction();
final _FileCancelDart _aqtFileCancel =
    _lib.lookup<NativeFunction<_FileCancelNative>>('aqt_file_cancel').asFunction();

// Lookup FFI functions — new tab/PTY functions
final _OpenTabDart _aqtOpenTab =
    _lib.lookup<NativeFunction<_OpenTabNative>>('aqt_open_tab').asFunction();
final _WritePtyDart _aqtWritePty =
    _lib.lookup<NativeFunction<_WritePtyNative>>('aqt_write_pty').asFunction();
final _ResizeTabDart _aqtResizeTab =
    _lib.lookup<NativeFunction<_ResizeTabNative>>('aqt_resize_tab').asFunction();

// Lookup FFI functions — 0-RTT resume (may not exist in .so yet; guarded below)
late final _GetTokenDart? _aqtGetSessionToken;
late final _ResumeDart? _aqtResume;

typedef _GetU64Native = Uint64 Function(Pointer<Void>);
typedef _GetU64Dart = int Function(Pointer<Void>);
late final _GetU64Dart? _aqtGetLastRecvAgeMs;

// RESUME 处置查询。
//
// 这里曾经是 _aqtGetLastResumeServerOutOff / _aqtGetLastResumeReplayBytes，
// Dart 侧读走后算 `serverOutOff - replayBytes` 反推「服务端是续传还是重建」。
// 那个判据在服务端一改语义时静默失效（d7dc3ef → e382759）。现在服务端直接
// 声明处置，客户端不推断。
typedef _GetI32Native = Int32 Function(Pointer<Void>);
typedef _GetI32Dart = int Function(Pointer<Void>);
typedef _GetExitStatusNative = Int32 Function(Pointer<Void>, Pointer<Uint8>);
typedef _GetExitStatusDart = int Function(Pointer<Void>, Pointer<Uint8>);
late final _GetI32Dart? _aqtGetResumeDisposition;
late final _GetU64Dart? _aqtGetResumeInSeenOff;
late final _GetU64Dart? _aqtGetResumeTtlSecs;
late final _GetU64Dart? _aqtGetResumePreludeLen;
late final _GetExitStatusDart? _aqtGetResumeExitStatus;

// FFI type alias — client→server notify ack (Route B; ack still rides the
// control stream, only the push direction moved to its own uni stream —
// see rust/aqt_client_ffi/src/ffi.rs's aqt_notify_ack doc comment).
typedef _NotifyAckNative = Int32 Function(Pointer<Void>, Uint64);
typedef _NotifyAckDart = int Function(Pointer<Void>, int);
late final _NotifyAckDart? _aqtNotifyAck;

/// QUIC path-level statistics surfaced as the debug overlay `path` row.
/// Wraps the C-ABI struct `AqtPathStats` from
/// `rust/aqt_client_ffi/src/ffi.rs`; refreshed on demand via
/// `AqtTransport.refreshPathStats()`.
class PathStats {
  final int rttUs;
  final int lostPackets;
  final int sentPackets;
  final int migrationCount;
  final int rebindingCount;
  final int cwndBytes;

  const PathStats({
    this.rttUs = 0,
    this.lostPackets = 0,
    this.sentPackets = 0,
    this.migrationCount = 0,
    this.rebindingCount = 0,
    this.cwndBytes = 0,
  });

  static const PathStats empty = PathStats();

  int get rttMs => (rttUs / 1000).round();
  double get lossRate =>
      sentPackets == 0 ? 0.0 : lostPackets / sentPackets;
  int get cwndKB => (cwndBytes / 1024).round();
}

/// Layout matches `AqtPathStats` in `rust/aqt_client_ffi/src/ffi.rs`.
/// Total 64 bytes (24-byte reserved tail for forward compat).
final class _AqtPathStatsStruct extends Struct {
  @Uint64() external int rttUs;
  @Uint64() external int lostPackets;
  @Uint64() external int sentPackets;
  @Uint32() external int migrationCount;
  @Uint32() external int rebindingCount;
  @Uint64() external int cwndBytes;
  @Array<Uint8>(24) external Array<Uint8> reserved;
}

typedef _GetPathStatsNative = Int32 Function(
    Pointer<Void>, Pointer<_AqtPathStatsStruct>);
typedef _GetPathStatsDart = int Function(
    Pointer<Void>, Pointer<_AqtPathStatsStruct>);
late final _GetPathStatsDart? _aqtGetPathStats;

void _initOptionalFfi() {
  try {
    _aqtGetSessionToken = _lib
        .lookup<NativeFunction<_GetTokenNative>>('aqt_get_session_token')
        .asFunction();
  } catch (_) {
    _aqtGetSessionToken = null;
  }
  try {
    _aqtGetResumeDisposition = _lib
        .lookup<NativeFunction<_GetI32Native>>('aqt_get_resume_disposition')
        .asFunction();
  } catch (_) {
    _aqtGetResumeDisposition = null;
  }
  try {
    _aqtGetResumeInSeenOff = _lib
        .lookup<NativeFunction<_GetU64Native>>('aqt_get_resume_in_seen_off')
        .asFunction();
  } catch (_) {
    _aqtGetResumeInSeenOff = null;
  }
  try {
    _aqtGetResumeTtlSecs = _lib
        .lookup<NativeFunction<_GetU64Native>>('aqt_get_resume_ttl_secs')
        .asFunction();
  } catch (_) {
    _aqtGetResumeTtlSecs = null;
  }
  try {
    _aqtGetResumePreludeLen = _lib
        .lookup<NativeFunction<_GetU64Native>>('aqt_get_resume_prelude_len')
        .asFunction();
  } catch (_) {
    _aqtGetResumePreludeLen = null;
    // 这是四种「读到 0」的成因里唯一指向**构建问题**的一支，也是唯一在
    // init 阶段就能确定的一支，所以只给它留痕。
    //
    // 这个符号是新加的：任何一次忘了重建 native 库的构建（Gradle 的
    // cargo ndk 集成在 cargo-ndk 缺失时只打一条 NOTE 就跳过，构建仍然
    // 成功）都会让设备上恒读到 0 —— 表现得和「服务端是旧版本」完全一样。
    // 而这条链路的全部意义就是做真机测量，测量本身的构建缺陷若无法察觉，
    // 采回来的基线会静默作废。
    dlog('AQT', 'aqt_get_resume_prelude_len 未找到 —— '
        'libaqt_client_ffi.so 可能是旧的（需要 cargo-ndk 重建 jniLibs）');
  }
  try {
    _aqtGetResumeExitStatus = _lib
        .lookup<NativeFunction<_GetExitStatusNative>>(
            'aqt_get_resume_exit_status')
        .asFunction();
  } catch (_) {
    _aqtGetResumeExitStatus = null;
  }
  try {
    _aqtGetLastRecvAgeMs = _lib
        .lookup<NativeFunction<_GetU64Native>>('aqt_get_last_recv_age_ms')
        .asFunction();
  } catch (_) {
    _aqtGetLastRecvAgeMs = null;
  }
  try {
    _aqtResume = _lib
        .lookup<NativeFunction<_ResumeNative>>('aqt_resume')
        .asFunction();
  } catch (_) {
    _aqtResume = null;
  }
  try {
    _aqtGetPathStats = _lib
        .lookup<NativeFunction<_GetPathStatsNative>>('aqt_get_path_stats')
        .asFunction();
  } catch (_) {
    _aqtGetPathStats = null;
  }
  try {
    _aqtNotifyAck = _lib
        .lookup<NativeFunction<_NotifyAckNative>>('aqt_notify_ack')
        .asFunction();
  } catch (_) {
    _aqtNotifyAck = null;
  }
}

final bool _optionalFfiInited = () {
  _initOptionalFfi();
  return true;
}();

/// AQT event kinds from Rust AqtEventKind (must match repr)
enum AqtEventKind {
  connected, // 0
  disconnected, // 1
  failed, // 2
  ptyOutput, // 3
  tabOpened, // 4
  tabClosed, // 5
  historyPreloadDone, // 6
  ticketReceived, // 7
  notify, // 8 — server-pushed self-hosted notification (Route B, own uni stream)
  // 9 曾是 scrollbackChunk（FetchScrollback 的响应）。整条通道随协议版本 2
  // 删除，**不要复用这个序号** —— 枚举按下标解析，复用会让旧 .so 推上来的
  // 事件被当成新语义处理。
}

/// A polled event from Rust
class AqtEvent {
  final AqtEventKind kind;
  final int tabId;
  final Uint8List data;

  /// Populated only when [kind] is [AqtEventKind.notify], decoded from [data]
  /// by [AqtFfi.decodeNotifyPayload]. Null for every other event kind.
  final int? notifyEventId;
  final int? notifyTsUnixMs;
  final int? notifyTabId;
  final String? notifyText;

  const AqtEvent({
    required this.kind,
    required this.tabId,
    required this.data,
    this.notifyEventId,
    this.notifyTsUnixMs,
    this.notifyTabId,
    this.notifyText,
  });
}

/// Decoded fields of a Notify event's `data` payload. See
/// [AqtFfi.decodeNotifyPayload] for the byte layout this mirrors.
class NotifyPayload {
  final int eventId;
  final int tsUnixMs;
  final int? tabId;
  final String text;
  const NotifyPayload({
    required this.eventId,
    required this.tsUnixMs,
    required this.tabId,
    required this.text,
  });
}

/// High-level Dart wrapper around the raw FFI functions.
class AqtFfi {
  /// Initiate connection. Returns opaque handle pointer.
  static Pointer<Void> connect({
    required String host,
    required int port,
    required Uint8List spki,
    required Uint8List sessionToken,
    required String sni,
  }) {
    final hostPtr = host.toNativeUtf8();
    final sniPtr = sni.toNativeUtf8();
    final spkiMem = calloc<Uint8>(spki.length);
    for (var i = 0; i < spki.length; i++) {
      spkiMem[i] = spki[i];
    }
    final tokenMem = calloc<Uint8>(32);
    for (var i = 0; i < 32; i++) {
      tokenMem[i] = sessionToken[i];
    }
    final params = calloc<AqtConnectParams>();
    params.ref
      ..host = hostPtr
      ..port = port
      ..spkiPtr = spkiMem
      ..spkiLen = spki.length
      ..tokenPtr = tokenMem
      ..sni = sniPtr;
    final outHandle = calloc<Pointer<Void>>();

    final code = _aqtConnect(params, outHandle);
    final handle = outHandle.value;

    calloc.free(hostPtr);
    calloc.free(sniPtr);
    calloc.free(spkiMem);
    calloc.free(tokenMem);
    calloc.free(outHandle);
    calloc.free(params);

    if (code != 0 || handle == nullptr) {
      throw StateError('aqt_connect failed: code=$code');
    }
    return handle;
  }

  static void close(Pointer<Void> handle) {
    if (handle == nullptr) return;
    _aqtClose(handle);
  }

  /// Poll one event. Returns null if no event available.
  // PollEvent buffer capacity. Must be >= the largest single PtyOutput event
  // the server can produce in one frame:
  //   • drive_pty_forwarder coalesce ceiling ≈ 32 KB + one PTY read (4 KB) ≈ 36 KB
  //   • spawn_pty_forwarder initial_bytes (RESUME / OPEN_TAB ring replay)
  //     is chunked at 1 MB by the server, so single frames can reach ~1 MB
  //
  // With the previous 4 KB cap, aqt_poll_event silently truncated any larger
  // event (copy_len = evt.data.len().min(data_cap)) and `data_len_out` only
  // reported the truncated length — the tail bytes were dropped without any
  // signal. That is the actual "compression-boundary byte loss" symptom users
  // reported and the reason DebugOverlay's chunk-size stats never exceeded
  // 4 KB no matter what.
  //
  // 1 MiB is a safe ceiling for the ring-replay path; per-poll allocation cost
  // at 60–120 Hz is acceptable on modern Android (calloc-then-free under one
  // ms). If allocation pressure ever becomes an issue, hoist this into a
  // per-AqtTransport reusable buffer.
  static const int _kPollBufferBytes = 1024 * 1024;

  static AqtEvent? pollEvent(Pointer<Void> handle) {
    if (handle == nullptr) return null;
    final kindPtr = calloc<Uint8>();
    final tabIdPtr = calloc<Uint32>();
    final dataBuf = calloc<Uint8>(_kPollBufferBytes);
    final dataLenPtr = calloc<IntPtr>();

    try {
      final code = _aqtPollEvent(
          handle, kindPtr, tabIdPtr, dataBuf, _kPollBufferBytes, dataLenPtr);
      if (code != 0) return null; // -1 = no event
      final kindVal = kindPtr.value;
      final kind = kindVal < AqtEventKind.values.length
          ? AqtEventKind.values[kindVal]
          : AqtEventKind.failed;
      final dataLen = dataLenPtr.value;
      final data = Uint8List(dataLen);
      for (var i = 0; i < dataLen; i++) {
        data[i] = dataBuf[i];
      }
      if (kind == AqtEventKind.notify) {
        final n = decodeNotifyPayload(data);
        return AqtEvent(
          kind: kind,
          tabId: tabIdPtr.value,
          data: data,
          notifyEventId: n.eventId,
          notifyTsUnixMs: n.tsUnixMs,
          notifyTabId: n.tabId,
          notifyText: n.text,
        );
      }
      return AqtEvent(kind: kind, tabId: tabIdPtr.value, data: data);
    } finally {
      calloc.free(kindPtr);
      calloc.free(tabIdPtr);
      calloc.free(dataBuf);
      calloc.free(dataLenPtr);
    }
  }

  /// Normalizes the raw `i64` `tab_id` sentinel packed by Rust's
  /// `encode_notify_payload` (`rust/aqt_client_ffi/src/ffi.rs`) into a
  /// nullable Dart int. `-1` (Rust's `Option<u32>::None` widened to i64,
  /// chosen because no real `u32` tab_id can ever widen to `-1`) becomes
  /// `null`; any non-negative value passes through unchanged. Pure function,
  /// exposed for unit testing this exact sentinel boundary.
  static int? normalizeNotifyTabId(int rawTabId) =>
      rawTabId < 0 ? null : rawTabId;

  /// Decodes a Notify event's `data` payload. Byte layout produced by
  /// `encode_notify_payload` in `rust/aqt_client_ffi/src/ffi.rs`:
  ///   [0..8)   event_id    u64 LE
  ///   [8..16)  ts_unix_ms  u64 LE
  ///   [16..24) tab_id      i64 LE — -1 means "no tab" (see
  ///                                 [normalizeNotifyTabId]).
  ///   [24..)   text        UTF-8, unprefixed (length is `data.length`).
  /// Pure function — exposed for unit testing.
  static NotifyPayload decodeNotifyPayload(Uint8List data) {
    final bd = ByteData.sublistView(data);
    final eventId = bd.getUint64(0, Endian.little);
    final tsUnixMs = bd.getUint64(8, Endian.little);
    final rawTabId = bd.getInt64(16, Endian.little);
    final text = utf8.decode(data.sublist(24));
    return NotifyPayload(
      eventId: eventId,
      tsUnixMs: tsUnixMs,
      tabId: normalizeNotifyTabId(rawTabId),
      text: text,
    );
  }

  /// Acknowledge notifications up to and including [lastEventId]. Writes a
  /// NotifyAck frame on the control stream (Route B only made the
  /// server→client push direction independent; the ack keeps riding the
  /// existing control bi-stream — see `aqt_notify_ack`'s doc comment in
  /// `rust/aqt_client_ffi/src/ffi.rs`). No-op if the FFI symbol is missing
  /// (old .so): the server will simply keep redelivering this notification
  /// until a client that can ack connects, which is the same
  /// redelivery-until-ack behaviour NotifyQueue already guarantees.
  static void notifyAck(Pointer<Void> handle, int lastEventId) {
    // ignore: unnecessary_statements
    _optionalFfiInited;
    final fn = _aqtNotifyAck;
    if (fn == null) return;
    fn(handle, lastEventId);
  }

  static int state(Pointer<Void> handle) => _aqtState(handle);
  static void heartbeat(Pointer<Void> handle) => _aqtHeartbeat(handle);
  static void roam(Pointer<Void> handle) => _aqtRoam(handle);
  /// True RFC 9000 §9 connection migration via Endpoint::rebind. Only call
  /// from positively-identified network-interface-change paths (NOT from
  /// generic stale-probe loops).
  static void rebind(Pointer<Void> handle) => _aqtRebind(handle);
  static void setForeground(Pointer<Void> handle, bool active) =>
      _aqtSetForeground(handle, active ? 1 : 0);

  static void fileCancel(Pointer<Void> handle, int requestId) {
    _aqtFileCancel(handle, requestId);
  }

  /// Open a new PTY tab. Result arrives as [AqtEventKind.tabOpened] event.
  static int openTab(
      Pointer<Void> handle, int cols, int rows, String term) {
    final termPtr = term.toNativeUtf8();
    try {
      return _aqtOpenTab(handle, cols, rows, termPtr);
    } finally {
      calloc.free(termPtr);
    }
  }

  /// Write PTY input bytes to [tabId].
  static void writePty(Pointer<Void> handle, int tabId, Uint8List data) {
    if (data.isEmpty) return;
    final dataPtr = calloc<Uint8>(data.length);
    for (var i = 0; i < data.length; i++) {
      dataPtr[i] = data[i];
    }
    try {
      _aqtWritePty(handle, tabId, dataPtr, data.length);
    } finally {
      calloc.free(dataPtr);
    }
  }

  /// Send a resize event for [tabId].
  static void resizeTab(
      Pointer<Void> handle, int tabId, int cols, int rows) {
    _aqtResizeTab(handle, tabId, cols, rows);
  }

  /// 一次 RESUME 里服务端对这个 tab 的处置。
  ///
  /// 字段与 Rust 的 `Disposition` 一一对应。客户端**按类型分派，不做任何
  /// 算术推断** —— 这里曾经有 `getLastResumeServerOutOff` /
  /// `getLastResumeReplayBytes` 两个方法，调用方用
  /// `serverOutOff - replayBytes` 反推「服务端是续传还是重建」，服务端一改
  /// 语义那个判据就静默失效（d7dc3ef → e382759）。
  /// 服务端在最近一次 RESUME_ACK 里下发的 session TTL（秒）。
  /// 0 = 拿不到（旧 .so / 还没 RESUME 过），调用方该用自己的兜底值。
  ///
  /// 让服务端下发而不是两侧各写一个常量 —— 后者正是「服务端 7 天 vs
  /// 客户端 110 分钟」那个 bug 的根源：锁屏过夜后服务端会话还活着，客户端
  /// 已经把 token 删了。
  static int resumeTtlSecs(Pointer<Void> handle) {
    // ignore: unnecessary_statements
    _optionalFfiInited;
    return _aqtGetResumeTtlSecs?.call(handle) ?? 0;
  }

  /// 服务端在最近一次 RESUME_ACK 里下发的快照字节数。0 = 没拿到。
  ///
  /// **只喂诊断**：客户端拿它判断快照流完了没有，好打上 replayComplete
  /// 时间戳。**不做任何数据分派** —— 见 aqt_protocol 里该字段的文档，
  /// 按字节数分派正是被推翻的那套 offset 语义的核心。
  static int resumePreludeLen(Pointer<Void> handle) {
    // ignore: unnecessary_statements
    _optionalFfiInited;
    return _aqtGetResumePreludeLen?.call(handle) ?? 0;
  }

  static AqtDisposition? resumeDisposition(Pointer<Void> handle) {
    // ignore: unnecessary_statements
    _optionalFfiInited;
    final code = _aqtGetResumeDisposition?.call(handle) ?? 0;
    switch (code) {
      case 1: // Restored
        // 恢复内容不在这里取 —— 它是新 PTY 流的头几个字节，随 live 输出
        // 一起流进终端。客户端对它不做任何特殊处理。
        return AqtRestored(
          serverInSeenOff: _aqtGetResumeInSeenOff?.call(handle) ?? 0,
        );
      case 2:
        return const AqtNewSession();
      case 3:
        final fn = _aqtGetResumeExitStatus;
        if (fn == null) return const AqtTabGone(null);
        final has = calloc<Uint8>();
        try {
          final status = fn(handle, has);
          return AqtTabGone(has.value == 1 ? status : null);
        } finally {
          calloc.free(has);
        }
      default:
        return null;
    }
  }

  /// Sentinel meaning "no inbound packet has ever been observed". Deliberately
  /// a large POSITIVE value: the watchdog treats larger as older.
  static const int kNeverReceivedAgeMs = 0x7fffffffffffffff;

  /// C1 — Milliseconds since last observed inbound quinn packet (PtyOutput,
  /// ACK, datagram, PATH_RESPONSE). Returns [kNeverReceivedAgeMs] (≈ "never")
  /// when the FFI symbol is missing (old .so), the handle is null, or no
  /// inbound has ever arrived. Polled at 1Hz by the foreground watchdog.
  ///
  /// `rust/aqt_client_ffi/src/ffi.rs`'s `aqt_get_last_recv_age_ms` returns
  /// Rust's `u64::MAX` for all three of those cases. Dart has no unsigned
  /// 64-bit integer type, so FFI marshals that bit pattern into a *signed*
  /// int — `-1`, the SMALLEST possible value. Left unhandled, the watchdog
  /// would read "nothing has ever arrived on this connection" as "traffic
  /// just arrived, perfectly healthy", inverting the sentinel's meaning and
  /// permanently hiding a genuinely dead link from the watchdog. We
  /// deliberately tolerate this on the Dart side (map any negative result
  /// back to the "infinitely old" sentinel) rather than changing the Rust
  /// ABI, so this fix works with any already-deployed `.so`.
  static int getLastRecvAgeMs(Pointer<Void> handle) {
    // ignore: unnecessary_statements
    _optionalFfiInited;
    final fn = _aqtGetLastRecvAgeMs;
    if (fn == null) return kNeverReceivedAgeMs;
    final raw = fn(handle);
    if (raw < 0) return kNeverReceivedAgeMs;
    return raw;
  }

  /// QUIC path-level stats for the debug overlay.
  /// Returns null when the FFI symbol is missing (old .so) or the
  /// underlying call returned non-zero (handle null, connection torn
  /// down, RwLock contended).
  static PathStats? getPathStats(Pointer<Void> handle) {
    // ignore: unnecessary_statements
    _optionalFfiInited;
    final fn = _aqtGetPathStats;
    if (fn == null) return null;
    final buf = calloc<_AqtPathStatsStruct>();
    try {
      final code = fn(handle, buf);
      if (code != 0) return null;
      final s = buf.ref;
      return PathStats(
        rttUs: s.rttUs,
        lostPackets: s.lostPackets,
        sentPackets: s.sentPackets,
        migrationCount: s.migrationCount,
        rebindingCount: s.rebindingCount,
        cwndBytes: s.cwndBytes,
      );
    } finally {
      calloc.free(buf);
    }
  }

  /// Retrieve 32-byte session token for 0-RTT reconnect.
  /// Returns null if [aqt_get_session_token] is not available in the .so yet.
  static Uint8List? getSessionToken(Pointer<Void> handle) {
    // Ensure optional FFI is initialised (idempotent).
    // ignore: unnecessary_statements
    _optionalFfiInited;
    final fn = _aqtGetSessionToken;
    if (fn == null) return null;
    final buf = calloc<Uint8>(32);
    try {
      final code = fn(handle, buf);
      if (code != 0) return null;
      final token = Uint8List(32);
      for (var i = 0; i < 32; i++) { token[i] = buf[i]; }
      return token;
    } finally {
      calloc.free(buf);
    }
  }

  /// Attempt 0-RTT session resume. Creates a new handle and connects to the
  /// server using RESUME instead of HELLO (no conflicting aqt_connect() needed).
  /// Returns the new handle pointer, or null if not available / failed.
  ///
  /// [ringTailHash]: FNV-1a hash of the last 8 raw bytes at [lastOutOff].
  /// 0 = no hash (server uses lastOutOff as-is, backwards compatible).
  /// Non-zero: server verifies client is in sync; hash match → lean replay.
  static Pointer<Void>? resume({
    required String host,
    required int port,
    required Uint8List spki,
    required Uint8List sessionToken,
    required int tabId,
    int lastInOff = 0,
  }) {
    // ignore: unnecessary_statements
    _optionalFfiInited;
    final fn = _aqtResume;
    if (fn == null) return null;
    final hostPtr = host.toNativeUtf8();
    final spkiMem = calloc<Uint8>(spki.length);
    for (var i = 0; i < spki.length; i++) {
      spkiMem[i] = spki[i];
    }
    final tokenMem = calloc<Uint8>(32);
    for (var i = 0; i < 32; i++) {
      tokenMem[i] = sessionToken[i];
    }
    final outHandle = calloc<Pointer<Void>>();
    try {
      // 后三个位置参数是 lastOutOff / lastInOff / ringTailHash。
      // 恢复不再携带位置信息，Rust 侧已经显式忽略它们（见 do_quic_resume）。
      // ABI 暂时保留是为了不跟 .so 的签名同步改动 —— 下一次协议改版一起删。
      final code = fn(outHandle, hostPtr, port, spkiMem, spki.length,
          tokenMem, tabId, 0, 0, 0);
      if (code != 0 || outHandle.value == nullptr) return null;
      return outHandle.value;
    } finally {
      calloc.free(hostPtr);
      calloc.free(spkiMem);
      calloc.free(tokenMem);
      calloc.free(outHandle);
    }
  }
}

/// 服务端对一次 RESUME 的处置。客户端按类型分派，不推断。
sealed class AqtDisposition {
  const AqtDisposition();
}

/// 会话与 PTY 都在，随附一份自足的屏幕快照。
class AqtRestored extends AqtDisposition {
  /// 服务端已收到的输入字节数，据此补发断线瞬间没送达的按键。
  final int serverInSeenOff;

  const AqtRestored({required this.serverInSeenOff});
}

/// 会话不存在或已过期 —— 复位终端、开新 shell。
class AqtNewSession extends AqtDisposition {
  const AqtNewSession();
}

/// token 有效但这个 tab 的进程已退出 —— 显示退出状态，**不**复位终端。
class AqtTabGone extends AqtDisposition {
  final int? exitStatus;
  const AqtTabGone(this.exitStatus);
}

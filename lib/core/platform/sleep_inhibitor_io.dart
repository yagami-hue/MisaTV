import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

typedef _SetThreadExecutionStateNative = Uint32 Function(Uint32);
typedef _SetThreadExecutionStateDart = int Function(int);

/// 播放期间阻止系统自动休眠 / 关屏。
///
/// Windows 的 `SetThreadExecutionState` 是**按线程**记录状态的：必须在同一个线程
/// 先 `ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED`，结束时再
/// `ES_CONTINUOUS` 撤销。Dart UI isolate 一直存活，所以 acquire/release 成对调用即可。
/// Android 通过 MethodChannel 控制窗口的 `FLAG_KEEP_SCREEN_ON` 标志。
class SleepInhibitor {
  SleepInhibitor._();

  static const _continuous = 0x80000000;
  static const _systemRequired = 0x00000001;
  static const _displayRequired = 0x00000002;
  static const _androidChannel = MethodChannel('com.kniephos.kniephos/sleep_inhibitor');

  static _SetThreadExecutionStateDart? _fn;
  static int _depth = 0;

  /// 引用计数：换集/重进播放器时避免提前撤销。
  static void acquire() {
    _depth++;
    if (_depth != 1) return;
    _setKeepScreenOn(true);
  }

  static void release() {
    if (_depth <= 0) return;
    _depth--;
    if (_depth != 0) return;
    _setKeepScreenOn(false);
  }

  /// 播放器销毁时兜底：无论计数多少都恢复系统默认休眠策略。
  static void releaseAll() {
    _depth = 0;
    _setKeepScreenOn(false);
  }

  static void _setKeepScreenOn(bool enabled) {
    if (Platform.isWindows) {
      _callWindows(
        enabled ? (_continuous | _systemRequired | _displayRequired) : _continuous,
      );
    } else if (Platform.isAndroid) {
      _androidChannel
          .invokeMethod<void>('setKeepScreenOn', enabled)
          .catchError((_) {});
    }
  }

  static void _callWindows(int flags) {
    try {
      _fn ??= DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_SetThreadExecutionStateNative, _SetThreadExecutionStateDart>(
        'SetThreadExecutionState',
      );
      _fn!(flags);
    } catch (_) {
      // 非 Windows / 调用失败（权限、无桌面会话）时静默忽略，不影响播放
    }
  }
}

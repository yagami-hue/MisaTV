// 睡眠定时器（纯逻辑，可注入时钟，便于单测）。
//
// 为什么需要：看片睡着是真实场景，而 Windows 端没有系统级「到点暂停」的
// 可靠办法（`SetThreadExecutionState` 只能阻止休眠，不能暂停播放）。
//
// 两种模式，对应两种真实用法：
//   · 固定时长：睡前想「再看 30 分钟」，到点直接暂停；
//   · 播完当前视频：不想被中途打断，但也不想它自动连播下去。
//
// 这里只做状态与到期判定，真正的暂停动作由播放器层执行：内核不持有播放器，
// 这样它可以被单测，也不会在播放器销毁后留下悬挂引用。

import 'dart:async';

/// 定时模式。
enum SleepTimerMode {
  /// 固定时长后暂停。
  duration,

  /// 当前视频播完后暂停（不触发自动连播）。
  endOfVideo,
}

/// 定时器状态快照（UI 直接读它渲染）。
class SleepTimerState {
  const SleepTimerState({
    this.mode,
    this.deadlineMs,
    this.totalMs = 0,
  });

  static const SleepTimerState off = SleepTimerState();

  final SleepTimerMode? mode;

  /// 到期时刻（毫秒时间戳）；仅 [SleepTimerMode.duration] 有值。
  final int? deadlineMs;

  /// 设定的总时长（毫秒），用于算进度。
  final int totalMs;

  bool get active => mode != null;

  /// 剩余毫秒；已到期返回 0，非 duration 模式返回 null。
  int? remainingMs(int nowMs) {
    final deadline = deadlineMs;
    if (deadline == null) return null;
    final left = deadline - nowMs;
    return left <= 0 ? 0 : left;
  }

  /// 进度 0~1（已过去的比例）；非 duration 模式返回 null。
  double? progress(int nowMs) {
    if (deadlineMs == null || totalMs <= 0) return null;
    final left = remainingMs(nowMs) ?? 0;
    return ((totalMs - left) / totalMs).clamp(0.0, 1.0);
  }
}

/// 睡眠定时器内核。
///
/// [onExpire] 只在到期时回调一次；暂停动作由调用方执行。定时器在到期后
/// **自动复位为关闭**，不需要调用方再手动清一次（避免「暂停了但设置还亮着」）。
class SleepTimer {
  SleepTimer({
    required this.onExpire,
    DateTime Function()? clock,
    this.onChanged,
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final void Function() onExpire;

  /// 状态变化回调（UI 据此刷新倒计时与按钮文案）。
  final void Function(SleepTimerState state)? onChanged;

  SleepTimerState _state = SleepTimerState.off;
  Timer? _timer;

  SleepTimerState get state => _state;

  bool get active => _state.active;

  /// 设定固定时长。重复调用会覆盖旧设置（用户改主意很常见）。
  void startForDuration(Duration duration) {
    _cancelTimer();
    if (duration <= Duration.zero) {
      cancel();
      return;
    }
    final now = _clock().millisecondsSinceEpoch;
    _state = SleepTimerState(
      mode: SleepTimerMode.duration,
      deadlineMs: now + duration.inMilliseconds,
      totalMs: duration.inMilliseconds,
    );
    _timer = Timer(duration, _fire);
    onChanged?.call(_state);
  }

  /// 播完当前视频后暂停。
  void startAtEndOfVideo() {
    _cancelTimer();
    _state = const SleepTimerState(mode: SleepTimerMode.endOfVideo);
    onChanged?.call(_state);
  }

  /// 关闭定时器（用户手动取消，或到期后自动调用）。
  void cancel() {
    _cancelTimer();
    if (!_state.active) return;
    _state = SleepTimerState.off;
    onChanged?.call(_state);
  }

  /// 视频播放结束时由播放器调用。
  ///
  /// 返回 true 表示「应当暂停且不要连播」——调用方据此跳过自动下一集。
  /// 非 endOfVideo 模式返回 false，让正常连播逻辑照常执行。
  bool handleVideoEnded() {
    if (_state.mode != SleepTimerMode.endOfVideo) return false;
    _cancelTimer();
    _state = SleepTimerState.off;
    onChanged?.call(_state);
    onExpire();
    return true;
  }

  /// 时钟推进后的到期检查（用于单测与「应用休眠后恢复」）。
  ///
  /// 真实的 [Timer] 在系统休眠期间不走，唤醒后可能已经远超截止时间；
  /// 调用方在窗口重新获得焦点时调一次，可以立即补上这次暂停。
  void checkExpired() {
    if (_state.mode != SleepTimerMode.duration) return;
    final left = _state.remainingMs(_clock().millisecondsSinceEpoch);
    if (left != null && left <= 0) _fire();
  }

  void _fire() {
    _cancelTimer();
    if (!_state.active) return;
    _state = SleepTimerState.off;
    onChanged?.call(_state);
    onExpire();
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _cancelTimer();
    _state = SleepTimerState.off;
  }

  /// 把剩余时长格式化成 `29:30` / `1:05:00`。
  static String formatDuration(int ms) {
    final total = (ms + 999) ~/ 1000; // 向上取整：剩 0.4 秒也显示 1 秒
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }
}

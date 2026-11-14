import 'package:flutter/material.dart';

import '../../services/player/sleep_timer.dart';

/// 睡眠定时器弹层的选择结果。
class SleepTimerChoice {
  const SleepTimerChoice._({this.duration, this.atEndOfVideo = false, this.cancel = false});

  /// 固定时长模式。
  const SleepTimerChoice.duration(Duration duration)
    : this._(duration: duration);

  /// 播完当前视频。
  const SleepTimerChoice.endOfVideo() : this._(atEndOfVideo: true);

  /// 关闭定时器。
  const SleepTimerChoice.off() : this._(cancel: true);

  final Duration? duration;
  final bool atEndOfVideo;
  final bool cancel;
}

/// 预设时长：覆盖「再眯一会儿」到「看完这一部」的常见跨度。
const List<Duration> kSleepTimerPresets = [
  Duration(minutes: 15),
  Duration(minutes: 30),
  Duration(minutes: 45),
  Duration(minutes: 60),
  Duration(minutes: 90),
  Duration(minutes: 120),
];

/// 睡眠定时器弹层。
///
/// [current] 用来显示剩余时间并提供「关闭」按钮；为 null 表示当前未启用。
Future<SleepTimerChoice?> showSleepTimerSheet({
  required BuildContext context,
  required SleepTimerState current,
  int? nowMs,
}) {
  return showModalBottomSheet<SleepTimerChoice>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      final remaining = nowMs == null ? null : current.remainingMs(nowMs);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('睡眠定时', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  if (current.active)
                    TextButton(
                      onPressed: () =>
                          Navigator.of(ctx).pop(const SleepTimerChoice.off()),
                      child: const Text('关闭'),
                    ),
                ],
              ),
              Text(
                current.active
                    ? _activeLabel(current, remaining)
                    : '到点自动暂停播放，适合躺着看片时使用。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.76),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '定时时长',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in kSleepTimerPresets)
                    ActionChip(
                      label: Text(_presetLabel(preset)),
                      onPressed: () => Navigator.of(
                        ctx,
                      ).pop(SleepTimerChoice.duration(preset)),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                '或者',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      Navigator.of(ctx).pop(const SleepTimerChoice.endOfVideo()),
                  icon: const Icon(Icons.movie_filter_rounded, size: 18),
                  label: const Text('播完当前视频后暂停（不连播）'),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '「播完当前视频」会跳过自动连播，等你自己决定看下一集。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

String _presetLabel(Duration d) {
  final minutes = d.inMinutes;
  if (minutes < 60) return '$minutes 分钟';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
}

String _activeLabel(SleepTimerState state, int? remaining) {
  if (state.mode == SleepTimerMode.endOfVideo) {
    return '当前设置：播完这一集后暂停，不会自动连播。';
  }
  if (remaining == null) return '定时器已启用。';
  return '剩余 ${SleepTimer.formatDuration(remaining)}，到点自动暂停。';
}

/// 播放器顶栏用的简短标签：`剩余 29:30` / `本集播完`；未启用时为空串。
String sleepTimerBadge(SleepTimerState state, int nowMs) {
  if (!state.active) return '';
  if (state.mode == SleepTimerMode.endOfVideo) return '本集播完';
  final remaining = state.remainingMs(nowMs);
  if (remaining == null) return '';
  return '剩余 ${SleepTimer.formatDuration(remaining)}';
}

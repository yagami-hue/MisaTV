import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/download_task.dart';
import '../../models/video_download_record.dart';
import '../../services/download/video_download_manager.dart';
import '../../services/download/video_download_service.dart';
import '../../services/relay/local_relay.dart';
import '../../services/torrent/download_folder.dart';
import '../widgets/empty_state.dart';

/// 下载管理：手动下载的记录（暂停 / 继续 / 删除）+ 边播缓存统计与清理。
class VideoDownloadsPage extends StatefulWidget {
  const VideoDownloadsPage({super.key});

  @override
  State<VideoDownloadsPage> createState() => _VideoDownloadsPageState();
}

class _VideoDownloadsPageState extends State<VideoDownloadsPage> {
  VideoDownloadManager? _manager;
  List<LocalDownloadFile> _files = const [];
  int _cacheBytes = 0;
  int _cacheEntries = 0;
  int _completedSeen = -1;

  /// 上一次看到的任务状态：用于「下载完成 / 失败」提示与状态切换动效。
  final Map<String, VideoDownloadStatus> _lastStatuses = {};

  /// 速度采样：进度回调很密，用滑动平均避免数字乱跳。
  final Map<String, _SpeedSample> _speedSamples = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_manager != null) return;
    final manager = AppScope.of(context).videoDownloads;
    _manager = manager..loadIfNeeded();
    _completedSeen = _completedCount(manager);
    for (final record in manager.records) {
      _lastStatuses[record.id] = record.status;
    }
    manager.addListener(_onManagerChanged);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _manager?.removeListener(_onManagerChanged);
    super.dispose();
  }

  /// 任务状态变化时给出提示；下载完成时顺便重新扫盘。
  void _onManagerChanged() {
    final manager = _manager;
    if (manager == null) return;
    for (final record in manager.records) {
      _trackSpeed(record);
      final last = _lastStatuses[record.id];
      if (last == record.status) continue;
      _lastStatuses[record.id] = record.status;
      if (last == null) continue;
      if (record.status == VideoDownloadStatus.completed) {
        _toast(
          '「${record.title}」下载完成',
          actionLabel: '打开文件夹',
          onAction: () => openDownloadFolder(
            record.directory.isEmpty ? videoDownloadDir() : record.directory,
          ),
        );
      } else if (record.status == VideoDownloadStatus.failed) {
        _toast(
          '「${record.title}」下载失败'
          '${record.error.isEmpty ? '' : '：${record.error}'}',
        );
      }
    }
    final ids = {for (final record in manager.records) record.id};
    _lastStatuses.removeWhere((id, _) => !ids.contains(id));
    _speedSamples.removeWhere((id, _) => !ids.contains(id));

    final done = _completedCount(manager);
    if (done == _completedSeen) return;
    _completedSeen = done;
    unawaited(_refresh());
  }

  int _completedCount(VideoDownloadManager manager) => manager.records
      .where((record) => record.status == VideoDownloadStatus.completed)
      .length;

  /// 用相邻两次进度回调的字节差估算速度（指数平滑）。
  void _trackSpeed(VideoDownloadRecord record) {
    if (!record.active) {
      _speedSamples.remove(record.id);
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final prev = _speedSamples[record.id];
    if (prev == null) {
      _speedSamples[record.id] = _SpeedSample(
        bytes: record.receivedBytes,
        at: now,
        speed: 0,
      );
      return;
    }
    final elapsed = now - prev.at;
    if (elapsed < 350) return;
    final delta = record.receivedBytes - prev.bytes;
    if (delta < 0) {
      _speedSamples[record.id] = _SpeedSample(
        bytes: record.receivedBytes,
        at: now,
        speed: prev.speed,
      );
      return;
    }
    final instant = delta * 1000 / elapsed;
    _speedSamples[record.id] = _SpeedSample(
      bytes: record.receivedBytes,
      at: now,
      speed: prev.speed <= 0 ? instant : prev.speed * 0.65 + instant * 0.35,
    );
  }

  double _speedOf(String id) => _speedSamples[id]?.speed ?? 0;

  Future<void> _refresh() async {
    final files = await scanVideoDownloadFiles();
    final bytes = await LocalRelay.instance.streamCacheBytes();
    final entries = await LocalRelay.instance.streamCacheEntryCount();
    if (!mounted) return;
    setState(() {
      _files = files;
      _cacheBytes = bytes;
      _cacheEntries = entries;
    });
  }

  void _toast(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        action: actionLabel == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
      ),
    );
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 记录对应的文件路径（含 `.part`）不算「其他文件」。
  List<LocalDownloadFile> _orphanFiles(VideoDownloadManager manager) {
    final known = <String>{};
    for (final record in manager.records) {
      final path = record.filePath.trim().toLowerCase();
      if (path.isEmpty) continue;
      known
        ..add(path)
        ..add('$path.part');
    }
    return [
      for (final file in _files)
        if (!known.contains(file.path.toLowerCase())) file,
    ];
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      _toast('操作失败：$e');
    }
    await _refresh();
  }

  Future<void> _removeRecord(
    VideoDownloadManager manager,
    VideoDownloadRecord record, {
    required bool deleteFile,
  }) async {
    if (deleteFile) {
      final ok = await _confirm(
        '删除下载',
        '将删除「${record.title}」及其本地文件，无法恢复。',
        '删除',
      );
      if (!ok) return;
    }
    await _act(() => manager.remove(record.id, deleteFile: deleteFile));
    if (deleteFile) {
      _toast('已删除下载文件');
    } else {
      _toast('已清除记录，文件保留在下载目录');
    }
  }

  Future<void> _clearAll(
    VideoDownloadManager manager, {
    required bool deleteFiles,
  }) async {
    if (manager.records.isEmpty) return;
    final ok = await _confirm(
      deleteFiles ? '删除全部下载' : '清除全部下载记录',
      deleteFiles
          ? '将删除全部下载记录及其本地文件，无法恢复。'
          : '只清除下载记录，已下载的文件会保留在下载目录。',
      deleteFiles ? '全部删除' : '清除记录',
    );
    if (!ok) return;
    await _act(() => manager.clearRecords(deleteFiles: deleteFiles));
    _toast(deleteFiles ? '下载文件已全部删除' : '下载记录已清除');
  }

  Future<void> _clearStreamCache() async {
    final ok = await _confirm(
      '清空边播缓存',
      '将删除播放时缓存的分片（${formatDownloadSize(_cacheBytes)}），'
          '不影响 downloads 目录里已下载的视频。',
      '清空',
    );
    if (!ok) return;
    await LocalRelay.instance.clearStreamCache();
    await _refresh();
    _toast('边播缓存已清空');
  }

  Future<void> _deleteOrphan(LocalDownloadFile file) async {
    final ok = await _confirm(
      file.partial ? '删除未完成的文件' : '删除文件',
      '将删除「${file.name}」，无法恢复。',
      '删除',
    );
    if (!ok) return;
    await deleteDownloadFile(file.path);
    await _refresh();
    _toast('文件已删除');
  }

  @override
  Widget build(BuildContext context) {
    final manager = _manager;
    if (manager == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final theme = Theme.of(context);
        final records = manager.records;
        final files = _orphanFiles(manager);
        final done = records
            .where((r) => r.status == VideoDownloadStatus.completed)
            .length;
        final active = records
            .where((r) => r.status == VideoDownloadStatus.downloading)
            .length;
        final dir = videoDownloadDir();
        return Scaffold(
          appBar: AppBar(
            title: const Text('下载管理'),
            actions: [
              PopupMenuButton<String>(
                tooltip: '批量操作',
                onSelected: (value) {
                  if (value == 'clear') {
                    unawaited(_clearAll(manager, deleteFiles: false));
                  } else if (value == 'delete') {
                    unawaited(_clearAll(manager, deleteFiles: true));
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'clear',
                    child: Text('清除全部记录（保留文件）'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('删除全部（含文件）'),
                  ),
                ],
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                _SummaryCard(
                  records: records.length,
                  completed: done,
                  active: active,
                  cacheBytes: _cacheBytes,
                  cacheEntries: _cacheEntries,
                ),
                if (dir.isEmpty) ...[
                  const SizedBox(height: 10),
                  _HintBanner(
                    icon: Icons.warning_amber_rounded,
                    message: '下载目录不可用：边播缓存未启用，暂时无法保存新下载。',
                    color: theme.colorScheme.error,
                  ),
                ],
                const SizedBox(height: 14),
                _SectionHeader(
                  title: '手动下载',
                  trailing: _CountBadge(
                    text: '${records.length} 个',
                    visible: records.isNotEmpty,
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: records.isEmpty
                      ? const _Appear(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 10),
                            child: EmptyState(
                              icon: Icons.download_done_rounded,
                              title: '还没有下载记录',
                              message:
                                  '在播放器底栏点下载按钮，即可把当前视频保存到边播缓存目录下的 '
                                  'downloads 文件夹。',
                              compact: true,
                            ),
                          ),
                        )
                      : Column(
                          children: [
                            for (final record in records) ...[
                              _Appear(
                                key: ValueKey('record-${record.id}'),
                                child: _RecordTile(
                                  record: record,
                                  speed: _speedOf(record.id),
                                  onPause: () {
                                    manager.pause(record.id);
                                    _toast(
                                      '已暂停，可从「更多操作」继续下载',
                                    );
                                  },
                                  onResume: () => _act(
                                    () => manager.resume(record.id),
                                  ),
                                  onOpenFolder: () => openDownloadFolder(
                                    record.directory.isEmpty
                                        ? dir
                                        : record.directory,
                                  ),
                                  onRemove: (deleteFile) => _removeRecord(
                                    manager,
                                    record,
                                    deleteFile: deleteFile,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ],
                        ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: files.isEmpty
                      ? const SizedBox.shrink()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 8),
                            _SectionHeader(
                              title: '下载目录中的其他文件',
                              trailing: _CountBadge(
                                text: '${files.length} 个',
                                visible: true,
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.only(bottom: 6),
                              child: Text(
                                '这些文件没有对应的下载记录（例如已清除记录，或上次中断留下的半截文件）。',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            for (final file in files)
                              _OrphanTile(
                                key: ValueKey('file-${file.path}'),
                                file: file,
                                onDelete: () => unawaited(_deleteOrphan(file)),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 10),
                _SectionHeader(
                  title: '边播缓存',
                  trailing: _CountBadge(
                    text: '$_cacheEntries 个分片',
                    visible: _cacheEntries > 0,
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.speed_rounded),
                  title: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: Text(
                      '已缓存 ${formatDownloadSize(_cacheBytes)}',
                      key: ValueKey('cache-$_cacheBytes'),
                    ),
                  ),
                  subtitle: const Text(
                    '播放时顺手缓存的分片，用于重看 / 拖动时不再回源；'
                    '下载的视频不在其中。',
                  ),
                  trailing: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: _cacheBytes > 0 ? 1 : 0.45,
                    child: OutlinedButton(
                      onPressed: _cacheBytes > 0
                          ? () => unawaited(_clearStreamCache())
                          : null,
                      child: const Text('清空'),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_open_rounded),
                  title: const Text('下载目录'),
                  subtitle: Text(
                    dir.isEmpty ? '未启用（需要先开启边播边缓存）' : dir,
                  ),
                  trailing: dir.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '打开下载目录',
                          onPressed: () => openDownloadFolder(dir),
                          icon: const Icon(Icons.open_in_new_rounded),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SpeedSample {
  const _SpeedSample({
    required this.bytes,
    required this.at,
    required this.speed,
  });

  final int bytes;
  final int at;
  final double speed;
}

/// 首次出现时的淡入 + 上滑，让新增记录 / 页面区块有出场感。
///
/// 使用稳定的 Key 后，进度刷新重建不会重播动画。
class _Appear extends StatelessWidget {
  const _Appear({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.records,
    required this.completed,
    required this.active,
    required this.cacheBytes,
    required this.cacheEntries,
  });

  final int records;
  final int completed;
  final int active;
  final int cacheBytes;
  final int cacheEntries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final title = records == 0 ? '暂无下载' : '已下载 $completed / $records 个任务';
    final subtitle =
        '边播缓存 ${formatDownloadSize(cacheBytes)} · $cacheEntries 个分片';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: active > 0 ? 0.11 : 0.07),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _SummaryIcon(active: active > 0, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.25),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: Text(
                    title,
                    key: ValueKey('summary-title-$title'),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: active > 0
                          ? Padding(
                              key: const ValueKey('active-dot'),
                              padding: const EdgeInsets.only(right: 6),
                              child: _PulsingDot(color: color, size: 7),
                            )
                          : const SizedBox.shrink(key: ValueKey('idle')),
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: Text(
                          active > 0
                              ? '$active 个任务下载中 · $subtitle'
                              : subtitle,
                          key: ValueKey('summary-sub-$active-$subtitle'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 下载中的图标缓慢上下浮动，静止状态保持原样。
class _SummaryIcon extends StatefulWidget {
  const _SummaryIcon({required this.active, required this.color});

  final bool active;
  final Color color;

  @override
  State<_SummaryIcon> createState() => _SummaryIconState();
}

class _SummaryIconState extends State<_SummaryIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _SummaryIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, -2.5 * _controller.value),
        child: child,
      ),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.download_rounded, color: widget.color),
      ),
    );
  }
}

class _HintBanner extends StatelessWidget {
  const _HintBanner({
    required this.icon,
    required this.message,
    required this.color,
  });

  final IconData icon;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Row(
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 数字变化的淡入淡出，避免计数直接跳变。
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.text, required this.visible});

  final String text;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: visible
          ? Text(
              text,
              key: ValueKey(text),
              style: theme.textTheme.labelSmall,
            )
          : const SizedBox.shrink(key: ValueKey('empty')),
    );
  }
}

/// 下载状态的彩色胶囊：颜色与图标带过渡，下载中显示呼吸圆点。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.label});

  final VideoDownloadStatus status;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _statusColor(theme, status);
    final pulsing = status == VideoDownloadStatus.downloading;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: pulsing
                ? Padding(
                    key: const ValueKey('pulse'),
                    padding: const EdgeInsets.only(right: 5),
                    child: _PulsingDot(color: color, size: 6),
                  )
                : Padding(
                    key: ValueKey(status),
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(
                      _statusIcon(status),
                      size: 12,
                      color: color,
                    ),
                  ),
          ),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 呼吸圆点：告诉用户「正在动」而不是卡住了。
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final value = _controller.value;
        final pulse = 1 - (value < 0.5 ? value : 1 - value) * 2;
        return Opacity(
          opacity: 0.45 + 0.55 * pulse,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.record,
    required this.speed,
    required this.onPause,
    required this.onResume,
    required this.onOpenFolder,
    required this.onRemove,
  });

  final VideoDownloadRecord record;
  final double speed;
  final VoidCallback onPause;
  final Future<void> Function() onResume;
  final VoidCallback onOpenFolder;
  final Future<void> Function(bool deleteFile) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = record.active;
    final paused = record.status == VideoDownloadStatus.paused;
    final failed = record.status == VideoDownloadStatus.failed;
    final completed = record.status == VideoDownloadStatus.completed;
    final fraction = record.fraction;
    final eta = _etaText(record, speed);
    final details = <String>[
      if (record.receivedBytes > 0) formatDownloadSize(record.receivedBytes),
      if (record.totalBytes > 0)
        formatDownloadSize(record.totalBytes)
      else if (record.totalSegments > 0)
        '${record.completedSegments}/${record.totalSegments} 段',
      if (active && speed > 0) '${formatDownloadSize(speed.round())}/s',
      if (active && eta != null) '剩余 $eta',
      if (!active && record.updatedAt > 0) _formatTimeShort(record.updatedAt),
    ].join(' · ');
    final showBar = active || paused || (failed && (fraction ?? 0) > 0);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: completed
            ? theme.colorScheme.primary.withValues(alpha: 0.07)
            : theme.colorScheme.onSurface.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: animation,
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: Icon(
                _statusIcon(record.status),
                key: ValueKey(record.status),
                size: 20,
                color: _statusColor(theme, record.status),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        record.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StatusChip(
                      status: record.status,
                      label: _statusLabel(record.status),
                    ),
                  ],
                ),
                if (active && record.stage.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    record.stage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
                if (showBar) ...[
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: fraction == null
                        ? LinearProgressIndicator(
                            minHeight: 4,
                            color: _statusColor(theme, record.status),
                            backgroundColor: theme.colorScheme.onSurface
                                .withValues(alpha: 0.08),
                          )
                        : TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: 0, end: fraction),
                            duration: const Duration(milliseconds: 420),
                            curve: Curves.easeOutCubic,
                            builder: (context, value, _) =>
                                LinearProgressIndicator(
                                  value: value,
                                  minHeight: 4,
                                  color: _statusColor(theme, record.status),
                                  backgroundColor: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.08),
                                ),
                          ),
                  ),
                ],
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    details,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.62,
                      ),
                    ),
                  ),
                ],
                if (failed && record.error.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 13,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          record.error,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) {
              switch (value) {
                case 'pause':
                  onPause();
                case 'resume':
                  unawaited(onResume());
                case 'folder':
                  onOpenFolder();
                case 'delete':
                  unawaited(onRemove(true));
                case 'remove':
                  unawaited(onRemove(false));
              }
            },
            itemBuilder: (context) => [
              if (active)
                const PopupMenuItem(value: 'pause', child: Text('暂停下载')),
              if (record.canResume)
                const PopupMenuItem(value: 'resume', child: Text('继续下载')),
              if (completed)
                const PopupMenuItem(value: 'folder', child: Text('打开文件夹')),
              if (active || record.canResume)
                const PopupMenuDivider(),
              const PopupMenuItem(value: 'delete', child: Text('删除文件并移除记录')),
              // 进行中的任务需要先暂停：直接移除会连带删掉 .part。
              if (!active)
                const PopupMenuItem(
                  value: 'remove',
                  child: Text('仅移除记录（保留文件）'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OrphanTile extends StatelessWidget {
  const _OrphanTile({
    super.key,
    required this.file,
    required this.onDelete,
  });

  final LocalDownloadFile file;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        file.partial
            ? Icons.pause_circle_outline_rounded
            : Icons.movie_outlined,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (file.partial) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '未完成',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.tertiary,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        '${formatDownloadSize(file.size)} · ${_formatTime(file.modified)}',
      ),
      trailing: IconButton(
        tooltip: '删除文件',
        onPressed: onDelete,
        icon: const Icon(Icons.delete_outline_rounded),
      ),
    );
  }
}

String _statusLabel(VideoDownloadStatus status) => switch (status) {
  VideoDownloadStatus.downloading => '下载中',
  VideoDownloadStatus.paused => '已暂停',
  VideoDownloadStatus.completed => '已完成',
  VideoDownloadStatus.failed => '下载失败',
  VideoDownloadStatus.cancelled => '已取消',
};

IconData _statusIcon(VideoDownloadStatus status) => switch (status) {
  VideoDownloadStatus.downloading => Icons.downloading_rounded,
  VideoDownloadStatus.paused => Icons.pause_circle_outline_rounded,
  VideoDownloadStatus.completed => Icons.check_circle_outline_rounded,
  VideoDownloadStatus.failed => Icons.error_outline_rounded,
  VideoDownloadStatus.cancelled => Icons.cancel_outlined,
};

Color _statusColor(ThemeData theme, VideoDownloadStatus status) =>
    switch (status) {
      VideoDownloadStatus.completed => theme.colorScheme.primary,
      VideoDownloadStatus.downloading => theme.colorScheme.primary,
      VideoDownloadStatus.failed => theme.colorScheme.error,
      VideoDownloadStatus.paused => theme.colorScheme.tertiary,
      VideoDownloadStatus.cancelled => theme.colorScheme.onSurface.withValues(
        alpha: 0.6,
      ),
    };

/// 剩余时间（按当前速度粗估）；HLS 只有分段数时不做估算。
String? _etaText(VideoDownloadRecord record, double speed) {
  if (speed <= 0 || record.totalBytes <= 0) return null;
  final remain = record.totalBytes - record.receivedBytes;
  if (remain <= 0) return null;
  final seconds = remain / speed;
  if (seconds.isNaN || seconds.isInfinite || seconds > 24 * 3600) return null;
  if (seconds < 60) return '${seconds.round()} 秒';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes 分钟';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
}

String _formatTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

String _formatTimeShort(int millis) =>
    _formatTime(DateTime.fromMillisecondsSinceEpoch(millis));

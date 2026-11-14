import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/errors/app_error.dart';
import '../../models/download_task.dart';
import '../../services/torrent/download_folder.dart';
import '../../services/torrent/download_manager.dart';
import '../widgets/empty_state.dart';

/// aria2 下载管理器：任务列表、添加、暂停 / 继续 / 删除。
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  DownloadManager? _manager;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_manager != null) return;
    final manager = AppScope.of(context).downloadManager;
    _manager = manager;
    manager
      ..refresh()
      ..startPolling();
  }

  @override
  void dispose() {
    _manager?.stopPolling();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(Future<void> Function() action, String failure) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _toast('$failure：${describeAppError(e).message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showAddDialog(DownloadManager manager) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加下载'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '下载地址',
                  hintText: 'https://… 或 magnet:?xt=urn:btih:…',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '保存到：${manager.downloadDir.isEmpty ? '默认磁力目录' : manager.downloadDir}',
                style: Theme.of(ctx).textTheme.labelSmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('开始下载'),
          ),
        ],
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (confirmed != true || !mounted) return;
    if (text.isEmpty) return;
    await _run(() => manager.add(text), '添加下载失败');
    if (mounted) _toast('已提交下载任务');
  }

  @override
  Widget build(BuildContext context) {
    final manager = _manager;
    if (manager == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final theme = Theme.of(context);
        final tasks = manager.tasks;
        return Scaffold(
          appBar: AppBar(
            title: const Text('下载管理'),
            actions: [
              IconButton(
                tooltip: '添加任务',
                onPressed: _busy ? null : () => _showAddDialog(manager),
                icon: const Icon(Icons.add_rounded),
              ),
              PopupMenuButton<String>(
                enabled: !_busy,
                tooltip: '更多',
                onSelected: (value) {
                  switch (value) {
                    case 'pauseAll':
                      _run(manager.pauseAll, '暂停失败');
                    case 'resumeAll':
                      _run(manager.resumeAll, '继续失败');
                    case 'clear':
                      _run(manager.clearFinished, '清理失败');
                    case 'folder':
                      openDownloadFolder(manager.downloadDir);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'pauseAll',
                    child: Text('全部暂停'),
                  ),
                  PopupMenuItem(
                    value: 'resumeAll',
                    child: Text('全部继续'),
                  ),
                  PopupMenuItem(
                    value: 'clear',
                    child: Text('清空已结束'),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'folder',
                    child: Text('打开下载目录'),
                  ),
                ],
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () => manager.refresh(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                _SummaryCard(manager: manager),
                if (manager.error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      manager.error,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                if (tasks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 60),
                    child: EmptyState(
                      icon: Icons.download_outlined,
                      title: manager.loading ? '正在读取任务…' : '还没有下载任务',
                      message: manager.available
                          ? '点右上角「+」添加 http / 磁力链接；'
                                '磁力播放中的任务也会出现在这里。'
                          : '浏览器版不支持 aria2 下载，请使用桌面版。',
                    ),
                  )
                else
                  for (final task in tasks)
                    _TaskTile(
                      task: task,
                      busy: _busy,
                      onPause: task.isActive || task.isWaiting
                          ? () => _run(
                              () => manager.pauseTask(task.gid),
                              '暂停失败',
                            )
                          : null,
                      onResume: task.isPaused
                          ? () => _run(
                              () => manager.resumeTask(task.gid),
                              '继续失败',
                            )
                          : null,
                      onRemove: () => _run(
                        () => manager.removeTask(task.gid),
                        '删除失败',
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

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.manager});

  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = manager.tasks.where((e) => e.isActive).length;
    final waiting = manager.tasks.where((e) => e.isWaiting).length;
    final done = manager.tasks.where((e) => e.isComplete).length;
    return Card(
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Expanded(
              child: _Metric(
                label: '下载速度',
                value: formatDownloadSpeed(manager.downloadSpeed),
                icon: Icons.download_rounded,
              ),
            ),
            Expanded(
              child: _Metric(
                label: '上传速度',
                value: formatDownloadSpeed(manager.uploadSpeed),
                icon: Icons.upload_rounded,
              ),
            ),
            Expanded(
              child: _Metric(
                label: '任务',
                value: '$active 进行 · $waiting 等待 · $done 完成',
                icon: Icons.list_alt_rounded,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.busy,
    required this.onPause,
    required this.onResume,
    required this.onRemove,
  });

  final DownloadTask task;
  final bool busy;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = task.totalLength > 0 ? task.progress : null;
    final sizeText = task.totalLength > 0
        ? '${formatDownloadSize(task.completedLength)} / ${formatDownloadSize(task.totalLength)}'
        : formatDownloadSize(task.completedLength);
    final detail = <String>[
      task.statusLabel,
      sizeText,
      if (task.isActive && task.downloadSpeed > 0)
        formatDownloadSpeed(task.downloadSpeed),
      if (task.isTorrent && task.seeders > 0) '做种 ${task.seeders}',
      if (task.isTorrent && task.connections > 0) '连接 ${task.connections}',
    ].join(' · ');
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Icon(
                task.isTorrent
                    ? Icons.link_rounded
                    : Icons.insert_drive_file_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 5,
                      backgroundColor: theme.colorScheme.onSurface.withValues(
                        alpha: 0.08,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.62),
                    ),
                  ),
                  if (task.isError && task.errorMessage.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        task.errorMessage,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: task.isPaused ? '继续' : '暂停',
              onPressed: busy ? null : (task.isPaused ? onResume : onPause),
              icon: Icon(
                task.isPaused
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
                size: 20,
              ),
            ),
            IconButton(
              tooltip: '删除任务',
              onPressed: busy ? null : onRemove,
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

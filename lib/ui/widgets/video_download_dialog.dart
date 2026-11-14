import 'package:flutter/material.dart';

import '../../models/download_task.dart';
import '../../models/video_download.dart';
import '../../services/download/video_download_service.dart';
import '../../services/torrent/download_folder.dart';

/// 打开「下载视频」进度弹窗；关闭弹窗不会中止下载（可在设置 → 下载管理继续操作）。
Future<void> showVideoDownloadDialog(
  BuildContext context, {
  required String title,
  required VideoDownloadTask task,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _VideoDownloadDialog(title: title, task: task),
  );
}

class _VideoDownloadDialog extends StatefulWidget {
  const _VideoDownloadDialog({required this.title, required this.task});

  final String title;
  final VideoDownloadTask task;

  @override
  State<_VideoDownloadDialog> createState() => _VideoDownloadDialogState();
}

class _VideoDownloadDialogState extends State<_VideoDownloadDialog> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<VideoDownloadProgress>(
      valueListenable: widget.task.progress,
      builder: (context, progress, _) {
        final active = progress.active;
        final details = <String>[
          if (progress.receivedBytes > 0)
            formatDownloadSize(progress.receivedBytes),
          if (progress.totalBytes > 0)
            formatDownloadSize(progress.totalBytes)
          else if (progress.totalSegments > 0)
            '${progress.completedSegments}/${progress.totalSegments} 段',
        ].join(' / ');
        return AlertDialog(
          title: const Text('下载视频'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress.fraction,
                    minHeight: 6,
                    backgroundColor: theme.colorScheme.onSurface.withValues(
                      alpha: 0.08,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        progress.stage,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (details.isNotEmpty)
                      Text(details, style: theme.textTheme.labelSmall),
                  ],
                ),
                if (progress.error.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    progress.error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (progress.done && progress.path.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  SelectableText(
                    progress.path,
                    maxLines: 3,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  active
                      ? '下载复用播放时的同一条中继链路；关掉弹窗会转入后台继续下载。'
                      : '文件保存在边播缓存目录下的 downloads 文件夹，可在 设置 → 下载管理 中暂停 / 继续 / 删除。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (progress.done && progress.path.isNotEmpty)
              TextButton.icon(
                onPressed: () => openDownloadFolder(widget.task.directory),
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('打开文件夹'),
              ),
            if (active) ...[
              TextButton(
                onPressed: () {
                  widget.task.pause();
                  Navigator.of(context).pop();
                },
                child: const Text('暂停下载'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('后台下载'),
              ),
            ] else
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
          ],
        );
      },
    );
  }
}

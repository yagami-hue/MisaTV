import 'package:flutter/material.dart';

import '../../models/vod.dart';

/// 同名影片的跨源候选列表。
///
/// 搜索结果默认按「片名 + 年份」去重成一张卡；这里把各源返回的原始条目
/// 摊开，让用户自己比较线路 / 备注 / 来源后选一个进入详情。
Future<void> showSourceVariantsSheet(
  BuildContext context, {
  required List<VodItem> variants,
  required String currentSourceKey,
  required ValueChanged<VodItem> onOpen,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.6;
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    variants.first.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '共 ${variants.length} 个来源，点击任一来源进入详情',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: variants.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 20),
                itemBuilder: (context, index) {
                  final item = variants[index];
                  final current = item.sourceKey == currentSourceKey;
                  return ListTile(
                    leading: CircleAvatar(
                      radius: 18,
                      backgroundColor: current
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.surfaceContainerHighest,
                      child: Icon(
                        current
                            ? Icons.check_rounded
                            : Icons.live_tv_rounded,
                        size: 18,
                        color: current
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.sourceName.isEmpty
                                ? item.sourceKey
                                : item.sourceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (current) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.12,
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '当前',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      [
                        if (item.year.isNotEmpty) item.year,
                        if (item.remarks.isNotEmpty) item.remarks,
                        if (item.type.isNotEmpty) item.type,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      onOpen(item);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}

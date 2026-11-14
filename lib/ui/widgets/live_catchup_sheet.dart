import 'package:flutter/material.dart';

import '../../core/utils/text_utils.dart';
import '../../models/live.dart';
import '../../models/vod.dart';
import '../../services/live/catchup.dart';
import '../../services/live/epg.dart';
import '../../services/live/live_ua_policy.dart';
import '../raw_play.dart';

/// 频道节目单 + 直播回看入口。
///
/// 节目单始终可看；只有频道声明了 `catchup` / `catchup-source` 时，
/// 已结束或正在播的节目才显示「回看 / 从头看」。
Future<void> showLiveCatchupSheet(
  BuildContext context, {
  required LiveChannel channel,
  required List<EpgProgram> programs,
}) async {
  final lines = channelLines(channel);
  if (lines.isEmpty) return;
  final rawLine = lines.first.url;
  final liveUrl = splitUrlHeadersClean(rawLine);
  final headers = _channelHeaders(channel, rawLine);
  final supported =
      channel.catchupType.trim().isNotEmpty ||
      channel.catchupSource.trim().isNotEmpty;
  final selected = await showModalBottomSheet<EpgProgram>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final now = DateTime.now().millisecondsSinceEpoch;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${channel.name} · 节目单',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (programs.isNotEmpty)
                      Text(
                        '${programs.length} 档',
                        style: theme.textTheme.labelSmall,
                      ),
                  ],
                ),
              ),
              if (!supported)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    '该频道未声明回看能力，只能查看节目单。',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              const Divider(height: 1),
              Flexible(
                child: programs.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(28),
                        child: Center(child: Text('没有节目单数据')),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: programs.length,
                        separatorBuilder: (_, _) => const Divider(
                          height: 1,
                          indent: 20,
                          endIndent: 20,
                        ),
                        itemBuilder: (context, index) {
                          final program = programs[index];
                          final past = program.endTime <= now;
                          final current =
                              program.startTime <= now && now < program.endTime;
                          final canCatchup = supported && (past || current);
                          return ListTile(
                            dense: true,
                            title: Text(
                              program.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: current
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: current
                                    ? theme.colorScheme.primary
                                    : null,
                              ),
                            ),
                            subtitle: Text(program.range),
                            trailing: canCatchup
                                ? TextButton(
                                    onPressed: () =>
                                        Navigator.of(sheetContext).pop(program),
                                    child: Text(current ? '从头看' : '回看'),
                                  )
                                : Text(
                                    current
                                        ? '直播中'
                                        : (past ? '已结束' : '未开始'),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.5),
                                    ),
                                  ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (selected == null || !context.mounted) return;
  final result = buildCatchupUrl(
    channel: channel,
    liveUrl: liveUrl,
    program: selected,
  );
  if (result == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          supported
              ? '这个节目的回看地址无法生成（${channel.catchupType.isEmpty ? '未声明类型' : channel.catchupType}）'
              : '该频道未提供直播回看',
        ),
      ),
    );
    return;
  }
  await openRawPlayback(
    context,
    title: channel.name,
    subtitle: '直播回看 · ${selected.range}',
    episodes: [
      Episode(
        name: '${selected.range} ${selected.title}',
        url: result.url,
      ),
    ],
    headers: headers,
    sourceKey: 'live-catchup',
    flag: '回看',
  );
}

Map<String, String> _channelHeaders(LiveChannel channel, String rawLineUrl) {
  final url = splitUrlHeadersClean(rawLineUrl);
  final inline = splitUrlHeaders(rawLineUrl);
  final headers = <String, String>{
    ...?channel.header,
    ...inline,
    // 同播放器：已有（任意大小写的）UA 时不再补一个同名键。
    if (channel.ua.isNotEmpty &&
        liveHeaderValue(channel.header ?? const {}, 'user-agent').isEmpty &&
        liveHeaderValue(inline, 'user-agent').isEmpty)
      'User-Agent': channel.ua,
    if (channel.referer.isNotEmpty) 'Referer': channel.referer,
    if (channel.origin.isNotEmpty) 'Origin': channel.origin,
  };
  // 与直播播放器同一套自定义 UA 优先级（命中的接口规则 > 已有 UA > 全局默认）。
  applyLiveStreamUa(headers, url);
  return headers;
}

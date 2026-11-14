import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/utils/text_utils.dart';
import '../../models/site_config.dart';
import '../../models/user_data.dart';
import '../../models/vod.dart';
import '../../services/drive/drive_line_hint.dart';
import '../../state/app_state.dart';
import '../open_player.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass.dart';
import '../widgets/hover_marquee_text.dart';
import '../widgets/secondary_long_press.dart';
import 'player_page.dart';

/// 观看历史：独立的底部导航页面（直播与收藏之间），支持关键词搜索与按源筛选。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final _searchController = TextEditingController();
  String _query = '';

  /// null = 全部来源。
  String? _sourceKey;

  /// 续播请求进行中：连续点击历史卡片时只拉起一个播放器。
  bool _resuming = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matches(HistoryItem item, String? sourceKey) {
    if (sourceKey != null && item.sourceKey != sourceKey) return false;
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    return [
      item.name,
      item.episodeName,
      item.remarks,
      item.sourceName,
    ].any((value) => value.toLowerCase().contains(query));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final all = app.history;
    final sourceNames = <String, String>{};
    final sourceCounts = <String, int>{};
    for (final item in all) {
      sourceNames.putIfAbsent(
        item.sourceKey,
        () => item.sourceName.isEmpty ? '未知来源' : item.sourceName,
      );
      sourceCounts.update(item.sourceKey, (v) => v + 1, ifAbsent: () => 1);
    }
    // 记录被删光后，之前选中的来源可能已不存在：按「全部」处理。
    final activeSource =
        _sourceKey != null && sourceNames.containsKey(_sourceKey)
        ? _sourceKey
        : null;
    final filtered = all.where((h) => _matches(h, activeSource)).toList();
    final filtering = _query.trim().isNotEmpty || activeSource != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 720;
        final maxWidth = constraints.maxWidth;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      narrow ? 18 : 28,
                      8,
                      narrow ? 18 : 28,
                      12,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '观看历史',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontSize: 26,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                all.isEmpty
                                    ? '播放记录只保存在本机'
                                    : filtering
                                    ? '${filtered.length} / ${all.length} 条记录'
                                    : '共 ${all.length} 条记录 · 进度保存在本机',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (all.isNotEmpty)
                          TextButton.icon(
                            onPressed: () async {
                              final ok = await _confirm(
                                context,
                                '清空全部历史？',
                                '此操作不可恢复',
                              );
                              if (ok == true) await app.clearHistory();
                            },
                            icon: const Icon(Icons.delete_sweep_outlined),
                            label: const Text('清空'),
                          ),
                      ],
                    ),
                  ),
                ),
                if (all.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        narrow ? 18 : 28,
                        0,
                        narrow ? 18 : 28,
                        14,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _searchController,
                                  onChanged: (v) => setState(() => _query = v),
                                  decoration: InputDecoration(
                                    hintText: '搜索剧名 / 集名 / 备注 / 来源',
                                    prefixIcon: const Icon(
                                      Icons.search_rounded,
                                      size: 20,
                                    ),
                                    suffixIcon: _query.isEmpty
                                        ? null
                                        : IconButton(
                                            tooltip: '清除',
                                            onPressed: () {
                                              _searchController.clear();
                                              setState(() => _query = '');
                                            },
                                            icon: const Icon(
                                              Icons.close_rounded,
                                              size: 18,
                                            ),
                                          ),
                                    isDense: true,
                                    filled: true,
                                    fillColor: theme
                                        .colorScheme
                                        .surfaceContainerHighest
                                        .withValues(alpha: 0.4),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton.icon(
                                onPressed: () => _pickSource(
                                  activeSource,
                                  sourceNames,
                                  sourceCounts,
                                  all.length,
                                ),
                                icon: const Icon(
                                  Icons.filter_alt_outlined,
                                  size: 18,
                                ),
                                label: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 120,
                                  ),
                                  child: Text(
                                    activeSource == null
                                        ? '全部来源'
                                        : (sourceNames[activeSource] ?? '来源'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 48),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (all.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.history_rounded,
                      title: '还没有观看记录',
                      message: '开始播放后，进度会自动保存在本机',
                    ),
                  )
                else if (filtered.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.search_off_rounded,
                      title: '没有匹配的记录',
                      message: '换个关键词，或切换上方来源试试',
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      narrow ? 18 : 28,
                      0,
                      narrow ? 18 : 28,
                      12,
                    ),
                    sliver: SliverList.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        return _HistoryTile(
                          item: item,
                          onTap: () => _resume(context, item),
                          onSecondaryLongPress: () =>
                              app.requestSearch(item.name),
                          onDelete: () => app.removeHistory(item.key),
                        );
                      },
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 30)),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickSource(
    String? activeSource,
    Map<String, String> sourceNames,
    Map<String, int> sourceCounts,
    int allCount,
  ) async {
    final theme = Theme.of(context);
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.filter_alt_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('按来源筛选', style: theme.textTheme.titleMedium),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      selected: activeSource == null,
                      leading: const Icon(Icons.all_inbox_rounded),
                      title: const Text('全部来源'),
                      trailing: Text('$allCount'),
                      onTap: () => Navigator.pop(ctx, ''),
                    ),
                    for (final entry in sourceNames.entries)
                      ListTile(
                        selected: activeSource == entry.key,
                        leading: const Icon(Icons.dns_rounded),
                        title: Text(
                          entry.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text('${sourceCounts[entry.key] ?? 0}'),
                        onTap: () => Navigator.pop(ctx, entry.key),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    setState(() => _sourceKey = picked.isEmpty ? null : picked);
  }

  /// 历史记录里只存了当前集，拿完整选集后按原始地址/集名/index 定位回同一集。
  int _findEpisodeIndex(
    List<Episode> episodes,
    HistoryItem item,
    String resolved, {
    required bool sameLine,
  }) {
    int? byUrl(String target) {
      if (target.isEmpty) return null;
      for (var i = 0; i < episodes.length; i++) {
        if (episodes[i].url == target ||
            splitUrlHeadersClean(episodes[i].url) == target) {
          return i;
        }
      }
      return null;
    }

    final matched = byUrl(item.rawUrl.trim()) ?? byUrl(resolved);
    if (matched != null) return matched;
    if (item.episodeName.isNotEmpty) {
      for (var i = 0; i < episodes.length; i++) {
        if (episodes[i].name == item.episodeName) return i;
      }
    }
    if (sameLine && item.episodeIndex > 0) {
      return item.episodeIndex.clamp(0, episodes.length - 1);
    }
    return 0;
  }

  Future<void> _resume(BuildContext context, HistoryItem item) async {
    if (_resuming) return;
    _resuming = true;
    try {
      await _resumeInner(context, item);
    } finally {
      _resuming = false;
    }
  }

  Future<void> _resumeInner(BuildContext context, HistoryItem item) async {
    final app = AppScope.of(context);
    final site = _siteOf(app, item.sourceKey);
    if (site == null) {
      _toast(context, '找不到这条记录对应的站点');
      return;
    }
    VodDetail synthetic(String episodeUrl) => VodDetail(
      id: item.vodId,
      name: item.name,
      pic: item.pic,
      remarks: item.remarks,
      sourceKey: item.sourceKey,
      flags: [item.flag],
      episodes: {
        item.flag: [
          Episode(
            name: item.episodeName.isEmpty ? '正片' : item.episodeName,
            url: episodeUrl,
          ),
        ],
      },
    );

    final raw = splitUrlHeadersClean(item.url);
    final storedRaw = item.rawUrl.trim();
    // 已经失效的本机取流地址（加固壳 JVM 重启后端口就没了，/play 的 token
    // 也只在本进程有效）。
    final staleLocal =
        (raw.contains('127.0.0.1') || raw.contains('localhost')) &&
        RegExp(r'/chunk|/proxy|/play').hasMatch(raw);
    final isDriveLine = driveHintFromFlag(item.flag) != null;

    // ★ 详情就是完整选集列表。续播时先拉一次详情，网盘线路也不例外，
    //   否则历史里只带当前这一集，播放器选集栏只有一集、上下集按钮也切不动。
    //   详情拉取失败时再回落到后面的单集重取链逻辑。
    VodDetail? full;
    try {
      full = await app.sourceService.detail(site, item.vodId);
    } catch (_) {
      full = null;
    }
    if (!context.mounted) return;
    if (full != null && full.flags.isNotEmpty) {
      final flag = full.flags.contains(item.flag)
          ? item.flag
          : full.flags.first;
      final episodes = full.episodeList(flag);
      if (episodes.isNotEmpty) {
        final sameLine = flag == item.flag;
        final index = _findEpisodeIndex(
          episodes,
          item,
          raw,
          sameLine: sameLine,
        );
        // 网盘线路的已解析地址是带 Cookie/临时取流的地址，不能直接复用，
        // 统一交给播放器用原始集数地址重新取链。
        final canUseDirect =
            !isDriveLine && sameLine && !staleLocal && raw.startsWith('http');
        await openVodPlayer(
          context,
          app,
          PlayerSession(
            detail: full,
            site: site,
            flag: flag,
            episodeIndex: index,
            episodes: episodes,
            initialPlay: canUseDirect
                ? PlayResult(
                    url: raw,
                    flag: flag,
                    // 直链往往依赖 Referer / UA：历史里存过就原样带上，
                    // 旧记录没存时退回 URL 里内嵌的 `|` 头。
                    headers: item.headers.isNotEmpty
                        ? item.headers
                        : splitUrlHeaders(item.url),
                  )
                : null,
            startPositionMs: item.positionMs,
          ),
        );
        return;
      }
    }

    if (storedRaw.isEmpty && !staleLocal) {
      // 旧记录：直接播已解析地址（保持原行为）。
      if (!raw.startsWith('http')) {
        _toast(context, '这条记录没有可用的播放地址');
        return;
      }
      final detail = synthetic(item.url);
      final play = PlayResult(
        url: raw,
        flag: item.flag,
        headers: item.headers.isNotEmpty
            ? item.headers
            : splitUrlHeaders(item.url),
      );
      await openVodPlayer(
        context,
        app,
        PlayerSession(
          detail: detail,
          site: site,
          flag: item.flag,
          episodeIndex: 0,
          episodes: detail.episodeList(item.flag),
          initialPlay: play,
          startPositionMs: item.positionMs,
        ),
      );
      return;
    }

    if (storedRaw.isNotEmpty) {
      // 新记录：拿原始集数地址交给播放器重新取链（网盘源的临时地址不会再被复用）。
      final detail = synthetic(storedRaw);
      await openVodPlayer(
        context,
        app,
        PlayerSession(
          detail: detail,
          site: site,
          flag: item.flag,
          episodeIndex: 0,
          episodes: detail.episodeList(item.flag),
          startPositionMs: item.positionMs,
        ),
      );
      return;
    }

    // 旧记录里是本机临时取流地址：重新拉一次详情，拿回原始集数地址。
    _toast(context, '取流地址已失效，正在重新获取播放地址…');
    VodDetail? fresh;
    try {
      fresh = await app.sourceService.detail(site, item.vodId);
    } catch (_) {
      fresh = null;
    }
    if (!context.mounted) return;
    final freshDetail = fresh;
    if (freshDetail == null || freshDetail.flags.isEmpty) {
      _toast(context, '重新获取失败，请回到详情页重新播放');
      return;
    }
    final flag = freshDetail.flags.contains(item.flag)
        ? item.flag
        : freshDetail.flags.first;
    final episodes = freshDetail.episodeList(flag);
    if (episodes.isEmpty) {
      _toast(context, '该剧集暂时没有可播线路');
      return;
    }
    final index = item.episodeIndex.clamp(0, episodes.length - 1);
    await openVodPlayer(
      context,
      app,
      PlayerSession(
        detail: freshDetail,
        site: site,
        flag: flag,
        episodeIndex: index,
        episodes: episodes,
        startPositionMs: item.positionMs,
      ),
    );
  }

  SourceBean? _siteOf(AppState app, String key) {
    final sites = app.config?.sites ?? const <SourceBean>[];
    for (final s in sites) {
      if (s.key == key) return s;
    }
    return null;
  }

  Future<bool?> _confirm(BuildContext context, String title, String message) {
    return showDialog<bool>(
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
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.item,
    required this.onTap,
    required this.onSecondaryLongPress,
    required this.onDelete,
  });
  final HistoryItem item;
  final VoidCallback onTap;
  final VoidCallback onSecondaryLongPress;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SecondaryLongPressDetector(
      onLongPress: onSecondaryLongPress,
      child: GlassPanel(
        padding: const EdgeInsets.all(10),
        borderRadius: 18,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 68,
                  height: 96,
                  child: item.pic.isEmpty
                      ? Container(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.14,
                          ),
                        )
                      : Image.network(
                          item.pic,
                          fit: BoxFit.cover,
                          cacheWidth: 200,
                          errorBuilder: (_, _, _) => Container(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.14,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HoverMarqueeText(
                      item.name,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${item.episodeName.isEmpty ? item.remarks : item.episodeName} · ${item.sourceName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.70,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: item.progress,
                        minHeight: 4,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.progress > 0.01
                          ? '已看 ${(item.progress * 100).round()}% · ${_timeAgo(item.updatedAt)}'
                          : _timeAgo(item.updatedAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.60,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '移除此记录',
                onPressed: onDelete,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _timeAgo(int ms) {
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60000) return '刚刚';
    if (diff < 3600000) return '${diff ~/ 60000} 分钟前';
    if (diff < 86400000) return '${diff ~/ 3600000} 小时前';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}-${d.day}';
  }
}

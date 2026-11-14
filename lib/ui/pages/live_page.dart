import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/live.dart';
import '../../models/site_config.dart';
import '../../services/file_dialog_service.dart';
import '../../services/live/epg.dart';
import '../../services/live/live_export.dart';
import '../open_player.dart';
import '../widgets/empty_state.dart';
import '../widgets/mouse_drag_scroll.dart';
import '../widgets/glass.dart';
import '../widgets/hover_marquee_text.dart';
import '../widgets/live_catchup_sheet.dart';

class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  int _groupIndex = 0;
  String? _loadedKey;
  bool _loading = false;
  String? _error;
  List<LiveGroup> _groups = const [];
  Map<String, EpgEntry> _epg = const {};
  Map<String, List<EpgProgram>> _programs = const {};
  int _epgSeq = 0;
  Timer? _epgTimer;

  @override
  void dispose() {
    _epgTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    final key = _liveKey(app.lives, app.activeLiveIndex);
    if (key != _loadedKey) {
      _loadedKey = key;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  String _liveKey(List<LiveBean> lives, int index) {
    if (lives.isEmpty) return '';
    return '$index|${lives[index].name}|${lives[index].url}';
  }

  Future<void> _load() async {
    final app = AppScope.of(context);
    final lives = app.lives;
    if (lives.isEmpty) {
      setState(() {
        _groups = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    final bean = lives[app.activeLiveIndex];
    _epgTimer?.cancel();
    _epgSeq++;
    setState(() {
      _loading = true;
      _error = null;
      _groups = const [];
      _epg = const {};
      _programs = const {};
      _groupIndex = 0;
    });
    try {
      final groups = await app.liveService.load(
        bean,
        sites: app.config?.sites ?? const [],
      );
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _loading = false;
      });
      if (groups.isNotEmpty) unawaited(_refreshEpg(bean, groups));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// EPG 是增强项：失败只当作没有节目单，不影响频道列表与播放。
  Future<void> _refreshEpg(
    LiveBean bean,
    List<LiveGroup> groups, {
    bool refresh = false,
  }) async {
    final app = AppScope.of(context);
    final seq = ++_epgSeq;
    Map<String, List<EpgProgram>> programs = const {};
    try {
      programs = await app.epgService.loadProgramsFor(
        bean: bean,
        channels: groups.expand((g) => g.channels).toList(),
        refresh: refresh,
      );
    } catch (_) {
      programs = const {};
    }
    if (!mounted || seq != _epgSeq) return;
    final epg = programs.isEmpty
        ? const <String, EpgEntry>{}
        : buildEpgEntries(programs, DateTime.now().millisecondsSinceEpoch);
    setState(() {
      _programs = programs;
      _epg = epg;
    });
    _scheduleEpgRefresh(bean, groups, epg);
  }

  /// 只在「当前节目结束 / 下一档开始」时再拉一次，不做轮询。
  void _scheduleEpgRefresh(
    LiveBean bean,
    List<LiveGroup> groups,
    Map<String, EpgEntry> epg,
  ) {
    _epgTimer?.cancel();
    int? soonest;
    for (final entry in epg.values) {
      final at = entry.current?.endTime ?? entry.next?.startTime;
      if (at == null) continue;
      if (soonest == null || at < soonest) soonest = at;
    }
    if (soonest == null) return;
    final delta = soonest - DateTime.now().millisecondsSinceEpoch + 1000;
    final delay = Duration(milliseconds: delta.clamp(1000, 6 * 3600 * 1000));
    _epgTimer = Timer(delay, () {
      if (mounted) unawaited(_refreshEpg(bean, groups, refresh: true));
    });
  }

  Future<void> _export(String format) async {
    final app = AppScope.of(context);
    final bean = app.activeLive;
    if (bean == null || _groups.isEmpty) return;
    final text = format == 'm3u'
        ? LiveExport.renderM3u(_groups)
        : LiveExport.renderTxt(_groups);
    if (text.isEmpty) {
      _toast('当前线路没有可导出的频道');
      return;
    }
    final now = DateTime.now();
    final date =
        '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final ext = format == 'm3u' ? 'm3u' : 'txt';
    try {
      final path = await FileDialogService.saveText(
        suggestedName: LiveExport.suggestedName(bean.displayName, date, ext),
        text: text,
        type: FileDialogService.liveType,
      );
      if (!mounted) return;
      _toast(path == null ? '已取消导出' : '已导出到：$path');
    } catch (e) {
      if (!mounted) return;
      _toast('导出失败：$e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final lives = app.lives;

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        final maxWidth = constraints.maxWidth;
        if (lives.isEmpty) {
          return Center(
            child: EmptyState(
              icon: Icons.live_tv_rounded,
              title: '这份配置没有直播源',
              message: app.config == null
                  ? '先导入一份包含 lives 的 TVBox 订阅'
                  : '可以换一份带直播线路的配置试试',
            ),
          );
        }
        final group = _groups.isEmpty
            ? null
            : _groups[_groupIndex.clamp(0, _groups.length - 1)];
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    narrow ? 18 : 28,
                    8,
                    narrow ? 18 : 28,
                    10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '直播',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontSize: 26,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${lives.length} 条线路 · ${_groups.length} 个分组'
                              '${_epg.isEmpty ? '' : ' · EPG 已匹配'}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '导出当前线路',
                        enabled: _groups.isNotEmpty,
                        onSelected: _export,
                        icon: const Icon(Icons.file_download_outlined),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'txt',
                            child: Text('导出 TXT（分组,#genre#）'),
                          ),
                          PopupMenuItem(
                            value: 'm3u',
                            child: Text('导出 M3U 播放列表'),
                          ),
                        ],
                      ),
                      IconButton(
                        tooltip: '刷新',
                        onPressed: _load,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                ),
                if (app.liveProfiles.length > 1)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      narrow ? 18 : 28,
                      0,
                      narrow ? 18 : 28,
                      8,
                    ),
                    child: ScrollConfiguration(
                      behavior: const MouseDragScrollBehavior(),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            Text(
                              '直播订阅',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.55,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            for (final profile in app.liveProfiles)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(profile.name),
                                  selected:
                                      app.activeLiveProfileId == profile.id,
                                  onSelected: (_) =>
                                      app.setActiveLiveProfile(profile.id),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (lives.length > 1)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      narrow ? 18 : 28,
                      0,
                      narrow ? 18 : 28,
                      10,
                    ),
                    child: ScrollConfiguration(
                      behavior: const MouseDragScrollBehavior(),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            Text(
                              '直播线路',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.55,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            for (var i = 0; i < lives.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(lives[i].displayName),
                                  selected: app.activeLiveIndex == i,
                                  onSelected: (_) =>
                                      app.setActiveLive(lives[i]),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _error != null
                      ? Center(
                          child: EmptyState(
                            icon: Icons.wifi_off_rounded,
                            title: '直播加载失败',
                            message: _error,
                            action: FilledButton.tonalIcon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('重试'),
                            ),
                          ),
                        )
                      : _groups.isEmpty
                      ? const EmptyState(
                          icon: Icons.live_tv_outlined,
                          title: '没有解析到频道',
                          message: '订阅内容可能为空，或格式暂不支持',
                        )
                      : narrow
                      ? _MobileBody(
                          groups: _groups,
                          groupIndex: _groupIndex,
                          epg: _epg,
                          programs: _programs,
                          onGroup: (i) => setState(() => _groupIndex = i),
                          onPlay: (channel, line) => _play(
                            context,
                            app.activeLive ?? lives.first,
                            channel,
                            line,
                          ),
                          onCatchup: _openCatchup,
                        )
                      : _DesktopBody(
                          groups: _groups,
                          groupIndex: _groupIndex,
                          epg: _epg,
                          programs: _programs,
                          onGroup: (i) => setState(() => _groupIndex = i),
                          group: group!,
                          onPlay: (channel, line) => _play(
                            context,
                            app.activeLive ?? lives.first,
                            channel,
                            line,
                          ),
                          onCatchup: _openCatchup,
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openCatchup(
    LiveChannel channel,
    List<EpgProgram> programs,
  ) => showLiveCatchupSheet(
    context,
    channel: channel,
    programs: programs,
  );

  Future<void> _play(
    BuildContext context,
    LiveBean bean,
    LiveChannel channel,
    LiveLine line,
  ) async {
    final app = AppScope.of(context);
    await openLivePlayer(
      context,
      app,
      bean: bean,
      channel: channel,
      initialLine: line,
      epg: entryOf(_epg, epgRefOf(channel)),
      groups: _groups,
      epgEntries: _epg,
      initialGroup: _groups.isEmpty
          ? ''
          : _groups[_groupIndex.clamp(0, _groups.length - 1)].group,
    );
  }
}

class _DesktopBody extends StatelessWidget {
  const _DesktopBody({
    required this.groups,
    required this.groupIndex,
    required this.epg,
    required this.programs,
    required this.onGroup,
    required this.group,
    required this.onPlay,
    required this.onCatchup,
  });

  final List<LiveGroup> groups;
  final int groupIndex;
  final Map<String, EpgEntry> epg;
  final Map<String, List<EpgProgram>> programs;
  final ValueChanged<int> onGroup;
  final LiveGroup group;
  final void Function(LiveChannel, LiveLine) onPlay;
  final void Function(LiveChannel, List<EpgProgram>) onCatchup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 200,
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 4, 10, 20),
            itemCount: groups.length,
            itemBuilder: (context, index) {
              final active = index == groupIndex;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onGroup(index),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: active
                          ? theme.colorScheme.primary.withValues(alpha: 0.16)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: HoverMarqueeText(
                            groups[index].group,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: active
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color: active ? theme.colorScheme.primary : null,
                            ),
                          ),
                        ),
                        Text(
                          '${groups[index].channels.length}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Expanded(
          child: _ChannelGrid(
            channels: group.channels,
            epg: epg,
            programs: programs,
            onPlay: onPlay,
            onCatchup: onCatchup,
          ),
        ),
      ],
    );
  }
}

class _MobileBody extends StatelessWidget {
  const _MobileBody({
    required this.groups,
    required this.groupIndex,
    required this.epg,
    required this.programs,
    required this.onGroup,
    required this.onPlay,
    required this.onCatchup,
  });

  final List<LiveGroup> groups;
  final int groupIndex;
  final Map<String, EpgEntry> epg;
  final Map<String, List<EpgProgram>> programs;
  final ValueChanged<int> onGroup;
  final void Function(LiveChannel, LiveLine) onPlay;
  final void Function(LiveChannel, List<EpgProgram>) onCatchup;

  @override
  Widget build(BuildContext context) {
    final group = groups[groupIndex.clamp(0, groups.length - 1)];
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ScrollConfiguration(
            behavior: const MouseDragScrollBehavior(),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < groups.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(
                        '${groups[i].group} ${groups[i].channels.length}',
                      ),
                      selected: groupIndex == i,
                      onSelected: (_) => onGroup(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _ChannelGrid(
            channels: group.channels,
            epg: epg,
            programs: programs,
            onPlay: onPlay,
            onCatchup: onCatchup,
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          ),
        ),
      ],
    );
  }
}

class _ChannelGrid extends StatelessWidget {
  const _ChannelGrid({
    required this.channels,
    required this.epg,
    required this.programs,
    required this.onPlay,
    required this.onCatchup,
    this.padding = const EdgeInsets.fromLTRB(10, 4, 28, 28),
  });
  final List<LiveChannel> channels;
  final Map<String, EpgEntry> epg;
  final Map<String, List<EpgProgram>> programs;
  final void Function(LiveChannel, LiveLine) onPlay;
  final void Function(LiveChannel, List<EpgProgram>) onCatchup;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: padding,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 256,
        mainAxisExtent: 74,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final channel = channels[index];
        final lines = channelLines(channel);
        final programsOf =
            lookupEpg(programs, epgRefOf(channel)) ?? const <EpgProgram>[];
        return _ChannelTile(
          channel: channel,
          lineCount: lines.length,
          epg: entryOf(epg, epgRefOf(channel)),
          onSchedule: programsOf.isEmpty
              ? null
              : () => onCatchup(channel, programsOf),
          onTap: () {
            if (lines.isEmpty) return;
            // 多条线路时默认起播源 1；其余线路在播放器顶栏的「N 条线路」里切换。
            onPlay(channel, lines.first);
          },
        );
      },
    );
  }
}

class _ChannelTile extends StatefulWidget {
  const _ChannelTile({
    required this.channel,
    required this.lineCount,
    required this.epg,
    required this.onTap,
    this.onSchedule,
  });
  final LiveChannel channel;
  final int lineCount;
  final EpgEntry? epg;
  final VoidCallback onTap;
  final VoidCallback? onSchedule;

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    final lineCount = widget.lineCount;
    final epg = widget.epg;
    final onTap = widget.onTap;
    final theme = Theme.of(context);
    final current = epg?.current;
    final next = epg?.next;
    final tooltip = <String>[
      if (current != null) '正在播 ${current.range} ${current.title}',
      if (next != null) '下一档 ${next.start} ${next.title}',
    ].join('\n');
    final tile = GlassPanel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      borderRadius: 16,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: channel.logo.isEmpty
                  ? Center(
                      child: Text(
                        channel.name.characters.first,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    )
                  : Image.network(
                      channel.logo,
                      fit: BoxFit.contain,
                      cacheWidth: 128,
                      errorBuilder: (_, _, _) => Center(
                        child: Text(
                          channel.name.characters.first,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HoverMarqueeText(
                    channel.name,
                    externalHover: _hover,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 3),
                  HoverMarqueeText(
                    current != null
                        ? '${current.start} ${current.title}'
                        : '$lineCount 条线路',
                    externalHover: _hover,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: current != null
                          ? theme.colorScheme.primary.withValues(alpha: 0.8)
                          : theme.colorScheme.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ),
            if (widget.onSchedule != null)
              IconButton(
                tooltip: '节目单 / 回看',
                onPressed: widget.onSchedule,
                icon: const Icon(Icons.schedule_rounded, size: 18),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 28,
                  minHeight: 28,
                ),
              ),
            const Icon(Icons.play_arrow_rounded, size: 20),
          ],
        ),
      ),
    );
    final hoverTile = MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: tile,
    );
    return tooltip.isEmpty
        ? hoverTile
        : Tooltip(message: tooltip, child: hoverTile);
  }
}

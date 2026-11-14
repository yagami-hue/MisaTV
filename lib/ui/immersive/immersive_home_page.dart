import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/site_config.dart';
import '../../models/user_data.dart';
import '../../models/vod.dart';
import '../../state/app_state.dart';
import '../widgets/mouse_drag_scroll.dart';
import 'focus_memory.dart';
import 'immersive_category_page.dart';
import 'immersive_widgets.dart';

/// 沉浸观影首页：大屏海报轮播 + 横图卡片横向货架。
class ImmersiveHomePage extends StatefulWidget {
  const ImmersiveHomePage({super.key});

  @override
  State<ImmersiveHomePage> createState() => _ImmersiveHomePageState();
}

class _ImmersiveHomePageState extends State<ImmersiveHomePage> {
  String _siteKey = '__init__';
  bool _loading = true;
  String? _error;
  List<ImmersiveHeroItem> _hero = const [];
  List<({String title, List<_HomeEntry> items})> _shelves = const [];
  List<SortClass> _classes = const [];
  SourceBean? _site;
  int _total = 0;

  /// 焦点记忆：从详情页返回时恢复到刚才那张卡片，而不是跳回第一张。
  ///
  /// 这里不需要 onChanged 刷新界面：高亮由每张卡自己 setState，
  /// 外层只要在数据变化时调用 [_syncFocusKeys] 维护 key 集合即可。
  final FocusMemory _focusMemory = FocusMemory();

  /// `货架下标:条目下标` → FocusNode。按内容 key 缓存，列表刷新后复用同一节点。
  final Map<String, FocusNode> _focusNodes = {};

  /// 首页整体的键盘 / 遥控器焦点入口：方向键在货架之间移动。
  final FocusNode _rootFocus = FocusNode(debugLabel: 'immersive-home');

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    _focusNodes.clear();
    _rootFocus.dispose();
    super.dispose();
  }

  /// 取（或建）某个卡片的焦点节点。
  FocusNode _focusNodeFor(String key) => _focusNodes.putIfAbsent(
    key,
    () => FocusNode(debugLabel: 'immersive-card-$key'),
  );

  /// 货架内容变化后：同步有效 key，释放已消失卡片的节点。
  void _syncFocusKeys() {
    final keys = <String>[
      for (var s = 0; s < _shelves.length; s++)
        for (var i = 0; i < _shelves[s].items.length; i++) '$s:$i',
      for (var i = 0; i < _classes.length; i++) 'cls:$i',
    ];
    final removed = _focusMemory.syncKeys(keys);
    for (final key in removed) {
      _focusNodes.remove(key)?.dispose();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    final key = app.activeSiteKey ?? '';
    if (key == _siteKey) return;
    _siteKey = key;
    _load();
  }

  Future<void> _load() async {
    final app = AppScope.of(context);
    final site = app.activeSite;
    final key = app.activeSiteKey ?? '';
    setState(() {
      _loading = true;
      _error = null;
      _hero = const [];
      _shelves = const [];
      _classes = const [];
      _site = null;
      _total = 0;
    });
    if (site == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final data = await app.sourceService.home(site);
      if (!mounted || key != (app.activeSiteKey ?? '')) return;
      final items = data.items;
      _total = items.length;
      setState(() {
        _loading = false;
        _site = site;
        _classes = [
          for (final cls in data.classes)
            if (cls.id.trim().isNotEmpty && cls.name.trim().isNotEmpty) cls,
        ];
        _hero = [
          for (final item in items.take(6))
            ImmersiveHeroItem(
              title: item.name,
              year: _validYear(item.year) ? item.year : '',
              subtitle: _heroSubtitle(item, site),
              description: _heroDescription(item),
              fallback: item.cleanPic,
              actionLabel: '查看详情',
              onTap: () => openImmersiveItem(context, item),
            ),
        ];
        _shelves = [
          if (items.isNotEmpty)
            (
              title: '当前源 · 热门',
              items: [for (final item in items.take(24)) _entryOf(item, site)],
            ),
        ];
      });
      if (items.isEmpty) {
        await _loadDoubanFallback(app);
        await _loadContinueWatching(app);
        return;
      }
      unawaited(_loadCategoryShelves(app, site, data.classes, key));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
    if (mounted) await _loadContinueWatching(app);
  }

  Future<void> _loadContinueWatching(AppState app) async {
    final map = <String, HistoryItem>{};
    for (final item in app.history.take(12)) {
      map.putIfAbsent(item.key, () => item);
    }
    if (map.isEmpty || !mounted) return;
    final entries = <_HomeEntry>[
      for (final item in map.values)
        _HomeEntry(
          title: item.name,
          year: '',
          subtitle: item.episodeName.isEmpty ? item.sourceName : item.episodeName,
          fallback: item.pic,
          badge: item.episodeName.isEmpty ? '' : item.episodeName,
          progress: item.progress,
          item: VodItem(
            id: item.vodId,
            name: item.name,
            pic: item.pic,
            sourceKey: item.sourceKey,
            sourceName: item.sourceName,
            remarks: item.remarks,
          ),
        ),
    ];
    setState(() {
      _shelves = [
        (title: '继续观看', items: entries),
        ..._shelves,
      ];
    });
  }

  Future<void> _loadCategoryShelves(
    AppState app,
    SourceBean site,
    List<SortClass> classes,
    String key,
  ) async {
    final picked = classes
        .where((cls) => cls.id.trim().isNotEmpty && cls.name.trim().isNotEmpty)
        .take(2)
        .toList();
    for (final cls in picked) {
      try {
        final result = await app.sourceService.category(
          site,
          cls.id,
          '1',
          const {},
        );
        if (!mounted || key != (app.activeSiteKey ?? '')) return;
        final items = result.items.take(20).toList();
        if (items.isEmpty) continue;
        setState(() {
          _shelves = [
            ..._shelves,
            (title: cls.name, items: [for (final item in items) _entryOf(item, site)]),
          ];
        });
      } catch (_) {
        // 单个分类失败不影响其它货架
      }
    }
  }

  Future<void> _loadDoubanFallback(AppState app) async {
    try {
      final sections = await app.discoverService.loadSections();
      if (!mounted) return;
      _classes = const [];
      final filled = [for (final s in sections) if (s.items.isNotEmpty) s];
      if (filled.isEmpty) return;
      final heroSource = filled.first.items.take(6).toList();
      setState(() {
        _hero = [
          for (final item in heroSource)
            ImmersiveHeroItem(
              title: item.title,
              year: item.year?.toString() ?? '',
              subtitle: '豆瓣推荐 · 全源搜索',
              fallback: item.posterUrl,
              actionLabel: '搜索片源',
              onTap: () => app.requestSearch(item.title),
            ),
        ];
        _shelves = [
          for (final section in filled.take(4))
            (
              title: section.title,
              items: [
                for (final item in section.items.take(20))
                  _HomeEntry(
                    title: item.title,
                    year: item.year?.toString() ?? '',
                    subtitle: item.mediaType == 'tv' ? '剧集' : '电影',
                    fallback: item.posterUrl,
                  ),
              ],
            ),
        ];
        _loading = false;
      });
      // 列表内容变了：同步焦点 key（释放已消失卡片的节点），
      // 数据到位后再恢复上次位置，否则此时节点还不存在。
      if (mounted) {
        _syncFocusKeys();
        _restoreFocusSoon();
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 等一帧再恢复焦点：卡片要先进树，FocusNode 才能被 requestFocus。
  void _restoreFocusSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _focusMemory.restoreTarget(fallback: '0:0');
      if (target == null) return;
      final node = _focusNodes[target];
      if (node == null || !node.canRequestFocus) return;
      node.requestFocus();
    });
  }

  String _heroSubtitle(VodItem item, SourceBean site) {
    final parts = <String>[
      if (item.type.isNotEmpty && item.type != item.remarks) item.type,
      site.displayName,
    ];
    return parts.join(' · ');
  }

  String _heroDescription(VodItem item) {
    final remarks = item.remarks.trim();
    if (remarks.isEmpty) return '';
    // 「国剧」「电影」这类短标签已经在副标题里，不重复占一行。
    if (remarks.length <= 4 && !remarks.contains(RegExp(r'\d'))) return '';
    return remarks;
  }

  bool _validYear(String raw) {
    final value = int.tryParse(raw.trim());
    return value != null && value >= 1900 && value <= 2100;
  }

  _HomeEntry _entryOf(VodItem item, SourceBean site) => _HomeEntry(
    title: item.name,
    year: item.year,
    subtitle: item.remarks.isEmpty ? site.displayName : item.remarks,
    fallback: item.cleanPic,
    item: item,
  );

  void _open(_HomeEntry entry) {
    final item = entry.item;
    if (item != null) {
      openImmersiveItem(context, item);
      return;
    }
    AppScope.of(context).requestSearch(entry.title);
  }

  void _openCategory(SortClass cls) {
    final site = _site ?? AppScope.of(context).activeSite;
    if (site == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImmersiveCategoryPage(site: site, sortClass: cls),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    // Hero 直接铺满整屏：大屏模式下第一眼就是完整横图，向下滚动才是分类与货架。
    final heroHeight = MediaQuery.sizeOf(context).height;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: ImmersiveEmpty(
          title: '首页加载失败',
          message: _error!,
          action: FilledButton.tonal(
            onPressed: _load,
            child: const Text('重试'),
          ),
        ),
      );
    }
    if (_hero.isEmpty) {
      return Center(
        child: ImmersiveEmpty(
          title: '当前源没有内容',
          message: app.activeSite == null
              ? '先在设置里导入订阅'
              : '在右上角切换其它源，或到搜索页检索',
        ),
      );
    }

    // 焦点容器把方向键交给 Flutter 的焦点树遍历（按几何顺序在货架间移动），
    // 并开启自动滚动：焦点走到视口外的卡片时，外层 Scrollable 会跟随滚动。
    // 这比自己算网格更稳（货架是横向滚动 + 多个分架的混合布局）。
    return Focus(
      focusNode: _rootFocus,
      child: ScrollConfiguration(
        behavior: const MouseDragScrollBehavior(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 44),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          ImmersiveHero(items: _hero, height: heroHeight),
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 4, 56, 0),
            child: Row(
              children: [
                Text(
                  '当前源',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.44),
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(width: 10),
                PopupMenuButton<String>(
                  tooltip: '切换源',
                  initialValue: app.activeSiteKey,
                  onSelected: (key) => app.setActiveSite(key),
                  itemBuilder: (_) => [
                    for (final site in app.usableSites)
                      PopupMenuItem(
                        value: site.key,
                        child: Row(
                          children: [
                            Expanded(child: Text(site.displayName)),
                            if (site.key == app.activeSiteKey)
                              Icon(
                                Icons.check_rounded,
                                size: 16,
                                color: theme.colorScheme.primary,
                              ),
                          ],
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          app.activeSite?.displayName ?? '选择源',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.expand_more_rounded,
                          size: 18,
                          color: Colors.white.withValues(alpha: 0.56),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                if (_total > 0)
                  Text(
                    '共 $_total 部',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.42),
                    ),
                  ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _load,
                  icon: Icon(
                    Icons.refresh_rounded,
                    color: Colors.white.withValues(alpha: 0.52),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (_classes.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(56, 0, 56, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '分类浏览',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '点击进入分类选片',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.42),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 48,
              child: ScrollConfiguration(
                behavior: const MouseDragScrollBehavior(),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 56),
                  itemCount: _classes.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) => _CategoryChip(
                    label: _classes[index].name,
                    onTap: () => _openCategory(_classes[index]),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 26),
          ],
          for (var shelfIndex = 0; shelfIndex < _shelves.length; shelfIndex++) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(56, 0, 56, 0),
              child: ImmersiveShelf(
                title: _shelves[shelfIndex].title,
                itemCount: _shelves[shelfIndex].items.length,
                height: 232,
                itemBuilder: (context, index) {
                  final entry = _shelves[shelfIndex].items[index];
                  final key = '$shelfIndex:$index';
                  return ImmersiveCard(
                    title: entry.title,
                    year: entry.year,
                    subtitle: entry.subtitle,
                    fallback: entry.fallback,
                    badge: entry.badge,
                    progress: entry.progress,
                    showText: false,
                    width: 310,
                    focusNode: _focusNodeFor(key),
                    onFocus: () => _focusMemory.remember(key),
                    onTap: () {
                      // 记住位置：从详情页返回时恢复到这里。
                      _focusMemory.remember(key);
                      _open(entry);
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 30),
          ],
        ],
      ),
        ),
      ),
    );
  }
}

class _CategoryChip extends StatefulWidget {
  const _CategoryChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_CategoryChip> createState() => _CategoryChipState();
}

class _CategoryChipState extends State<_CategoryChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: _hover ? 0.13 : 0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hover
                  ? theme.colorScheme.primary.withValues(alpha: 0.55)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Text(
            widget.label,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: _hover ? 0.96 : 0.78),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeEntry {
  const _HomeEntry({
    required this.title,
    this.year = '',
    this.subtitle = '',
    this.fallback = '',
    this.badge = '',
    this.progress = 0,
    this.item,
  });

  final String title;
  final String year;
  final String subtitle;
  final String fallback;
  final String badge;
  final double progress;
  final VodItem? item;
}

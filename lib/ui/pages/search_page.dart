import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/site_config.dart';
import '../../models/vod.dart';
import '../../services/matching/title_matching.dart';
import '../../state/app_state.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass.dart';
import '../widgets/import_sheet.dart';
import '../widgets/poster_card.dart';
import '../widgets/source_variants_sheet.dart';
import 'detail_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  StreamSubscription<SearchProgress>? _sub;
  SearchProgress? _progress;
  bool _searching = false;
  String _keyword = '';

  /// 非 null 时只显示该源的结果；null 表示显示全部（跨源去重后的合并结果）。
  String? _filterSourceKey;

  /// 输入 `关键词@` 后选定的「置顶源」：后续搜索只查它。
  String? _pinnedSiteKey;

  /// 详情页发起的搜索请求序号；变化时执行一次。
  int _handledSearchSeq = 0;

  /// `@` 源选择浮层锚点。
  final _fieldLink = LayerLink();
  final _fieldKey = GlobalKey();
  OverlayEntry? _sourceOverlay;

  /// 输入联想：本地（历史 / 收藏 / 最近观看）立即出，豆瓣标题防抖后补。
  Timer? _suggestTimer;
  int _suggestSeq = 0;
  List<_SearchSuggestion> _suggestions = const [];
  String _lastText = '';

  @override
  void initState() {
    super.initState();
    _lastText = _controller.text;
    _controller.addListener(_onQueryChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _suggestTimer?.cancel();
    _hideSourceOverlay();
    _focusNode.removeListener(_onFocusChanged);
    _controller.removeListener(_onQueryChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 搜索范围内的源：可用、可搜索、且未被内容过滤屏蔽。
  List<SourceBean> _searchableSites(AppState app) {
    final filter = app.contentFilter;
    final sites = filter.active
        ? app.usableSites.where((s) => !filter.blocksSource(s)).toList()
        : app.usableSites;
    return sites.where((s) => s.searchable == 1).toList();
  }

  SourceBean? _pinnedSite(List<SourceBean> sites) {
    final key = _pinnedSiteKey;
    if (key == null) return null;
    for (final site in sites) {
      if (site.key == key) return site;
    }
    return null;
  }

  /// 兼容直接输入 `关键词@源名` 后回车：名称 / key 精确命中优先，只有一个
  /// 模糊命中时也直接采用，其余情况让用户从浮层里选。
  SourceBean? _matchSite(List<SourceBean> sites, String filter) {
    final q = filter.trim().toLowerCase();
    if (q.isEmpty) return null;
    for (final site in sites) {
      if (site.displayName.toLowerCase() == q || site.key.toLowerCase() == q) {
        return site;
      }
    }
    final hits = [
      for (final site in sites)
        if (site.displayName.toLowerCase().contains(q) ||
            site.key.toLowerCase().contains(q))
          site,
    ];
    return hits.length == 1 ? hits.first : null;
  }

  String _atFilter() {
    final text = _controller.text;
    final at = text.lastIndexOf('@');
    return at < 0 ? '' : text.substring(at + 1);
  }

  /// 同名跨源候选：用 `sourceItems`（未去重原始结果）按片名 + 年份归组。
  ///
  /// 合并结果只保留一条代表条目，`sourceItems` 里才有其它源的原始 id，
  /// 换源进详情时必须用后者，否则会把 A 源的 id 带到 B 源。
  List<VodItem> _variantsFor(VodItem item) {
    final progress = _progress;
    if (progress == null) return [item];
    final key = searchDedupeKey(item.name, year: item.year);
    final out = <VodItem>[];
    final seen = <String>{};
    for (final list in progress.sourceItems.values) {
      for (final candidate in list) {
        if (searchDedupeKey(candidate.name, year: candidate.year) != key) {
          continue;
        }
        final id = '${candidate.sourceKey}\u0000${candidate.id}';
        if (seen.add(id)) out.add(candidate);
      }
    }
    if (out.isEmpty) return [item];
    out.sort((a, b) {
      final bySource = a.sourceName.compareTo(b.sourceName);
      if (bySource != 0) return bySource;
      return a.remarks.compareTo(b.remarks);
    });
    return out;
  }

  void _showVariants(VodItem item) {
    final variants = _variantsFor(item);
    if (variants.length <= 1) return;
    showSourceVariantsSheet(
      context,
      variants: variants,
      currentSourceKey: item.sourceKey,
      onOpen: (picked) {
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => DetailPage(item: picked)),
        );
      },
    );
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus && _controller.text.contains('@')) {
      _syncSourceOverlay();
    }
  }

  void _onQueryChanged() {
    final text = _controller.text;
    if (text == _lastText || !mounted) return;
    _lastText = text;
    _suggestTimer?.cancel();
    final seq = ++_suggestSeq;
    final app = AppScope.of(context);
    final local = _localSuggestions(app, text);
    setState(() => _suggestions = local);
    if (text.contains('@')) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncSourceOverlay();
      });
      return;
    }
    _hideSourceOverlay();
    // 已经搜过同一个词时不再弹联想，避免遮住刚出来的结果。
    final settled = _progress != null && text.trim() == _keyword;
    if (settled || text.trim().isEmpty) return;
    _suggestTimer = Timer(const Duration(milliseconds: 320), () async {
      final online = await _onlineSuggestions(app, text);
      if (!mounted || seq != _suggestSeq) return;
      setState(() {
        _suggestions = _mergeSuggestions(local, online);
      });
    });
  }

  List<_SearchSuggestion> _localSuggestions(AppState app, String raw) {
    final query = raw.trim().toLowerCase();
    if (query.isEmpty) return const [];
    final rows = <(int, _SearchSuggestion)>[];
    final seen = <String>{};

    void collect(
      Iterable<String> values,
      String kind,
      IconData icon,
      int baseRank,
    ) {
      for (final value in values) {
        final text = value.trim();
        if (text.isEmpty) continue;
        final lower = text.toLowerCase();
        if (lower == query || !lower.contains(query)) continue;
        if (!seen.add(lower)) continue;
        final rank = baseRank * 2 + (lower.startsWith(query) ? 0 : 1);
        rows.add((rank, _SearchSuggestion(text: text, kind: kind, icon: icon)));
      }
    }

    collect(app.searchHistory, '搜索记录', Icons.history_rounded, 0);
    collect(
      app.favorites.map((f) => f.displayTitle),
      '收藏',
      Icons.favorite_rounded,
      1,
    );
    collect(
      app.history.map((h) => h.name.split(' - ').first),
      '最近观看',
      Icons.play_circle_outline_rounded,
      2,
    );
    rows.sort((a, b) {
      final byRank = a.$1.compareTo(b.$1);
      if (byRank != 0) return byRank;
      return a.$2.text.length.compareTo(b.$2.text.length);
    });
    return [for (final row in rows.take(6)) row.$2];
  }

  Future<List<_SearchSuggestion>> _onlineSuggestions(
    AppState app,
    String raw,
  ) async {
    final query = raw.trim();
    if (query.length < 2) return const [];
    try {
      final titles = await app.discoverService.suggestTitles(query);
      return [
        for (final title in titles)
          _SearchSuggestion(
            text: title,
            kind: '豆瓣',
            icon: Icons.local_movies_rounded,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static List<_SearchSuggestion> _mergeSuggestions(
    List<_SearchSuggestion> local,
    List<_SearchSuggestion> online,
  ) {
    final out = <_SearchSuggestion>[];
    final seen = <String>{};
    for (final item in [...local, ...online]) {
      if (!seen.add(item.text.toLowerCase())) continue;
      out.add(item);
      if (out.length >= 8) break;
    }
    return out;
  }

  bool get _showSuggestionsPanel {
    if (_suggestions.isEmpty || _controller.text.trim().isEmpty) return false;
    if (_controller.text.contains('@')) return false;
    return _progress == null || _controller.text.trim() != _keyword;
  }

  /// `@` 源选择浮层：输入 @ 后的文字按与首页换源相同的规则过滤站点。
  void _syncSourceOverlay() {
    if (!mounted || !_controller.text.contains('@')) {
      _hideSourceOverlay();
      return;
    }
    if (_sourceOverlay == null) {
      _sourceOverlay = OverlayEntry(builder: _buildSourceOverlay);
      Overlay.of(context, rootOverlay: true).insert(_sourceOverlay!);
    } else {
      _sourceOverlay!.markNeedsBuild();
    }
  }

  void _hideSourceOverlay() {
    final entry = _sourceOverlay;
    if (entry == null) return;
    _sourceOverlay = null;
    try {
      entry.remove();
    } catch (_) {
      // 退出 / 页面销毁时 Overlay 已不在，忽略即可。
    }
  }

  Widget _buildSourceOverlay(BuildContext overlayContext) {
    final app = AppScope.of(context);
    final sites = _searchableSites(app);
    final filter = _atFilter().trim().toLowerCase();
    var filtered = filter.isEmpty
        ? sites
        : [
            for (final site in sites)
              if (site.displayName.toLowerCase().contains(filter) ||
                  site.key.toLowerCase().contains(filter))
                site,
          ];
    // 已置顶的源排第一，继续输入筛选时也不会被列表埋掉。
    final pinnedKey = _pinnedSiteKey;
    if (pinnedKey != null) {
      final index = filtered.indexWhere((site) => site.key == pinnedKey);
      if (index > 0) {
        filtered = [
          filtered[index],
          ...filtered.sublist(0, index),
          ...filtered.sublist(index + 1),
        ];
      }
    }
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    final width = (box?.size.width ?? 420).clamp(280.0, 720.0);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _hideSourceOverlay,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: _fieldLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 6),
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: _SourceAtPopup(
              sites: filtered,
              total: sites.length,
              filter: _atFilter().trim(),
              selectedKey: _pinnedSiteKey,
              onSelect: _selectSearchSource,
              onClose: _closeAtMode,
            ),
          ),
        ),
      ],
    );
  }

  void _selectSearchSource(SourceBean? site) {
    final text = _controller.text;
    final at = text.lastIndexOf('@');
    final base = at < 0 ? text.trim() : text.substring(0, at).trimRight();
    _hideSourceOverlay();
    if (base.isEmpty) {
      setState(() => _pinnedSiteKey = site?.key);
      _controller.clear();
      _focusNode.requestFocus();
      return;
    }
    setState(() => _pinnedSiteKey = site?.key);
    _search(base);
  }

  void _closeAtMode() {
    final text = _controller.text;
    final at = text.lastIndexOf('@');
    if (at < 0) {
      _hideSourceOverlay();
      return;
    }
    _hideSourceOverlay();
    final base = text.substring(0, at);
    _controller.value = TextEditingValue(
      text: base,
      selection: TextSelection.collapsed(offset: base.length),
    );
    _focusNode.requestFocus();
  }

  /// 取消置顶源；当前结果如果是只搜这个源来的，立即改用全部源重搜。
  void _clearPinnedSite() {
    final rerun =
        _pinnedSiteKey != null &&
        _progress != null &&
        _keyword.isNotEmpty &&
        _controller.text.trim() == _keyword;
    setState(() => _pinnedSiteKey = null);
    if (rerun) _search(_keyword);
  }

  /// 回到搜索首页（清空结果与输入，重新看到搜索历史）。
  void _resetSearch() {
    _sub?.cancel();
    _sub = null;
    _suggestTimer?.cancel();
    _suggestSeq++;
    _hideSourceOverlay();
    setState(() {
      _progress = null;
      _searching = false;
      _keyword = '';
      _filterSourceKey = null;
      _pinnedSiteKey = null;
      _suggestions = const [];
    });
    _controller.clear();
    _focusNode.unfocus();
  }

  void _search(String keyword) {
    final app = AppScope.of(context);
    final sites = _searchableSites(app);
    var query = keyword.trim();
    String? pinKey = _pinnedSiteKey;

    // 直接输入 `关键词@源名` 回车：解析并选中该源；只有 @ 时打开浮层。
    final at = query.lastIndexOf('@');
    if (at >= 0) {
      final sourceText = query.substring(at + 1).trim();
      query = query.substring(0, at).trim();
      if (sourceText.isEmpty) {
        _syncSourceOverlay();
        return;
      }
      final match = _matchSite(sites, sourceText);
      if (match == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('没有匹配的源「$sourceText」，请从列表中选择')));
        _syncSourceOverlay();
        return;
      }
      pinKey = match.key;
      setState(() => _pinnedSiteKey = pinKey);
    }
    if (query.isEmpty) return;

    var scope = sites;
    final pin = pinKey;
    if (pin != null) {
      final pinned = [
        for (final site in sites)
          if (site.key == pin) site,
      ];
      if (pinned.isEmpty) {
        pinKey = null;
      } else {
        scope = pinned;
      }
    }
    if (scope.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('没有可用的搜索源')));
      return;
    }

    _sub?.cancel();
    _suggestTimer?.cancel();
    _suggestSeq++;
    _hideSourceOverlay();
    _keyword = query;
    app.addSearchKeyword(query);
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    setState(() {
      _searching = true;
      _filterSourceKey = pinKey;
      _suggestions = const [];
      _progress = SearchProgress(
        items: const [],
        perSource: const [],
        done: 0,
        total: scope.length,
      );
    });
    _sub = app.searchService
        .search(query, scope)
        .listen(
          (event) {
            if (!mounted) return;
            setState(() {
              _progress = event;
              _searching = !event.finished;
            });
          },
          onError: (Object e) {
            if (!mounted) return;
            setState(() {
              _searching = false;
            });
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('搜索失败：$e')));
          },
        );
  }

  /// 按内容过滤生成展示用的进度快照（合并结果与各源结果都过滤）。
  SearchProgress _filterProgress(AppState app, SearchProgress progress) {
    final filter = app.contentFilter;
    if (!filter.active) return progress;
    List<VodItem> keep(List<VodItem> items) =>
        items.where((item) => !filter.blocksVod(item)).toList();
    return SearchProgress(
      items: keep(progress.items),
      perSource: progress.perSource,
      done: progress.done,
      total: progress.total,
      finished: progress.finished,
      sourceItems: {
        for (final entry in progress.sourceItems.entries)
          entry.key: keep(entry.value),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    if (app.pendingSearchSeq != _handledSearchSeq) {
      _handledSearchSeq = app.pendingSearchSeq;
      final keyword = app.pendingSearchKeyword ?? '';
      if (keyword.trim().isNotEmpty) {
        // 详情页发起的外部搜索默认搜全部源，不继承搜索框里手工置顶的源。
        _pinnedSiteKey = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _search(keyword);
        });
      }
    }
    final rawProgress = _progress;
    final progress = rawProgress == null
        ? null
        : _filterProgress(app, rawProgress);
    final hiddenCount = rawProgress == null
        ? 0
        : rawProgress.items.length - (progress?.items.length ?? 0);
    final searchSites = _searchableSites(app);
    final pinnedSite = _pinnedSite(searchSites);
    SearchPerSource? selectedSource;
    if (progress != null && _filterSourceKey != null) {
      for (final source in progress.perSource) {
        if (source.key == _filterSourceKey) {
          selectedSource = source;
          break;
        }
      }
    }
    final visibleItems = progress == null
        ? const <VodItem>[]
        : _filterSourceKey == null
        ? progress.items
        : (progress.sourceItems[_filterSourceKey] ?? const <VodItem>[]);

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
                      10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (progress != null) ...[
                              IconButton(
                                tooltip: '返回搜索首页',
                                visualDensity: VisualDensity.compact,
                                onPressed: _resetSearch,
                                icon: const Icon(Icons.arrow_back_rounded),
                              ),
                              const SizedBox(width: 2),
                            ],
                            Expanded(
                              child: Text(
                                '搜索',
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontSize: 26,
                                ),
                              ),
                            ),
                            if (app.config != null)
                              Text(
                                pinnedSite == null
                                    ? '同时搜索 ${searchSites.length} 个站点'
                                    : '仅搜索 ${pinnedSite.displayName}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.45,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        CompositedTransformTarget(
                          key: _fieldKey,
                          link: _fieldLink,
                          child: TextField(
                            controller: _controller,
                            focusNode: _focusNode,
                            textInputAction: TextInputAction.search,
                            onSubmitted: _search,
                            onTap: () {
                              if (_controller.text.contains('@')) {
                                _syncSourceOverlay();
                              }
                            },
                            decoration: InputDecoration(
                              hintText: '搜索电影、剧集、动漫…；@ 指定站点，year:/type:/area: 过滤，-词 排除',
                              prefixIcon: const Icon(Icons.search_rounded),
                              suffixIcon: _controller.text.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: '清空',
                                      onPressed: () {
                                        _controller.clear();
                                        _focusNode.requestFocus();
                                      },
                                      icon: const Icon(Icons.close_rounded),
                                    ),
                            ),
                          ),
                        ),
                        if (pinnedSite != null) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Icon(
                                Icons.push_pin_rounded,
                                size: 15,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '只搜索',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.55,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              InputChip(
                                label: Text(pinnedSite.displayName),
                                visualDensity: VisualDensity.compact,
                                onDeleted: _clearPinnedSite,
                                deleteIcon: const Icon(
                                  Icons.close_rounded,
                                  size: 16,
                                ),
                                labelStyle: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                        if (_showSuggestionsPanel) ...[
                          const SizedBox(height: 8),
                          _SuggestionPanel(
                            suggestions: _suggestions,
                            onSelect: _search,
                          ),
                        ],
                        if (app.searchHistory.isNotEmpty &&
                            progress == null &&
                            !_showSuggestionsPanel) ...[
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Text(
                                '最近搜索',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                              ),
                              const Spacer(),
                              GestureDetector(
                                onTap: app.clearSearchHistory,
                                child: Text(
                                  '清空',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final keyword in app.searchHistory.take(12))
                                ActionChip(
                                  label: Text(keyword),
                                  backgroundColor: theme.colorScheme.primary
                                      .withValues(alpha: 0.1),
                                  side: BorderSide.none,
                                  labelStyle: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.primary,
                                  ),
                                  onPressed: () => _search(keyword),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (progress != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        narrow ? 18 : 28,
                        6,
                        narrow ? 18 : 28,
                        14,
                      ),
                      child: _ProgressPanel(
                        progress: progress,
                        keyword: _keyword,
                        searching: _searching,
                        selectedKey: _filterSourceKey,
                        hidden: hiddenCount,
                        onSelect: (key) => setState(() {
                          _filterSourceKey = key == _filterSourceKey
                              ? null
                              : key;
                        }),
                      ),
                    ),
                  ),
                if (app.config == null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.playlist_add_rounded,
                      title: '导入配置后开始搜索',
                      message: 'MisaTV 不内置内容源，请先导入你自己的订阅',
                      action: FilledButton.icon(
                        onPressed: () => showImportConfigSheet(context),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('导入订阅'),
                      ),
                    ),
                  )
                else if (progress == null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: pinnedSite == null
                          ? Icons.travel_explore_rounded
                          : Icons.push_pin_rounded,
                      title: pinnedSite == null
                          ? '一次搜索所有站点'
                          : '在 ${pinnedSite.displayName} 中搜索',
                      message: pinnedSite == null
                          ? '输入关键词，结果会随着各站点返回实时出现'
                          : '输入关键词，只搜索这个站点；输入 @ 可更换源',
                    ),
                  )
                else if (visibleItems.isEmpty && _searching)
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: narrow ? 18 : 28),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 188,
                            mainAxisExtent: 292,
                            crossAxisSpacing: 14,
                            mainAxisSpacing: 18,
                          ),
                      delegate: SliverChildBuilderDelegate(
                        (_, _) => _PosterSkeleton(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.45),
                        ),
                        childCount: 8,
                      ),
                    ),
                  )
                else if (visibleItems.isEmpty && !_searching)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: selectedSource?.status == 'error'
                          ? Icons.cloud_off_rounded
                          : Icons.search_off_rounded,
                      title: selectedSource?.status == 'error'
                          ? '这个源搜索失败'
                          : _filterSourceKey == null
                          ? '没有找到相关内容'
                          : '这个源没有返回结果',
                      message: selectedSource?.status == 'error'
                          ? (selectedSource!.error.isEmpty
                                ? '该源没有返回具体原因'
                                : selectedSource.error)
                          : _filterSourceKey == null
                          ? (hiddenCount > 0
                                ? '命中内容过滤的 $hiddenCount 条已隐藏，可在 设置 → 内容过滤 里调整'
                                : '试试更短的关键词，或检查站点是否可用')
                          : '可以点「全部」看其他源，搜索仍在继续',
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      narrow ? 18 : 28,
                      4,
                      narrow ? 18 : 28,
                      12,
                    ),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 188,
                            mainAxisExtent: 292,
                            crossAxisSpacing: 14,
                            mainAxisSpacing: 18,
                          ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final item = visibleItems[index];
                        return PosterCard(
                          item: item,
                          showSource: true,
                          onSecondaryLongPress: () =>
                              app.requestSearch(item.name),
                          onShowSources: item.sameFromOtherSources > 0
                              ? () => _showVariants(item)
                              : null,
                          onTap: () {
                            _hideSourceOverlay();
                            if (app.isDoubanSourceKey(item.sourceKey)) {
                              app.requestSearch(item.name);
                              return;
                            }
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => DetailPage(item: item),
                              ),
                            );
                          },
                        );
                      }, childCount: visibleItems.length),
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
}

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({
    required this.progress,
    required this.keyword,
    required this.searching,
    required this.selectedKey,
    required this.onSelect,
    this.hidden = 0,
  });
  final SearchProgress progress;
  final String keyword;
  final bool searching;
  final String? selectedKey;
  final ValueChanged<String?> onSelect;

  /// 被内容过滤隐藏的条数。
  final int hidden;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errors = progress.perSource.where((s) => s.status == 'error').length;
    final hits = progress.perSource.where((s) => s.status == 'ok').length;
    // 只展示真正有结果的源：空结果 / 失败源不占按钮位置，也不再用红字抢注意力。
    final hitSources = [
      for (final source in progress.perSource)
        if (source.status == 'ok' && source.count > 0) source,
    ];
    String? selectedName;
    if (selectedKey != null) {
      for (final source in progress.perSource) {
        if (source.key == selectedKey) {
          selectedName = source.name;
          break;
        }
      }
    }
    final visibleCount = selectedKey == null
        ? progress.items.length
        : (progress.sourceItems[selectedKey]?.length ?? 0);
    final filterLabel = selectedKey == null
        ? ''
        : '（只看 ${selectedName ?? selectedKey}）';
    return GlassPanel(
      padding: const EdgeInsets.all(14),
      borderRadius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (searching)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  searching
                      ? '正在搜索「$keyword」 · ${progress.done}/${progress.total}$filterLabel'
                      : '「$keyword」找到 $visibleCount 条结果$filterLabel'
                            '${progress.filterSummary.isEmpty ? '' : ' · ${progress.filterSummary}'}'
                            '${hidden > 0 ? ' · 已屏蔽 $hidden 条' : ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (hits > 0)
                Text(
                  '$hits 个源命中',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              if (errors > 0) ...[
                const SizedBox(width: 8),
                Text(
                  '$errors 个源无结果',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
              ],
            ],
          ),
          if (hitSources.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (hitSources.length > 1)
                  _SourceChip(
                    label: '全部 ${progress.items.length}',
                    selected: selectedKey == null,
                    onTap: () => onSelect(null),
                  ),
                for (final source in hitSources)
                  _SourceChip(
                    label: '${source.name} ${source.count}',
                    selected: selectedKey == source.key,
                    onTap: () => onSelect(source.key),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '只显示有结果的源；点标签只看该源，再点一次回到全部',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.16)
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.55,
                ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? accent.withValues(alpha: 0.55)
                : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Icons.check_rounded, size: 15, color: accent),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? accent
                    : theme.colorScheme.onSurface.withValues(alpha: 0.78),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchSuggestion {
  const _SearchSuggestion({
    required this.text,
    required this.kind,
    required this.icon,
  });

  final String text;
  final String kind;
  final IconData icon;
}

/// 搜索框下方的联想列表：本地历史 / 收藏 / 最近观看即时出，豆瓣标题随后补。
class _SuggestionPanel extends StatelessWidget {
  const _SuggestionPanel({required this.suggestions, required this.onSelect});

  final List<_SearchSuggestion> suggestions;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassPanel(
      padding: const EdgeInsets.symmetric(vertical: 4),
      borderRadius: 14,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final suggestion in suggestions)
            InkWell(
              onTap: () => onSelect(suggestion.text),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Icon(
                      suggestion.icon,
                      size: 16,
                      color: theme.colorScheme.primary.withValues(alpha: 0.75),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        suggestion.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      suggestion.kind,
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
        ],
      ),
    );
  }
}

/// 输入 `@` 时锚定在搜索框下方的小浮层：选一个源，或继续输入筛选源。
class _SourceAtPopup extends StatelessWidget {
  const _SourceAtPopup({
    required this.sites,
    required this.total,
    required this.filter,
    required this.selectedKey,
    required this.onSelect,
    required this.onClose,
  });

  final List<SourceBean> sites;
  final int total;
  final String filter;
  final String? selectedKey;
  final ValueChanged<SourceBean?> onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 16,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.alternate_email_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '选择搜索源',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          filter.isEmpty ? '继续输入可筛选站点' : '筛选：$filter',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '$total 个源',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.65,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (sites.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                child: Text(
                  '没有匹配的源，换个关键词试试',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  children: [
                    _SourceOption(
                      icon: Icons.apps_rounded,
                      title: '全部源',
                      subtitle: '搜索所有可用站点',
                      selected: selectedKey == null,
                      selectedLabel: '当前',
                      onTap: () => onSelect(null),
                    ),
                    for (final site in sites)
                      _SourceOption(
                        icon: Icons.dns_rounded,
                        title: site.displayName,
                        subtitle: '${site.kindLabel} · ${site.key}',
                        selected: selectedKey == site.key,
                        onTap: () => onSelect(site),
                      ),
                  ],
                ),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 9),
              child: Text(
                '选中后只搜索该源；@ 后的文字会实时筛选站点',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.selectedLabel = '已置顶',
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final String selectedLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface.withValues(alpha: 0.72),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.65,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Text(
                selectedLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.check_circle_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PosterSkeleton extends StatelessWidget {
  const _PosterSkeleton({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Container(height: 12, width: 100, color: color),
      ],
    );
  }
}

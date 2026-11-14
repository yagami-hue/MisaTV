part of '../settings_page.dart';

/// 站点可能有上百个：展开后限制高度，在卡片内滚动，避免整页被拉得很长。
class _SiteList extends StatefulWidget {
  const _SiteList({required this.sites, required this.app});
  final List<SourceBean> sites;
  final AppState app;

  @override
  State<_SiteList> createState() => _SiteListState();
}

class _SiteListState extends State<_SiteList> {
  final ScrollController _controller = ScrollController();

  /// 最近一次体检结果（仅本次会话，用来在行尾显示状态点）。
  final Map<String, SourceHealth> _health = {};
  final Set<String> _picked = {};
  bool _selecting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int get _failedCount => _health.values
      .where((h) => h.status == 'error')
      .where((h) => widget.sites.any((s) => s.key == h.key))
      .length;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final theme = Theme.of(context);
    _picked.removeWhere((key) => !widget.sites.any((s) => s.key == key));
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '按主页真实返回判定可用性（并发 4）',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
                Wrap(
                  spacing: 2,
                  children: [
                    TextButton.icon(
                      onPressed: () => _checkSites(context, widget.sites),
                      icon: const Icon(Icons.monitor_heart_outlined, size: 16),
                      label: const Text('一键体检'),
                    ),
                    if (_failedCount > 0)
                      TextButton.icon(
                        onPressed: () => _deleteFailed(context),
                        icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                        label: Text('删除失败源（$_failedCount）'),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _selecting = !_selecting;
                        if (!_selecting) _picked.clear();
                      }),
                      icon: Icon(
                        _selecting
                            ? Icons.done_rounded
                            : Icons.checklist_rounded,
                        size: 16,
                      ),
                      label: Text(_selecting ? '完成' : '多选'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Flexible(
            child: Scrollbar(
              controller: _controller,
              thumbVisibility: true,
              child: ListView.builder(
                controller: _controller,
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: widget.sites.length,
                itemBuilder: (context, index) {
                  final site = widget.sites[index];
                  final usable = app.isSiteUsable(site);
                  return _SiteRow(
                    site: site,
                    active: app.activeSite?.key == site.key,
                    usable: usable,
                    health: _health[site.key],
                    selecting: _selecting,
                    selected: _picked.contains(site.key),
                    onSelect: () => setState(() {
                      if (!_picked.add(site.key)) _picked.remove(site.key);
                    }),
                    onTap: _selecting
                        ? () => setState(() {
                            if (!_picked.add(site.key)) {
                              _picked.remove(site.key);
                            }
                          })
                        : usable
                        ? () async {
                            await app.setActiveSite(site.key);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('已切换到 ${site.displayName}'),
                              ),
                            );
                          }
                        : site.isJarSpider
                        ? () => ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'JAR / DEX 源需要 JVM 运行时（设置 → 播放 → JVM 运行时）',
                              ),
                            ),
                          )
                        : null,
                    onDiagnose: () => _checkSites(context, [site]),
                    onToggleSearch: () => _toggleSearch(context, site),
                    onEdit: () => _editSite(context, site),
                    onDelete: () => _deleteSite(context, site),
                  );
                },
              ),
            ),
          ),
          if (_selecting) ...[
            const Divider(height: 12),
            Row(
              children: [
                Text(
                  '已选 ${_picked.length} / ${widget.sites.length}',
                  style: theme.textTheme.labelSmall,
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    if (_picked.length == widget.sites.length) {
                      _picked.clear();
                    } else {
                      _picked.addAll(widget.sites.map((s) => s.key));
                    }
                  }),
                  child: Text(
                    _picked.length == widget.sites.length ? '取消全选' : '全选',
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _picked.isEmpty
                      ? null
                      : () => _movePicked(context),
                  icon: const Icon(Icons.drive_file_move_outlined, size: 17),
                  label: const Text('移动到订阅'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _picked.isEmpty
                      ? null
                      : () => _deletePicked(context),
                  icon: const Icon(Icons.delete_outline_rounded, size: 17),
                  label: Text('删除所选（${_picked.length}）'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _deletePicked(BuildContext context) async {
    if (_picked.isEmpty) return;
    final ok = await _confirmDelete(context, '删除选中的 ${_picked.length} 个站点？');
    if (ok != true) return;
    final removed = await widget.app.removeSites(_picked);
    if (!context.mounted) return;
    setState(() {
      _picked.clear();
      _selecting = false;
    });
    _settingsSnack(context, '已删除 $removed 个站点；订阅刷新后不会自动恢复');
  }

  Future<void> _movePicked(BuildContext context) async {
    if (_picked.isEmpty) return;
    final targets = [
      for (final profile in widget.app.profiles)
        if (profile.id != widget.app.activeProfileId && !profile.isLiveOnly)
          profile,
    ];
    if (targets.isEmpty) {
      _settingsSnack(context, '没有其他可移动的点播订阅，请先导入或创建订阅');
      return;
    }
    final targetId = await showMoveSitesTargetDialog(
      context,
      profiles: targets,
      count: _picked.length,
    );
    if (targetId == null || !context.mounted) return;
    ConfigProfile? target;
    for (final profile in targets) {
      if (profile.id == targetId) {
        target = profile;
        break;
      }
    }
    if (target == null) return;
    final moved = await widget.app.moveSitesToProfile(_picked, targetId);
    if (!context.mounted) return;
    setState(() {
      _picked.clear();
      _selecting = false;
    });
    _settingsSnack(
      context,
      moved > 0 ? '已移动 $moved 个站点到「${target.name}」' : '移动失败：目标订阅可能不是 JSON 配置',
    );
  }

  Future<void> _deleteFailed(BuildContext context) async {
    final failed = _health.values
        .where((h) => h.status == 'error')
        .map((h) => h.key)
        .where((key) => widget.sites.any((s) => s.key == key))
        .toSet();
    if (failed.isEmpty) return;
    final ok = await _confirmDelete(context, '删除 ${failed.length} 个体检失败的站点？');
    if (ok != true) return;
    final removed = await widget.app.removeSites(failed);
    if (!context.mounted) return;
    setState(() {
      for (final key in failed) {
        _health.remove(key);
        _picked.remove(key);
      }
    });
    _settingsSnack(context, '已删除 $removed 个失败源');
  }

  Future<bool?> _confirmDelete(BuildContext context, String message) =>
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认删除站点'),
          content: Text('$message\n\n只从当前配置里移除，并记录为「已删除」；订阅刷新时不会自动恢复。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      );

  Future<void> _checkSites(BuildContext context, List<SourceBean> sites) async {
    final results = await showDialog<Map<String, SourceHealth>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HealthCheckDialog(sites: sites),
    );
    if (results != null && mounted) {
      setState(() => _health.addAll(results));
    }
  }

  /// 站点行上的「参与搜索」开关：只改这一个字段，改动即时生效。
  Future<void> _toggleSearch(BuildContext context, SourceBean site) async {
    final next = site.searchable != 1;
    final ok = await widget.app.setSiteSearchable(site.key, next);
    if (!context.mounted) return;
    if (!ok) {
      _settingsSnack(context, '这份配置不是 JSON 订阅，改不了站点');
      return;
    }
    _settingsSnack(
      context,
      next ? '「${site.displayName}」已参与搜索' : '「${site.displayName}」已退出搜索',
    );
  }

  Future<void> _editSite(BuildContext context, SourceBean site) async {
    final edited = await showDialog<SourceBean>(
      context: context,
      builder: (_) => _SiteEditDialog(site: site),
    );
    if (edited == null) return;
    final ok = await widget.app.updateSite(site.key, edited);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? '已保存 ${edited.displayName}' : '这份配置不是 JSON 订阅，改不了站点',
        ),
      ),
    );
  }

  Future<void> _deleteSite(BuildContext context, SourceBean site) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除站点「${site.displayName}」？'),
        content: const Text('只从当前配置里移除这个站点，不影响其他内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await widget.app.removeSite(site.key);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已删除 ${site.displayName}' : '这份配置不是 JSON 订阅，改不了站点'),
      ),
    );
  }
}

/// 编辑单个站点：名称 / 地址 / 类型等字段，`key` 保持只读。
///
/// 「参与搜索」不在这里改：站点列表行上直接开关，避免为了改一个布尔值
/// 打开整张表再保存。
class _SiteEditDialog extends StatefulWidget {
  const _SiteEditDialog({required this.site});
  final SourceBean site;

  @override
  State<_SiteEditDialog> createState() => _SiteEditDialogState();
}

class _SiteEditDialogState extends State<_SiteEditDialog> {
  static const _siteExtTemplate = '{\n  "siteUrl": "https://example.com"\n}';
  static const _hikerExtTemplate =
      '{\n'
      '  "url": "https://example.com",\n'
      '  "list": ".video-list li",\n'
      '  "name": ".title",\n'
      '  "pic": "img@src",\n'
      '  "urlKey": "a@href"\n'
      '}';

  late final TextEditingController _name = TextEditingController(
    text: widget.site.name,
  );
  late final TextEditingController _api = TextEditingController(
    text: widget.site.api,
  );
  late final TextEditingController _type = TextEditingController(
    text: '${widget.site.type}',
  );
  late final TextEditingController _jar = TextEditingController(
    text: widget.site.jar,
  );
  late final TextEditingController _timeout = TextEditingController(
    text: '${widget.site.timeout}',
  );
  late final TextEditingController _ext = TextEditingController(
    text: widget.site.ext,
  );
  late final TextEditingController _playUrl = TextEditingController(
    text: widget.site.playUrl,
  );
  late final TextEditingController _click = TextEditingController(
    text: widget.site.click,
  );
  late final TextEditingController _style = TextEditingController(
    text: widget.site.style,
  );
  String? _error;
  String? _extError;
  String _extHint = '';

  @override
  void initState() {
    super.initState();
    _validateExt();
  }

  @override
  void dispose() {
    _name.dispose();
    _api.dispose();
    _type.dispose();
    _jar.dispose();
    _timeout.dispose();
    _ext.dispose();
    _playUrl.dispose();
    _click.dispose();
    _style.dispose();
    super.dispose();
  }

  /// ext 以 JSON 形态使用时做实时校验；蜘蛛也可能收原始字符串（如加密 blob），
  /// 所以只有看起来像 JSON 的内容才强制合法。
  void _validateExt() {
    final text = _ext.text.trim();
    if (text.isEmpty) {
      _extError = null;
      _extHint = '';
      return;
    }
    if (!text.startsWith('{') && !text.startsWith('[')) {
      _extError = null;
      _extHint = '非 JSON 内容会原样传给蜘蛛';
      return;
    }
    try {
      jsonDecode(text);
      _extError = null;
      _extHint = 'JSON 合法';
    } catch (e) {
      _extError = 'ext 不是合法 JSON：$e';
      _extHint = '';
    }
  }

  void _applyExtTemplate(String value) {
    _ext.text = value == 'hiker' ? _hikerExtTemplate : _siteExtTemplate;
    _validateExt();
    setState(() {});
  }

  void _save() {
    final api = _api.text.trim();
    if (api.isEmpty) {
      setState(() => _error = '地址不能为空');
      return;
    }
    _validateExt();
    if (_extError != null) {
      setState(() {});
      return;
    }
    final source = widget.site;
    Navigator.of(context).pop(
      SourceBean(
        key: source.key,
        name: _name.text.trim(),
        type: int.tryParse(_type.text.trim()) ?? source.type,
        api: api,
        searchable: source.searchable,
        quickSearch: source.quickSearch,
        changeable: source.changeable,
        filterable: source.filterable,
        playUrl: _playUrl.text.trim(),
        ext: _ext.text.trim(),
        jar: _jar.text.trim(),
        playerType: source.playerType,
        categories: source.categories,
        timeout: (int.tryParse(_timeout.text.trim()) ?? source.timeout).clamp(
          5,
          60,
        ),
        click: _click.text.trim(),
        style: _style.text.trim(),
        homePage: source.homePage,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('编辑站点'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'key：${widget.site.key}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '名称'),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _api,
                decoration: const InputDecoration(
                  labelText: '地址',
                  hintText: 'CMS 接口地址，或 csp_ 蜘蛛类名',
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _type,
                      decoration: const InputDecoration(
                        labelText: '类型',
                        hintText: '0 XML / 1 JSON / 3 蜘蛛 / -1 推送',
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 92,
                    child: TextField(
                      controller: _timeout,
                      decoration: const InputDecoration(labelText: '超时(秒)'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '参与搜索：在站点列表点搜索图标切换，改完立即生效',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _jar,
                decoration: const InputDecoration(
                  labelText: 'JAR 地址（可选）',
                  hintText: '留空则用订阅顶层的 spider',
                ),
                minLines: 1,
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _playUrl,
                decoration: const InputDecoration(
                  labelText: 'playUrl（可选）',
                  hintText: '站内解析地址，含 {playUrl} 时会替换剧集地址；一般留空',
                ),
                minLines: 1,
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _click,
                      decoration: const InputDecoration(
                        labelText: 'click（可选）',
                        hintText: 'host;selector',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _style,
                      decoration: const InputDecoration(
                        labelText: 'style（可选）',
                        hintText: '源展示风格',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text('ext（蜘蛛参数）', style: theme.textTheme.bodySmall),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '插入 ext 模板',
                    onSelected: _applyExtTemplate,
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'site',
                        child: Text('通用站点 {siteUrl}'),
                      ),
                      PopupMenuItem(
                        value: 'hiker',
                        child: Text('海阔规则 {list/name/pic}'),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.article_outlined, size: 16),
                          const SizedBox(width: 4),
                          Text('插入模板', style: theme.textTheme.labelSmall),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              TextField(
                controller: _ext,
                decoration: const InputDecoration(
                  hintText: '多数 csp_ / JS 蜘蛛需要 {"siteUrl": "https://资源站根地址"}',
                ),
                minLines: 3,
                maxLines: 8,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                onChanged: (_) => setState(_validateExt),
              ),
              if (_extError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _extError!,
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                )
              else if (_extHint.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _extHint,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.45,
                      ),
                    ),
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

/// 站点区块折叠时显示的一行摘要：当前使用的站点。
class _SiteSummary extends StatelessWidget {
  const _SiteSummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    final site = app.activeSite;
    if (site == null) {
      return Text('点击展开选择站点', style: hint);
    }
    return Row(
      children: [
        Text('当前', style: hint),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            site.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _KindBadge(text: site.kindLabel, ok: app.isSiteUsable(site)),
        const SizedBox(width: 8),
        Text('点击展开切换', style: hint),
      ],
    );
  }
}

/// 直播源区块折叠时的摘要：当前使用的线路。
class _LiveSummary extends StatelessWidget {
  const _LiveSummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    final live = app.activeLive;
    if (live == null) return Text('点击展开管理直播源', style: hint);
    return Row(
      children: [
        Text('当前', style: hint),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            live.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '${app.activeLiveProfile?.name ?? '本地线路'} · ${app.lives.length} 条',
          style: hint,
        ),
        const SizedBox(width: 8),
        Text('点击展开切换', style: hint),
      ],
    );
  }
}

/// 播放区块折叠时的摘要：两个开关的状态。
class _PlaySummary extends StatelessWidget {
  const _PlaySummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    final settings = app.playerSettings;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        Text('自动连播${settings.autoPlayNext ? '开启' : '关闭'}', style: hint),
        Text('自动换线${settings.autoSwitchLine ? '开启' : '关闭'}', style: hint),
        Text('进度记忆${settings.rememberProgress ? '开启' : '关闭'}', style: hint),
        Text('无痕${settings.incognito ? '开启' : '关闭'}', style: hint),
        Text('去广告${settings.m3u8Purify ? '开启' : '关闭'}', style: hint),
        Text('点击展开', style: hint),
      ],
    );
  }
}

/// 内容过滤区块折叠时的摘要：开关状态与屏蔽词数量。
class _ContentFilterSummary extends StatelessWidget {
  const _ContentFilterSummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    final filter = app.contentFilter;
    final lock = filter.hasPassword ? ' · 已设置关闭密码' : '';
    return Row(
      children: [
        Text(
          '${filter.enabled ? 'R18 过滤已开启' : 'R18 过滤已关闭'}$lock',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '${filter.keywords.length} 个屏蔽词 · 点击展开管理',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: hint,
          ),
        ),
      ],
    );
  }
}

/// 主题模式的中文名，设置页的标题栏与折叠摘要共用。
String _themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.light => '浅色',
  ThemeMode.dark => '深色',
  ThemeMode.system => '跟随系统',
};

/// 订阅配置区块折叠时的摘要：当前档案与数量。
class _ProfileSummary extends StatelessWidget {
  const _ProfileSummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    final profile = app.activeProfile;
    if (profile == null) return Text('还没有配置，点击展开导入订阅', style: hint);
    return Row(
      children: [
        Text('当前', style: hint),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            profile.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('${app.vodProfiles.length} 个点播', style: hint),
        const SizedBox(width: 8),
        Text('点击展开管理', style: hint),
      ],
    );
  }
}

/// 外观区块折叠时的摘要：主题模式与主题色。
class _AppearanceSummary extends StatelessWidget {
  const _AppearanceSummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    return Row(
      children: [
        Text('主题色', style: hint),
        const SizedBox(width: 6),
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: app.accentColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '第 ${app.accentIndex + 1} / ${AppState.accentPalette.length} 种',
          style: hint,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            // 首页列数 / 浏览方式已挪到「界面与首页」，这里只描述外观本身。
            '横条${switch (app.navBarSize) {
              0 => '紧凑',
              2 => '较大',
              3 => '超大',
              _ => '标准',
            }}${app.navBarAutoHide ? ' · 自动隐藏' : ' · 常驻'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: hint,
          ),
        ),
        const SizedBox(width: 8),
        Text('点击展开', style: hint),
      ],
    );
  }
}

/// 数据区块折叠时的摘要：历史、收藏与搜索历史的条数。
class _DataSummary extends StatelessWidget {
  const _DataSummary({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
    );
    return Row(
      children: [
        Flexible(
          child: Text(
            '历史 ${app.history.length} · 收藏 ${app.favorites.length} · 搜索 ${app.searchHistory.length}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: hint,
          ),
        ),
        const SizedBox(width: 8),
        Text('点击展开清理', style: hint),
      ],
    );
  }
}

/// 直播源列表：与站点一样限高滚动，点一行即切换当前线路。
class _LiveSourceList extends StatefulWidget {
  const _LiveSourceList({required this.lives, required this.app});
  final List<LiveBean> lives;
  final AppState app;

  @override
  State<_LiveSourceList> createState() => _LiveSourceListState();
}

class _LiveSourceListState extends State<_LiveSourceList> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _controller,
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: widget.lives.length,
          itemBuilder: (context, index) {
            final live = widget.lives[index];
            return _LiveSourceRow(
              live: live,
              active: app.activeLiveIndex == index,
              unusableReason: live.supported ? null : '不支持的直播类型：${live.type}',
              onTap: live.supported
                  ? () async {
                      await app.setActiveLive(live);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已切换到 ${live.displayName}')),
                      );
                    }
                  : null,
              onEdit: () => _editLive(context, index, live),
              onDelete: () => _deleteLive(context, index, live),
            );
          },
        ),
      ),
    );
  }

  Future<void> _editLive(BuildContext context, int index, LiveBean live) async {
    final edited = await showDialog<LiveBean>(
      context: context,
      builder: (_) => _LiveEditDialog(live: live),
    );
    if (edited == null) return;
    final ok = await widget.app.updateLiveSource(index, edited);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? '已保存 ${edited.displayName}' : '这份配置不是 JSON 订阅，改不了直播源',
        ),
      ),
    );
  }

  Future<void> _deleteLive(
    BuildContext context,
    int index,
    LiveBean live,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除直播源「${live.displayName}」？'),
        content: const Text('只从当前配置里移除这一条线路，不影响其他内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await widget.app.removeLiveSource(index);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已删除 ${live.displayName}' : '这份配置不是 JSON 订阅，改不了直播源'),
      ),
    );
  }
}

/// 编辑单条直播源的弹窗：名称、地址、类型与 EPG。
class _LiveEditDialog extends StatefulWidget {
  const _LiveEditDialog({required this.live});
  final LiveBean live;

  @override
  State<_LiveEditDialog> createState() => _LiveEditDialogState();
}

class _LiveEditDialogState extends State<_LiveEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.live.name,
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.live.url,
  );
  late final TextEditingController _type = TextEditingController(
    text: widget.live.type,
  );
  late final TextEditingController _epg = TextEditingController(
    text: widget.live.epg,
  );
  late final TextEditingController _timeZone = TextEditingController(
    text: widget.live.timeZone,
  );

  /// 自定义 UA：留空表示沿用订阅自带 / 自动探测（见 LiveService）。
  late final TextEditingController _ua = TextEditingController(
    text: widget.live.ua,
  );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _type.dispose();
    _epg.dispose();
    _timeZone.dispose();
    _ua.dispose();
    super.dispose();
  }

  void _save() {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '地址不能为空');
      return;
    }
    final type = _type.text.trim();
    final live = widget.live;
    Navigator.of(context).pop(
      LiveBean(
        name: _name.text.trim(),
        api: live.api,
        type: type.isEmpty ? '0' : type,
        url: url,
        jar: live.jar,
        ext: live.ext,
        epg: _epg.text.trim(),
        playerType: live.playerType,
        timeZone: _timeZone.text.trim(),
        timeout: live.timeout,
        header: live.header,
        // 用户填了就覆盖订阅自带值；留空则沿用原值。
        ua: _ua.text.trim().isEmpty ? live.ua : _ua.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑直播源'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: '地址',
                hintText: 'TXT / M3U 订阅地址，或直播接口地址',
              ),
              minLines: 1,
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _type,
                    decoration: const InputDecoration(
                      labelText: '类型',
                      hintText: '0 = TXT / M3U；3 = 蜘蛛',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _epg,
                    decoration: const InputDecoration(
                      labelText: 'EPG（可选）',
                      hintText: '节目单地址',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _timeZone,
              decoration: const InputDecoration(
                labelText: 'EPG 时区（可选）',
                hintText: 'Asia/Shanghai；留空 = 本机时区',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ua,
              decoration: InputDecoration(
                labelText: '自定义 UA（可选）',
                hintText: '留空 = 自动（已知服务用其指定 UA，其余用 okhttp/3.12.0）',
                helperText: kLiveUaHelper,
                helperMaxLines: 3,
                suffixIcon: _ua.text.trim().isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () => setState(_ua.clear),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

class _LiveSourceRow extends StatelessWidget {
  const _LiveSourceRow({
    required this.live,
    required this.active,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    this.unusableReason,
  });

  final LiveBean live;
  final bool active;
  final String? unusableReason;
  final VoidCallback? onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usable = unusableReason == null;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(
                  alpha: usable ? 0.12 : 0.05,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.live_tv_rounded,
                size: 17,
                color: usable ? theme.colorScheme.primary : theme.disabledColor,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          live.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _KindBadge(
                        text: live.type == '3'
                            ? '蜘蛛'
                            : (live.type == '0' ? 'TXT' : 'TYPE ${live.type}'),
                        ok: usable,
                      ),
                    ],
                  ),
                  Text(
                    unusableReason ?? live.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: usable
                          ? theme.colorScheme.onSurface.withValues(alpha: 0.60)
                          : theme.colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
            if (active)
              Icon(
                Icons.check_circle_rounded,
                color: theme.colorScheme.primary,
                size: 20,
              )
            else if (usable)
              const Icon(Icons.chevron_right_rounded, size: 20)
            else
              Icon(Icons.block_rounded, color: theme.disabledColor, size: 18),
            const SizedBox(width: 4),
            _RowIconButton(
              icon: Icons.edit_outlined,
              tooltip: '编辑',
              onPressed: onEdit,
            ),
            _RowIconButton(
              icon: Icons.delete_outline_rounded,
              tooltip: '删除',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表行尾的紧凑图标按钮（编辑 / 删除）。
class _RowIconButton extends StatelessWidget {
  const _RowIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      color: color ?? theme.colorScheme.onSurface.withValues(alpha: 0.70),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.app,
    this.asLive = false,
  });

  final ConfigProfile profile;
  final AppState app;

  /// true = 直播订阅列表：只切换 lives，不改变点播档案。
  final bool asLive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = asLive
        ? app.activeLiveProfileId == profile.id
        : app.activeProfileId == profile.id;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: asLive
          ? () => app.setActiveLiveProfile(profile.id)
          : () => app.activateProfile(profile.id),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.primary.withValues(alpha: 0.1)
              : null,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active
                ? theme.colorScheme.primary.withValues(alpha: 0.4)
                : theme.dividerColor,
          ),
        ),
        child: Row(
          children: [
            Icon(
              active
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: active ? theme.colorScheme.primary : theme.disabledColor,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(profile.name, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    asLive
                        ? '${profile.liveCount} 个直播源 · 只切换直播，不影响点播'
                        : '${profile.siteCount} 站点 · ${profile.liveCount} 直播 · '
                              '${profile.report.ok} 可用${profile.report.degraded > 0 ? ' / ${profile.report.degraded} 降级' : ''}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.70,
                      ),
                    ),
                  ),
                  if (profile.url.isNotEmpty)
                    Text(
                      profile.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.35,
                        ),
                      ),
                    ),
                  if (profile.lastRefreshAt != null)
                    Text(
                      '上次刷新 ${_dateLabel(profile.lastRefreshAt!)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.35,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (profile.url.startsWith('http'))
              _RowIconButton(
                icon: Icons.refresh_rounded,
                tooltip: '刷新订阅',
                onPressed: () => _refresh(context),
              ),
            _RowIconButton(
              icon: Icons.edit_outlined,
              tooltip: '重命名',
              onPressed: () => _rename(context),
            ),
            IconButton(
              tooltip: '删除配置',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text('删除「${profile.name}」？'),
                    content: Text(
                      asLive
                          ? '只删除本机保存的直播订阅，不影响源站，也不影响点播订阅。'
                          : '只删除本机保存的订阅，不影响源站。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (ok == true) await app.removeProfile(profile.id);
              },
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: profile.name),
    );
    if (name == null) return;
    await app.renameProfile(profile.id, name);
  }

  Future<void> _refresh(BuildContext context) async {
    try {
      final outcome = await app.refreshProfile(
        profile.id,
        activate: asLive
            ? app.activeLiveProfileId == profile.id
            : app.activeProfileId == profile.id,
      );
      if (!context.mounted) return;
      _settingsSnack(
        context,
        asLive
            ? '已刷新「${outcome.profile.name}」：${outcome.profile.liveCount} 路直播'
            : '已刷新「${outcome.profile.name}」：${outcome.profile.siteCount} 个站点',
      );
    } catch (e) {
      if (context.mounted) _settingsSnack(context, '刷新失败：$e');
    }
  }
}

String _dateLabel(DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  final sameDay =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  if (sameDay) {
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
  return '${local.month}-${local.day} ${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// 重命名订阅档案。控制器由 State 持有，避免弹窗退场动画还在读它时被提前 dispose。
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名订阅配置'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '名称'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _SiteRow extends StatelessWidget {
  const _SiteRow({
    required this.site,
    required this.active,
    required this.usable,
    required this.onEdit,
    required this.onDelete,
    required this.onDiagnose,
    required this.onToggleSearch,
    this.onTap,
    this.health,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
  });
  final SourceBean site;
  final bool active;
  final bool usable;
  final SourceHealth? health;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onDiagnose;
  final VoidCallback onToggleSearch;
  final VoidCallback? onTap;
  final bool selecting;
  final bool selected;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            if (selecting) ...[
              Checkbox(value: selected, onChanged: (_) => onSelect?.call()),
              const SizedBox(width: 2),
            ],
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(
                  alpha: usable ? 0.12 : 0.05,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                site.displayName.characters.first,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: usable
                      ? theme.colorScheme.primary
                      : theme.disabledColor,
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
                      Flexible(
                        child: Text(
                          site.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _KindBadge(text: site.kindLabel, ok: usable),
                    ],
                  ),
                  if (!usable)
                    Text(
                      site.unsupportedReason,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    )
                  else
                    Text(
                      site.searchable == 1 ? site.key : '不参与搜索 · ${site.key}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: site.searchable == 1 ? 0.4 : 0.62,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (!selecting) ...[
              if (health != null) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: '${health!.statusLabel} · ${health!.message}',
                  child: _HealthDot(status: health!.status),
                ),
              ],
              if (active)
                Icon(
                  Icons.check_circle_rounded,
                  color: theme.colorScheme.primary,
                  size: 20,
                )
              else if (usable)
                const Icon(Icons.chevron_right_rounded, size: 20)
              else
                Icon(Icons.block_rounded, color: theme.disabledColor, size: 18),
              const SizedBox(width: 4),
              _RowIconButton(
                icon: site.searchable == 1
                    ? Icons.search_rounded
                    : Icons.search_off_rounded,
                tooltip: site.searchable == 1
                    ? '参与搜索：已开启（点击关闭）'
                    : '参与搜索：已关闭（点击开启）',
                color: site.searchable == 1
                    ? theme.colorScheme.primary
                    : theme.disabledColor,
                onPressed: onToggleSearch,
              ),
              _RowIconButton(
                icon: Icons.monitor_heart_outlined,
                tooltip: '诊断',
                onPressed: onDiagnose,
              ),
              _RowIconButton(
                icon: Icons.edit_outlined,
                tooltip: '编辑',
                onPressed: onEdit,
              ),
              _RowIconButton(
                icon: Icons.delete_outline_rounded,
                tooltip: '删除',
                onPressed: onDelete,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 站点行尾的体检状态点：绿=有内容/分类，黄=需补 ext，红=失败。
class _HealthDot extends StatelessWidget {
  const _HealthDot({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (status) {
      'ok-content' || 'ok-classes' => const Color(0xFF4CAF50),
      'needs-ext' => const Color(0xFFFFB300),
      'empty' => theme.colorScheme.onSurface.withValues(alpha: 0.55),
      _ => theme.colorScheme.error,
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// 逐个源真实调用主页的体检弹窗；并发 4，边出结果边显示。
class _HealthCheckDialog extends StatefulWidget {
  const _HealthCheckDialog({required this.sites});
  final List<SourceBean> sites;

  @override
  State<_HealthCheckDialog> createState() => _HealthCheckDialogState();
}

class _HealthCheckDialogState extends State<_HealthCheckDialog> {
  final Map<String, SourceHealth> _results = {};
  int _done = 0;
  bool _running = true;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (!mounted) return;
    final app = AppScope.of(context);
    var next = 0;
    Future<void> worker() async {
      while (!_closed && mounted) {
        final index = next++;
        if (index >= widget.sites.length) return;
        final site = widget.sites[index];
        final health = await app.probeSite(site);
        if (!mounted) return;
        setState(() {
          _results[site.key] = health;
          _done++;
        });
      }
    }

    final workers = <Future<void>>[];
    for (var i = 0; i < 4 && i < widget.sites.length; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);
    if (!mounted) return;
    setState(() => _running = false);
  }

  void _close() {
    _closed = true;
    Navigator.of(context).pop(_results);
  }

  String get _title {
    if (_running) return '源体检 $_done/${widget.sites.length}';
    final ok = _results.values.where((e) => e.ok).length;
    final need = _results.values.where((e) => e.needsExt).length;
    final bad = _results.length - ok - need;
    return '体检完成：$ok 可用 · $need 需补 ext · $bad 不可用';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(_title),
      content: SizedBox(
        width: 560,
        height: 400,
        child: ListView.builder(
          itemCount: widget.sites.length,
          itemBuilder: (context, index) {
            final site = widget.sites[index];
            final health = _results[site.key];
            final (icon, color) = switch (health?.status) {
              'ok-content' || 'ok-classes' => (
                Icons.check_circle_rounded,
                const Color(0xFF4CAF50),
              ),
              'needs-ext' => (Icons.info_rounded, const Color(0xFFFFB300)),
              'empty' => (
                Icons.remove_circle_outline,
                theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
              'error' => (Icons.error_rounded, theme.colorScheme.error),
              _ => (Icons.more_horiz_rounded, theme.colorScheme.outline),
            };
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  health == null
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(icon, size: 18, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          site.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (health != null)
                          Text(
                            health.elapsedMs > 0
                                ? '${health.message} · ${health.elapsedMs}ms'
                                : health.message,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: health.ok
                                  ? theme.colorScheme.onSurface.withValues(
                                      alpha: 0.55,
                                    )
                                  : theme.colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (health != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        health.statusLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: color,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        FilledButton(onPressed: _close, child: Text(_running ? '停止并关闭' : '关闭')),
      ],
    );
  }
}

class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.text, required this.ok});
  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: ok
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : theme.colorScheme.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: ok ? theme.colorScheme.primary : theme.colorScheme.error,
        ),
      ),
    );
  }
}


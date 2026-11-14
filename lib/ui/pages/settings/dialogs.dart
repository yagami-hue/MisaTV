part of '../settings_page.dart';

class _KazumiRuleRow extends StatelessWidget {
  const _KazumiRuleRow({required this.rule, required this.onDelete});

  final KazumiRule rule;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final search = rule.searchMode == 'api' ? 'API 搜索' : 'XPath 搜索';
    final chapter = rule.chapterMode == 'api' ? 'API 选集' : 'XPath 选集';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.auto_awesome_rounded, size: 18),
      title: Text(rule.name),
      subtitle: Text(
        'v${rule.version.isEmpty ? '?' : rule.version} · $search / $chapter',
      ),
      trailing: IconButton(
        tooltip: '删除规则',
        icon: const Icon(Icons.delete_outline_rounded, size: 19),
        onPressed: onDelete,
      ),
    );
  }
}

class _KazumiRulePickerDialog extends StatefulWidget {
  const _KazumiRulePickerDialog({required this.rules, required this.installed});

  final List<Map<String, dynamic>> rules;
  final Set<String> installed;

  @override
  State<_KazumiRulePickerDialog> createState() =>
      _KazumiRulePickerDialogState();
}

class _KazumiRulePickerDialogState extends State<_KazumiRulePickerDialog> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = [
      for (final item in widget.rules)
        if (item['name']?.toString().trim().isNotEmpty == true) item,
    ]..sort((a, b) => a['name'].toString().compareTo(b['name'].toString()));
    return AlertDialog(
      title: const Text('导入 Kazumi 规则'),
      content: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选择要导入的动漫源规则（共 ${items.length} 条，已安装的会覆盖更新）：',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final item in items)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _selected.contains(item['name'].toString()),
                        title: Text(item['name'].toString()),
                        subtitle: Text(
                          'v${item['version'] ?? '?'}'
                          '${widget.installed.contains(item['name']) ? ' · 已安装' : ''}',
                        ),
                        onChanged: (checked) {
                          setState(() {
                            final name = item['name'].toString();
                            if (checked == true) {
                              _selected.add(name);
                            } else {
                              _selected.remove(name);
                            }
                          });
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            setState(() {
              if (_selected.length == items.length) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(items.map((item) => item['name'].toString()));
              }
            });
          },
          child: Text(_selected.length == items.length ? '全不选' : '全选'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop({..._selected}),
          child: Text('导入${_selected.isEmpty ? '' : '（${_selected.length}）'}'),
        ),
      ],
    );
  }
}

/// TMDB 凭据在设置行上的说明：只说当前用的是哪一种，不显示任何密钥内容。
String _tmdbCredentialLabel(String apiKey, String readToken) {
  final credential = TmdbCredential.resolve(
    apiKey: apiKey,
    readToken: readToken,
  );
  if (credential.isConfigured) return ' · TMDB ${credential.label}';
  final filled = apiKey.trim().isNotEmpty || readToken.trim().isNotEmpty;
  return filled ? ' · TMDB 凭据无法识别' : ' · TMDB 未配置';
}

String _artworkSourceLabel(String raw) =>
    switch (normalizeArtworkPriority(raw)) {
      'tmdb' => 'TMDB',
      'imdb' => 'IMDb',
      _ => '豆瓣',
    };

Future<void> _openArtworkSettings(BuildContext context, AppState app) async {
  final result = await showDialog<_ArtworkConfig>(
    context: context,
    builder: (_) => _ArtworkSettingsDialog(
      initialPriority: normalizeArtworkPriority(
        app.playerSettings.artworkPriority,
      ),
      initialKey: app.playerSettings.tmdbApiKey,
      initialToken: app.playerSettings.tmdbReadToken,
    ),
  );
  if (result == null) return;
  await app.setPlayerSettings(
    app.playerSettings.copyWith(
      artworkPriority: result.priority,
      tmdbApiKey: result.key,
      tmdbReadToken: result.token,
    ),
  );
  if (context.mounted) {
    _settingsSnack(context, '封面来源已保存：${_artworkSourceLabel(result.priority)}');
  }
}

class _ArtworkConfig {
  const _ArtworkConfig(this.priority, this.key, this.token);
  final String priority;

  /// v3 API Key（走 query）与 v4 Read Access Token（走 Authorization 头）。
  final String key;
  final String token;
}

Future<void> _openBossKeySettings(BuildContext context, AppState app) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) =>
        _BossKeyDialog(initial: normalizeBossKey(app.playerSettings.bossKey)),
  );
  if (result == null) return;
  await app.setPlayerSettings(app.playerSettings.copyWith(bossKey: result));
  final ok = await BossKeyService.instance.applyBossKey(result);
  if (!context.mounted) return;
  // 未设置是正常状态，不是失败。
  if (!isBossKeySet(result)) {
    _settingsSnack(context, '老板键已关闭（不再占用任何全局热键）');
    return;
  }
  if (!ok) {
    // 冲突时必须说清楚：用户选了却没生效，比没设置更让人困惑。
    final detail = BossKeyService.instance.lastHotKeyError;
    _settingsSnack(
      context,
      detail.isEmpty
          ? '${bossKeyLabel(result)} 不可用（可能被其它软件占用），请换一个组合'
          : '${bossKeyLabel(result)} 不可用：$detail',
    );
    return;
  }
  _settingsSnack(context, '老板键已设为 ${bossKeyLabel(result)}');
}

class _BossKeyDialog extends StatefulWidget {
  const _BossKeyDialog({required this.initial});
  final String initial;

  @override
  State<_BossKeyDialog> createState() => _BossKeyDialogState();
}

class _BossKeyDialogState extends State<_BossKeyDialog> {
  late String _value = widget.initial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
      height: 1.5,
    );
    return AlertDialog(
      title: const Text('老板键'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '按下后自动暂停视频并把软件收进系统托盘；再按一次老板键或点托盘图标，'
                '回到之前的播放状态与窗口形态（全屏回全屏、小窗回小窗）。',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
              ),
              const SizedBox(height: 8),
              Text(
                '默认不占用任何全局热键。选择一个组合后才会生效；'
                '若提示不可用，说明该组合已被其它软件占用，换一个即可。',
                style: hint,
              ),
              const SizedBox(height: 8),
              Text('沉浸观影模式下老板键不生效。', style: hint),
              const SizedBox(height: 14),
              for (final item in kBossKeyShortcuts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(item.$2),
                  trailing: _value == item.$1
                      ? const Icon(Icons.check_circle_rounded, size: 20)
                      : null,
                  onTap: () => setState(() => _value = item.$1),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_value),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _ArtworkSettingsDialog extends StatefulWidget {
  const _ArtworkSettingsDialog({
    required this.initialPriority,
    required this.initialKey,
    this.initialToken = '',
  });

  final String initialPriority;
  final String initialKey;
  final String initialToken;

  @override
  State<_ArtworkSettingsDialog> createState() => _ArtworkSettingsDialogState();
}

class _ArtworkSettingsDialogState extends State<_ArtworkSettingsDialog> {
  late String _priority = widget.initialPriority;

  /// 旧版本只有一个输入框；把粘在里面的令牌摆回令牌框，用户一眼看得懂。
  late final TmdbCredential _initial = TmdbCredential.resolve(
    apiKey: widget.initialKey,
    readToken: widget.initialToken,
  );
  late final TextEditingController _key = TextEditingController(
    text: _initial.kind == TmdbCredentialKind.apiKey ? _initial.value : '',
  );
  late final TextEditingController _token = TextEditingController(
    text: _initial.kind == TmdbCredentialKind.readToken ? _initial.value : '',
  );
  bool _probing = false;
  List<ArtworkProbeResult> _results = const [];
  String _probeError = '';

  TmdbCredential get _keyCredential => TmdbCredential.parse(_key.text);
  TmdbCredential get _tokenCredential => TmdbCredential.parse(_token.text);

  /// 实际生效的那一份：两份都填时优先读访问令牌（走请求头，不把密钥放进 URL）。
  TmdbCredential get _credential =>
      TmdbCredential.resolve(apiKey: _key.text, readToken: _token.text);

  /// 填了就必须是对应格式：密钥框里放令牌、令牌框里放密钥都要挡住。
  bool get _canSave =>
      (_key.text.trim().isEmpty ||
          _keyCredential.kind == TmdbCredentialKind.apiKey) &&
      (_token.text.trim().isEmpty ||
          _tokenCredential.kind == TmdbCredentialKind.readToken);

  @override
  void initState() {
    super.initState();
    _key.addListener(_onChanged);
    _token.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _key.removeListener(_onChanged);
    _token.removeListener(_onChanged);
    _key.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    final app = AppScope.of(context);
    setState(() {
      _probing = true;
      _probeError = '';
      _results = const [];
    });
    try {
      // 测试前先保存凭据，否则服务读到的还是旧配置。
      await app.setPlayerSettings(
        app.playerSettings.copyWith(
          tmdbApiKey: _keyCredential.kind == TmdbCredentialKind.apiKey
              ? _keyCredential.value
              : '',
          tmdbReadToken: _tokenCredential.kind == TmdbCredentialKind.readToken
              ? _tokenCredential.value
              : '',
        ),
      );
      final results = await app.artworkService.probe('流浪地球', year: '2019');
      if (mounted) setState(() => _results = results);
    } catch (e) {
      if (mounted) setState(() => _probeError = '$e');
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('横图封面来源'),
      content: SizedBox(
        width: 660,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '沉浸观影的海报轮播、详情页背景与卡片都优先使用横图。'
                '找不到横图时会自动尝试下一个来源，最后回落到源里的竖版海报。',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
              ),
              const SizedBox(height: 16),
              Text('优先来源', style: theme.textTheme.labelMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in const [
                    ('douban', '豆瓣'),
                    ('tmdb', 'TMDB'),
                    ('imdb', 'IMDb'),
                  ])
                    ChoiceChip(
                      label: Text(item.$2),
                      selected: _priority == item.$1,
                      onSelected: (_) => setState(() => _priority = item.$1),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _priority == 'douban'
                    ? '豆瓣：按片名查条目后取剧情剧照里最宽的一张；无需配置。'
                    : (_priority == 'tmdb'
                          ? 'TMDB：优先使用 backdrop 横图；需要 API Key 或 v4 Token，未填写时会自动回落到其它来源。'
                          : 'IMDb：自动查 IMDb 公开图库的剧照；无需登录，也不会出现“配置完没有封面”。'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              Text('TMDB 凭据（填一个即可）', style: theme.textTheme.labelMedium),
              const SizedBox(height: 6),
              TextField(
                controller: _key,
                decoration: const InputDecoration(
                  labelText: 'API 密钥（v3）',
                  hintText: '32 位十六进制，请求时作为 api_key 参数',
                ),
              ),
              if (_key.text.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _keyCredential.kind == TmdbCredentialKind.apiKey
                      ? '格式正确：32 位 API 密钥，请求时作为 api_key 参数。'
                      : (_keyCredential.kind == TmdbCredentialKind.readToken
                            ? '这是读访问令牌，请填到下面的「API 读访问令牌」框。'
                            : _keyCredential.problem),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _keyCredential.kind == TmdbCredentialKind.apiKey
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              TextField(
                controller: _token,
                minLines: 1,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'API 读访问令牌（v4）',
                  hintText: 'eyJ 开头的长串，请求时放在 Authorization 头',
                ),
              ),
              if (_token.text.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  _tokenCredential.kind == TmdbCredentialKind.readToken
                      ? '格式正确：读访问令牌，请求时放在 Authorization 头里。'
                      : (_tokenCredential.kind == TmdbCredentialKind.apiKey
                            ? '这是 v3 API 密钥，请填到上面的「API 密钥」框。'
                            : _tokenCredential.problem),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _tokenCredential.kind == TmdbCredentialKind.readToken
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                    height: 1.4,
                  ),
                ),
              ],
              if (_keyCredential.kind == TmdbCredentialKind.apiKey &&
                  _tokenCredential.kind == TmdbCredentialKind.readToken) ...[
                const SizedBox(height: 6),
                Text(
                  '两份都有效：实际使用 ${_credential.label}（令牌优先）。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                '两个值在 TMDB 后台都能拿到，填一个就够；都填时优先用读访问令牌'
                '（令牌走请求头，密钥不会出现在 URL 里）。整段粘贴也行，会自动去掉 Bearer 前缀。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.52),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _probing ? null : _probe,
                    icon: _probing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.photo_size_select_large_rounded),
                    label: Text(_probing ? '正在测试…' : '测试封面抓取'),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '测试片名：流浪地球（2019）',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.52,
                      ),
                    ),
                  ),
                ],
              ),
              if (_probeError.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _probeError,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              for (final result in _results) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        switch (result.source) {
                          'tmdb' => 'TMDB',
                          'imdb' => 'IMDb',
                          _ => '豆瓣',
                        },
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child: result.url.isEmpty
                          ? Text(
                              '未取到横图：${result.error}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.error.withValues(
                                  alpha: 0.85,
                                ),
                              ),
                            )
                          : Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.network(
                                    result.url,
                                    width: 112,
                                    height: 63,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const SizedBox(width: 112, height: 63),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    result.url,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.55),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ],
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
        FilledButton(
          // 填了却对不上格式（或填错了框）时不让保存，避免存一份用不了的凭据。
          onPressed: _canSave
              ? () => Navigator.of(context).pop(
                  _ArtworkConfig(
                    _priority,
                    _keyCredential.kind == TmdbCredentialKind.apiKey
                        ? _keyCredential.value
                        : '',
                    _tokenCredential.kind == TmdbCredentialKind.readToken
                        ? _tokenCredential.value
                        : '',
                  ),
                )
              : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

Future<void> _exportMerged(BuildContext context) async {
  final app = AppScope.of(context);
  final picked = await showDialog<Set<String>>(
    context: context,
    builder: (_) => _MergeExportDialog(profiles: app.vodProfiles),
  );
  if (picked == null || picked.isEmpty) return;
  try {
    final text = app.exportMergedConfig(picked);
    final path = await FileDialogService.saveText(
      suggestedName: 'misatv-merged.json',
      text: text,
      type: FileDialogService.jsonType,
    );
    if (!context.mounted) return;
    _settingsSnack(context, path == null ? '已取消导出' : '合并配置已保存到 $path');
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '合并导出失败：$e');
  }
}

Future<void> _exportBackup(BuildContext context) async {
  final app = AppScope.of(context);
  try {
    final data = app.buildBackupData();
    final text = const JsonEncoder.withIndent('  ').convert(data);
    final stamp = DateTime.now();
    final name =
        'misatv-backup-${stamp.year}'
        '${stamp.month.toString().padLeft(2, '0')}'
        '${stamp.day.toString().padLeft(2, '0')}-'
        '${stamp.hour.toString().padLeft(2, '0')}'
        '${stamp.minute.toString().padLeft(2, '0')}.json';
    final path = await FileDialogService.saveText(
      suggestedName: name,
      text: text,
      type: FileDialogService.backupType,
    );
    if (!context.mounted) return;
    _settingsSnack(context, path == null ? '已取消导出' : '设置备份已保存到 $path');
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '导出备份失败：$e');
  }
}

Future<void> _restoreBackup(BuildContext context) async {
  final app = AppScope.of(context);
  try {
    final path = await FileDialogService.pickFile(
      types: [FileDialogService.backupType],
    );
    if (path == null) return;
    final text = await FileDialogService.readText(path);
    final data = BackupData.parse(text);
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入设置备份？'),
        content: const Text(
          '会用备份内容覆盖当前的订阅档案、收藏、历史、播放设置与网盘 Cookie。\n'
          '备份文件里的网盘凭据是明文，请只导入你信任的文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('覆盖导入'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await app.restoreBackupData(data);
    if (!context.mounted) return;
    _settingsSnack(context, '设置备份已导入');
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '导入备份失败：$e');
  }
}

String _driveAccountsSubtitle(AppState app) {
  bool ready(String key) {
    final account = app.driveAccounts[key];
    return (account?.cookie ?? '').trim().isNotEmpty &&
        account?.extra['guest'] != 'true';
  }

  final signed = [
    for (final entry in driveProviderNames.entries)
      if (ready(entry.key)) entry.value,
  ];
  if (signed.isEmpty) {
    final stale = [
      for (final entry in driveProviderNames.entries)
        if (!AppState.isOptionalDriveProvider(entry.key) &&
            (app.driveAccounts[entry.key]?.cookie ?? '').trim().isNotEmpty &&
            app.driveAccounts[entry.key]?.extra['guest'] == 'true')
          entry.value,
    ];
    return stale.isEmpty
        ? '未登录 · 点击扫码或粘贴 Cookie 配置夸克 / UC / 百度 / 115 / 哔哩'
        : '${stale.join(' / ')} 登录已失效，点击重新配置';
  }
  final usernames = [
    for (final entry in driveProviderNames.entries)
      if (ready(entry.key))
        (app.driveAccounts[entry.key]?.username ?? '').trim(),
  ].where((name) => name.isNotEmpty).toList();
  return '${signed.join(' / ')} 已登录'
      '${usernames.isEmpty ? '' : ' · ${usernames.join(' / ')}'}';
}

void _settingsSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// 开启 / 关闭 R18 过滤：开启时设置关闭密码，关闭时必须验证该密码。
Future<void> _toggleContentFilter(
  BuildContext context,
  AppState app,
  bool enable,
) async {
  if (enable) {
    if (app.contentFilter.hasPassword) {
      await app.setContentFilter(app.contentFilter.copyWith(enabled: true));
      return;
    }
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _SetFilterPasswordDialog(),
    );
    if (password == null) return;
    await app.setContentFilter(
      app.contentFilter.copyWith(
        enabled: true,
        passwordHash: hashContentFilterPassword(password),
      ),
    );
    return;
  }

  // 旧配置可能已开启但没有密码：允许直接关闭，下次开启时会补设密码。
  if (!app.contentFilter.hasPassword) {
    await app.setContentFilter(app.contentFilter.copyWith(enabled: false));
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => _VerifyFilterPasswordDialog(settings: app.contentFilter),
  );
  if (confirmed != true) return;
  await app.setContentFilter(app.contentFilter.copyWith(enabled: false));
}

class _SetFilterPasswordDialog extends StatefulWidget {
  const _SetFilterPasswordDialog();

  @override
  State<_SetFilterPasswordDialog> createState() =>
      _SetFilterPasswordDialogState();
}

class _SetFilterPasswordDialogState extends State<_SetFilterPasswordDialog> {
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String _error = '';

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final password = _passwordCtrl.text;
    if (password.length < contentFilterPasswordMinLength) {
      setState(() => _error = '密码至少 $contentFilterPasswordMinLength 位');
      return;
    }
    if (password != _confirmCtrl.text) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }
    Navigator.of(context).pop(password);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('设置关闭密码'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'R18 过滤开启后，关闭过滤需要输入此密码。请设置一个孩子不知道的密码。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordCtrl,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(
                labelText: '密码（至少 $contentFilterPasswordMinLength 位）',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _confirmCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: '再次输入密码'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('开启过滤')),
      ],
    );
  }
}

class _VerifyFilterPasswordDialog extends StatefulWidget {
  const _VerifyFilterPasswordDialog({
    required this.settings,
    this.title = '关闭 R18 过滤',
    this.message = '请输入开启过滤时设置的关闭密码。',
    this.confirmLabel = '关闭过滤',
  });
  final ContentFilterSettings settings;
  final String title;
  final String message;
  final String confirmLabel;

  @override
  State<_VerifyFilterPasswordDialog> createState() =>
      _VerifyFilterPasswordDialogState();
}

class _VerifyFilterPasswordDialogState
    extends State<_VerifyFilterPasswordDialog> {
  final _controller = TextEditingController();
  String _error = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.settings.verifyPassword(_controller.text)) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _error = '密码不正确');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.message,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: true,
              decoration: const InputDecoration(labelText: '关闭密码'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

Future<void> _editContentFilterKeywords(BuildContext context) async {
  final app = AppScope.of(context);
  // 过滤开启时，改屏蔽词等于改变过滤效果，同样需要密码。
  if (app.contentFilter.enabled && app.contentFilter.hasPassword) {
    final verified = await showDialog<bool>(
      context: context,
      builder: (_) => _VerifyFilterPasswordDialog(
        settings: app.contentFilter,
        title: '修改 R18 过滤规则',
        message: '修改屏蔽关键词需要输入开启过滤时设置的密码。',
        confirmLabel: '继续修改',
      ),
    );
    if (verified != true || !context.mounted) return;
  }
  final result = await showDialog<List<String>>(
    context: context,
    builder: (_) =>
        _ContentFilterKeywordsDialog(initial: app.contentFilter.keywords),
  );
  if (result == null) return;
  await app.setContentFilter(app.contentFilter.copyWith(keywords: result));
  if (context.mounted) {
    _settingsSnack(
      context,
      result.isEmpty
          ? '已清空屏蔽关键词（恢复默认词可重新启用）'
          : '已保存 ${result.length} 个屏蔽关键词'
                '${app.contentFilter.enabled ? '' : '；开启「屏蔽 R18 / 成人内容」后生效'}',
    );
  }
}

class _ContentFilterKeywordsDialog extends StatefulWidget {
  const _ContentFilterKeywordsDialog({required this.initial});
  final List<String> initial;

  @override
  State<_ContentFilterKeywordsDialog> createState() =>
      _ContentFilterKeywordsDialogState();
}

class _ContentFilterKeywordsDialogState
    extends State<_ContentFilterKeywordsDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial.join('\n'),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('R18 屏蔽关键词'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '每行一个关键词（也可用逗号分隔），不区分大小写；命中片名、备注、类型、地区、标签或来源名称即隐藏，分类名命中也会从分类栏隐藏。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '屏蔽关键词',
                hintText: 'R18\n18禁\n成人',
                alignLabelWithHint: true,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(
                  () => _controller.text = defaultContentFilterKeywords.join(
                    '\n',
                  ),
                ),
                child: const Text('恢复默认词'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(normalizeContentFilterKeywords(_controller.text.split('\n'))),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

Future<void> _editDanmakuStyle(BuildContext context) async {
  final app = AppScope.of(context);
  final result = await showDialog<DanmakuSettings>(
    context: context,
    builder: (_) => _DanmakuStyleDialog(initial: app.danmakuSettings),
  );
  if (result != null) await app.setDanmakuSettings(result);
}

int _customLineCount(String text) {
  var n = 0;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.isNotEmpty && !t.startsWith('#')) n++;
  }
  return n;
}

String _danmakuEndpointsSubtitle(DanmakuSettings settings) {
  final enabled = settings.endpoints
      .where((e) => e.enabled && e.url.trim().isNotEmpty)
      .length;
  final custom = settings.endpoints
      .where((e) => !isBuiltinEndpoint(e.url))
      .length;
  return '已启用 $enabled 个'
      '${custom == 0 ? '' : ' · 自定义 $custom 个'}'
      '；匹配失败时会自动扩大搜索';
}

Future<void> _editDanmakuEndpoints(BuildContext context) async {
  final app = AppScope.of(context);
  final result = await showDialog<DanmakuSettings>(
    context: context,
    builder: (_) => _DanmakuEndpointDialog(initial: app.danmakuSettings),
  );
  if (result != null) await app.setDanmakuSettings(result);
}

class _DanmakuEndpointDialog extends StatefulWidget {
  const _DanmakuEndpointDialog({required this.initial});
  final DanmakuSettings initial;

  @override
  State<_DanmakuEndpointDialog> createState() => _DanmakuEndpointDialogState();
}

class _DanmakuEndpointDialogState extends State<_DanmakuEndpointDialog> {
  late final Map<String, bool> _enabled = {
    for (final e in widget.initial.endpoints)
      normalizeEndpointBase(e.url): e.enabled,
  };
  late final TextEditingController _customCtrl = TextEditingController(
    text: customEndpointsText(widget.initial.endpoints),
  );

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('弹幕接口'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '勾选参与搜索的内置接口；匹配失败时播放器会自动再查一遍所有接口。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.76),
                ),
              ),
              const SizedBox(height: 6),
              for (final e in builtinDanmakuEndpoints)
                SwitchListTile.adaptive(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _enabled[normalizeEndpointBase(e.url)] ?? e.enabled,
                  onChanged: (v) => setState(
                    () => _enabled[normalizeEndpointBase(e.url)] = v,
                  ),
                  title: Text(e.name),
                  subtitle: Text(
                    e.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              const Divider(height: 24),
              TextField(
                controller: _customCtrl,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: '自定义接口',
                  hintText: '每行：名称@https://...',
                  helperText: '只要兼容 TVBox 弹幕协议（/api/v2/search/anime 等）即可',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final toggled = <DanmakuEndpoint>[
              for (final e in widget.initial.endpoints)
                isBuiltinEndpoint(e.url)
                    ? e.copyWith(
                        enabled:
                            _enabled[normalizeEndpointBase(e.url)] ?? e.enabled,
                      )
                    : e,
            ];
            Navigator.of(context).pop(
              widget.initial.copyWith(
                endpoints: mergeEndpoints(toggled, _customCtrl.text),
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _DanmakuStyleDialog extends StatefulWidget {
  const _DanmakuStyleDialog({required this.initial});
  final DanmakuSettings initial;

  @override
  State<_DanmakuStyleDialog> createState() => _DanmakuStyleDialogState();
}

class _DanmakuStyleDialogState extends State<_DanmakuStyleDialog> {
  late double _regionRatio = widget.initial.regionRatio;
  late double _fontSize = widget.initial.fontSize;
  late double _opacity = widget.initial.opacity;
  late double _speed = widget.initial.speed;
  late double _offset = widget.initial.offset;
  late final TextEditingController _blockWordCtrl = TextEditingController(
    text: widget.initial.blockWords.join('\n'),
  );

  @override
  void dispose() {
    _blockWordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      int divisions,
      ValueChanged<double> onChanged,
      String display,
    ) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: theme.textTheme.bodySmall),
              const Spacer(),
              Text(display, style: theme.textTheme.labelSmall),
            ],
          ),
          Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: (v) => setState(() => onChanged(v)),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('弹幕样式'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              slider(
                '显示区域',
                _regionRatio,
                danmakuRegionMinRatio,
                danmakuRegionMaxRatio,
                18,
                (v) => _regionRatio = v,
                '${(_regionRatio * 100).round()}% 屏',
              ),
              const SizedBox(height: 4),
              slider(
                '字号',
                _fontSize,
                12,
                40,
                28,
                (v) => _fontSize = v,
                '${_fontSize.toStringAsFixed(0)}px',
              ),
              slider(
                '透明度',
                _opacity,
                0.2,
                1,
                8,
                (v) => _opacity = v,
                '${(_opacity * 100).round()}%',
              ),
              slider(
                '滚动速度',
                _speed,
                60,
                240,
                18,
                (v) => _speed = v,
                '${_speed.round()}px/s',
              ),
              slider(
                '时间偏移',
                _offset,
                -10,
                10,
                40,
                (v) => _offset = v,
                '${_offset.toStringAsFixed(1)}s',
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _blockWordCtrl,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '弹幕屏蔽词',
                  hintText: '每行一个关键词，如：剧透、广告；/正则/ 也可',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            widget.initial.copyWith(
              regionRatio: _regionRatio,
              fontSize: _fontSize,
              opacity: _opacity,
              speed: _speed,
              offset: _offset,
              blockWords: normalizeDanmakuBlockWords(_blockWordCtrl.text),
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

Future<void> _pickPlayerFit(BuildContext context, AppState app) async {
  final current = normalizePlayerFit(app.playerSettings.fit);
  final picked = await showDialog<PlayerFit>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('画面比例'),
      children: [
        for (final fit in playerFits)
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(fit),
            child: Row(
              children: [
                Icon(
                  current == fit
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 20,
                  color: current == fit
                      ? Theme.of(ctx).colorScheme.primary
                      : null,
                ),
                const SizedBox(width: 10),
                Text(fit.label),
              ],
            ),
          ),
      ],
    ),
  );
  if (picked == null) return;
  await app.setPlayerSettings(app.playerSettings.copyWith(fit: picked.name));
}

Future<void> _editAssrtToken(BuildContext context) async {
  final app = AppScope.of(context);
  final token = await showDialog<String>(
    context: context,
    builder: (_) => _TokenDialog(initial: app.assrtToken),
  );
  if (token == null) return;
  await app.setAssrtToken(token);
  if (context.mounted) {
    _settingsSnack(
      context,
      token.trim().isEmpty ? '已清空 assrt token' : '已保存 assrt token',
    );
  }
}

String _defaultPlayerLabel(AppState app) {
  final id = app.playerSettings.defaultPlayer;
  if (id == kDefaultPlayerYaozhiMpv) return 'Yaozhi MPV';
  final path = app.playerSettings.defaultCustomPlayerPathValue;
  if (path.isNotEmpty) {
    for (final entry in app.playerSettings.externalPlayers) {
      if (entry.path.trim().toLowerCase() != path.toLowerCase()) continue;
      final name = entry.name.trim().isEmpty
          ? externalPlayerDisplayName(entry.path)
          : entry.name.trim();
      return externalPlayerExists(path) ? name : '$name（文件不存在）';
    }
    return externalPlayerDisplayName(path);
  }
  return '内置播放器';
}

Future<void> _pickDefaultPlayer(BuildContext context, AppState app) async {
  final mpvInstalled = await MpvExtension.instance.isInstalled;
  if (!context.mounted) return;
  final current = app.playerSettings.defaultPlayer;
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('默认播放器'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DefaultPlayerTile(
                icon: Icons.desktop_windows_outlined,
                title: '内置播放器',
                subtitle: 'MisaTV 内置 fvp 内核',
                selected:
                    normalizeDefaultPlayer(current) == kDefaultPlayerBuiltin,
                onTap: () => Navigator.of(ctx).pop(kDefaultPlayerBuiltin),
              ),
              _DefaultPlayerTile(
                icon: Icons.play_circle_outline_rounded,
                title: 'Yaozhi MPV',
                subtitle: mpvInstalled
                    ? '已安装 · 独立 MPV 窗口'
                    : '未安装 · 播放时会回退到内置播放器',
                selected: current == kDefaultPlayerYaozhiMpv,
                onTap: () => Navigator.of(ctx).pop(kDefaultPlayerYaozhiMpv),
              ),
              for (final entry in app.playerSettings.externalPlayers)
                _DefaultPlayerTile(
                  icon: Icons.open_in_new_rounded,
                  title: entry.name.trim().isEmpty
                      ? externalPlayerDisplayName(entry.path)
                      : entry.name.trim(),
                  subtitle: externalPlayerExists(entry.path)
                      ? entry.path
                      : '文件不存在 · ${entry.path}',
                  selected: current == defaultCustomPlayerId(entry.path),
                  enabled: externalPlayerExists(entry.path),
                  onTap: () =>
                      Navigator.of(ctx).pop(defaultCustomPlayerId(entry.path)),
                ),
              if (app.playerSettings.externalPlayers.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '还没有自定义第三方播放器，可在上一项「自定义第三方播放器」里添加。',
                    style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurface
                          .withValues(alpha: 0.72),
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
  if (picked == null || !context.mounted) return;
  await app.setPlayerSettings(
    app.playerSettings.copyWith(defaultPlayer: picked),
  );
  if (!context.mounted) return;
  _settingsSnack(context, '默认播放器已设为 ${_defaultPlayerLabel(app)}');
}

class _DefaultPlayerTile extends StatelessWidget {
  const _DefaultPlayerTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: enabled,
      leading: Icon(icon, size: 20),
      title: Text(title),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall,
      ),
      trailing: selected
          ? Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary)
          : const Icon(Icons.circle_outlined, size: 18),
      onTap: enabled ? onTap : null,
    );
  }
}

Future<void> _editExternalPlayers(BuildContext context) async {
  final app = AppScope.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('自定义第三方播放器'),
      content: SizedBox(
        width: 560,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
          ),
          child: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: app,
              builder: (ctx, _) {
                final entries = app.playerSettings.externalPlayers;
                if (entries.isEmpty) {
                  return Text(
                    '还没有添加播放器。点击下方「添加播放器」选择任意播放器 exe，'
                    '无需安装或在系统中注册；添加后会出现在播放器的「外部播放器」列表最前面。',
                    style: Theme.of(ctx).textTheme.bodySmall
                        ?.copyWith(height: 1.6),
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final entry in entries)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.play_circle_outline_rounded),
                        title: Text(
                          entry.name.trim().isEmpty
                              ? externalPlayerDisplayName(entry.path)
                              : entry.name,
                        ),
                        subtitle: Text(
                          externalPlayerExists(entry.path)
                              ? entry.path
                              : '文件不存在 · ${entry.path}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: '移除',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () =>
                              _removeExternalPlayer(ctx, app, entry),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭'),
        ),
        FilledButton.tonalIcon(
          onPressed: () => _addExternalPlayers(ctx, app),
          icon: const Icon(Icons.add_rounded),
          label: const Text('添加播放器'),
        ),
      ],
    ),
  );
}

Future<void> _addExternalPlayers(BuildContext context, AppState app) async {
  List<String>? paths;
  try {
    paths = await FileDialogService.pickFiles(
      types: const [FileDialogService.exeType],
      confirmButtonText: '添加播放器',
    );
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '无法打开文件选择器：$e');
    return;
  }
  if (paths == null || paths.isEmpty) return;
  final entries = [...app.playerSettings.externalPlayers];
  final seen = {for (final entry in entries) entry.path.trim().toLowerCase()};
  var added = 0;
  for (final raw in paths) {
    final path = raw.trim();
    if (path.isEmpty || !seen.add(path.toLowerCase())) continue;
    entries.add(
      ExternalPlayerEntry(name: externalPlayerDisplayName(path), path: path),
    );
    added++;
  }
  if (added == 0) {
    if (context.mounted) _settingsSnack(context, '选择的播放器已经在列表中了');
    return;
  }
  await app.setCustomExternalPlayers(entries);
  if (context.mounted) _settingsSnack(context, '已添加 $added 个播放器');
}

Future<void> _removeExternalPlayer(
  BuildContext context,
  AppState app,
  ExternalPlayerEntry entry,
) async {
  final entries = [
    for (final item in app.playerSettings.externalPlayers)
      if (item.path.toLowerCase() != entry.path.toLowerCase()) item,
  ];
  await app.setCustomExternalPlayers(entries);
  if (app.playerSettings.defaultCustomPlayerPathValue.toLowerCase() ==
      entry.path.toLowerCase()) {
    await app.setPlayerSettings(
      app.playerSettings.copyWith(defaultPlayer: kDefaultPlayerBuiltin),
    );
  }
  if (context.mounted) {
    _settingsSnack(
      context,
      '已移除 ${entry.name.trim().isEmpty ? externalPlayerDisplayName(entry.path) : entry.name}',
    );
  }
}

/// 「自定义直播 UA」的一行摘要（设置页折叠卡片里的 subtitle）。
String _liveUaSubtitle(AppState app) {
  final policy = app.liveUaPolicy;
  if (policy.isEmpty) {
    return '未配置；留空即自动探测（已知服务用其指定 UA，其余 okhttp/3.12.0）';
  }
  final parts = <String>[
    if (policy.defaultUa.trim().isNotEmpty) '默认 UA 已设置',
    if (policy.ruleCount > 0) '接口例外 ${policy.ruleCount} 条',
  ];
  return parts.join(' · ');
}

Future<void> _editLiveUaPolicy(BuildContext context, AppState app) async {
  final saved = await showDialog<LiveUaPolicy>(
    context: context,
    builder: (_) => _LiveUaPolicyDialog(initial: app.liveUaPolicy),
  );
  if (saved == null) return;
  await app.setLiveUaPolicy(saved);
  if (context.mounted) {
    _settingsSnack(
      context,
      saved.isEmpty
          ? '已清空自定义直播 UA，恢复自动探测'
          : '自定义直播 UA 已保存（下次加载直播单与切台生效）',
    );
  }
}

/// 自定义直播 UA 编辑弹窗：一个全局默认值 + 若干「按接口」的例外规则。
///
/// 做成两层而不是一行输入：多数用户只有一个源要改 UA，而这个 UA 又不能
/// 发给所有源（会覆盖掉源站自己要求的固定 UA）。规则为空时只有默认值起作用。
class _LiveUaPolicyDialog extends StatefulWidget {
  const _LiveUaPolicyDialog({required this.initial});
  final LiveUaPolicy initial;

  @override
  State<_LiveUaPolicyDialog> createState() => _LiveUaPolicyDialogState();
}

class _LiveUaPolicyDialogState extends State<_LiveUaPolicyDialog> {
  late final TextEditingController _default = TextEditingController(
    text: widget.initial.defaultUa,
  );
  late final List<LiveUaRule> _rules = List.of(widget.initial.rules);

  @override
  void dispose() {
    _default.dispose();
    super.dispose();
  }

  Future<void> _addOrEdit([int? index]) async {
    final old = index == null ? null : _rules[index];
    final result = await showDialog<LiveUaRule>(
      context: context,
      builder: (_) => _LiveUaRuleDialog(initial: old),
    );
    if (result == null) return;
    setState(() {
      // 同一片段只能有一条：`matchRule` 是「靠前者优先」，界面上任由用户
      // 添加第二条同片段规则时，新填的 UA 永远轮不到生效（保存后看起来"没反应"）。
      // 新增时若已存在，就地覆盖那一条；编辑时把被覆盖的旧条目删掉。
      final dup = _rules.indexWhere(
        (r) => r.pattern.toLowerCase() == result.pattern.toLowerCase(),
      );
      if (index == null) {
        if (dup >= 0) {
          _rules[dup] = result;
        } else {
          _rules.add(result);
        }
      } else {
        _rules[index] = result;
        if (dup >= 0 && dup != index) _rules.removeAt(dup);
      }
    });
  }

  Future<void> _delete(int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条接口规则？'),
        content: Text('「${_rules[index].pattern}」将不再使用指定 UA。'),
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
    setState(() => _rules.removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('自定义直播 UA'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _default,
                decoration: const InputDecoration(
                  labelText: '默认直播 UA（可选）',
                  hintText: '留空 = 自动探测',
                  helperText:
                      '只对「订阅没写 ua、且下面没有规则命中」的直播接口生效：'
                      '不覆盖订阅自带的 ua，也不覆盖内置的已知服务 UA。',
                  helperMaxLines: 3,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '按接口的例外规则',
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                  if (_rules.isNotEmpty)
                    Text('${_rules.length} 条',
                        style: theme.textTheme.labelSmall),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '命中才生效，靠前者优先。地址片段按包含匹配；带正则元字符'
                '（* ( ) [ ] ^ \$ + ?）的按正则匹配。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 6),
              for (var i = 0; i < _rules.length; i++)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _rules[i].pattern,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                            Text(
                              _rules[i].ua,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.55,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _RowIconButton(
                        icon: Icons.edit_outlined,
                        tooltip: '编辑',
                        onPressed: () => _addOrEdit(i),
                      ),
                      _RowIconButton(
                        icon: Icons.delete_outline_rounded,
                        tooltip: '删除',
                        onPressed: () => _delete(i),
                      ),
                    ],
                  ),
                ),
              TextButton.icon(
                onPressed: () => _addOrEdit(),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('添加接口规则'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(LiveUaPolicy(defaultUa: _default.text.trim(), rules: _rules)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 单条「接口 → UA」规则的编辑弹窗。
class _LiveUaRuleDialog extends StatefulWidget {
  const _LiveUaRuleDialog({this.initial});
  final LiveUaRule? initial;

  @override
  State<_LiveUaRuleDialog> createState() => _LiveUaRuleDialogState();
}

class _LiveUaRuleDialogState extends State<_LiveUaRuleDialog> {
  late final TextEditingController _pattern = TextEditingController(
    text: widget.initial?.pattern ?? '',
  );
  late final TextEditingController _ua = TextEditingController(
    text: widget.initial?.ua ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _pattern.dispose();
    _ua.dispose();
    super.dispose();
  }

  void _save() {
    final pattern = _pattern.text.trim();
    final ua = _ua.text.trim();
    if (pattern.isEmpty) {
      setState(() => _error = '直播接口不能为空');
      return;
    }
    if (ua.isEmpty) {
      setState(() => _error = 'UA 不能为空');
      return;
    }
    Navigator.of(context).pop(LiveUaRule(pattern: pattern, ua: ua));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? '添加接口规则' : '编辑接口规则'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _pattern,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '直播接口',
                hintText: 'live.example.com，或地址片段 /playlist.m3u8',
                helperText: '按地址匹配；也可写正则，例如 .*ottiptv\\\\.cc.*',
                helperMaxLines: 2,
              ),
              minLines: 1,
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ua,
              decoration: const InputDecoration(
                labelText: 'User-Agent',
                hintText: 'qqlive',
              ),
              minLines: 1,
              maxLines: 3,
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
        FilledButton(onPressed: _save, child: const Text('确定')),
      ],
    );
  }
}

Future<void> _editSubtitleApis(BuildContext context) async {
  final app = AppScope.of(context);
  final text = await showDialog<String>(
    context: context,
    builder: (_) => _SubtitleApiDialog(initial: app.customSubtitleApis),
  );
  if (text == null) return;
  await app.setCustomSubtitleApis(text);
  if (context.mounted) {
    final n = _customLineCount(text);
    _settingsSnack(context, n == 0 ? '已清空自定义字幕 API' : '已保存 $n 个自定义字幕接口');
  }
}

class _SubtitleApiDialog extends StatefulWidget {
  const _SubtitleApiDialog({required this.initial});
  final String initial;

  @override
  State<_SubtitleApiDialog> createState() => _SubtitleApiDialogState();
}

class _SubtitleApiDialogState extends State<_SubtitleApiDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义字幕 API'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _ctrl,
                minLines: 6,
                maxLines: 12,
                decoration: const InputDecoration(
                  hintText:
                      '名称@https://example.com/sub?title={title}&ep={episode}',
                  helperText:
                      '每行一个。支持 {title} {year} {season} {episode} {rawName}；'
                      '接口可返回 JSON 候选列表，或直接返回 srt / ass / vtt / zip。',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'JSON 列表字段：url（必填）、title、language、format；'
                '也可以放在 data / results / subtitles / list 下。',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.72),
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 播放缓冲：起播预缓冲 + 最大缓冲（fvp 的 `bufferRange`）。
Future<void> _editBufferSettings(BuildContext context, AppState app) async {
  var minSec = app.playerSettings.bufferMinSec;
  var maxSec = app.playerSettings.bufferMaxSec;
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialog) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: const Text('播放缓冲'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '起播预缓冲 ${minSec.toStringAsFixed(1)} 秒',
                  style: theme.textTheme.bodyMedium,
                ),
                Slider(
                  value: minSec,
                  min: 0.2,
                  max: 10,
                  divisions: 49,
                  label: '${minSec.toStringAsFixed(1)}s',
                  onChanged: (v) => setDialog(() => minSec = v),
                ),
                Text(
                  '最大缓冲 ${maxSec.toStringAsFixed(0)} 秒',
                  style: theme.textTheme.bodyMedium,
                ),
                Slider(
                  value: maxSec,
                  min: 2,
                  max: 60,
                  divisions: 58,
                  label: '${maxSec.toStringAsFixed(0)}s',
                  onChanged: (v) => setDialog(() => maxSec = v),
                ),
                const SizedBox(height: 6),
                Text(
                  '只对内置 fvp 内核生效：预缓冲越大起播越稳，最大缓冲越大越抗卡顿，'
                  '代价是更多内存与流量；保存后立即应用到当前播放。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存'),
            ),
          ],
        );
      },
    ),
  );
  if (saved != true) return;
  final fixedMax = maxSec < minSec + 0.5 ? minSec + 0.5 : maxSec;
  await app.setPlayerSettings(
    app.playerSettings.copyWith(
      bufferMinSec: minSec,
      bufferMaxSec: fixedMax,
      bufferTuned: true,
    ),
  );
  if (context.mounted) _settingsSnack(context, '播放缓冲已更新，当前播放已应用');
}

/// 缓存容量上限：给固定档位，避免手填出离谱的值。
Future<void> _pickStreamCacheSize(BuildContext context, AppState app) async {
  const options = [256, 512, 1024, 2048, 4096, 8192];
  final current = app.playerSettings.streamCacheMb;
  final picked = await showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('缓存容量上限'),
      children: [
        for (final mb in options)
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(mb),
            child: Row(
              children: [
                Icon(
                  mb == current
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 18,
                  color: mb == current
                      ? Theme.of(ctx).colorScheme.primary
                      : Theme.of(ctx).disabledColor,
                ),
                const SizedBox(width: 10),
                Text(mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB'),
              ],
            ),
          ),
      ],
    ),
  );
  if (picked == null) return;
  await app.setPlayerSettings(
    app.playerSettings.copyWith(streamCacheMb: picked),
  );
  if (context.mounted) {
    _settingsSnack(
      context,
      '缓存上限已设为 ${picked >= 1024 ? '${picked ~/ 1024} GB' : '$picked MB'}',
    );
  }
}

/// 清空边播缓存目录。
Future<void> _clearStreamCache(BuildContext context) async {
  final bytes = await LocalRelay.instance.streamCacheBytes();
  if (!context.mounted) return;
  final size = bytes >= 1024 * 1024 * 1024
      ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('清空播放缓存'),
      content: Text('当前占用约 $size。清空后已缓存的分片会重新从网络拉取。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('清空'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await LocalRelay.instance.clearStreamCache();
  if (context.mounted) _settingsSnack(context, '播放缓存已清空');
}

Future<void> _pickMagnetDownloadDir(BuildContext context, AppState app) async {
  final current = app.playerSettings.magnetDownloadDir;
  final action = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('磁力下载位置'),
      content: Text(
        current.isEmpty
            ? '当前使用默认目录：应用数据目录/bt。\n\n'
                  '可指定其它文件夹；切换后新磁力任务会下载到新位置，'
                  '正在播放的任务会停止并需要重新打开。'
            : '当前目录：\n$current\n\n'
                  '切换后新磁力任务会下载到新位置，正在播放的任务会停止并需要重新打开。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop('reset'),
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop('pick'),
          child: const Text('选择文件夹'),
        ),
      ],
    ),
  );
  if (action == 'reset') {
    await app.setPlayerSettings(
      app.playerSettings.copyWith(magnetDownloadDir: ''),
    );
    if (context.mounted) _settingsSnack(context, '已恢复默认磁力下载位置');
    return;
  }
  if (action != 'pick') return;
  final path = await FileDialogService.pickDirectory(
    confirmButtonText: '选择磁力下载目录',
  );
  if (path == null || path.trim().isEmpty) return;
  await app.setPlayerSettings(
    app.playerSettings.copyWith(magnetDownloadDir: path.trim()),
  );
  if (context.mounted) _settingsSnack(context, '磁力下载位置已更新');
}

Future<void> _editXunlei(BuildContext context, AppState app) async {
  final account = app.xunleiAccount;
  if (!account.loggedIn) {
    final ok = await showXunleiLoginDialog(context, app);
    if (ok && context.mounted) {
      _settingsSnack(context, '迅雷云盘登录成功');
    }
    return;
  }
  final logout = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('迅雷云盘'),
      content: Text(
        '已登录：${account.displayName}\n\n'
        '磁力会先提交到迅雷云盘离线下载，云端完成后直接播放；'
        '云端失败或关闭该开关时自动回退 aria2。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('关闭'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('退出登录'),
        ),
      ],
    ),
  );
  if (logout == true) {
    await app.logoutXunlei();
    if (context.mounted) _settingsSnack(context, '已退出迅雷云盘');
  }
}

Future<void> _editProxy(BuildContext context) async {
  if (kIsWeb) {
    _settingsSnack(context, '内置代理仅支持桌面版');
    return;
  }
  final app = AppScope.of(context);
  final config = await showDialog<ProxyConfig>(
    context: context,
    builder: (_) => _ProxyDialog(initial: app.proxy),
  );
  if (config == null) return;
  await app.setProxy(config);
  if (context.mounted) {
    _settingsSnack(context, '网络代理：${ProxyRuntime.instance.summary}');
  }
}

class _ProxyDialog extends StatefulWidget {
  const _ProxyDialog({required this.initial});
  final ProxyConfig initial;

  @override
  State<_ProxyDialog> createState() => _ProxyDialogState();
}

class _ProxyDialogState extends State<_ProxyDialog> {
  late bool _enabled = widget.initial.enabled;
  late bool _followSystem = widget.initial.followSystem;
  late String _type = widget.initial.type;
  late final TextEditingController _host = TextEditingController(
    text: widget.initial.host,
  );
  late final TextEditingController _port = TextEditingController(
    text: widget.initial.port > 0 ? '${widget.initial.port}' : '7890',
  );
  late final TextEditingController _user = TextEditingController(
    text: widget.initial.username,
  );
  late final TextEditingController _pass = TextEditingController(
    text: widget.initial.password,
  );
  String _error = '';
  bool _diagnosing = false;
  List<String> _diagnosis = const [];

  Future<void> _diagnose() async {
    setState(() {
      _diagnosing = true;
      _diagnosis = const [];
    });
    final lines = await ProxyRuntime.instance.diagnose();
    if (!mounted) return;
    setState(() {
      _diagnosing = false;
      _diagnosis = lines;
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _save() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 0;
    if (_enabled &&
        !_followSystem &&
        (host.isEmpty || port <= 0 || port > 65535)) {
      setState(() => _error = '请填写有效的代理地址和端口（1-65535）');
      return;
    }
    Navigator.of(context).pop(
      ProxyConfig(
        enabled: _enabled && !_followSystem,
        followSystem: _followSystem,
        type: _type,
        host: host,
        port: port,
        username: _user.text.trim(),
        password: _pass.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('网络代理'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile.adaptive(
                value: _followSystem,
                onChanged: (v) => setState(() {
                  _followSystem = v;
                  _error = '';
                }),
                title: const Text('跟随系统代理'),
                subtitle: const Text(
                  '用 Windows「局域网设置」或 HTTPS_PROXY 环境变量里的代理（Clash / v2rayN 开系统代理即生效）；'
                  '连 api.themoviedb.org 这类域名必须走它',
                ),
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile.adaptive(
                value: _enabled,
                onChanged: (v) => setState(() {
                  _enabled = v;
                  if (v) _followSystem = false;
                  _error = '';
                }),
                title: const Text('使用手动代理'),
                subtitle: const Text('HTTP / SOCKS5 上联；本机 127.0.0.1 始终直连'),
                contentPadding: EdgeInsets.zero,
              ),
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 2),
                child: Text(
                  '两者都关闭时直连（默认）',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'http', label: Text('HTTP')),
                  ButtonSegment(value: 'socks5', label: Text('SOCKS5')),
                ],
                selected: {_type},
                onSelectionChanged: _followSystem
                    ? null
                    : (value) => setState(() => _type = value.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _host,
                enabled: !_followSystem,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: '127.0.0.1 或代理域名',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _port,
                enabled: !_followSystem,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '端口',
                  hintText: '7890',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _user,
                enabled: !_followSystem,
                decoration: const InputDecoration(
                  labelText: '用户名（可选）',
                  hintText: '代理开启认证时填写',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _pass,
                enabled: !_followSystem,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可选）'),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _diagnosing ? null : _diagnose,
                  icon: _diagnosing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check_rounded, size: 18),
                  label: Text(_diagnosing ? '正在自检…' : '代理自检'),
                ),
              ),
              for (final line in _diagnosis)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    line,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                  ),
                ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
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

class _TokenDialog extends StatefulWidget {
  const _TokenDialog({required this.initial});
  final String initial;

  @override
  State<_TokenDialog> createState() => _TokenDialogState();
}

class _TokenDialogState extends State<_TokenDialog> {
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
      title: const Text('assrt 字幕 token'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'assrt.net 免费注册后获取 token；留空只用 SubtitleCat',
        ),
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

class _MergeExportDialog extends StatefulWidget {
  const _MergeExportDialog({required this.profiles});
  final List<ConfigProfile> profiles;

  @override
  State<_MergeExportDialog> createState() => _MergeExportDialogState();
}

class _MergeExportDialogState extends State<_MergeExportDialog> {
  late final Set<String> _selected = {
    for (final p in widget.profiles)
      if (p.rawJson.trim().isNotEmpty) p.id,
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('合并导出配置'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '把勾选档案的源合并去重成一份 TVBox 订阅 JSON；不同档案的 jar / flags / 直播线路会一并带上。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final profile in widget.profiles)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: _selected.contains(profile.id),
                        onChanged: profile.rawJson.trim().isEmpty
                            ? null
                            : (v) => setState(() {
                                if (v == true) {
                                  _selected.add(profile.id);
                                } else {
                                  _selected.remove(profile.id);
                                }
                              }),
                        title: Text(profile.name),
                        subtitle: Text(
                          '${profile.siteCount} 站点 · ${profile.liveCount} 直播',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected),
          child: const Text('导出'),
        ),
      ],
    );
  }
}

/// WebDAV 服务器列表：添加 / 编辑 / 删除 / 浏览。
class _DavServerList extends StatefulWidget {
  const _DavServerList({required this.app});
  final AppState app;

  @override
  State<_DavServerList> createState() => _DavServerListState();
}

class _DavServerListState extends State<_DavServerList> {
  Future<void> _edit([DavServer? server]) async {
    final result = await showDialog<DavServer>(
      context: context,
      builder: (ctx) => _DavEditDialog(initial: server),
    );
    if (result == null || !mounted) return;
    try {
      await widget.app.saveDavServer(result);
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(DavServer server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 WebDAV 服务器'),
        content: Text('确定删除「${server.name}」？只影响本机保存的地址与凭据。'),
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
    if (ok != true || !mounted) return;
    await widget.app.removeDavServer(server.id);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _browse(DavServer server) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => DavBrowsePage(server: server)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final servers = widget.app.davService.servers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (servers.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '只读直连：PROPFIND 列目录，播放经本地 /play 中继注入 Basic 认证。',
              style: theme.textTheme.bodySmall,
            ),
          )
        else
          for (final server in servers)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_shared_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          server.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          server.username.isEmpty
                              ? server.url
                              : '${server.username}@${server.url}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _RowIconButton(
                    icon: Icons.folder_open_rounded,
                    tooltip: '浏览',
                    onPressed: () => _browse(server),
                  ),
                  _RowIconButton(
                    icon: Icons.edit_outlined,
                    tooltip: '编辑',
                    onPressed: () => _edit(server),
                  ),
                  _RowIconButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: '删除',
                    onPressed: () => _delete(server),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: () => _edit(),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('添加 WebDAV 服务器'),
        ),
      ],
    );
  }
}

class _DavEditDialog extends StatefulWidget {
  const _DavEditDialog({this.initial});
  final DavServer? initial;

  @override
  State<_DavEditDialog> createState() => _DavEditDialogState();
}

class _DavEditDialogState extends State<_DavEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.initial?.url ?? '',
  );
  late final TextEditingController _user = TextEditingController(
    text: widget.initial?.username ?? '',
  );
  late final TextEditingController _pass = TextEditingController(
    text: widget.initial?.password ?? '',
  );
  bool _obscure = true;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _url.text.trim();
    if (url.isEmpty) return;
    Navigator.of(context).pop(
      DavServer(
        id: widget.initial?.id ?? '',
        name: _name.text.trim(),
        url: url,
        username: _user.text.trim(),
        password: _pass.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.initial == null ? '添加 WebDAV 服务器' : '编辑 WebDAV 服务器'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '地址要指到 WebDAV 根（如 OpenList/AList 的 https://host:5244/dav）。',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '名称（可空，默认用主机名）'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _url,
                autofocus: widget.initial == null,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: 'https://host:5244/dav',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _user,
                decoration: const InputDecoration(labelText: '用户名（无认证可空）'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _pass,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: '密码',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 10),
              Text(
                '凭据与网盘 Cookie 一样只保存在本机并加密落盘，请勿在多设备共享的电脑上使用。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}


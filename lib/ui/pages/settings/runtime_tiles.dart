part of '../settings_page.dart';

class _MpvExtensionTile extends StatefulWidget {
  const _MpvExtensionTile();

  @override
  State<_MpvExtensionTile> createState() => _MpvExtensionTileState();
}

class _MpvExtensionTileState extends State<_MpvExtensionTile> {
  bool _loading = true;
  bool _installed = false;
  bool _busy = false;
  String? _error;
  MpvProgress? _progress;
  Map<String, String> _meta = const {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final installed = await MpvExtension.instance.isInstalled;
    final meta = await MpvExtension.instance.meta;
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _meta = meta;
      _loading = false;
    });
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = const MpvProgress(0, 0, '准备下载');
    });
    try {
      await MpvExtension.instance.install(
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Yaozhi MPV 扩展安装完成')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 Yaozhi MPV 扩展？'),
        content: const Text('只会删除本机下载的播放器文件，不影响订阅和播放记录。'),
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
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await MpvExtension.instance.remove();
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = _progress;
    final tag = _meta['tag'] ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.movie_filter_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Yaozhi MPV 扩展',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _installed
                              ? theme.colorScheme.primary.withValues(
                                  alpha: 0.12,
                                )
                              : theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _loading ? '检查中' : (_installed ? '已安装' : '未安装'),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: _installed
                                ? theme.colorScheme.primary
                                : theme.disabledColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _installed
                        ? '${tag.isEmpty ? '已下载' : tag} · 播放页可切换外部 MPV 窗口'
                        : '内置播放器已支持 HLS / MP4 / MKV；需要蓝光、HEVC 或 HDR 时可下载整合包（约 320 MB）',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.55,
                      ),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (_busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (_installed)
              TextButton(onPressed: _remove, child: const Text('删除'))
            else
              FilledButton.tonal(onPressed: _install, child: const Text('下载')),
          ],
        ),
        if (progress != null && _busy) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.fraction,
              minHeight: 5,
              backgroundColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${progress.stage}${progress.fraction == null ? '' : ' · ${(progress.fraction! * 100).toStringAsFixed(0)}%'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _JvmRuntimeTile extends StatefulWidget {
  const _JvmRuntimeTile({super.key});

  @override
  State<_JvmRuntimeTile> createState() => _JvmRuntimeTileState();
}

class _JvmRuntimeTileState extends State<_JvmRuntimeTile> {
  bool _loading = true;
  bool _installed = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    JvmRuntime.instance.progress.addListener(_onProgress);
    _refresh();
  }

  @override
  void dispose() {
    JvmRuntime.instance.progress.removeListener(_onProgress);
    super.dispose();
  }

  void _onProgress() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final installed = await JvmRuntime.instance.installed();
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _loading = false;
    });
  }

  Future<void> startInstall() async {
    if (_busy || _installed) return;
    await _install();
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await JvmRuntime.instance.ensureInstalled();
      await _refresh();
      if (!mounted) return;
      await AppScope.of(context).refreshJarReady();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('JVM 运行时安装完成，JAR 蜘蛛源已可用')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 JVM 运行时？'),
        content: const Text('只会删除本机下载的运行时文件，JAR 蜘蛛源下次使用时会重新下载。'),
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
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await JvmRuntime.instance.remove();
      await _refresh();
      if (!mounted) return;
      await AppScope.of(context).refreshJarReady();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = JvmRuntime.instance.progress.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.coffee_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'JVM 运行时',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _installed
                              ? theme.colorScheme.primary.withValues(
                                  alpha: 0.12,
                                )
                              : theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _loading ? '检查中' : (_installed ? '已安装' : '未安装'),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: _installed
                                ? theme.colorScheme.primary
                                : theme.disabledColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _installed
                        ? 'JAR / DEX 蜘蛛源可运行（JRE 17 + dex2jar）'
                        : '首次使用 .jar 蜘蛛时按需下载（约 85 MB），不占用安装包体积',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.55,
                      ),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (_busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (_installed)
              TextButton(onPressed: _remove, child: const Text('删除'))
            else
              FilledButton.tonal(onPressed: _install, child: const Text('下载')),
          ],
        ),
        if (_busy && progress != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.value,
              minHeight: 5,
              backgroundColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${progress.message}${progress.value == null ? '' : ' · ${(progress.value! * 100).toStringAsFixed(0)}%'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _ArmBridgeTile extends StatefulWidget {
  const _ArmBridgeTile({super.key});

  @override
  State<_ArmBridgeTile> createState() => _ArmBridgeTileState();
}

class _ArmBridgeTileState extends State<_ArmBridgeTile> {
  bool _loading = true;
  bool _installed = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    ArmBridgeRuntime.instance.progress.addListener(_onProgress);
    _refresh();
  }

  @override
  void dispose() {
    ArmBridgeRuntime.instance.progress.removeListener(_onProgress);
    super.dispose();
  }

  void _onProgress() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final installed = await ArmBridgeRuntime.instance.installed();
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _loading = false;
    });
  }

  Future<void> startInstall() async {
    if (_busy || _installed) return;
    await _install();
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ArmBridgeRuntime.instance.ensureInstalled();
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('加固壳支持已就绪，加固壳源首次调用会自动解包')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除加固壳支持？'),
        content: const Text(
          '只会删除 unidbg ARM 运行时；已解包的 payload 缓存会保留，缓存过的源仍可正常使用。',
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
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ArmBridgeRuntime.instance.remove();
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = ArmBridgeRuntime.instance.progress.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.shield_moon_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '加固壳支持',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _installed
                              ? theme.colorScheme.primary.withValues(
                                  alpha: 0.12,
                                )
                              : theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _loading ? '检查中' : (_installed ? '已安装' : '未安装'),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: _installed
                                ? theme.colorScheme.primary
                                : theme.disabledColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _installed
                        ? '加固壳（Guard / DexNative）源可解包（unidbg 0.9.9 · dynarmic）'
                        : '加固壳源首次调用时解包一次（约 39 MB），之后走纯 Java 快路径',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.55,
                      ),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (_busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (_installed)
              TextButton(onPressed: _remove, child: const Text('删除'))
            else
              FilledButton.tonal(onPressed: _install, child: const Text('下载')),
          ],
        ),
        if (_busy && progress != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.value,
              minHeight: 5,
              backgroundColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${progress.message}${progress.value == null ? '' : ' · ${(progress.value! * 100).toStringAsFixed(0)}%'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _PythonRuntimeTile extends StatefulWidget {
  const _PythonRuntimeTile({super.key});

  @override
  State<_PythonRuntimeTile> createState() => _PythonRuntimeTileState();
}

class _PythonRuntimeTileState extends State<_PythonRuntimeTile> {
  bool _loading = true;
  bool _installed = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    PyRuntime.instance.progress.addListener(_onProgress);
    _refresh();
  }

  @override
  void dispose() {
    PyRuntime.instance.progress.removeListener(_onProgress);
    super.dispose();
  }

  void _onProgress() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final installed = await PyRuntime.instance.installed();
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _loading = false;
    });
  }

  Future<void> startInstall() async {
    if (_busy || _installed) return;
    await _install();
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await PyRuntime.instance.ensureInstalled();
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Python 运行时安装完成，PY 蜘蛛源已可用')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 Python 运行时？'),
        content: const Text('只会删除本机下载的运行时文件，PY 蜘蛛源下次使用时会重新下载。'),
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
    if (ok != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await PyRuntime.instance.remove();
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = PyRuntime.instance.progress.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.terminal_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Python 运行时',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _installed
                              ? theme.colorScheme.primary.withValues(
                                  alpha: 0.12,
                                )
                              : theme.colorScheme.surfaceContainerHighest
                                    .withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _loading ? '检查中' : (_installed ? '已安装' : '未安装'),
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: _installed
                                ? theme.colorScheme.primary
                                : theme.disabledColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _installed
                        ? 'PY 蜘蛛源可运行（Python 3.11 + requests/lxml）'
                        : '首次使用 .py 蜘蛛时按需下载（约 20 MB），不占用安装包体积',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.55,
                      ),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (_busy)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (_installed)
              TextButton(onPressed: _remove, child: const Text('删除'))
            else
              FilledButton.tonal(onPressed: _install, child: const Text('下载')),
          ],
        ),
        if (_busy && progress != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.value,
              minHeight: 5,
              backgroundColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${progress.message}${progress.value == null ? '' : ' · ${(progress.value! * 100).toStringAsFixed(0)}%'}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// 订阅与源管理：本地导入 / 合并导出 / 备份恢复
// -----------------------------------------------------------------------------

Future<void> _importLocalJsonFile(BuildContext context) async {
  final app = AppScope.of(context);
  try {
    final path = await FileDialogService.pickFile(
      types: [FileDialogService.jsonType],
    );
    if (path == null) return;
    final payload = await LocalImportService.fromJsonFile(path);
    final outcome = await app.importFromLocalText(
      payload.text,
      name: payload.name,
    );
    if (!context.mounted) return;
    _settingsSnack(
      context,
      '已导入「${outcome.profile.name}」：${outcome.siteCount} 个站点',
    );
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '本地导入失败：$e');
  }
}

/// 本地 PY：单选 / 多选都会弹窗选择导入到已有订阅，或创建新订阅。
Future<void> _importLocalPyFiles(BuildContext context) async {
  final app = AppScope.of(context);
  try {
    final paths = await FileDialogService.pickFiles(
      types: [FileDialogService.pyType],
    );
    if (paths == null || paths.isEmpty) return;
    final sites = await LocalImportService.pySites(paths);
    if (!context.mounted) return;

    final target = await showPyImportTargetDialog(
      context,
      profiles: [
        for (final profile in app.profiles)
          if (!profile.isLiveOnly) profile,
      ],
      initialProfileId: app.activeProfile?.id,
      suggestedName: sites.length == 1
          ? sites.first['name'].toString()
          : '本地 PY 源',
      fileCount: sites.length,
    );
    if (target == null || !context.mounted) return;

    if (target.profileId != null) {
      final ok = await app.addSitesToProfile(target.profileId!, sites);
      if (!context.mounted) return;
      _settingsSnack(
        context,
        ok
            ? '已把 ${sites.length} 个 PY 源加入订阅「${target.name}」'
            : '目标订阅无法添加站点（可能不是 JSON 配置）',
      );
      return;
    }

    final outcome = await app.importFromLocalText(
      jsonEncode({'sites': sites}),
      name: target.name,
    );
    if (!context.mounted) return;
    _settingsSnack(
      context,
      '已创建订阅「${outcome.profile.name}」：${outcome.siteCount} 个站点',
    );
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '本地 PY 导入失败：$e');
  }
}

Future<void> _importLocalLive(BuildContext context) async {
  final app = AppScope.of(context);
  try {
    final path = await FileDialogService.pickFile(
      types: [FileDialogService.liveType],
    );
    if (path == null) return;
    final imported = await LocalLiveService.importFile(path);
    final url = LocalLiveService.fileUrlOfPath(imported.filePath);
    await app.addLocalLive(
      LiveBean(name: imported.name, api: url, type: '0', url: url, timeout: 15),
    );
    if (!context.mounted) return;
    _settingsSnack(context, '已导入本地直播源「${imported.name}」');
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '导入本地直播源失败：$e');
  }
}

Future<void> _importLocalPackage(
  BuildContext context, {
  bool zip = false,
}) async {
  final app = AppScope.of(context);
  try {
    final path = zip
        ? await FileDialogService.pickFile(types: [FileDialogService.zipType])
        : await FileDialogService.pickDirectory();
    if (path == null) return;
    final payload = zip
        ? await LocalImportService.fromPackageArchive(path)
        : await LocalImportService.fromPackage(path);
    final outcome = await app.importFromLocalText(
      payload.text,
      name: payload.name,
    );
    if (!context.mounted) return;
    _settingsSnack(
      context,
      '已导入本地包「${outcome.profile.name}」：${outcome.siteCount} 个站点',
    );
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '本地包导入失败：$e');
  }
}

Future<void> _importKazumiFromRepo(BuildContext context, AppState app) async {
  _settingsSnack(context, '正在获取 Kazumi 规则仓库…');
  List<Map<String, dynamic>> index;
  try {
    index = await app.sourceService.kazumi.fetchIndex();
  } catch (e) {
    if (context.mounted) {
      _settingsSnack(context, '获取 Kazumi 规则仓库失败：$e');
    }
    return;
  }
  if (!context.mounted) return;
  final installed = {for (final rule in app.kazumiRules) rule.name};
  final picked = await showDialog<Set<String>>(
    context: context,
    builder: (_) => _KazumiRulePickerDialog(rules: index, installed: installed),
  );
  if (picked == null || picked.isEmpty || !context.mounted) return;
  _settingsSnack(context, '正在下载 ${picked.length} 条规则…');
  final results = await Future.wait([
    for (final name in picked) _fetchKazumiRule(app, name),
  ]);
  final rules = <KazumiRule>[];
  var failed = 0;
  for (final rule in results) {
    if (rule == null) {
      failed++;
    } else {
      rules.add(rule);
    }
  }
  if (rules.isEmpty) {
    if (context.mounted) _settingsSnack(context, '规则下载失败，请检查网络后重试');
    return;
  }
  await app.importKazumiRules(rules);
  if (!context.mounted) return;
  _settingsSnack(
    context,
    '已导入 ${rules.length} 条 Kazumi 规则'
    '${failed > 0 ? '（$failed 条下载失败）' : ''}；到搜索页即可检索',
  );
}

Future<KazumiRule?> _fetchKazumiRule(AppState app, String name) async {
  try {
    return KazumiRule.fromJson(await app.sourceService.kazumi.fetchRule(name));
  } catch (e) {
    AppLog.w('kazumi', '规则 $name 下载失败', e);
    return null;
  }
}

Future<void> _importKazumiFile(BuildContext context, AppState app) async {
  try {
    final path = await FileDialogService.pickFile(
      types: [FileDialogService.jsonType],
      confirmButtonText: '导入 Kazumi 规则',
    );
    if (path == null) return;
    final text = await FileDialogService.readText(path);
    final decoded = jsonDecode(text);
    final maps = <Map<String, dynamic>>[];
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map) maps.add(Map<String, dynamic>.from(item));
      }
    } else if (decoded is Map) {
      maps.add(Map<String, dynamic>.from(decoded));
    }
    final rules = <KazumiRule>[];
    for (final map in maps) {
      final rule = KazumiRule.fromJson(map);
      if (rule.valid) rules.add(rule);
    }
    if (rules.isEmpty) {
      if (context.mounted) _settingsSnack(context, '没有识别到有效的 Kazumi 规则');
      return;
    }
    await app.importKazumiRules(rules);
    if (context.mounted) {
      _settingsSnack(context, '已导入 ${rules.length} 条 Kazumi 规则');
    }
  } catch (e) {
    if (context.mounted) _settingsSnack(context, '导入 Kazumi 规则失败：$e');
  }
}

Future<void> _deleteKazumiRule(
  BuildContext context,
  AppState app,
  KazumiRule rule,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除 Kazumi 规则'),
      content: Text('将移除「${rule.name}」这条动漫源；已下载的剧集缓存不受影响。'),
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
  if (ok != true) return;
  await app.removeKazumiRule(rule.key);
  if (context.mounted) {
    _settingsSnack(context, '已删除 Kazumi 规则「${rule.name}」');
  }
}


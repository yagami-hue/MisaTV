import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/errors/app_error.dart';
import '../../models/local_media.dart';
import '../../models/media_server.dart';
import '../../models/vod.dart';
import '../../services/file_dialog_service.dart';
import '../../services/media/local_media_service.dart';
import '../../services/media/media_server_service.dart';
import '../../state/app_state.dart';
import '../raw_play.dart';
import '../widgets/empty_state.dart';

/// 媒体库：Emby / Jellyfin 服务器 + 本地文件夹。
class MediaLibraryPage extends StatefulWidget {
  const MediaLibraryPage({super.key});

  @override
  State<MediaLibraryPage> createState() => _MediaLibraryPageState();
}

class _MediaLibraryPageState extends State<MediaLibraryPage> {
  bool _localTab = false;

  String? _serverId;
  String _libraryId = '';
  List<MediaLibrary> _libraries = const [];
  List<MediaItem> _items = const [];
  bool _loading = false;
  String _error = '';
  String _search = '';

  List<LocalMediaFile> _localFiles = const [];
  bool _scanning = false;
  String _localError = '';

  final TextEditingController _searchController = TextEditingController();

  bool _seeded = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    final app = AppScope.of(context);
    if (app.mediaServers.servers.isNotEmpty) {
      _openServer(app, app.mediaServers.servers.first);
    }
  }

  String _describe(Object error) {
    if (error is MediaServerException ||
        error is AppException ||
        error is FormatException) {
      return '$error';
    }
    return describeAppError(error).message;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openServer(AppState app, MediaServer server) async {
    setState(() {
      _serverId = server.id;
      _libraryId = '';
      _libraries = const [];
      _items = const [];
      _search = '';
      _searchController.clear();
      _loading = true;
      _error = '';
    });
    try {
      final libraries = await app.mediaServers.libraries(server);
      if (!mounted || _serverId != server.id) return;
      setState(() => _libraries = libraries);
      final first = libraries.isNotEmpty ? libraries.first.id : '';
      await _loadItems(app, server, parentId: first);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _describe(e);
      });
    }
  }

  Future<void> _loadItems(
    AppState app,
    MediaServer server, {
    required String parentId,
    String search = '',
  }) async {
    setState(() {
      if (search.isEmpty) _libraryId = parentId;
      _loading = true;
      _error = '';
    });
    try {
      final items = await app.mediaServers.items(
        server,
        parentId: parentId,
        search: search,
      );
      if (!mounted || _serverId != server.id) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _describe(e);
      });
    }
  }

  Future<void> _openSeries(AppState app, MediaServer server, MediaItem series) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final episodes = await app.mediaServers.episodes(server, series.id);
      if (!mounted) return;
      setState(() => _loading = false);
      if (episodes.isEmpty) {
        _toast('这部剧还没有可播放的集');
        return;
      }
      final picked = await showModalBottomSheet<MediaItem>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.78,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(series.name),
                  subtitle: Text('${episodes.length} 集'),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView.builder(
                    itemCount: episodes.length,
                    itemBuilder: (context, index) {
                      final episode = episodes[index];
                      return ListTile(
                        dense: true,
                        title: Text(_episodeTitle(episode)),
                        subtitle: episode.played
                            ? const Text('已看完')
                            : (episode.positionMs > 0
                                  ? Text('上次看到 ${_durationText(episode.positionMs)}')
                                  : null),
                        onTap: () => Navigator.of(ctx).pop(episode),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (picked == null || !mounted) return;
      await _play(app, server, picked, siblings: episodes, title: series.name);
    } catch (e) {
      if (!mounted) return;
      // 读剧集失败不应该把整个媒体库页面变成错误页，提示一下即可。
      setState(() => _loading = false);
      _toast('读取剧集失败：${_describe(e)}');
    }
  }

  Future<void> _play(
    AppState app,
    MediaServer server,
    MediaItem item, {
    List<MediaItem>? siblings,
    String? title,
  }) async {
    final list = (siblings ?? [item]).where((e) => e.isPlayable).toList();
    if (list.isEmpty) {
      _toast('该条目没有可播放的媒体');
      return;
    }
    final index = list.indexWhere((e) => e.id == item.id);
    final episodes = [
      for (final entry in list)
        Episode(
          name: _episodeTitle(entry),
          url: app.mediaServers.streamUrl(server, entry),
        ),
    ];
    await openRawPlayback(
      context,
      title: title ?? item.seriesName.ifEmpty(item.name),
      subtitle: '${server.kind.label} · ${server.name}',
      episodes: episodes,
      initialIndex: index < 0 ? 0 : index,
      sourceKey: 'media:${server.id}',
      flag: server.name,
    );
  }

  Future<void> _scanLocal(AppState app) async {
    setState(() {
      _scanning = true;
      _localError = '';
    });
    try {
      final files = await app.localMedia.scan();
      if (!mounted) return;
      setState(() {
        _localFiles = files;
        _scanning = false;
        _localError = app.localMedia.error;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _localError = '$e';
      });
    }
  }

  Future<void> _addLocalDir(AppState app) async {
    final dir = await FileDialogService.pickDirectory();
    if (dir == null || !mounted) return;
    try {
      await app.addLocalMediaDir(dir);
      await _scanLocal(app);
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _playLocal(int index) async {
    final files = _localFiles;
    if (files.isEmpty) return;
    final episodes = <Episode>[];
    final positions = <int>[];
    for (var i = 0; i < files.length; i++) {
      final url = localMediaPlayUrl(files[i].path);
      if (url.isEmpty) continue;
      positions.add(i);
      episodes.add(Episode(name: files[i].name, url: url));
    }
    if (episodes.isEmpty) {
      _toast('本地播放中继未启动，无法播放');
      return;
    }
    final initial = positions.indexOf(index);
    await openRawPlayback(
      context,
      title: '本地视频',
      subtitle: '${files.length} 个视频',
      episodes: episodes,
      initialIndex: initial < 0 ? 0 : initial,
      sourceKey: 'local-media',
      flag: '本地',
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    final servers = app.mediaServers.servers;
    MediaServer? server;
    for (final item in servers) {
      if (item.id == _serverId) {
        server = item;
        break;
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: _localTab
            ? const Text('本地视频')
            : (server == null ? const Text('媒体库') : Text(server.name)),
        actions: [
          if (!_localTab && server != null)
            IconButton(
              tooltip: '返回服务器列表',
              onPressed: () => setState(() {
                _serverId = null;
                _items = const [];
                _libraries = const [];
              }),
              icon: const Icon(Icons.dns_outlined),
            ),
          if (_localTab)
            IconButton(
              tooltip: '添加文件夹',
              onPressed: () => _addLocalDir(app),
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
          if (!_localTab)
            IconButton(
              tooltip: '添加服务器',
              onPressed: () => _editServer(app),
              icon: const Icon(Icons.add_rounded),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('媒体服务器'),
                  icon: Icon(Icons.dns_outlined, size: 18),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('本地视频'),
                  icon: Icon(Icons.folder_outlined, size: 18),
                ),
              ],
              selected: {_localTab},
              onSelectionChanged: (value) {
                final local = value.first;
                setState(() => _localTab = local);
                if (local && _localFiles.isEmpty && !_scanning) {
                  _scanLocal(app);
                }
              },
            ),
          ),
        ),
      ),
      body: _localTab
          ? _buildLocal(app, theme)
          : _buildServers(app, theme, servers, server),
    );
  }

  Widget _buildServers(
    AppState app,
    ThemeData theme,
    List<MediaServer> servers,
    MediaServer? server,
  ) {
    if (server == null) {
      if (servers.isEmpty) {
        return EmptyState(
          icon: Icons.dns_outlined,
          title: '还没有媒体服务器',
          message: '支持 Emby 与 Jellyfin：填写服务器地址与 API Key 后即可浏览、'
              '搜索并原画直通播放。',
          action: FilledButton.icon(
            onPressed: () => _editServer(app),
            icon: const Icon(Icons.add_rounded),
            label: const Text('添加服务器'),
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          for (final item in servers)
            Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 10),
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.4,
              ),
              child: ListTile(
                leading: Icon(
                  Icons.dns_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: Text(item.name),
                subtitle: Text(
                  '${item.kind.label} · ${item.baseUrl}'
                  '${item.userName.isEmpty ? '' : ' · ${item.userName}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') _editServer(app, item);
                    if (value == 'delete') _deleteServer(app, item);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
                onTap: () => _openServer(app, item),
              ),
            ),
        ],
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: '读取失败',
        message: _error,
        action: FilledButton.tonalIcon(
          onPressed: () => _openServer(app, server),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重试'),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              hintText: '搜索媒体库',
              border: const OutlineInputBorder(),
              suffixIcon: _search.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _search = '');
                        _loadItems(app, server, parentId: _libraryId);
                      },
                    ),
            ),
            onSubmitted: (value) {
              _search = value.trim();
              _loadItems(
                app,
                server,
                parentId: _search.isEmpty ? _libraryId : '',
                search: _search,
              );
            },
          ),
        ),
        if (_libraries.isNotEmpty && _search.isEmpty)
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _libraries.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final library = _libraries[index];
                return ChoiceChip(
                  label: Text(library.name),
                  selected: library.id == _libraryId,
                  onSelected: (_) => _loadItems(
                    app,
                    server,
                    parentId: library.id,
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 4),
        Expanded(
          child: _items.isEmpty
              ? const EmptyState(
                  icon: Icons.movie_outlined,
                  title: '这个媒体库是空的',
                  message: '换个媒体库，或用上方搜索。',
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 160,
                    childAspectRatio: 0.60,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (context, index) {
                    final item = _items[index];
                    final image = app.mediaServers.imageUrl(server, item);
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        if (item.isSeries) {
                          _openSeries(app, server, item);
                        } else {
                          _play(
                            app,
                            server,
                            item,
                            siblings: _items.where((e) => e.isPlayable).toList(),
                          );
                        }
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: image.isEmpty
                                  ? _PosterPlaceholder(theme: theme)
                                  : Image.network(
                                      image,
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      errorBuilder: (_, _, _) =>
                                          _PosterPlaceholder(theme: theme),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                          if (item.subtitle.isNotEmpty)
                            Text(
                              item.subtitle,
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
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildLocal(AppState app, ThemeData theme) {
    final dirs = app.localMedia.dirs;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        Text(
          '扫描本机文件夹里的视频，用内置播放器或外部播放器打开。'
          '文件不会被移动或转码。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
          ),
        ),
        const SizedBox(height: 12),
        if (dirs.isEmpty)
          Text(
            '还没有添加文件夹。点右上角「新建文件夹」图标选择目录。',
            style: theme.textTheme.bodySmall,
          )
        else
          for (final dir in dirs)
            Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 8),
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.35,
              ),
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.folder_outlined, size: 20),
                title: Text(
                  dir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: '移除',
                  onPressed: () async {
                    await app.removeLocalMediaDir(dir);
                    setState(() {
                      _localFiles = [
                        for (final file in _localFiles)
                          if (!file.path.startsWith(dir)) file,
                      ];
                    });
                  },
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ),
            ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _scanning ? null : () => _scanLocal(app),
              icon: _scanning
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: Text(_scanning ? '扫描中…' : '扫描文件夹'),
            ),
            const SizedBox(width: 12),
            Text(
              '${_localFiles.length} 个视频',
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
        if (_localError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _localError,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        const SizedBox(height: 8),
        if (_localFiles.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: EmptyState(
              icon: Icons.video_library_outlined,
              title: '没有扫描到视频',
              message: '支持 mp4 / mkv / avi / ts / rmvb 等常见格式。',
            ),
          )
        else
          for (var i = 0; i < _localFiles.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.movie_outlined, size: 20),
              title: Text(
                _localFiles[i].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_localFiles[i].subtitle} · '
                '${_sizeText(_localFiles[i].size)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _playLocal(i),
            ),
      ],
    );
  }

  Future<void> _deleteServer(AppState app, MediaServer server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${server.name}」？'),
        content: const Text('只删除本机保存的服务器配置，不影响服务器上的数据。'),
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
    await app.removeMediaServer(server.id);
    if (!mounted) return;
    setState(() {
      if (_serverId == server.id) {
        _serverId = null;
        _items = const [];
        _libraries = const [];
      }
    });
  }

  Future<void> _editServer(AppState app, [MediaServer? existing]) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final url = TextEditingController(text: existing?.baseUrl ?? '');
    final key = TextEditingController(text: existing?.apiKey ?? '');
    final user = TextEditingController(text: existing?.userId ?? '');
    var kind = existing?.kind ?? MediaServerKind.jellyfin;
    String testResult = '';
    var testing = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          MediaServer draft() => MediaServer(
            id: existing?.id ?? '',
            kind: kind,
            name: name.text.trim(),
            baseUrl: url.text.trim(),
            apiKey: key.text.trim(),
            userId: user.text.trim(),
          );
          return AlertDialog(
            title: Text(existing == null ? '添加媒体服务器' : '编辑媒体服务器'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SegmentedButton<MediaServerKind>(
                      segments: [
                        for (final item in MediaServerKind.values)
                          ButtonSegment(
                            value: item,
                            label: Text(item.label),
                          ),
                      ],
                      selected: {kind},
                      onSelectionChanged: (value) =>
                          setState(() => kind = value.first),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(
                        labelText: '名称（可留空）',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: url,
                      decoration: const InputDecoration(
                        labelText: '服务器地址',
                        hintText: 'http://192.168.1.10:8096',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: key,
                      obscureText: false,
                      decoration: const InputDecoration(
                        labelText: 'API Key',
                        hintText: '在服务器控制台创建的 API 密钥',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: user,
                      decoration: const InputDecoration(
                        labelText: '用户 ID（可选）',
                        hintText: '填了才会按用户维度显示媒体库与已看进度',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton.tonal(
                          onPressed: testing
                              ? null
                              : () async {
                                  setState(() {
                                    testing = true;
                                    testResult = '正在连接…';
                                  });
                                  try {
                                    final info = await app.mediaServers.test(
                                      draft(),
                                    );
                                    setState(() {
                                      testResult =
                                          '连接成功：${info.name.isEmpty ? kind.label : info.name}'
                                          '${info.version.isEmpty ? '' : ' · ${info.version}'}';
                                    });
                                  } catch (e) {
                                    setState(
                                      () => testResult = '连接失败：${_describe(e)}',
                                    );
                                  } finally {
                                    setState(() => testing = false);
                                  }
                                },
                          child: const Text('测试连接'),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            testResult,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(ctx).textTheme.labelSmall,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
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
    final draft = MediaServer(
      id: existing?.id ?? '',
      kind: kind,
      name: name.text.trim(),
      baseUrl: url.text.trim(),
      apiKey: key.text.trim(),
      userId: user.text.trim(),
    );
    name.dispose();
    url.dispose();
    key.dispose();
    user.dispose();
    if (saved != true || !mounted) return;
    try {
      final server = await app.saveMediaServer(draft);
      if (!mounted) return;
      await _openServer(app, server);
    } catch (e) {
      _toast('保存失败：${_describe(e)}');
    }
  }

  static String _episodeTitle(MediaItem item) {
    if (item.kind == 'Episode') {
      final season = item.seasonNumber.toString().padLeft(2, '0');
      final episode = item.episodeNumber.toString().padLeft(2, '0');
      return 'S$season E$episode · ${item.name}';
    }
    return item.name;
  }

  static String _durationText(int ms) {
    final total = (ms / 1000).round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int value) => value.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }

  static String _sizeText(int size) {
    if (size <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = size.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final text = value >= 100 || unit == 0
        ? value.round().toString()
        : value.toStringAsFixed(1);
    return '$text ${units[unit]}';
  }
}

class _PosterPlaceholder extends StatelessWidget {
  const _PosterPlaceholder({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          size: 28,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}

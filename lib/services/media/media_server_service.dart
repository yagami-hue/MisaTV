import 'dart:convert';

import '../../models/media_server.dart';
import '../../core/errors/app_error.dart';
import '../../core/net/app_http.dart';
import '../local_store.dart';

/// Emby / Jellyfin 操作失败（消息直接上屏）。
class MediaServerException implements Exception {
  MediaServerException(this.message);
  final String message;
  @override
  String toString() => message;
}

class MediaServerInfo {
  const MediaServerInfo({this.name = '', this.version = '', this.id = ''});
  final String name;
  final String version;
  final String id;
}

/// Emby / Jellyfin 服务器管理 + 浏览 / 搜索 / 播放地址。
///
/// 两者 API 同源：用 `X-Emby-Token` 认证，`/Items` 列条目，
/// `/Videos/{id}/stream?static=true` 直接取原始文件（原画直通，不经转码）。
class MediaServerService {
  MediaServerService(this._store, this._http);

  final LocalStore _store;
  final AppHttp _http;
  List<MediaServer> _servers = const [];

  List<MediaServer> get servers => List.unmodifiable(_servers);
  bool get hasServers => _servers.isNotEmpty;

  void load() {
    _servers = _store.loadMediaServers();
  }

  MediaServer? byId(String id) {
    for (final server in _servers) {
      if (server.id == id) return server;
    }
    return null;
  }

  Future<MediaServer> save(MediaServer server) async {
    final base = _normalizeBase(server.baseUrl);
    if (base.isEmpty) throw MediaServerException('请填写服务器地址');
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(base)) {
      throw MediaServerException('服务器地址需以 http:// 或 https:// 开头');
    }
    var name = server.name.trim();
    if (name.isEmpty) {
      try {
        name = Uri.parse(base).host;
      } catch (_) {
        name = server.kind.label;
      }
    }
    final saved = MediaServer(
      id: server.id.trim().isEmpty
          ? 'media-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          : server.id.trim(),
      kind: server.kind,
      name: name,
      baseUrl: base,
      apiKey: server.apiKey.trim(),
      userId: server.userId.trim(),
      userName: server.userName.trim(),
    );
    _servers = [
      for (final item in _servers)
        if (item.id != saved.id) item,
      saved,
    ];
    await _store.saveMediaServers(_servers);
    return saved;
  }

  Future<void> remove(String id) async {
    _servers = _servers.where((s) => s.id != id).toList();
    await _store.saveMediaServers(_servers);
  }

  /// 连通性测试（`/System/Info`）。
  Future<MediaServerInfo> test(MediaServer server) async {
    final data = await _get(server, '/System/Info');
    return MediaServerInfo(
      name: (data['ServerName'] ?? data['Name'] ?? '').toString(),
      version: (data['Version'] ?? '').toString(),
      id: (data['Id'] ?? '').toString(),
    );
  }

  /// 媒体库列表。
  Future<List<MediaLibrary>> libraries(MediaServer server) async {
    final userId = server.userId.trim();
    if (userId.isNotEmpty) {
      final data = await _get(server, '/Users/$userId/Views');
      return _itemsOf(data).map(MediaLibrary.fromJson).toList();
    }
    try {
      final data = await _get(server, '/Library/MediaFolders');
      final list = _itemsOf(data).map(MediaLibrary.fromJson).toList();
      if (list.isNotEmpty) return list;
    } catch (_) {
      // API Key 没有管理权限时回落到通用 Items 查询。
    }
    final data = await _get(
      server,
      '/Items',
      query: const {
        'Recursive': 'true',
        'IncludeItemTypes': 'CollectionFolder',
        'Fields': 'CollectionType',
      },
    );
    return _itemsOf(data).map(MediaLibrary.fromJson).toList();
  }

  /// 列出条目。[parentId] 为空 = 根。
  Future<List<MediaItem>> items(
    MediaServer server, {
    String parentId = '',
    String search = '',
    String includeTypes = 'Movie,Series,Video,BoxSet',
    String sortBy = 'SortName',
    int limit = 200,
  }) async {
    final userId = server.userId.trim();
    final path = userId.isEmpty ? '/Items' : '/Users/$userId/Items';
    final query = <String, String>{
      'Recursive': 'true',
      'IncludeItemTypes': includeTypes,
      'Fields': 'Overview,ProductionYear,PrimaryImageAspectRatio,ImageTags',
      'SortBy': sortBy,
      'SortOrder': 'Ascending',
      'Limit': '$limit',
      'ImageTypeLimit': '1',
      'EnableImageTypes': 'Primary',
      if (parentId.trim().isNotEmpty) 'ParentId': parentId.trim(),
      if (search.trim().isNotEmpty) 'SearchTerm': search.trim(),
    };
    final data = await _get(server, path, query: query);
    return _itemsOf(data).map(MediaItem.fromJson).toList();
  }

  /// 剧集的单集列表（按季 / 集号排序）。
  Future<List<MediaItem>> episodes(MediaServer server, String seriesId) async {
    final userId = server.userId.trim();
    final path = userId.isEmpty ? '/Items' : '/Users/$userId/Items';
    final data = await _get(
      server,
      path,
      query: {
        'ParentId': seriesId,
        'Recursive': 'true',
        'IncludeItemTypes': 'Episode',
        'Fields': 'Overview,ProductionYear,ImageTags',
        'SortBy': 'ParentIndexNumber,IndexNumber',
        'SortOrder': 'Ascending',
        'Limit': '500',
        'ImageTypeLimit': '1',
        'EnableImageTypes': 'Primary',
      },
    );
    return _itemsOf(data).map(MediaItem.fromJson).toList();
  }

  /// 海报地址（没有主图返回空串）。
  String imageUrl(MediaServer server, MediaItem item, {int width = 360}) {
    if (item.imageTag.isEmpty || item.id.isEmpty) return '';
    final base = _normalizeBase(server.baseUrl);
    final query = Uri(
      queryParameters: {
        'maxWidth': '$width',
        'tag': item.imageTag,
        if (server.apiKey.isNotEmpty) 'api_key': server.apiKey,
      },
    ).query;
    return '$base/Items/${Uri.encodeComponent(item.id)}/Images/Primary?$query';
  }

  /// 原画直通地址（`static=true` 让服务器不转码）。
  String streamUrl(MediaServer server, MediaItem item) {
    final base = _normalizeBase(server.baseUrl);
    final query = Uri(
      queryParameters: {
        'static': 'true',
        'mediaSourceId': item.id,
        if (server.apiKey.isNotEmpty) 'api_key': server.apiKey,
      },
    ).query;
    return '$base/Videos/${Uri.encodeComponent(item.id)}/stream?$query';
  }

  Future<Map<String, dynamic>> _get(
    MediaServer server,
    String path, {
    Map<String, String>? query,
  }) async {
    final base = _normalizeBase(server.baseUrl);
    if (base.isEmpty) throw MediaServerException('服务器地址为空');
    final uri = Uri.parse('$base$path').replace(
      queryParameters: query == null || query.isEmpty ? null : query,
    );
    final headers = <String, String>{
      'Accept': 'application/json',
      if (server.apiKey.isNotEmpty) 'X-Emby-Token': server.apiKey,
    };
    try {
      final res = await _http.getText(
        uri.toString(),
        headers: headers,
        timeout: const Duration(seconds: 12),
      );
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw MediaServerException('认证失败：请检查 API Key（HTTP ${res.statusCode}）');
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw MediaServerException('服务器返回 HTTP ${res.statusCode}');
      }
      final decoded = _decodeJson(res.body);
      if (decoded == null) throw MediaServerException('服务器返回的不是合法 JSON');
      return decoded;
    } on MediaServerException {
      rethrow;
    } catch (e) {
      throw MediaServerException(describeAppError(e).message);
    }
  }

  static Map<String, dynamic>? _decodeJson(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 非 JSON 应答（错误页 / 反向代理 HTML）统一按格式错误处理。
    }
    return null;
  }

  static List<Map<String, dynamic>> _itemsOf(Map<String, dynamic> data) {
    final raw = data['Items'] ?? data['items'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  static String _normalizeBase(String raw) =>
      raw.trim().replaceAll(RegExp(r'/+$'), '');
}

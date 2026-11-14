import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../models/dav.dart';
import '../local_store.dart';
import 'dav.dart';

/// WebDAV 操作失败（消息直接上屏）。
class DavException implements Exception {
  DavException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// WebDAV 存储服务：服务器管理 + 目录浏览（PROPFIND）+ 同步文件读写。
///
/// 播放不走这里（由 `/play` 中继 + `dav` 参数注入 Authorization 取流）；
/// [getText] / [putText] 只给「多端同步」读写一份 JSON 用。
class DavService {
  DavService(this._store);

  final LocalStore _store;
  List<DavServer> _servers = const [];

  List<DavServer> get servers => List.unmodifiable(_servers);
  bool get hasServers => _servers.isNotEmpty;

  void load() {
    _servers = _store.loadDavServers();
  }

  DavServer? byId(String id) {
    for (final server in _servers) {
      if (server.id == id) return server;
    }
    return null;
  }

  /// 保存（id 为空 = 新建）；返回落库后的条目（含新 id）。
  Future<DavServer> save(DavServer server) async {
    final url = normalizeDavBase(server.url);
    if (url.isEmpty) throw DavException('请填写服务器地址');
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
      throw DavException('服务器地址需以 http:// 或 https:// 开头');
    }
    var name = server.name.trim();
    if (name.isEmpty) {
      try {
        name = Uri.parse(url).host;
      } catch (_) {
        name = 'WebDAV';
      }
    }
    final saved = DavServer(
      id: server.id.trim().isEmpty
          ? 'dav-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          : server.id.trim(),
      name: name,
      url: url,
      username: server.username.trim(),
      password: server.password,
    );
    _servers = [
      for (final item in _servers)
        if (item.id != saved.id) item,
      saved,
    ];
    await _store.saveDavServers(_servers);
    return saved;
  }

  Future<void> remove(String id) async {
    _servers = _servers.where((s) => s.id != id).toList();
    await _store.saveDavServers(_servers);
  }

  /// `/play` 中继用：该服务器的 Authorization 头值（不存在/无凭据 → 空串）。
  String authHeader(String id) {
    final server = byId(id);
    if (server == null) return '';
    return davBasicAuth(server.username, server.password);
  }

  /// 读取远端文本文件；文件不存在返回 null（首次同步很常见）。
  Future<String?> getText(String id, String path) async {
    final server = byId(id);
    if (server == null) throw DavException('该 WebDAV 服务器不存在（可能已被删除）');
    final target = davJoin(normalizeDavBase(server.url), path);
    final auth = davBasicAuth(server.username, server.password);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(target));
      if (auth.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, auth);
      }
      final res = await req.close();
      final status = res.statusCode;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
      }
      if (status == 404) return null;
      if (status == 401) {
        throw DavException('认证失败（HTTP 401）：请检查用户名与密码');
      }
      if (status < 200 || status >= 300) {
        throw DavException('读取同步文件失败（HTTP $status）');
      }
      return utf8.decode(builder.takeBytes(), allowMalformed: true);
    } on DavException {
      rethrow;
    } on SocketException catch (e) {
      throw DavException('连接服务器失败：${e.message}');
    } on HttpException catch (e) {
      throw DavException('请求失败：${e.message}');
    } catch (e) {
      throw DavException('请求失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  /// 写入远端文本文件（覆盖）；父目录不存在时先 MKCOL。
  Future<void> putText(String id, String path, String text) async {
    final server = byId(id);
    if (server == null) throw DavException('该 WebDAV 服务器不存在（可能已被删除）');
    final base = normalizeDavBase(server.url);
    final auth = davBasicAuth(server.username, server.password);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      await _ensureCollections(client, base, path, auth);
      final req = await client.openUrl('PUT', Uri.parse(davJoin(base, path)));
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      if (auth.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, auth);
      }
      final body = utf8.encode(text);
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close();
      await res.drain<void>();
      final status = res.statusCode;
      if (status == 401) {
        throw DavException('认证失败（HTTP 401）：请检查用户名与密码');
      }
      if (status < 200 || status >= 300) {
        throw DavException('写入同步文件失败（HTTP $status）');
      }
    } on DavException {
      rethrow;
    } on SocketException catch (e) {
      throw DavException('连接服务器失败：${e.message}');
    } on HttpException catch (e) {
      throw DavException('请求失败：${e.message}');
    } catch (e) {
      throw DavException('请求失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  /// 逐级创建父集合（已存在时服务器回 405，忽略即可）。
  Future<void> _ensureCollections(
    HttpClient client,
    String base,
    String path,
    String auth,
  ) async {
    final segments = path
        .split('/')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (segments.length < 2) return;
    for (var i = 1; i < segments.length; i++) {
      final dir = '/${segments.take(i).join('/')}';
      try {
        final req = await client.openUrl(
          'MKCOL',
          Uri.parse(davJoin(base, dir)),
        );
        if (auth.isNotEmpty) {
          req.headers.set(HttpHeaders.authorizationHeader, auth);
        }
        req.contentLength = 0;
        final res = await req.close();
        await res.drain<void>();
      } catch (_) {
        // 单级创建失败（多半是已存在）不阻断后续 PUT；真正失败由 PUT 报错。
      }
    }
  }

  /// 列目录（path 省略 = 根）。
  Future<DavBrowseResult> browse(String id, {String path = '/'}) async {
    final server = byId(id);
    if (server == null) throw DavException('该 WebDAV 服务器不存在（可能已被删除）');
    final base = normalizeDavBase(server.url);
    final target = davJoin(base, path);
    final auth = davBasicAuth(server.username, server.password);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.openUrl('PROPFIND', Uri.parse(target));
      req.headers.set('Depth', '1');
      req.headers.set('Content-Type', 'application/xml; charset=utf-8');
      if (auth.isNotEmpty) req.headers.set(HttpHeaders.authorizationHeader, auth);
      req.add(utf8.encode(propfindBody));
      final res = await req.close();
      final status = res.statusCode;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
      }
      final text = utf8.decode(builder.takeBytes(), allowMalformed: true);
      if (status != 207 && status != 200) {
        if (status == 401) {
          throw DavException('认证失败（HTTP 401）：请检查用户名与密码');
        }
        throw DavException('服务器返回 HTTP $status（WebDAV 需返回 207 Multi-Status；请确认地址指向 /dav）');
      }
      final raw = parsePropfind(text);
      if (raw.isEmpty) throw DavException('未解析到目录内容（可能是地址不对，或需要用户名/密码）');

      final wantPath = hrefToPath(target, base);
      final basePath = davBasePath(base);
      final self = stripDavBase(wantPath, basePath).replaceAll(RegExp(r'/+$'), '');
      final current = self.isEmpty ? '/' : self;
      final entries = <DavEntry>[];
      for (final item in raw) {
        final decoded = hrefToPath(item.href, base);
        if (decoded.isEmpty) continue;
        final rel = stripDavBase(decoded, basePath);
        final norm = rel.replaceAll(RegExp(r'/+$'), '');
        // 去掉 PROPFIND 自身（集合本身）那一行。
        if ((norm.isEmpty ? '/' : norm) == current) continue;
        final fallbackName = norm.isEmpty ? '' : norm.substring(norm.lastIndexOf('/') + 1);
        final name = item.displayName.isNotEmpty ? item.displayName : fallbackName;
        if (name.isEmpty) continue;
        String url;
        try {
          url = Uri.parse('$base/').resolve(item.href.trim()).toString();
        } catch (_) {
          continue;
        }
        entries.add(
          DavEntry(
            name: name,
            path: norm.isEmpty ? '/' : norm,
            url: url,
            isDir: item.isDir,
            size: item.size,
            mtime: item.mtime,
          ),
        );
      }
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return DavBrowseResult(path: current, entries: entries);
    } on DavException {
      rethrow;
    } on SocketException catch (e) {
      throw DavException('连接服务器失败：${e.message}');
    } on HttpException catch (e) {
      throw DavException('请求失败：${e.message}');
    } catch (e) {
      throw DavException('请求失败：$e');
    } finally {
      client.close(force: true);
    }
  }
}

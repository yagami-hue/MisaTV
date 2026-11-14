import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/logging/app_log.dart';
import '../party/party_room.dart';
import '../sync/sync_bundle.dart';

/// 局域网同步服务：给同一网络的其他设备提供「同步包」与「一起看」房间。
///
/// 安全边界：
///   · 只监听 IPv4（`0.0.0.0`），不做公网映射；
///   · `/sync` 必须带配对码（[token]），否则 403；
///   · `/party` 必须带房间码，房间码只在房主界面上显示；
///   · 不做 CORS，网页无法跨站读取响应（配合 `/sync` 的配对码形成双重门槛）。
class LanServer {
  LanServer({
    required this.deviceName,
    required this.token,
    required this.snapshot,
    required this.apply,
  });

  static const int defaultPort = 9979;

  final String Function() deviceName;
  final String Function() token;
  final SyncBundle Function() snapshot;
  final Future<SyncMergeReport> Function(SyncBundle) apply;

  /// 「一起看」房间（同一进程的房主直接读写这个对象）。
  final PartyRoom party = PartyRoom();

  HttpServer? _server;
  int _port = 0;
  int _lastSyncAt = 0;

  bool get running => _server != null;
  int get port => _port;
  int get lastSyncAt => _lastSyncAt;

  /// 启动服务；[port] 为 0 或端口被占用时只尝试默认端口并回落到临时端口。
  Future<int> start({int port = defaultPort}) async {
    final existing = _server;
    if (existing != null) return _port;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    _port = server.port;
    server.listen(_handle, onError: (Object e) {
      AppLog.w('lan', '局域网服务连接异常：$e');
    });
    AppLog.i('lan', '局域网同步服务已启动：0.0.0.0:$_port');
    return _port;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _port = 0;
    party.clear();
    if (server != null) {
      await server.close(force: true);
      AppLog.i('lan', '局域网同步服务已停止');
    }
  }

  /// 本机的局域网 IPv4 地址（用于界面展示，不含回环）。
  Future<List<String>> lanAddresses() async {
    final out = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final item in interfaces) {
        for (final address in item.addresses) {
          if (address.isLoopback) continue;
          if (!out.contains(address.address)) out.add(address.address);
        }
      }
    } catch (_) {
      // 拿不到网卡列表时只展示 127.0.0.1。
    }
    if (out.isEmpty) out.add('127.0.0.1');
    return out;
  }

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    final path = request.uri.path;
    try {
      if (request.method != 'GET' && request.method != 'POST') {
        return await _json(res, 405, {'error': 'method not allowed'});
      }
      if (path == '/ping') {
        return await _json(res, 200, {
          'app': 'MisaTV',
          'name': deviceName(),
          'schemaVersion': SyncBundle.schemaVersion,
          'party': party.open,
        });
      }
      if (path == '/sync') {
        if (token().isNotEmpty && !_tokenMatches(request)) {
          return await _json(res, 403, {'error': '配对码不正确'});
        }
        if (request.method == 'GET') {
          return await _json(res, 200, snapshot().toJson());
        }
        final body = await _readJson(request);
        if (body == null) {
          return await _json(res, 400, {'error': '同步包无法解析'});
        }
        final bundle = SyncBundle.fromJson(body);
        final report = await apply(bundle);
        _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
        return await _json(res, 200, {
          'ok': true,
          'report': {
            'device': bundle.deviceName,
            'history': report.historyAccepted,
            'favorites': report.favoritesChanged,
            'skips': report.skipsChanged,
          },
          'bundle': snapshot().toJson(),
        });
      }
      if (path == '/party') {
        final code = (request.uri.queryParameters['code'] ?? '').trim();
        if (!party.open || code.isEmpty || code != party.code) {
          return await _json(res, 403, {'error': '房间不存在或房间码不正确'});
        }
        return await _json(res, 200, party.toJson());
      }
      return await _json(res, 404, {'error': 'not found'});
    } catch (e) {
      AppLog.w('lan', '处理 ${request.method} $path 失败', e);
      return await _json(res, 500, {'error': '$e'});
    }
  }

  bool _tokenMatches(HttpRequest request) {
    final provided =
        (request.uri.queryParameters['token'] ??
                request.headers.value('x-sync-token') ??
                '')
            .trim();
    final expected = token().trim();
    if (provided.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ provided.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<Map<String, dynamic>?> _readJson(HttpRequest request) async {
    const maxBytes = 4 * 1024 * 1024;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > maxBytes) return null;
    }
    if (builder.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _json(
    HttpResponse res,
    int status,
    Map<String, dynamic> body,
  ) async {
    res.statusCode = status;
    res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
    res.headers.set('Cache-Control', 'no-store');
    final bytes = utf8.encode(jsonEncode(body));
    res.contentLength = bytes.length;
    res.add(bytes);
    await res.close();
  }
}

/// 局域网客户端（观众 / 对端设备）。直连，不走系统代理。
class LanClient {
  LanClient._();

  static Future<Map<String, dynamic>> getJson(
    String url, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join();
      final decoded = jsonDecode(text);
      if (decoded is! Map) throw StateError('应答不是 JSON 对象');
      return Map<String, dynamic>.from(decoded);
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> postJson(
    String url,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final req = await client.postUrl(Uri.parse(url));
      req.headers.contentType = ContentType.json;
      final bytes = utf8.encode(jsonEncode(body));
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join();
      final decoded = jsonDecode(text);
      if (decoded is! Map) throw StateError('应答不是 JSON 对象');
      return Map<String, dynamic>.from(decoded);
    } finally {
      client.close(force: true);
    }
  }
}

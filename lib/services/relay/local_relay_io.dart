import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../core/logging/app_log.dart';
import '../../core/logging/log_redact.dart';
import '../drive/baidu_native.dart';
import '../drive/drive_descriptor.dart';
import '../drive/uc_native.dart';
import '../torrent/bt_stream.dart';
import 'm3u8_purify.dart';
import 'stream_cache_io.dart';

/// 本地 9978 中继：`/play` / `/file` / `/pkg` / `/img` / `/bt` / `/proxy?do=live`。
///
/// 与旧版 Electron 版保持同端口、同路由口径。播放时：
///   · 有 header / 防盗链 / 网盘 Cookie / WebDAV 凭据的地址经 `/play` 注入；
///   · m3u8 清单在回给播放器之前做去广告与递归改写（分片、密钥、子清单都指回中继）；
///   · 磁力播放走 `/bt`：按 Range 从 aria2 已校验的分片读盘。
class LocalRelay {
  LocalRelay._();
  static final LocalRelay instance = LocalRelay._();

  static const int preferredPort = 9978;

  /// BT 取流分片大小：每片写回播放器前做一次 piece 门控。
  static const int _btChunk = 512 * 1024;
  static final RegExp _btRoute = RegExp(r'^/bt/([0-9a-fA-F]{40})/(\d{1,6})/?$');

  HttpServer? _server;
  HttpClient? _client;

  /// 兼容模式客户端：个别视频 CDN 的证书链缺中间证书 / 自签，
  /// 严格校验会直接失败；仅在首次请求握手失败后对 GET/HEAD 重试使用。
  HttpClient? _insecureClient;
  int _port = 0;
  String _fileRoot = '';
  Map<String, String> Function() _driveTokens = () => const {};
  List<dynamic> Function() _rules = () => const [];
  bool Function() _purifyEnabled = () => false;
  String Function(String id) _davAuth = (_) => '';
  BtStreamSource? Function() _btSource = () => null;

  /// 当前常驻取流 JVM 的宿主代理端口（`/proxy?do=hmys` 等壳路由要转发给它）。
  int Function() _jvmProxyPort = () => 0;

  /// 边播边缓存的磁盘实现；未启用 / 未配置目录时为 null。
  StreamDiskCache? _streamCache;

  /// 外部播放器选集列表的按需解析：`/ext/<token>/<index>` 调到这里，
  /// 返回可直接播放的地址（通常是本机 `/play` 中继地址）。
  Future<String?> Function(String token, int index)? _externalEpisodeResolver;

  /// `/play` 的请求头不写进 URL，而是换成短 token（`hk=h1`）。
  ///
  /// 网盘直链 + Cookie + UA + Referer 一起塞进 query 时，URL 很容易超过
  /// FFmpeg 的 `MAX_URL_SIZE`（4096）。内置 fvp 用 Dart HttpClient 能忍，
  /// 外部 MPV 走 FFmpeg 会直接报「URL too long」打不开。token 只在 JVM /
  /// Dart 进程内存里，URL 保持短小。
  final Map<String, Map<String, String>> _playHeaderSets = {};
  final Map<String, String> _playHeaderTokens = {};
  int _playHeaderSeq = 0;
  static const _playHeaderMax = 400;

  /// 超长目标地址同样换成短 token（`p=h1`），避免超过 FFmpeg 的 URL 上限。
  ///
  /// 普通短视频地址仍用 `url=`，日志和排查更直观；只有编码后超过
  /// [_playUrlInlineMax] 的地址才走 `p`。
  final Map<String, String> _playTargets = {};
  final Map<String, String> _playTargetTokens = {};
  int _playTargetSeq = 0;
  static const _playTargetMax = 4000;
  static const _playUrlInlineMax = 3500;

  bool get running => _server != null;
  int get port => _port;
  String get baseUrl => 'http://127.0.0.1:$_port';

  Future<void> start({
    required String fileRoot,
    required Map<String, String> Function() driveTokens,
    required List<dynamic> Function() rules,
    required bool Function() purifyEnabled,
    String Function(String id)? davAuth,
    BtStreamSource? Function()? btSource,
    int Function()? jvmProxyPort,
    String Function()? cacheDir,
    bool Function()? cacheEnabled,
    int Function()? cacheLimitMb,
    Future<String?> Function(String token, int index)? externalEpisodeResolver,
  }) async {
    if (_server != null) return;
    _fileRoot = fileRoot;
    _driveTokens = driveTokens;
    _rules = rules;
    _purifyEnabled = purifyEnabled;
    _davAuth = davAuth ?? (_) => '';
    _btSource = btSource ?? () => null;
    _jvmProxyPort = jvmProxyPort ?? () => 0;
    final cacheRoot = cacheDir?.call().trim() ?? '';
    _streamCache = cacheRoot.isEmpty
        ? null
        : StreamDiskCache(
            dir: cacheRoot,
            enabled: cacheEnabled ?? () => false,
            limitMb: cacheLimitMb ?? () => 1024,
          );
    _externalEpisodeResolver = externalEpisodeResolver;
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = false;

    HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        preferredPort,
      );
    } on SocketException {
      // 9978 被旧版或别的程序占用时退回临时端口；生成的中继地址都带真实端口，
      // 不影响自身播放。
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    _server = server;
    _port = server.port;
    server.listen(_handle, onError: (Object _) {});
  }

  /// 边播边缓存当前占用字节数（设置页展示 / 清空前确认用）。
  Future<int> streamCacheBytes() async => await _streamCache?.totalBytes() ?? 0;

  /// 清空边播缓存目录。
  Future<void> clearStreamCache() async {
    await _streamCache?.clear();
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _port = 0;
    _playHeaderSets.clear();
    _playHeaderTokens.clear();
    _playTargets.clear();
    _playTargetTokens.clear();
    _streamCache = null;
    try {
      await server?.close(force: true);
    } catch (_) {
      // 退出阶段忽略
    }
    try {
      _client?.close(force: true);
    } catch (_) {
      // 退出阶段忽略
    }
    try {
      _insecureClient?.close(force: true);
    } catch (_) {
      // 退出阶段忽略
    }
    _client = null;
    _insecureClient = null;
  }

  String playUrl(
    String url, {
    Map<String, String> headers = const {},
    String provider = '',
  }) {
    if (!running) return url;
    if (_isRelayUrl(url)) return url;
    final query = <String, String>{};
    if (Uri.encodeComponent(url).length > _playUrlInlineMax) {
      query['p'] = _rememberPlayTarget(url);
    } else {
      query['url'] = url;
    }
    final headerToken = _rememberPlayHeaders(headers);
    if (headerToken.isNotEmpty) query['hk'] = headerToken;
    if (provider.isNotEmpty) query['ck'] = provider;
    return Uri.parse('$baseUrl/play')
        .replace(queryParameters: query)
        .toString();
  }

  String _rememberPlayTarget(String url) {
    final existing = _playTargetTokens[url];
    if (existing != null && _playTargets.containsKey(existing)) return existing;
    final token = 'p${_playTargetSeq++}';
    _playTargetTokens[url] = token;
    _playTargets[token] = url;
    if (_playTargetTokens.length > _playTargetMax) {
      final oldest = _playTargetTokens.keys.first;
      final oldToken = _playTargetTokens.remove(oldest);
      if (oldToken != null) _playTargets.remove(oldToken);
    }
    return token;
  }

  /// 相同请求头复用同一个 token：m3u8 的每个分片都会调用 [playUrl]，
  /// 不能为每个分片生成新 token，否则内存会被几百个相同的头集合撑大。
  String _rememberPlayHeaders(Map<String, String> headers) {
    if (headers.isEmpty) return '';
    final signature = headers.entries
        .map((e) => '${e.key.toLowerCase()}\u0001${e.value}')
        .join('\u0002');
    final existing = _playHeaderTokens[signature];
    if (existing != null && _playHeaderSets.containsKey(existing)) {
      return existing;
    }
    final token = 'h${_playHeaderSeq++}';
    _playHeaderTokens[signature] = token;
    _playHeaderSets[token] = Map<String, String>.from(headers);
    if (_playHeaderTokens.length > _playHeaderMax) {
      final oldest = _playHeaderTokens.keys.first;
      final oldToken = _playHeaderTokens.remove(oldest);
      if (oldToken != null) _playHeaderSets.remove(oldToken);
    }
    return token;
  }

  bool _isRelayUrl(String url) =>
      url.startsWith(baseUrl) || url.startsWith('http://127.0.0.1:9978/');

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Headers', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET,HEAD,OPTIONS');
    if (request.method == 'OPTIONS') {
      res.statusCode = 204;
      await res.close();
      return;
    }
    final path = request.uri.path;
    try {
      // /play、/proxy 的分片请求量很大，只在清单/失败时记录；其余路由逐条记。
      if (path != '/play' && path != '/proxy' && !path.startsWith('/proxy/')) {
        AppLog.i('relay', '${request.method} $path');
      }
      if (path == '/play') return await _handlePlay(request);
      if (path == '/file' || path.startsWith('/file/')) {
        return await _handleFile(request);
      }
      if (path == '/pkg' || path.startsWith('/pkg/')) {
        return await _handlePkg(request);
      }
      if (path == '/img') return await _handleImg(request);
      if (path.startsWith('/ext/')) {
        return await _handleExternalEpisode(request);
      }
      if (path.startsWith('/bt/')) return await _handleBt(request);
      if (path == '/proxy') return await _handleLiveProxy(request);
      if (path.startsWith('/proxy/')) {
        return await _handleJvmProxyPath(request);
      }
      if (path == '/') return await _text(res, 200, 'MisaTV local relay');
      return await _text(res, 404, 'not found');
    } catch (e, s) {
      AppLog.e('relay', '$path 处理失败', e, s);
      try {
        return await _text(res, 502, '中继失败：$e');
      } catch (_) {
        try {
          await res.close();
        } catch (_) {}
      }
    }
  }

  Future<void> _handlePlay(HttpRequest request) async {
    final res = request.response;
    final query = request.uri.queryParameters;
    var target = (query['url'] ?? query['u'] ?? '').trim();
    if (target.isEmpty) {
      final token = (query['p'] ?? '').trim();
      if (token.isNotEmpty) target = _playTargets[token] ?? '';
    }
    if (target.isEmpty) return _text(res, 400, '缺少 url');
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(target)) {
      return _text(res, 400, '只支持 http(s) 播放地址');
    }
    final provider = (query['ck'] ?? '').trim();
    final headers = _headersFromQuery(query, provider);
    // ★ 百度 dlink 的防盗链按 UA 判定：浏览器 UA 恒定 403 31326/user is not authorized
    //   （winbox 真机实证），必须用网盘客户端 UA。jar 有时只给浏览器 UA，这里强制纠正。
    final targetHost = Uri.tryParse(target)?.host.toLowerCase() ?? '';
    final baiduLink =
        provider == 'baidu' ||
        targetHost.contains('baidu.com') ||
        targetHost.contains('baidupcs.com') ||
        targetHost.contains('bcebos.com') ||
        targetHost.contains('bdstatic.com');
    if (baiduLink) {
      final currentUa = _headerValue(headers, HttpHeaders.userAgentHeader);
      if (!currentUa.toLowerCase().contains('netdisk')) {
        headers[HttpHeaders.userAgentHeader] = 'netdisk;P2SP;3.0.0;windows;;;';
      }
      if (_headerValue(headers, HttpHeaders.refererHeader).isEmpty) {
        headers[HttpHeaders.refererHeader] = 'https://pan.baidu.com/';
      }
    } else if (_headerValue(headers, HttpHeaders.userAgentHeader).isEmpty) {
      // 网盘直链有些会拒绝没有 UA 的请求（返回 403 / HTML），播放器只会报
      // “invalid or unsupported media”。调用方没给 UA 时补一个浏览器 UA。
      headers[HttpHeaders.userAgentHeader] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
    }
    // ★ 哔哩 CDN 按 Referer 防盗链：不带 bilibili.com 的 Referer 会回 403，
    //   播放器只报 invalid or unsupported media。未登录（只有 360P / 480P）时
    //   这条同样必需，不能因为「没配 Cookie」就跳过。
    final biliLink =
        provider == 'bili' ||
        targetHost.endsWith('bilibili.com') ||
        targetHost.endsWith('bilivideo.com') ||
        targetHost.endsWith('bilivideo.cn') ||
        targetHost.endsWith('hdslb.com');
    if (biliLink) {
      if (_headerValue(headers, HttpHeaders.refererHeader).isEmpty) {
        headers[HttpHeaders.refererHeader] = 'https://www.bilibili.com/';
      }
      if (_headerValue(headers, HttpHeaders.userAgentHeader).isEmpty) {
        headers[HttpHeaders.userAgentHeader] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
      }
    }
    final davId = (query['dav'] ?? '').trim();
    if (davId.isNotEmpty &&
        !headers.keys.any((k) => k.toLowerCase() == 'authorization')) {
      final auth = _davAuth(davId);
      if (auth.isNotEmpty) headers['Authorization'] = auth;
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    // 边播边缓存：命中直接读盘，连上游都不碰 —— 拖回看过的位置不再回源。
    final cacheKey = StreamDiskCache.keyOf(target);
    if (range == null &&
        request.method == 'GET' &&
        !target.toLowerCase().contains('.m3u8')) {
      final cached = await _streamCache?.lookup(cacheKey);
      if (cached != null) {
        res.statusCode = 200;
        res.headers.set(HttpHeaders.contentTypeHeader, cached.contentType);
        res.headers.contentLength = cached.length;
        await res.addStream(cached.file.openRead());
        await res.close();
        return;
      }
    }

    // ★ 网盘 CDN 的「跨度限速」：夸克 / 百度 / UC 的直链只要 Range 是**开放式**
    //   （`bytes=0-`）或跨度太大（实测 >~360MB 就触发），同一节点会被压到 ~0.1 MB/s，
    //   播放器表现为「能出画面但极慢、几乎无法播放」。
    //   同一地址改成 `bytes=0-33554431`（32MB）立刻回到 10–19 MB/s —— 与跨度成反比。
    //   这里把请求窗口夹到安全值再打上游；上游回 206 + 真实 Content-Range，
    //   播放器看到「给的比要的少」会自然续请求下一段，语义完全合规。
    final upstream = await _open(
      target,
      headers: headers,
      method: request.method,
      range: clampRange(range),
    );
    final finalUrl = _finalUrl(upstream, target);
    final contentType = _responseContentType(upstream);
    final looksM3u8 =
        finalUrl.toLowerCase().contains('.m3u8') ||
        contentType.contains('mpegurl') ||
        contentType.contains('application/vnd.apple');

    if (looksM3u8) {
      AppLog.i(
        'relay',
        '/play m3u8 ${upstream.statusCode} ${redactUrl(target)}',
      );
    }
    if (looksM3u8 && request.method != 'HEAD' && upstream.statusCode < 400) {
      var bytes = await _readLimited(upstream);
      final encoding = _responseHeader(
        upstream,
        HttpHeaders.contentEncodingHeader,
      ).toLowerCase();
      if (encoding.contains('gzip')) {
        try {
          bytes = gzip.decode(bytes);
        } catch (_) {
          // 解压失败按原文处理
        }
      }
      var text = utf8.decode(bytes, allowMalformed: true);
      if (_purifyEnabled() && text.startsWith('#EXTM3U')) {
        final result = purifyVodM3u8(
          text,
          finalUrl,
          rules: hostRegexFor(finalUrl, _rules()),
        );
        if (result != null && result.removed > 0) text = result.text;
      }
      final rewritten = _rewritePlaylist(text, finalUrl, headers, provider);
      res.statusCode = 200;
      res.headers.set('content-type', 'application/vnd.apple.mpegurl');
      final payload = utf8.encode(rewritten);
      res.headers.contentLength = payload.length;
      res.add(payload);
      await res.close();
      return;
    }

    res.statusCode = upstream.statusCode;
    _copyHeader(upstream, res, HttpHeaders.contentTypeHeader);
    _copyHeader(upstream, res, HttpHeaders.contentLengthHeader);
    _copyHeader(upstream, res, HttpHeaders.contentRangeHeader);
    _copyHeader(upstream, res, HttpHeaders.acceptRangesHeader);
    _copyHeader(upstream, res, HttpHeaders.lastModifiedHeader);
    _copyHeader(upstream, res, HttpHeaders.etagHeader);
    _copyHeader(upstream, res, HttpHeaders.cacheControlHeader);
    _copyHeader(upstream, res, HttpHeaders.contentEncodingHeader);
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    // 未命中缓存：一边转发给播放器，一边把分片写进本地。
    // 只缓存「整段 GET 的媒体响应」；Range、gzip、错误页一律透传。
    final cacheable =
        _streamCache != null &&
        range == null &&
        request.method == 'GET' &&
        upstream.statusCode == 200 &&
        _responseHeader(upstream, HttpHeaders.contentEncodingHeader).isEmpty &&
        _cacheableContentType(contentType);
    final writer = cacheable
        ? await _streamCache!.open(
            cacheKey,
            contentType: contentType,
            length: upstream.contentLength,
          )
        : null;
    if (writer == null) {
      await upstream.pipe(res);
      return;
    }
    try {
      await for (final chunk in upstream) {
        res.add(chunk);
        writer.add(chunk);
      }
      await res.close();
      await writer.commit();
    } catch (_) {
      // 播放器提前断开（拖动 / 切集）：半截文件不留在缓存里。
      await writer.abort();
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// 单次上游请求的 Range 跨度上限（32MB）。
  ///
  /// 实测（夸克 672MB / 2GB 两个直链，同一 cookie、同一节点）：
  ///   · `bytes=0-`（开放）→ 0.1 MB/s
  ///   · 跨度 2GB / 1GB / 512MB → 0.1 MB/s
  ///   · 跨度 400MB / 350MB → 0.1 / 4.6 MB/s（阈值在 ~360MB 附近）
  ///   · 跨度 300MB / 256MB → 5.4 / 7.8 MB/s
  ///   · 跨度 128MB / 64MB / 32MB → 9.8 / 9.6 / 13.0 MB/s
  ///   · 跨度 16MB / 8MB  → 8.5 / 19.2 MB/s
  /// 也就是说**速度与请求跨度反相关**，开放 Range 是最差的一种。
  /// 播放器（尤其 fvp / mpv）开场习惯发 `bytes=0-`，正好踩在这个坑上。
  static const int _maxUpstreamRangeBytes = 32 * 1024 * 1024;

  /// 把播放器的 Range 夹到安全跨度；无法解析时原样透传（不猜）。
  ///
  /// 只处理单区间 `bytes=<start>-<end|*>`：多区间（带逗号）与 `-<suffix>` 形态
  /// 直接透传 —— 那些在媒体播放里几乎不出现，改动它们风险大于收益。
  @visibleForTesting
  static String? clampRange(String? range) {
    if (range == null || range.trim().isEmpty) return range;
    final m = RegExp(
      r'^bytes\s*=\s*(\d+)\s*-\s*(\d*)$',
      caseSensitive: false,
    ).firstMatch(range.trim());
    if (m == null) return range;
    final start = int.tryParse(m.group(1)!);
    if (start == null || start < 0) return range;
    final endText = m.group(2)!.trim();
    if (endText.isEmpty) {
      // 开放区间：夹成固定跨度
      return 'bytes=$start-${start + _maxUpstreamRangeBytes - 1}';
    }
    final end = int.tryParse(endText);
    if (end == null || end < start) return range;
    if (end - start + 1 <= _maxUpstreamRangeBytes) return range;
    return 'bytes=$start-${start + _maxUpstreamRangeBytes - 1}';
  }

  /// 只把音视频 / 图片 / 二进制当作可缓存内容，避免把 HTML 错误页写进缓存。
  static bool _cacheableContentType(String type) {
    final value = type.toLowerCase();
    if (value.isEmpty) return true;
    return value.startsWith('video/') ||
        value.startsWith('audio/') ||
        value.startsWith('image/') ||
        value.contains('octet-stream') ||
        value.contains('mp2t') ||
        value.contains('mp4');
  }

  Future<void> _handleFile(HttpRequest request) async {
    final raw = request.uri.path.substring('/file'.length);
    final relative = _decodeRel(raw);
    await _serveFile(request, _fileRoot, relative);
  }

  Future<void> _handlePkg(HttpRequest request) async {
    final rest = request.uri.path.substring('/pkg'.length);
    final parts = rest.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.length < 2) {
      return _text(request.response, 400, 'pkg 路径应为 /pkg/<i>/<file>');
    }
    final index = int.tryParse(parts.first);
    if (index == null) return _text(request.response, 400, 'pkg 序号非法');
    final root = Directory(p.join(_fileRoot, 'local_pkgs'));
    if (!root.existsSync()) return _text(request.response, 404, '没有本地包');
    final dirs = root.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (index < 0 || index >= dirs.length) {
      return _text(request.response, 404, '本地包不存在');
    }
    final relative = '/${parts.skip(1).join('/')}';
    await _serveFile(request, dirs[index].path, relative);
  }

  Future<void> _serveFile(
    HttpRequest request,
    String root,
    String relative,
  ) async {
    final res = request.response;
    final decoded = _decodeRel(relative);
    if (decoded.isEmpty || decoded.contains('\u0000')) {
      return _text(res, 400, '路径非法');
    }
    final rootPath = p.normalize(p.absolute(root));
    final filePath = p.normalize(
      p.join(rootPath, decoded.replaceFirst(RegExp(r'^/+'), '')),
    );
    if (!p.isWithin(rootPath, filePath) && filePath != rootPath) {
      return _text(res, 403, '路径越界');
    }
    final file = File(filePath);
    if (!file.existsSync()) return _text(res, 404, '文件不存在');
    final length = file.lengthSync();
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null && range.startsWith('bytes=')) {
      final spec = range.substring('bytes='.length).split('-');
      final start = int.tryParse(spec.first) ?? 0;
      final end = spec.length > 1 && spec[1].isNotEmpty
          ? int.tryParse(spec[1]) ?? length - 1
          : length - 1;
      if (start < 0 || start >= length || end < start) {
        res.statusCode = 416;
        res.headers.set('content-range', 'bytes */$length');
        await res.close();
        return;
      }
      final safeEnd = end >= length ? length - 1 : end;
      res.statusCode = 206;
      res.headers.set('content-range', 'bytes $start-$safeEnd/$length');
      res.headers.contentLength = safeEnd - start + 1;
      res.headers.set('accept-ranges', 'bytes');
      res.headers.set('content-type', _contentTypeOf(file.path));
      if (request.method == 'HEAD') {
        await res.close();
        return;
      }
      await file.openRead(start, safeEnd + 1).pipe(res);
      return;
    }
    res.statusCode = 200;
    res.headers.contentLength = length;
    res.headers.set('accept-ranges', 'bytes');
    res.headers.set('content-type', _contentTypeOf(file.path));
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    await file.openRead().pipe(res);
  }

  /// 外部播放器选集：按需解析后 302 到真正的播放地址。
  ///
  /// 播放器在片单里切集时才会请求这里，所以不用在启动外部播放器之前
  /// 把整季直链全部解析一遍。
  Future<void> _handleExternalEpisode(HttpRequest request) async {
    final res = request.response;
    final segments = request.uri.pathSegments;
    final resolver = _externalEpisodeResolver;
    if (resolver == null || segments.length < 3) {
      return _text(res, 404, 'external playlist unavailable');
    }
    final token = segments[1];
    final index = int.tryParse(segments[2]);
    if (index == null || index < 0) {
      return _text(res, 400, 'bad episode index');
    }
    final target = await resolver(token, index);
    if (target == null || target.isEmpty) {
      return _text(res, 502, '无法解析这一集');
    }
    AppLog.i('relay', '/ext/$index -> ${redactUrl(target)}');
    res.statusCode = HttpStatus.found;
    res.headers.set(HttpHeaders.locationHeader, target);
    await res.close();
  }

  /// BT 取流口：`/bt/<infoHash>/<fileIndex>`。
  ///
  /// 与 `/play` 的差别是数据来自本机正在下载的文件：
  ///   · 必须有 Range（播放器 seek / 起播探测都靠它）；
  ///   · 必须有 piece 门控（未下载区读出来是稀疏零 → 喂零 = 坏流），按 512KB 分片逐段等待；
  ///   · 首片单独门控再写响应头，避免播放器拿到 200 却迟迟无字节。
  Future<void> _handleBt(HttpRequest request) async {
    final res = request.response;
    final match = _btRoute.firstMatch(request.uri.path);
    if (match == null) return _text(res, 404, 'bt 路径非法');
    final infoHash = match.group(1)!.toLowerCase();
    final fileIndex = int.parse(match.group(2)!);
    final source = _btSource();
    if (source == null) return _text(res, 503, 'BT 引擎未运行');
    final info = source.resolveStream(infoHash, fileIndex);
    if (info == null) return _text(res, 404, 'bt 会话不存在或文件序号不匹配');
    final total = info.length;
    if (total <= 0) return _text(res, 503, 'BT 文件为空');
    final file = File(info.absPath);
    if (!file.existsSync()) return _text(res, 503, 'BT 文件尚未落盘');

    final range = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = total - 1;
    final partial = range != null && range.isNotEmpty;
    if (partial) {
      final parsed = _parseByteRange(range, total);
      if (parsed == null) {
        res.statusCode = 416;
        res.headers.set('content-range', 'bytes */$total');
        await res.close();
        return;
      }
      start = parsed.$1;
      end = parsed.$2;
    }

    // 首片门控：只等这一小段（`bytes=0-` 不能变成「等全片」）。
    final firstEnd = start + _btChunk - 1 < end ? start + _btChunk - 1 : end;
    final ready = await source.waitCovered(
      infoHash,
      fileIndex,
      start,
      firstEnd,
    );
    if (!ready) return _text(res, 503, 'BT 数据未就绪（做种者过少或已无进度）');

    res.statusCode = partial ? 206 : 200;
    res.headers.set('content-type', _contentTypeOf(info.absPath));
    res.headers.set('accept-ranges', 'bytes');
    res.headers.contentLength = end - start + 1;
    if (partial) res.headers.set('content-range', 'bytes $start-$end/$total');
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    try {
      for (var pos = start; pos <= end; pos += _btChunk) {
        final stop = pos + _btChunk - 1 < end ? pos + _btChunk - 1 : end;
        if (pos > start) {
          final ok = await source.waitCovered(infoHash, fileIndex, pos, stop);
          if (!ok) {
            // 已经发出响应头，无法改状态码：直接断开，让播放器重试。
            await res.close();
            return;
          }
        }
        await res.addStream(file.openRead(pos, stop + 1));
      }
      await res.close();
    } catch (_) {
      // 客户端提前断开（seek/关闭）→ 忽略
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// 解析 `Range: bytes=`（只取第一段；支持 `a-b` / `a-` / `-n`）。
  (int, int)? _parseByteRange(String raw, int total) {
    final lower = raw.toLowerCase();
    if (!lower.startsWith('bytes=')) return null;
    final spec = lower.substring('bytes='.length).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final left = spec.substring(0, dash).trim();
    final right = spec.substring(dash + 1).trim();
    if (left.isEmpty) {
      final suffix = int.tryParse(right);
      if (suffix == null || suffix <= 0) return null;
      final start = suffix >= total ? 0 : total - suffix;
      return (start, total - 1);
    }
    final start = int.tryParse(left);
    if (start == null || start < 0 || start >= total) return null;
    if (right.isEmpty) return (start, total - 1);
    final end = int.tryParse(right);
    if (end == null || end < start) return null;
    return (start, end >= total ? total - 1 : end);
  }

  Future<void> _handleImg(HttpRequest request) async {
    final res = request.response;
    final query = request.uri.queryParameters;
    final target = (query['url'] ?? query['u'] ?? '').trim();
    if (target.isEmpty) return _text(res, 400, '缺少 url');
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(target)) {
      return _text(res, 400, '只支持 http(s) 图片地址');
    }
    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      if ((query['ref'] ?? '').trim().isNotEmpty)
        'Referer': query['ref']!.trim(),
    };
    // 代理链路抖动时（隧道被对端掐断、节点瞬断）重试一次再放弃：
    // 封面是并发拉取的，偶发失败在界面上就是「有个别封面不出来」。
    HttpClientResponse upstream;
    try {
      upstream = await _open(
        target,
        headers: headers,
        method: request.method,
      );
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      upstream = await _open(
        target,
        headers: headers,
        method: request.method,
      );
    }
    res.statusCode = upstream.statusCode;
    _copyHeader(upstream, res, HttpHeaders.contentTypeHeader);
    _copyHeader(upstream, res, HttpHeaders.contentLengthHeader);
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    await upstream.pipe(res);
  }

  Future<void> _handleLiveProxy(HttpRequest request) async {
    final res = request.response;
    final query = request.uri.queryParameters;
    final doValue = (query['do'] ?? '').trim().toLowerCase();
    // 小白/加固壳启动时会探 9978~9999 的 `/proxy?do=ck`，应答体必须等于 `ok`
    // 才会把本机 9978 当作宿主代理。之前这里回 400，壳拿到的端口是 -1，
    // 它生成的 m3u8 内部分片地址也会带着 `-1`，播放器随后直接报
    // `invalid or unsupported media`（只在顶层地址改端口的兜底救不回来）。
    if (doValue == 'ck') return _text(res, 200, 'ok');
    // 宿主网盘路由：爪/壳常把播放地址指向 App 的 `do=pan`（网盘直链），桌面端补实现。
    if (doValue == 'pan') return _handlePanProxy(request);
    // 通用宿主代理：`do=proxy` / `do=url` / `do=img`（老 TVBox 宿主约定）。
    if (doValue == 'proxy' || doValue == 'url' || doValue == 'img') {
      return _handleUrlProxy(request);
    }
    if (doValue != 'live') {
      // 壳自己的宿主路由（如 `do=hmys`）依赖该 JVM 内存里的状态（Cookie / 密钥 /
      // 签名），App 侧无法重放 —— 有常驻取流 JVM 时整条 query 原样转发过去。
      final jvmPort = _jvmProxyPort();
      if (jvmPort > 0 && jvmPort != _port) {
        return _forwardJvmProxy(request, jvmPort);
      }
      // 其它宿主路由（`do=py` / `do=hxq` 等）：只要有可转发的 url 就按通用代理处理，
      // 否则明确报错，避免壳拿到 404/400 后误判成空结果。
      if ((query['url'] ?? query['u'] ?? '').trim().isNotEmpty) {
        return _handleUrlProxy(request);
      }
      return _text(res, 400, 'do=$doValue 未实现（可用的 do=live/pan/proxy）');
    }
    final type = (query['type'] ?? 'txt').trim();
    if (type == '3') return _text(res, 501, '直播蜘蛛源当前由 App 直接调用，不经中继');
    final ext = (query['ext'] ?? '').trim();
    if (ext.isEmpty) return _text(res, 400, '缺少 ext');
    final target = _resolveExt(ext);
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(target)) {
      return _text(res, 400, '直播订阅地址无效');
    }
    final upstream = await _open(
      target,
      headers: {'User-Agent': 'Mozilla/5.0 TVBoxWin/0.1'},
      method: request.method,
    );
    res.statusCode = upstream.statusCode;
    _copyHeader(upstream, res, HttpHeaders.contentTypeHeader);
    _copyHeader(upstream, res, HttpHeaders.contentLengthHeader);
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    await upstream.pipe(res);
  }

  /// `/proxy/<jvmPort>?...`：旧宿主入口形态，转发到该 JVM 内的宿主代理。
  Future<void> _handleJvmProxyPath(HttpRequest request) async {
    final port = int.tryParse(request.uri.path.substring('/proxy/'.length));
    // 壳有时会把自己的发现端口（9978）再拼进路径；这种「自引用」按当前
    // 常驻取流 JVM 转发。其余只接管确定性分配段，避免把本机任意端口暴露成上游。
    final jvmPort = port == null || port == _port || port <= 0
        ? _jvmProxyPort()
        : (port >= 19970 && port <= 19999 ? port : 0);
    if (jvmPort <= 0) {
      return _text(request.response, 502, '没有可用的取流 JVM 代理');
    }
    return _forwardJvmProxy(request, jvmPort);
  }

  /// 把壳自己的 `/proxy` 路由整条转发到蜘蛛 JVM 内的宿主代理。
  ///
  /// 加固壳的播放清单（如 `do=hmys`）会在分片地址里继续带同一套 query，
  /// 只有该 JVM 内存里的 Cookie / 密钥 / 签名能解；App 侧不能也不该重放。
  Future<void> _forwardJvmProxy(HttpRequest request, int port) async {
    final res = request.response;
    final rawQuery = request.uri.query;
    final target =
        'http://127.0.0.1:$port/proxy'
        '${rawQuery.isEmpty ? '' : '?$rawQuery'}';
    final headers = <String, String>{};
    for (final name in const [
      HttpHeaders.rangeHeader,
      HttpHeaders.userAgentHeader,
      HttpHeaders.refererHeader,
      HttpHeaders.acceptHeader,
      HttpHeaders.cookieHeader,
    ]) {
      final value = request.headers.value(name);
      if (value != null && value.isNotEmpty) headers[name] = value;
    }
    final upstream = await _open(
      target,
      headers: headers,
      method: request.method,
      range: request.headers.value(HttpHeaders.rangeHeader),
    );
    res.statusCode = upstream.statusCode;
    _copyHeader(upstream, res, HttpHeaders.contentTypeHeader);
    _copyHeader(upstream, res, HttpHeaders.contentLengthHeader);
    _copyHeader(upstream, res, HttpHeaders.acceptRangesHeader);
    _copyHeader(upstream, res, HttpHeaders.contentRangeHeader);
    _copyHeader(upstream, res, HttpHeaders.contentEncodingHeader);
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    await upstream.pipe(res);
  }

  /// 宿主网盘路由 `do=pan`：把壳/爪返回的网盘分享（百度 / UC / 夸克）解成直链并中继。
  ///
  /// 兼容的入参（按常见宿主约定）：
  ///   · `site` / `provider`：baidu / uc / quark
  ///   · `url` / `u` / `share` / `s` / `target`：分享链接或描述符
  ///   · `pwd` / `code`：提取码
  ///   · `fileId` / `fsid`：本人盘文件 id（百度）
  Future<void> _handlePanProxy(HttpRequest request) async {
    final res = request.response;
    final q = request.uri.queryParameters;
    final provider = (q['site'] ?? q['provider'] ?? q['ck'] ?? '')
        .trim()
        .toLowerCase();
    final text = _panShareText(q, provider);
    if (text.isEmpty) {
      return _text(res, 400, 'do=pan 缺少分享地址/描述符');
    }
    final tokens = _driveTokens();
    NativeDriveLink? link;
    final baiduLike =
        provider.startsWith('baidu') ||
        text.startsWith('baidu@') ||
        text.contains('pan.baidu.com') ||
        text.contains('baidupcs.com');
    final ucLike =
        provider.startsWith('uc') ||
        provider.startsWith('quark') ||
        text.startsWith('uc@') ||
        text.startsWith('quark@') ||
        text.contains('drive.uc.cn') ||
        text.contains('pan.quark.cn');
    if (baiduLike) {
      link = await resolveBaiduDirect(
        text,
        cookie: (tokens['baidu'] ?? '').trim(),
        episodeName: (q['name'] ?? '').trim(),
      );
    } else if (ucLike) {
      final key = provider.startsWith('quark') ? 'quark' : 'uc';
      link = await resolveUcDirect(
        text,
        cookie: (tokens[key] ?? tokens['uc'] ?? '').trim(),
        flag: (q['flag'] ?? provider).trim(),
        episodeName: (q['name'] ?? '').trim(),
      );
    }
    if (link == null || !link.ok || link.url.isEmpty) {
      AppLog.w('relay', 'do=pan 解链失败 provider=$provider ${link?.reason ?? ''}');
      return _text(res, 502, '网盘解链失败：${link?.reason ?? '未识别的网盘'}');
    }
    AppLog.i('relay', 'do=pan 解链成功 ${redactUrl(link.url)}');
    final headers = <String, String>{...link.headers};
    final host = Uri.tryParse(link.url)?.host.toLowerCase() ?? '';
    if (host.contains('baidu') || host.contains('bdstatic')) {
      if (_headerValue(headers, HttpHeaders.userAgentHeader).isEmpty) {
        headers[HttpHeaders.userAgentHeader] = 'netdisk;P2SP;3.0.0;windows;;;';
      }
      if (_headerValue(headers, HttpHeaders.refererHeader).isEmpty) {
        headers[HttpHeaders.refererHeader] = 'https://pan.baidu.com/';
      }
    }
    await _streamTarget(request, link.url, headers);
  }

  /// 通用宿主代理 `do=proxy` / `do=url` / `do=img`：按 `url` 原样转发。
  Future<void> _handleUrlProxy(HttpRequest request) async {
    final res = request.response;
    final q = request.uri.queryParameters;
    final target = (q['url'] ?? q['u'] ?? q['target'] ?? '').trim();
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(target)) {
      return _text(res, 400, 'do=${q['do']} 缺少合法的 url');
    }
    final headers = _headersFromQuery(
      q,
      (q['ck'] ?? q['provider'] ?? '').trim(),
    );
    if (_headerValue(headers, HttpHeaders.userAgentHeader).isEmpty) {
      headers[HttpHeaders.userAgentHeader] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
    }
    await _streamTarget(request, target, headers);
  }

  /// 把目标地址按 Range 透传给播放器（统一补 Content-Type/Length 等）。
  Future<void> _streamTarget(
    HttpRequest request,
    String target,
    Map<String, String> headers,
  ) async {
    final res = request.response;
    // `do=pan` 解出来的百度 / UC / 夸克直链最终也走这里，同样会撞上 CDN 的跨度限速，
    // 所以和 `/play` 用同一套夹取规则。
    final range = clampRange(request.headers.value(HttpHeaders.rangeHeader));
    final upstream = await _open(
      target,
      headers: headers,
      method: request.method,
      range: range,
    );
    res.statusCode = upstream.statusCode;
    _copyHeader(upstream, res, HttpHeaders.contentTypeHeader);
    _copyHeader(upstream, res, HttpHeaders.contentLengthHeader);
    _copyHeader(upstream, res, HttpHeaders.acceptRangesHeader);
    _copyHeader(upstream, res, HttpHeaders.contentRangeHeader);
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    await upstream.pipe(res);
  }

  /// 从 `do=pan` 的参数里拼出可解链的文本（分享链接 / 描述符 / 本人盘 fileId / shareId）。
  String _panShareText(Map<String, String> q, String provider) {
    for (final key in const [
      'url',
      'u',
      'share',
      's',
      'target',
      'link',
      'raw',
    ]) {
      final value = (q[key] ?? '').trim();
      if (value.isEmpty) continue;
      if (value.startsWith('baidu@') ||
          value.startsWith('uc@') ||
          value.startsWith('quark@') ||
          RegExp(r'^https?://', caseSensitive: false).hasMatch(value)) {
        final pwd = (q['pwd'] ?? q['code'] ?? '').trim();
        if (pwd.isNotEmpty && !value.contains('pwd=')) {
          final sep = value.contains('?') ? '&' : '?';
          return '$value${sep}pwd=$pwd';
        }
        return value;
      }
    }
    // 爪/壳的宿主约定：`do=pan&site=<网盘>&shareId=<surl>&fileId=<fsid>&fileToken=<sekey>`
    final shareId = (q['shareId'] ?? q['share_id'] ?? q['surl'] ?? '').trim();
    if (shareId.isNotEmpty) {
      if (RegExp(r'^https?://', caseSensitive: false).hasMatch(shareId)) {
        return shareId;
      }
      final pwd = (q['pwd'] ?? q['code'] ?? '').trim();
      if (provider.startsWith('baidu') || provider.isEmpty) {
        return 'https://pan.baidu.com/s/$shareId${pwd.isEmpty ? '' : '?pwd=$pwd'}';
      }
      final fileId = (q['fileId'] ?? q['file_id'] ?? '').trim();
      final token = (q['fileToken'] ?? q['token'] ?? '').trim();
      return 'do=pan&site=$provider&shareId=$shareId'
          '&fileId=$fileId&fileToken=$token';
    }
    final fileId = (q['fileId'] ?? q['fsid'] ?? '').trim();
    if (fileId.isNotEmpty) {
      final site = provider.isEmpty ? 'baidu' : provider;
      return 'do=pan&site=$site&fileId=$fileId';
    }
    // 有的壳直接把 `名称[大小]__<fsid>` 描述符放进 name/desc。
    final desc = (q['desc'] ?? q['name'] ?? '').trim();
    if (desc.contains('__')) return desc;
    return '';
  }

  /// 大小写不敏感地取请求头值。
  String _headerValue(Map<String, String> headers, String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return '';
  }

  Map<String, String> _headersFromQuery(
    Map<String, String> query,
    String provider,
  ) {
    final headers = <String, String>{};
    final headerToken = (query['hk'] ?? '').trim();
    if (headerToken.isNotEmpty) {
      final stored = _playHeaderSets[headerToken];
      if (stored != null) headers.addAll(stored);
    }
    // 兼容旧格式（ua / referer / cookie / h）直接放在 query 里的地址。
    final ua = (query['ua'] ?? '').trim();
    if (ua.isNotEmpty) headers.putIfAbsent('User-Agent', () => ua);
    final referer = (query['referer'] ?? '').trim();
    if (referer.isNotEmpty) headers.putIfAbsent('Referer', () => referer);
    final raw = (query['h'] ?? '').trim();
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            headers.putIfAbsent(
              entry.key.toString(),
              () => entry.value.toString(),
            );
          }
        }
      } catch (_) {
        // 非法扩展头忽略
      }
    }
    final cookie = (query['cookie'] ?? '').trim();
    if (cookie.isNotEmpty) headers.putIfAbsent('Cookie', () => cookie);
    if (provider.isNotEmpty) {
      final token = (_driveTokens()[provider] ?? '').trim();
      if (token.isNotEmpty) {
        final old = headers['Cookie'] ?? '';
        if (old.isEmpty) {
          headers['Cookie'] = token;
        } else if (!old.contains(token)) {
          // 蜘蛛已经给了完整 Cookie 时不再重复追加，避免 HLS 多级改写后
          // Cookie 越滚越长、把外部播放器的请求头顶爆。
          headers['Cookie'] = '$old; $token';
        }
      }
    }
    return headers;
  }

  /// 手动跟随重定向。
  ///
  /// ★ 为什么不能用 `request.followRedirects = true`（实测踩死过一次）：
  ///   百度网盘 `dlink` 会先回 302 到 `*.baidupcs.com` 的真实流地址。交给 Dart 自动跟随，
  ///   同一个 URL、同一套头，结果恒定 **403**；改成手动取 `Location` 再发一次就是 **206**。
  ///   自动跟随在换 host 时会改写请求（丢掉 `User-Agent` —— 实测「无 UA → 403、
  ///   有 UA → 206」，而 CDN 正是按 UA 判防盗链），所以这里自己走：
  ///   · 每一跳都保留 User-Agent / Range / Referer（这三样是防盗链判定依据）；
  ///   · 换 host 时丢掉 `Cookie`（本机网盘 cookie 不该发给 CDN 域，实测不带也能过）；
  ///   · 最多 5 跳，与原来的 `maxRedirects` 一致。
  Future<HttpClientResponse> _openFollow(
    HttpClient targetClient, {
    required String url,
    required Map<String, String> headers,
    required String method,
    String? range,
  }) async {
    var current = Uri.parse(url);
    final origin = current.host.toLowerCase();
    for (var hop = 0; hop <= 5; hop++) {
      final req = await targetClient.openUrl(method, current);
      final crossHost = current.host.toLowerCase() != origin;
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      headers.forEach((key, value) {
        if (crossHost && key.toLowerCase() == 'cookie') return;
        req.headers.set(key, value);
      });
      if (range != null && range.isNotEmpty) {
        req.headers.set(HttpHeaders.rangeHeader, range);
      }
      req.followRedirects = false;
      final response = await req.close();
      final code = response.statusCode;
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (code < 300 || code >= 400 || location == null || location.isEmpty) {
        return response;
      }
      // 丢弃这一跳的响应体，避免连接悬挂
      await response.drain<void>().catchError((Object _) {});
      current = current.resolve(location);
      // 只跟随 http(s)；其它协议原样交回（上层按状态码处理）
      if (!current.isScheme('http') && !current.isScheme('https')) {
        throw HttpException('重定向到不支持的协议：${current.scheme}');
      }
    }
    throw HttpException('重定向次数过多：$url');
  }

  Future<HttpClientResponse> _open(
    String url, {
    required Map<String, String> headers,
    required String method,
    String? range,
  }) async {
    final client = _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = false;

    Future<HttpClientResponse> send(HttpClient targetClient) => _openFollow(
      targetClient,
      url: url,
      headers: headers,
      method: method,
      range: range,
    );

    try {
      return await send(client);
    } on HandshakeException catch (e) {
      // 视频 CDN 常见「证书链缺中间证书 / 自签」：浏览器播放器通常放行，
      // Dart 的严格校验会直接拒绝。仅对无副作用的 GET/HEAD 用兼容客户端重试一次。
      if (method != 'GET' && method != 'HEAD') rethrow;
      final host = Uri.tryParse(url)?.host ?? '';
      AppLog.w('relay', 'TLS 证书校验失败，改用兼容模式重试 host=$host | $e');
      final insecure = _insecureClient ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..autoUncompress = false
        ..badCertificateCallback = (_, _, _) => true;
      return await send(insecure);
    }
  }

  String _finalUrl(HttpClientResponse response, String original) {
    var url = original;
    for (final redirect in response.redirects) {
      try {
        url = Uri.parse(url).resolve(redirect.location.toString()).toString();
      } catch (_) {
        url = redirect.location.toString();
      }
    }
    return url;
  }

  String _rewritePlaylist(
    String text,
    String baseUrl,
    Map<String, String> headers,
    String provider,
  ) {
    final out = <String>[];
    final uriAttr = RegExp(r'URI="([^"]*)"');
    for (final raw in text.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty) {
        out.add(line);
        continue;
      }
      if (line.startsWith('#')) {
        out.add(
          line.replaceAllMapped(uriAttr, (m) {
            final abs = _resolveRef(baseUrl, m.group(1) ?? '');
            if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(abs)) {
              return m.group(0)!;
            }
            return 'URI="${playUrl(abs, headers: headers, provider: provider)}"';
          }),
        );
        continue;
      }
      final abs = _resolveRef(baseUrl, line);
      if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(abs)) {
        out.add(line);
      } else {
        out.add(playUrl(abs, headers: headers, provider: provider));
      }
    }
    return out.join('\n');
  }

  String _resolveRef(String base, String ref) {
    final value = ref.trim();
    if (value.isEmpty) return value;
    if (RegExp(
      r'^(https?:|data:|skd:|file:)',
      caseSensitive: false,
    ).hasMatch(value)) {
      return value;
    }
    try {
      return Uri.parse(base).resolve(value).toString();
    } catch (_) {
      return value;
    }
  }

  String _resolveExt(String ext) {
    final raw = ext.trim();
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(raw)) return raw;
    var s = raw
        .replaceAll(RegExp(r'\s'), '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    while (s.length % 4 != 0) {
      s += '=';
    }
    try {
      return utf8.decode(base64.decode(s));
    } catch (_) {
      return raw;
    }
  }

  Future<List<int>> _readLimited(
    HttpClientResponse response, {
    int maxBytes = 8 << 20,
  }) async {
    final out = <int>[];
    await for (final chunk in response) {
      out.addAll(chunk);
      if (out.length >= maxBytes) break;
    }
    return out;
  }

  void _copyHeader(HttpClientResponse from, HttpResponse to, String name) {
    // `HttpHeaders.value()` 在同名头出现多次时直接抛
    // `HttpException: More than one value for header …`（上游 CDN 常重复下发
    // `cache-control: no-cache` / `no-store`），会让整段分片变成 502，播放器
    // 只能反复重试黑屏。这里按列表取：列表型头合并，其余取首个非空值。
    final values = from.headers[name];
    if (values == null || values.isEmpty) return;
    final listValue = name.toLowerCase() == HttpHeaders.cacheControlHeader;
    final value = values.length == 1
        ? values.first
        : (listValue ? values.join(', ') : values.first);
    if (value.isNotEmpty) to.headers.set(name, value);
  }

  /// 上游响应头取首个值（重复头不会抛异常）。
  String _responseHeader(HttpClientResponse response, String name) {
    final values = response.headers[name];
    return (values == null || values.isEmpty) ? '' : values.first;
  }

  /// 上游 `Content-Type` 的安全取值：畸形 / 重复时返回空串而不是中断整段下载。
  String _responseContentType(HttpClientResponse response) {
    try {
      return response.headers.contentType?.mimeType.toLowerCase() ?? '';
    } catch (_) {
      return '';
    }
  }

  String _decodeRel(String raw) {
    try {
      return Uri.decodeComponent(raw);
    } catch (_) {
      return raw;
    }
  }

  String _contentTypeOf(String path) {
    final ext = p.extension(path).toLowerCase();
    return switch (ext) {
      '.m3u8' => 'application/vnd.apple.mpegurl',
      '.ts' => 'video/mp2t',
      '.m4s' => 'video/iso.segment',
      '.mp4' => 'video/mp4',
      '.m4v' => 'video/mp4',
      '.webm' => 'video/webm',
      '.mkv' => 'video/x-matroska',
      '.flv' => 'video/x-flv',
      '.mov' => 'video/quicktime',
      '.mpd' => 'application/dash+xml',
      '.json' => 'application/json',
      '.js' => 'application/javascript',
      '.py' => 'text/plain; charset=utf-8',
      '.html' || '.htm' => 'text/html; charset=utf-8',
      '.css' => 'text/css; charset=utf-8',
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.xml' => 'application/xml',
      '.txt' || '.log' => 'text/plain; charset=utf-8',
      _ => 'application/octet-stream',
    };
  }

  Future<void> _text(HttpResponse res, int status, String message) async {
    res.statusCode = status;
    res.headers.set('content-type', 'text/plain; charset=utf-8');
    res.add(utf8.encode(message));
    await res.close();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:gbk_codec/gbk_codec.dart';
import 'package:http/http.dart' as http;

import '../errors/app_error.dart';
import '../logging/app_log.dart';
import '../logging/log_redact.dart';
import '../../services/relay/proxy_rules.dart';
import 'doh_client.dart';
import 'url_utils.dart';

class AppHttpException implements Exception {
  AppHttpException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class HttpResponseText {
  HttpResponseText(
    this.url,
    this.body,
    this.statusCode, [
    this.contentType = '',
  ]);
  final String url;
  final String body;
  final int statusCode;
  final String contentType;
}

/// 从 `Set-Cookie` 头里取 `k=v` 片段（多个 Cookie 可能被逗号拼在一起）。
///
/// 只做同站重试用的会话 Cookie：忽略 `Expires` 等属性，不处理 Domain/Path。
String parseSetCookieHeader(String raw) {
  final out = <String>[];
  for (final line in raw.split(RegExp(r',\s*(?=[A-Za-z0-9_\-]+=)'))) {
    final seg = line.split(';').first.trim();
    if (seg.isEmpty || !seg.contains('=')) continue;
    if (seg.toLowerCase().startsWith('expires=')) continue;
    out.add(seg);
  }
  return out.join('; ');
}

class AppHttp {
  AppHttp({http.Client? client}) : _client = client ?? http.Client();

  /// 请求观察者（蜘蛛调试用）：设置后每次发出请求前回调一次。
  ///
  /// 只覆盖走 [AppHttp] 的请求；JS 蜘蛛的 curl 子进程、jar 蜘蛛的 OkHttp
  /// 不经过这里，调试面板不会列出它们 —— 这是刻意的限制，不要假装能看全。
  static void Function(String method, String url)? observer;

  final http.Client _client;
  http.Client? _dohClient;

  /// host → `a=b; c=d`，只用于订阅重试，不持久化。
  final Map<String, String> _cookies = {};

  static const _defaultHeaders = <String, String>{
    'User-Agent': 'okhttp/4.12.0',
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
  };

  Future<HttpResponseText> getText(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
    bool useDoh = false,
  }) async {
    final normalized = normalizeHostUrl(url);
    final mirrors = githubMirrorUrls(normalized);
    // GitHub 直连被墙时通常会卡满超时，先给一个短截止，尽快切到 jsDelivr。
    final firstTimeout =
        mirrors.isEmpty || timeout <= const Duration(seconds: 8)
        ? timeout
        : const Duration(seconds: 8);
    try {
      return await _getTextOnce(
        normalized,
        headers: headers,
        timeout: firstTimeout,
        useDoh: useDoh,
      );
    } catch (e) {
      if (mirrors.isEmpty) rethrow;
      for (final mirror in mirrors) {
        try {
          final res = await _getTextOnce(
            mirror,
            headers: headers,
            timeout: timeout,
            useDoh: useDoh,
          );
          AppLog.i('http', 'GitHub 镜像回退 ${redactUrl(mirror)}');
          return res;
        } catch (_) {
          // 换下一个镜像
        }
      }
      rethrow;
    }
  }

  /// 订阅代理规则：命中的地址改走本机中继的通用代理口（TVBox `rules[].hosts`）。
  ///
  /// 只覆盖走 AppHttp 的请求（CMS / 蜘蛛的 Dart 侧 / 封面 / 字幕接口等）；
  /// JVM 里的 jar 蜘蛛自带 OkHttp，走的是应用设置里的系统代理。
  String _proxyRouted(String url, {Map<String, String>? headers}) {
    final rules = ProxyRules.current;
    if (rules.isEmpty || !rules.matches(url)) return url;
    return rules.rewrite(url, headers: headers);
  }

  Future<HttpResponseText> _getTextOnce(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
    bool useDoh = false,
  }) async {
    final normalized = _proxyRouted(normalizeHostUrl(url), headers: headers);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw AppHttpException('无效的地址：$url');
    }
    final client = useDoh ? (_dohClient ??= createDohClient()) : _client;
    observer?.call('GET', normalized);
    try {
      final res = await client
          .get(uri, headers: {..._defaultHeaders, ...?headers})
          .timeout(timeout);
      // 403/503 也可能带 Set-Cookie（反爬先种 Cookie），要赶在抛错前收下。
      final setCookie = res.headers['set-cookie'];
      if (setCookie != null) _captureCookies(uri, setCookie);
      if (res.statusCode >= 400) {
        AppLog.w('http', 'GET ${redactUrl(normalized)} HTTP ${res.statusCode}');
        throw AppHttpException(
          '站点返回 HTTP ${res.statusCode}',
          statusCode: res.statusCode,
        );
      }
      final body = _decodeBody(res.bodyBytes, res.headers['content-type']);
      return HttpResponseText(
        normalized,
        body,
        res.statusCode,
        res.headers['content-type'] ?? '',
      );
    } on AppHttpException {
      rethrow;
    } catch (e) {
      // 异常文本里可能带完整 URL（含 ?api_key=…），落盘前先给 query 值打码。
      final detail = redactQueryValues(e.toString());
      AppLog.w('http', 'GET ${redactUrl(normalized)} 失败', detail);
      throw AppHttpException(describeAppError(e).message);
    }
  }

  /// 只读响应体开头的 [maxBytes] 字节，用于「先鉴定这是不是直播单」。
  ///
  /// 有的直播单很大（`live.catvod.com` 一份约 1.4MB，生成还慢），导入时整份
  /// 下完再判断会让用户等几十秒；只要开头是 `#EXTM3U` / `#genre#` 之类标记，
  /// 就足以认定是直播源，剩下的交给直播页按需加载。
  ///
  /// 失败 / 超时返回 null，由调用方回落到整份下载。
  Future<HttpResponseText?> probeText(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
    int maxBytes = 32 << 10,
    bool useDoh = false,
  }) async {
    final normalized = _proxyRouted(normalizeHostUrl(url), headers: headers);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return null;
    }
    StreamSubscription<List<int>>? sub;
    try {
      final request = http.Request('GET', uri)
        ..headers.addAll({..._defaultHeaders, ...?headers})
        ..followRedirects = true;
      final client = useDoh ? (_dohClient ??= createDohClient()) : _client;
      observer?.call('GET', normalized);
      final res = await client.send(request).timeout(timeout);
      final setCookie = res.headers['set-cookie'];
      if (setCookie != null) _captureCookies(uri, setCookie);
      if (res.statusCode >= 400) return null;
      final buf = <int>[];
      final done = Completer<void>();
      sub = res.stream.listen(
        (chunk) {
          buf.addAll(chunk);
          if (buf.length >= maxBytes && !done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future.timeout(timeout, onTimeout: () {});
      final body = _decodeBody(
        Uint8List.fromList(buf),
        res.headers['content-type'],
      );
      return HttpResponseText(
        normalized,
        body,
        res.statusCode,
        res.headers['content-type'] ?? '',
      );
    } catch (e) {
      AppLog.w('http', '探测 ${redactUrl(normalized)} 失败', e);
      return null;
    } finally {
      await sub?.cancel();
    }
  }

  /// 表单 POST（解析接口常见的 `url=` 形式）。
  Future<HttpResponseText> postForm(
    String url, {
    required Map<String, String> body,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final normalized = _proxyRouted(normalizeHostUrl(url), headers: headers);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw AppHttpException('无效的地址：$url');
    }
    try {
      observer?.call('POST', normalized);
      final res = await _client
          .post(
            uri,
            headers: {
              ..._defaultHeaders,
              'Content-Type': 'application/x-www-form-urlencoded',
              ...?headers,
            },
            body: Uri(queryParameters: body).query,
          )
          .timeout(timeout);
      final setCookie = res.headers['set-cookie'];
      if (setCookie != null) _captureCookies(uri, setCookie);
      if (res.statusCode >= 400) {
        AppLog.w(
          'http',
          'POST ${redactUrl(normalized)} HTTP ${res.statusCode}',
        );
        throw AppHttpException(
          '站点返回 HTTP ${res.statusCode}',
          statusCode: res.statusCode,
        );
      }
      final text = _decodeBody(res.bodyBytes, res.headers['content-type']);
      return HttpResponseText(
        normalized,
        text,
        res.statusCode,
        res.headers['content-type'] ?? '',
      );
    } on AppHttpException {
      rethrow;
    } catch (e) {
      final detail = redactQueryValues(e.toString());
      AppLog.w('http', 'POST ${redactUrl(normalized)} 失败', detail);
      throw AppHttpException(describeAppError(e).message);
    }
  }

  /// JSON POST（Hhplayer 等解析接口按 `application/json` 收参数）。
  Future<HttpResponseText> postJson(
    String url, {
    required Map<String, dynamic> body,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final normalized = _proxyRouted(normalizeHostUrl(url), headers: headers);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      throw AppHttpException('无效的地址：$url');
    }
    try {
      observer?.call('POST', normalized);
      final res = await _client
          .post(
            uri,
            headers: {
              ..._defaultHeaders,
              'Content-Type': 'application/json',
              ...?headers,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      final setCookie = res.headers['set-cookie'];
      if (setCookie != null) _captureCookies(uri, setCookie);
      if (res.statusCode >= 400) {
        AppLog.w(
          'http',
          'POST ${redactUrl(normalized)} HTTP ${res.statusCode}',
        );
        throw AppHttpException(
          '站点返回 HTTP ${res.statusCode}',
          statusCode: res.statusCode,
        );
      }
      final text = _decodeBody(res.bodyBytes, res.headers['content-type']);
      return HttpResponseText(
        normalized,
        text,
        res.statusCode,
        res.headers['content-type'] ?? '',
      );
    } on AppHttpException {
      rethrow;
    } catch (e) {
      final detail = redactQueryValues(e.toString());
      AppLog.w('http', 'POST ${redactUrl(normalized)} 失败', detail);
      throw AppHttpException(describeAppError(e).message);
    }
  }

  /// 本次会话从该 URL 所在站点捕获的 Cookie（没有则为空串）。
  String cookiesFor(String url) {
    final uri = Uri.tryParse(normalizeHostUrl(url));
    if (uri == null) return '';
    return _cookies[uri.host] ?? '';
  }

  void _captureCookies(Uri uri, String raw) {
    final fresh = parseSetCookieHeader(raw);
    if (fresh.isEmpty) return;
    final values = <String, String>{};
    void absorb(String source) {
      for (final part in source.split(';')) {
        final idx = part.indexOf('=');
        if (idx > 0) {
          values[part.substring(0, idx).trim()] = part
              .substring(idx + 1)
              .trim();
        }
      }
    }

    absorb(_cookies[uri.host] ?? '');
    absorb(fresh);
    if (values.isEmpty) return;
    _cookies[uri.host] = values.entries
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
  }

  String _decodeBody(Uint8List bytes, String? contentType) {
    if (bytes.isEmpty) return '';
    var charset = _charsetOf(contentType);
    if (charset.isEmpty) {
      final head = latin1.decode(bytes.take(2048).toList(), allowInvalid: true);
      final m = RegExp(
        r'''charset\s*=\s*["']?([\w-]+)''',
        caseSensitive: false,
      ).firstMatch(head);
      charset = m?.group(1)?.toLowerCase() ?? '';
    }
    if (charset == 'gbk' || charset == 'gb2312' || charset == 'gb18030') {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        // 落到 UTF-8 兜底
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  String _charsetOf(String? contentType) {
    if (contentType == null) return '';
    final m = RegExp(
      r'charset\s*=\s*([\w-]+)',
      caseSensitive: false,
    ).firstMatch(contentType);
    return m?.group(1)?.toLowerCase() ?? '';
  }

  void close() {
    _client.close();
    _dohClient?.close();
  }
}

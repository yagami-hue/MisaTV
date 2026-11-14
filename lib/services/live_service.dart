import 'dart:convert';
import 'dart:io';

import 'package:gbk_codec/gbk_codec.dart';

import '../core/logging/app_log.dart';
import '../core/logging/log_redact.dart';
import '../core/net/app_http.dart';
import '../core/utils/file_url.dart';
import '../models/live.dart';
import '../models/site_config.dart';
import '../models/vod.dart';
import 'live/live_ua_policy.dart';
import 'live_parser.dart';
import 'source_service.dart';

class LiveService {
  LiveService(this.http, [this._sourceService]);

  final AppHttp http;
  final SourceService? _sourceService;

  /// host → 能取到直播单的 UA。
  ///
  /// 有些直播服务按 UA 放行：`live.catvod.com` 对默认的 `okhttp/4.x` 直接挂住
  /// 不回包，只认 TVBox 客户端的 `okhttp/3.12.0`。记住成功的 UA，后续刷新
  /// 不必每次都先等一轮超时。
  static final Map<String, String> _hostUa = {};

  /// 已知直播服务要求的固定 UA（列表和频道流都要带）。
  ///
  /// `live.ottiptv.cc`（肥羊直播源）会按 UA 下发内容：不带上作者指定的 UA
  /// 时列表里的频道会指向广告流，表现为「能打开但播的是广告」。作者会不定期
  /// 更换这个 UA（`okHttp/Mod-1.5.0.0` → `qqlive`），源站换 UA 后同步改这里。
  static const Map<String, String> hostDefaultUa = {
    'live.ottiptv.cc': 'qqlive',
  };

  /// 查已知服务的固定 UA（host 不区分大小写）。
  static String? defaultUaLiveHost(String host) =>
      hostDefaultUa[host.trim().toLowerCase()];

  Future<List<LiveGroup>> load(
    LiveBean bean, {
    List<SourceBean> sites = const [],
  }) async {
    if (bean.isSpider) {
      return _loadSpider(bean, sites);
    }
    // type 1 和 0 都是普通 txt/m3u 直播源；只有未知类型才拒绝。
    if (bean.type != '0' && bean.type != '1') {
      throw SourceException('不支持的直播类型：${bean.type}');
    }
    var url = bean.url.trim();
    if (url.isEmpty) url = bean.api.trim();
    if (url.contains('/proxy?do=live&type=txt&ext=')) {
      final ext = url.split('ext=').last;
      url = _decodeUrlSafe(ext);
    }
    if (url.startsWith('file://')) {
      try {
        final bytes = await File(filePathOf(url)).readAsBytes();
        return LiveParser.parseToGroups(_decodeLocal(bytes));
      } catch (e) {
        throw SourceException('本地直播源读取失败：$e');
      }
    }
    if (!url.startsWith('http')) {
      throw SourceException('直播订阅地址无效：${bean.url}');
    }
    final host = Uri.tryParse(url)?.host ?? '';
    // 订阅 header 里的 UA 要按大小写不敏感取：订阅常写小写 \`user-agent\`。
    final headerUaValue = liveHeaderValue(bean.header ?? const {}, 'user-agent');
    final headerUa = headerUaValue.isNotEmpty;
    // 用户在「设置 → 直播源 → 自定义直播 UA」里填的内容。
    // 只有**命中的接口规则**算「用户点名给这条直播接口」：与订阅自带 ua 同级，
    // 跳过自动探测，并能盖过订阅 header 里的 UA。全局默认 UA 不算点名 ——
    // 它排在内置表之后（见下面 firstUa），否则给 live.ottiptv.cc 填一个全局
    // UA 就会把必须携带的 qqlive 换掉，列表直接指向广告流（改动前不可能发生，
    // 不能因为这个功能把已知服务搞坏）。
    final policy = LiveUaPolicy.current;
    final ruleUa = policy.matchRule(url);
    final explicitUa = ruleUa != null || bean.ua.isNotEmpty || headerUa;
    var baseHeaders = <String, String>{
      if (bean.ua.isNotEmpty) 'User-Agent': bean.ua,
      ...?bean.header,
    };
    // 规则命中要真的盖过订阅 header：直接给 `baseHeaders['User-Agent']` 赋值，
    // 在订阅写的是小写 `user-agent` 时会并存两个键，发包时哪个生效看遍历顺序。
    if (ruleUa != null) {
      baseHeaders = withLiveHeader(baseHeaders, ruleUa);
    }
    // 列表阶段**实际发出去**的 UA，频道流必须继承同一个值，
    // 否则「列表能刷出来、一点开就 invalid media」——服务端对频道流同样校验。
    //
    // 必须与下面 fetch() 的请求头严格一致：`...?bean.header` 展开在
    // `if (bean.ua.isNotEmpty) 'User-Agent': bean.ua` 之后，订阅 header 里
    // 写了 `user-agent` 时会**盖掉** `bean.ua`，所以这里也以 header 为先。
    // 早先写成 «`bean.ua` > header»，两者同时存在时请求带的是 header-ua、
    // 频道却继承 bean-ua，表现为列表正常但一点开就黑屏。
    final listUa = headerUaValue.isNotEmpty ? headerUaValue : bean.ua;
    final timeout = Duration(seconds: bean.timeout);
    Future<List<LiveGroup>> fetch(String? ua) async {
      final res = await http.getText(
        url,
        headers: {'User-Agent': ?ua, ...baseHeaders},
        timeout: timeout,
      );
      final streamUa = ua ?? ruleUa ?? listUa;
      if (LiveParser.isDirectPlaylist(res.body)) {
        // 订阅地址本身就是一份 HLS 播放列表（不是频道列表）：直接包成一条流，
        // 避免把 .ts 分片当频道解析，播放器拿到半截地址就报 invalid media。
        final groups = LiveParser.directStream(
          bean.displayName,
          url,
          ua: streamUa,
          referer: url,
          header: bean.header,
        );
        AppLog.i(
          'live',
          '加载直播源 ${bean.displayName} 直链播放列表 host=$host ua=$streamUa '
              'url=${redactUrl(url)}',
        );
        return groups;
      }
      final groups = LiveParser.applyDefaults(
        LiveParser.parseToGroups(res.body),
        ua: streamUa,
        // 只给已知「列表和流都校验 Referer」的服务补 Referer；普通公开 M3U
        // 的频道来自各种 CDN，塞一个外部 Referer 反而会被防盗链拒绝。
        referer: (host == 'live.ottiptv.cc' || host == 'live.catvod.com')
            ? url
            : '',
        header: bean.header,
      );
      AppLog.i(
        'live',
        '加载直播源 ${bean.displayName} groups=${groups.length} '
            'channels=${groups.fold<int>(0, (n, g) => n + g.channels.length)} '
            'host=$host ua=$streamUa url=${redactUrl(url)}',
      );
      return groups;
    }

    Object? firstError;
    // 用户没指定 UA 时先用已知服务的固定 UA（如 live.ottiptv.cc 必须
    // `qqlive`），其次用 TVBox 客户端 UA（live.catvod.com 对默认的
    // okhttp/4.x 会直接挂住，等到超时才失败）。
    final knownUa = defaultUaLiveHost(host);
    final defaultUa = policy.defaultUa.trim();
    try {
      final firstUa = explicitUa
          ? null
          : (knownUa ??
                (defaultUa.isNotEmpty ? defaultUa : _hostUa[host]) ??
                _clientUa);
      final groups = await fetch(firstUa);
      // 探测缓存只记「程序选出来的 UA」。用户的全局默认 UA 不写进去：
      // 否则他清掉设置后，本次会话里这个 host 还会继续用那个 UA。
      if (firstUa != null && firstUa != defaultUa) _hostUa[host] = firstUa;
      return groups;
    } catch (e) {
      firstError = e;
    }
    // 只认现代 UA 的服务再用默认头试一次；已知必须固定 UA 的服务不能退回
    // 无 UA（那会拿到广告流）。
    if (!explicitUa && knownUa == null) {
      try {
        return await fetch(null);
      } catch (_) {
        // 仍失败时保留第一次的错误
      }
    }
    if (firstError is AppHttpException) {
      throw SourceException('直播订阅加载失败：${firstError.message}');
    }
    throw SourceException('直播订阅加载失败：$firstError');
  }

  /// TVBox / winbox 客户端的 UA：不少直播服务只对它放行。
  static const _clientUa = 'okhttp/3.12.0';

  /// 直播蜘蛛（type=3 或带 api 的直播源）：找同 api / key 的点播源，
  /// 没有就在本地合成一个蜘蛛源；清单地址取自 `url`（与上游一致）。
  Future<List<LiveGroup>> _loadSpider(
    LiveBean bean,
    List<SourceBean> sites,
  ) async {
    final service = _sourceService;
    if (service == null) throw SourceException('直播蜘蛛需要蜘蛛服务支持');
    final synthesized = bean.spiderSite;
    if (synthesized == null) {
      throw SourceException('直播蜘蛛没有 api 地址（${bean.displayName}）');
    }
    final api = synthesized.api;

    SourceBean? site;
    for (final item in sites) {
      if (item.api.trim() == api || item.key.trim() == api) {
        site = item;
        break;
      }
    }
    final raw = await service.liveContent(
      site ?? synthesized,
      bean.spiderInput,
    );
    if (raw.trim().isEmpty) return const [];
    return LiveParser.parseToGroups(raw);
  }

  /// 直播蜘蛛的频道地址常常指向 `http://127.0.0.1:9978/proxy?do=py&...`：
  /// 地址要等点击时才向蜘蛛取（收视授权/动态签名），这里把 302 Location
  /// 解出来交给播放器。
  Future<String> resolveProxyPlay(LiveBean bean, String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !isSpiderProxyUrl(url)) return url;
    final service = _sourceService;
    final site = bean.spiderSite;
    if (service == null || site == null || !site.isPySpider) {
      throw SourceException('该直播源不是 PY 蜘蛛，无法解析播放地址');
    }
    final params = Map<String, String>.from(uri.queryParameters)..remove('do');
    final result = await service.py.proxy(site, params);
    if (result.status >= 300 && result.status < 400) {
      final location = result.header('location');
      if (location.isNotEmpty) return location;
    }
    final detail = result.body.trim();
    throw SourceException(
      detail.isEmpty ? '直播蜘蛛未返回播放地址（HTTP ${result.status}）' : detail,
    );
  }

  /// 本机 `/proxy?do=py` 蜘蛛代理地址（TVBox 直播蜘蛛取流的约定）。
  static bool isSpiderProxyUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    if (uri.path != '/proxy') return false;
    if (uri.queryParameters['do'] != 'py') return false;
    return uri.host == '127.0.0.1' ||
        uri.host == 'localhost' ||
        uri.host.isEmpty;
  }

  String _decodeLocal(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        return latin1.decode(bytes);
      }
    }
  }

  String _decodeUrlSafe(String input) {
    var s = input.trim();
    final idx = s.indexOf('&');
    if (idx >= 0) s = s.substring(0, idx);
    try {
      s = s.replaceAll('-', '+').replaceAll('_', '/');
      while (s.length % 4 != 0) {
        s += '=';
      }
      return utf8.decode(base64Url.decode(s));
    } catch (_) {
      try {
        return utf8.decode(base64.decode(s));
      } catch (_) {
        return input;
      }
    }
  }
}

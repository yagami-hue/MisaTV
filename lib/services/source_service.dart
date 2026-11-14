import 'dart:convert';

import '../core/logging/app_log.dart';
import '../core/logging/log_redact.dart';
import '../core/utils/text_utils.dart';
import '../models/site_config.dart';
import '../models/vod.dart';
import 'cms_source.dart';
import 'jar_spider_service.dart';
import 'js_spider_service.dart';
import 'kazumi/kazumi_source.dart';
import 'py_spider_service.dart';
import 'source/source_adapter.dart';
import 'source/source_adapters.dart';

class SourceService {
  SourceService(this.cms, this.js, this.py, this.jar)
    : kazumi = KazumiSource(cms.http) {
    // 顺序即优先级；CMS 是兜底，必须放最后（它的 supports 恒为 true）。
    _adapters = [
      KazumiSourceAdapter(kazumi),
      JsSourceAdapter(js),
      PySourceAdapter(py),
      JarSourceAdapter(jar),
      CmsSourceAdapter(cms),
    ];
  }

  final CmsSource cms;
  final JsSpiderService js;
  final PySpiderService py;
  final JarSpiderService jar;

  /// Kazumi 规则源（type=5）：搜索/选集走规则，播放交给网页嗅探。
  final KazumiSource kazumi;

  late final List<SourceAdapter> _adapters;

  SourceAdapter _adapterFor(SourceBean site) =>
      _adapters.firstWhere((adapter) => adapter.supports(site));

  /// 配置级全局 spider jar：JAR 源自身未写 `jar` 时用它。
  void setGlobalJar(String url) => jar.globalJar = url.trim();

  /// 应用退出：结束常驻取流进程（PY / JAR）等后台子进程。
  Future<void> shutdown() async {
    await py.shutdown();
    await jar.shutdown();
  }

  /// 统一记录一次源调用（类型 / 耗时 / 结果 / 失败堆栈），便于复盘。
  Future<T> _logged<T>(
    String op,
    SourceBean site,
    Future<T> Function() body, {
    String note = '',
    String Function(T value)? summarize,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final value = await body();
      AppLog.i(
        'source',
        '$op key=${site.key} type=${site.type} ${note.isEmpty ? '' : '$note '}'
            '${sw.elapsedMilliseconds}ms${summarize == null ? '' : ' ${summarize(value)}'}',
      );
      return value;
    } catch (e, s) {
      AppLog.e(
        'source',
        '$op key=${site.key} type=${site.type} ${note.isEmpty ? '' : '$note '}'
            '${sw.elapsedMilliseconds}ms api=${redactUrl(site.api)}',
        e,
        s,
      );
      rethrow;
    }
  }

  Future<CmsResult> home(SourceBean site) => _logged(
    'home',
    site,
    () => _adapterFor(site).home(site),
    summarize: (r) => 'items=${r.items.length} classes=${r.classes.length}',
  );

  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  ) => _logged(
    'category',
    site,
    () => _adapterFor(site).category(site, tid, pg, filters),
    note: 'tid=$tid pg=$pg filters=${filters.length}',
    summarize: (r) => 'items=${r.items.length} page=${r.page}/${r.pagecount}',
  );

  Future<VodDetail?> detail(
    SourceBean site,
    String id, {
    String name = '',
  }) => _logged(
    'detail',
    site,
    () => _adapterFor(site).detail(site, id, name: name),
    note: 'id=${shorten(id, 80)}',
    summarize: (d) => d == null
        ? 'null'
        : 'flags=${d.flags.length} episodes=${d.flags.map((f) => d.episodes[f]?.length ?? 0).join(',')}',
  );

  Future<List<VodItem>> search(SourceBean site, String keyword) => _logged(
    'search',
    site,
    () => _adapterFor(site).search(site, keyword),
    note: 'wd=${shorten(keyword, 40)}',
    summarize: (items) => 'items=${items.length}',
  );

  /// 直播蜘蛛（type=3）：调用 `liveContent(url)` 拿直播订阅原文。
  Future<String> liveContent(SourceBean site, String url) => _logged(
    'live',
    site,
    () => _adapterFor(site).live(site, url),
    note: 'url=${redactUrl(url)}',
    summarize: (text) => 'chars=${text.length}',
  );

  Future<PlayResult> resolvePlay({
    required SourceBean site,
    required SiteConfig config,
    required String flag,
    required String rawUrl,
    bool jarReady = false,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final result = await _resolvePlayInner(
        site: site,
        config: config,
        flag: flag,
        rawUrl: rawUrl,
        jarReady: jarReady,
      );
      AppLog.i(
        'play',
        'resolve site=${site.key} flag=$flag ${sw.elapsedMilliseconds}ms '
            'url=${redactUrl(result.url)} parse=${result.parse} '
            'raw=${shorten(redactUrl(rawUrl), 120)} '
            'msg=${shorten(result.message, 160)}',
      );
      return result;
    } catch (e, s) {
      AppLog.e(
        'play',
        'resolve site=${site.key} flag=$flag ${sw.elapsedMilliseconds}ms '
            'raw=${redactUrl(rawUrl)}',
        e,
        s,
      );
      rethrow;
    }
  }

  Future<PlayResult> _resolvePlayInner({
    required SourceBean site,
    required SiteConfig config,
    required String flag,
    required String rawUrl,
    bool jarReady = false,
  }) async {
    if (!(site.supported || (jarReady && site.isJarSpider))) {
      return PlayResult(url: '', message: site.unsupportedReason);
    }
    final raw = rawUrl.trim();
    if (raw.isEmpty) return const PlayResult(url: '', message: '播放地址为空');

    final adapter = _adapterFor(site);

    // Kazumi 规则：剧集地址是播放页 → parse=1，由上游网页嗅探出媒体直链；
    // 选集接口直接给 m3u8/mp4 时按直链播放。
    if (adapter.family == SourceFamily.kazumi) {
      return await adapter.play(
            site,
            flag,
            raw,
            vipFlags: config.flags,
          ) ??
          const PlayResult(url: '', message: 'Kazumi 规则未返回播放地址');
    }

    String? spiderError;
    if (adapter.family != SourceFamily.cms) {
      try {
        final spiderPlay = await adapter.play(
          site,
          flag,
          raw,
          vipFlags: config.flags,
        );
        if (spiderPlay != null) return spiderPlay;
      } on SourceException catch (e) {
        spiderError = e.message;
      }
    }

    // site.playUrl 模板：含 `{playUrl}` 时用剧集地址替换（对齐 TVBox 的 CMS 播放口径）。
    var target = raw;
    final template = site.playUrl.trim();
    if (site.type != 3 && template.contains('{playUrl}')) {
      target = template.replaceAll('{playUrl}', raw);
    }

    // 磁力/电驴链接直接交给内置 BT 引擎：剧集地址本身就是 magnet 时，
    // 蜘蛛的 playerContent 只会回「不是可播放直链」，上层再误判成线路不可用。
    if (RegExp(r'^magnet:', caseSensitive: false).hasMatch(target) ||
        RegExp(r'^ed2k://', caseSensitive: false).hasMatch(target)) {
      return PlayResult(
        url: '',
        flag: flag,
        message: '磁力/电驴链接由内置 BT 引擎播放',
        externalLink: target,
      );
    }

    if (config.flags.contains(flag)) {
      return PlayResult(
        url: '',
        parse: 1,
        flag: flag,
        message: '该资源需要 VIP 解析（$flag），轻量内核暂未内置解析服务',
      );
    }

    if (RegExp(r'^thunder://', caseSensitive: false).hasMatch(target)) {
      final inner = decodeThunder(target);
      if (inner.isEmpty) {
        return const PlayResult(url: '', message: 'thunder 链接解码失败');
      }
      return resolvePlay(
        site: site,
        config: config,
        flag: flag,
        rawUrl: inner,
        jarReady: jarReady,
      );
    }
    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(target)) {
      final headers = splitUrlHeaders(target);
      return PlayResult(url: target, flag: flag, headers: headers, message: '');
    }
    if (RegExp(r'^(rtmp|rtsp|mms)', caseSensitive: false).hasMatch(target)) {
      return PlayResult(url: target, flag: flag);
    }
    if (RegExp(r'^ftp://', caseSensitive: false).hasMatch(target)) {
      return PlayResult(
        url: '',
        flag: flag,
        message: 'FTP 地址需要外部播放器',
        externalLink: target,
      );
    }
    if (spiderError != null && spiderError.isNotEmpty) {
      return PlayResult(url: '', flag: flag, message: spiderError);
    }
    return PlayResult(
      url: '',
      parse: 1,
      flag: flag,
      message: '该地址需要第三方解析，轻量内核暂未内置',
    );
  }

  static String decodeThunder(String raw) {
    final s = raw.trim();
    if (!RegExp(r'^thunder://', caseSensitive: false).hasMatch(s)) return '';
    final b64 = s
        .replaceFirst(RegExp(r'^thunder://', caseSensitive: false), '')
        .trim();
    if (b64.isEmpty) return '';
    try {
      final decoded = utf8.decode(base64.decode(b64), allowMalformed: true);
      final m = RegExp(r'^AA([\s\S]*?)ZZ$').firstMatch(decoded);
      return m?.group(1)?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }
}

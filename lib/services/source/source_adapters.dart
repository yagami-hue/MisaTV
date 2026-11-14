import '../../models/site_config.dart';
import '../../models/vod.dart';
import '../cms_source.dart';
import '../jar_spider_service.dart';
import '../js_spider_service.dart';
import '../kazumi/kazumi_source.dart';
import '../py_spider_service.dart';
import 'source_adapter.dart';

/// CMS / JS / PY / JAR / Kazumi 五种源类型的适配器。
///
/// 适配器只做转发，不改变原有参数与异常语义；日志、VIP 标记、URL 模板等
/// 公共逻辑仍留在 [SourceService]。

class CmsSourceAdapter extends SourceAdapter {
  const CmsSourceAdapter(this.cms);

  final CmsSource cms;

  @override
  SourceFamily get family => SourceFamily.cms;

  /// CMS 是兜底类型：前面四种都不匹配时都按 CMS 处理。
  @override
  bool supports(SourceBean site) => true;

  @override
  Future<CmsResult> home(SourceBean site) => cms.home(site);

  @override
  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  ) => cms.category(site, tid, pg, filters);

  @override
  Future<VodDetail?> detail(
    SourceBean site,
    String id, {
    String name = '',
  }) => cms.detail(site, id);

  @override
  Future<List<VodItem>> search(SourceBean site, String keyword) =>
      cms.search(site, keyword);

  @override
  Future<String> live(SourceBean site, String url) async {
    throw SourceException('${site.displayName} 不是蜘蛛源，无法加载直播');
  }
}

class JsSourceAdapter extends SourceAdapter {
  const JsSourceAdapter(this.js);

  final JsSpiderService js;

  @override
  SourceFamily get family => SourceFamily.js;

  @override
  bool supports(SourceBean site) => site.isJsSpider;

  @override
  Future<CmsResult> home(SourceBean site) => js.home(site);

  @override
  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  ) => js.category(site, tid, pg, filters);

  @override
  Future<VodDetail?> detail(
    SourceBean site,
    String id, {
    String name = '',
  }) => js.detail(site, id);

  @override
  Future<List<VodItem>> search(SourceBean site, String keyword) =>
      js.search(site, keyword);

  @override
  Future<String> live(SourceBean site, String url) => js.live(site, url);

  @override
  Future<PlayResult?> play(
    SourceBean site,
    String flag,
    String rawUrl, {
    required List<String> vipFlags,
  }) => js.play(site, flag, rawUrl, vipFlags: vipFlags);
}

class PySourceAdapter extends SourceAdapter {
  const PySourceAdapter(this.py);

  final PySpiderService py;

  @override
  SourceFamily get family => SourceFamily.py;

  @override
  bool supports(SourceBean site) => site.isPySpider;

  @override
  Future<CmsResult> home(SourceBean site) => py.home(site);

  @override
  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  ) => py.category(site, tid, pg, filters);

  @override
  Future<VodDetail?> detail(
    SourceBean site,
    String id, {
    String name = '',
  }) => py.detail(site, id);

  @override
  Future<List<VodItem>> search(SourceBean site, String keyword) =>
      py.search(site, keyword);

  @override
  Future<String> live(SourceBean site, String url) => py.live(site, url);

  @override
  Future<PlayResult?> play(
    SourceBean site,
    String flag,
    String rawUrl, {
    required List<String> vipFlags,
  }) => py.play(site, flag, rawUrl, vipFlags: vipFlags);
}

class JarSourceAdapter extends SourceAdapter {
  JarSourceAdapter(this.jar);

  final JarSpiderService jar;

  @override
  SourceFamily get family => SourceFamily.jar;

  @override
  bool supports(SourceBean site) => site.isJarSpider;

  @override
  Future<CmsResult> home(SourceBean site) => jar.home(site);

  @override
  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  ) => jar.category(site, tid, pg, filters);

  @override
  Future<VodDetail?> detail(
    SourceBean site,
    String id, {
    String name = '',
  }) => jar.detail(site, id);

  @override
  Future<List<VodItem>> search(SourceBean site, String keyword) =>
      jar.search(site, keyword);

  @override
  Future<String> live(SourceBean site, String url) => jar.live(site, url);

  @override
  Future<PlayResult?> play(
    SourceBean site,
    String flag,
    String rawUrl, {
    required List<String> vipFlags,
  }) => jar.play(site, flag, rawUrl, vipFlags: vipFlags);
}

class KazumiSourceAdapter extends SourceAdapter {
  const KazumiSourceAdapter(this.kazumi);

  final KazumiSource kazumi;

  @override
  SourceFamily get family => SourceFamily.kazumi;

  @override
  bool supports(SourceBean site) => site.isKazumi;

  @override
  Future<CmsResult> home(SourceBean site) => kazumi.home(site);

  @override
  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  ) => kazumi.category(site, tid, pg);

  @override
  Future<VodDetail?> detail(
    SourceBean site,
    String id, {
    String name = '',
  }) => kazumi.detail(site, id, name: name);

  @override
  Future<List<VodItem>> search(SourceBean site, String keyword) =>
      kazumi.search(site, keyword);

  @override
  Future<String> live(SourceBean site, String url) async {
    throw SourceException('${site.displayName} 不是蜘蛛源，无法加载直播');
  }

  @override
  Future<PlayResult?> play(
    SourceBean site,
    String flag,
    String rawUrl, {
    required List<String> vipFlags,
  }) async => kazumi.play(site, rawUrl);
}

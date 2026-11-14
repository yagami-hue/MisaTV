import '../../models/site_config.dart';
import '../../models/vod.dart';

/// 源类型家族：决定播放链路是否需要先走蜘蛛。
enum SourceFamily { cms, js, py, jar, kazumi }

/// 一种源类型的取数实现。
///
/// 之前 [SourceService] 里每个方法都是一串 `if (site.isJsSpider) ...` 分支，
/// 新增源类型要改 5 个方法、漏改一处就会出现「首页能看、搜索报错」这类半可用状态。
/// 现在把每种类型收敛到一个适配器，[SourceService] 只负责日志与播放兜底。
abstract class SourceAdapter {
  const SourceAdapter();

  SourceFamily get family;

  /// 是否由本适配器处理；注册表按顺序取第一个命中的，CMS 作为兜底恒为 true。
  bool supports(SourceBean site);

  Future<CmsResult> home(SourceBean site);

  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  );

  Future<VodDetail?> detail(SourceBean site, String id, {String name = ''});

  Future<List<VodItem>> search(SourceBean site, String keyword);

  /// 直播蜘蛛（type=3）取直播订阅原文。
  Future<String> live(SourceBean site, String url);

  /// 蜘蛛取播；返回 null 表示该类型没有蜘蛛播放链路，交给 URL 模板兜底。
  Future<PlayResult?> play(
    SourceBean site,
    String flag,
    String rawUrl, {
    required List<String> vipFlags,
  }) async => null;
}

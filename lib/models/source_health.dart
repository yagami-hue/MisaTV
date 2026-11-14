import '../core/logging/log_redact.dart';
import 'site_config.dart';
import 'vod.dart';

/// 单个源的主页体检结果。
///
/// 分类与 winbox 的 `classifyHealth` 对齐：
/// - `ok-content`：主页直接解析到条目；
/// - `ok-classes`：主页没有条目，但有分类可点；
/// - `needs-ext`：蜘蛛主页为空且 ext 未配置（补 ext 后可能可用）；
/// - `empty`：请求成功但既无条目也无分类；
/// - `error`：请求或蜘蛛执行抛错。
class SourceHealth {
  const SourceHealth({
    required this.key,
    required this.name,
    required this.status,
    required this.message,
    this.items = 0,
    this.classes = 0,
    this.elapsedMs = 0,
  });

  final String key;
  final String name;
  final String status;
  final String message;
  final int items;
  final int classes;

  /// 本次探测耗时（毫秒）；0 表示未统计（如冷却跳过）。
  final int elapsedMs;

  bool get ok => status == 'ok-content' || status == 'ok-classes';
  bool get needsExt => status == 'needs-ext';

  SourceHealth withElapsed(int ms) => SourceHealth(
    key: key,
    name: name,
    status: status,
    message: message,
    items: items,
    classes: classes,
    elapsedMs: ms,
  );

  factory SourceHealth.fromHome(SourceBean site, CmsResult result) {
    final items = result.items.length;
    final classes = result.classes.length;
    if (items > 0) {
      return SourceHealth(
        key: site.key,
        name: site.displayName,
        status: 'ok-content',
        message: result.homeFallback ? '首页无列表，已回退到首个分类（$items 条）' : '首页解析到 $items 条内容',
        items: items,
        classes: classes,
      );
    }
    if (classes > 0) {
      return SourceHealth(
        key: site.key,
        name: site.displayName,
        status: 'ok-classes',
        message: '首页无推荐，但有 $classes 个分类可浏览',
        items: items,
        classes: classes,
      );
    }
    if (site.type == 3 && site.ext.trim().isEmpty) {
      return SourceHealth(
        key: site.key,
        name: site.displayName,
        status: 'needs-ext',
        message: '蜘蛛首页为空且 ext 未配置：在站点编辑里补上 ext（通用站点填 {"siteUrl": ...}）',
      );
    }
    final cms = site.type == 0 || site.type == 1 || site.type == 4;
    return SourceHealth(
      key: site.key,
      name: site.displayName,
      status: 'empty',
      message: cms
          ? '主页请求成功但没有内容（源站可能已失效；部分 CMS 需要 api 后补 ?ac=videolist）'
          : '主页请求成功但没有内容（源站可能已失效或接口结构变化）',
    );
  }

  factory SourceHealth.failure(SourceBean site, Object error) {
    final raw = error is SourceException ? error.message : '$error';
    // 审计报告会导出给用户 / 贴到反馈里：先把 URL 里的凭据遮掉。
    final message = redactQueryValues(raw.replaceAll('\n', ' ').trim());
    return SourceHealth(
      key: site.key,
      name: site.displayName,
      status: 'error',
      message: message.isEmpty ? '请求失败' : shorten(message, 300),
    );
  }

  String get statusLabel => switch (status) {
        'ok-content' => '有内容',
        'ok-classes' => '有分类',
        'needs-ext' => '需补 ext',
        _ => '不可用',
      };
}

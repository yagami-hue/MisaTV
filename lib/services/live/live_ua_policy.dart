/// 用户自定义的直播 UA 策略（设置 → 内容与订阅 → 直播源 → 自定义直播 UA）。
///
/// 两类真实需求：
///   1. 某个直播服务换了 UA 规则，内置表（`LiveService.hostDefaultUa`）还没跟上 —— 用户自己填；
///   2. 只能对**某一个直播接口**生效：强 UA 的服务（live.ottiptv.cc 这类）不能因为
///      别的源填了 UA 就被影响，反之用户给某条源填的 UA 也不能传染给整个 App。
///
/// 生效优先级（`resolve`）：
///   命中的接口规则 > 订阅自带的 ua（`LiveBean.ua`）> 全局默认 UA > 内置表 / 自动探测。
///
/// 留空 = 不参与，整套行为退回改动前（已知服务用其指定 UA，其余用 okhttp/3.12.0）。
library;

import 'dart:convert';

/// 频道流打开时该用的 UA：命中这条接口地址的规则优先，其次沿用已有的
/// [currentUa]（来自订阅或直播单），再次是全局默认 UA；都拿不到时返回空串。
///
/// 直播单地址与频道流地址常常不是同一个 host（CDN 线路），所以播放器侧要按
/// **实际取流的地址**再解一次，不能只信列表阶段的结果。
String resolveLiveStreamUa(String url, {String currentUa = ''}) {
  final policy = LiveUaPolicy.current;
  return policy.matchRule(url) ?? policy.resolve(url, subscriptionUa: currentUa);
}

/// 大小写不敏感地取请求头。
///
/// 订阅里的 `header` 常写成小写 `user-agent`（JS / PY 蜘蛛的写法），按
/// `headers['User-Agent']` 直接取会取不到 —— 于是「订阅自带的 UA」被当成不存在，
/// 全局默认 UA 反过来把它盖掉，与文档写的优先级相反。
String liveHeaderValue(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return '';
}

/// 大小写不敏感地写入请求头，并清掉同名的大小写变体。
///
/// `package:http` 发包时会把头名统一转小写，同一个 Map 里同时存在
/// `user-agent` 与 `User-Agent` 时哪一个生效取决于遍历顺序 —— 必须先去重。
Map<String, String> withLiveHeader(
  Map<String, String> headers,
  String value,
) {
  return {
    for (final e in headers.entries)
      if (e.key.toLowerCase() != 'user-agent') e.key: e.value,
    'User-Agent': value,
  };
}

/// 按实际取流地址把 UA 落到 [headers] 上（播放器 / 回看共用）。
///
/// 规则命中覆盖一切；否则只填空位，绝不抢走订阅或直播单已经带的 UA。
void applyLiveStreamUa(Map<String, String> headers, String url) {
  final ua = resolveLiveStreamUa(
    url,
    currentUa: liveHeaderValue(headers, 'user-agent'),
  );
  if (ua.isEmpty) return;
  final merged = withLiveHeader(headers, ua);
  headers
    ..clear()
    ..addAll(merged);
}

/// 一条「接口 → UA」规则。[pattern] 的匹配语义与 `ProxyRules` 一致：
/// 带正则元字符的按正则匹配，非法正则退回普通包含匹配（不丢规则）。
class LiveUaRule {
  const LiveUaRule({required this.pattern, required this.ua});

  /// 匹配片段：host（`live.ottiptv.cc`）、地址片段（`/bstation`）或正则。
  final String pattern;

  /// 命中后要使用的 User-Agent。
  final String ua;

  Map<String, dynamic> toJson() => {'pattern': pattern, 'ua': ua};

  factory LiveUaRule.fromJson(Map json) => LiveUaRule(
    pattern: (json['pattern'] ?? json['host'] ?? '').toString().trim(),
    ua: (json['ua'] ?? '').toString().trim(),
  );
}

/// 当前生效的直播 UA 策略；静态持有，与 `ProxyRules.current` 同一套做法
/// （LiveService 与本机中继都要读，但都不持有 AppState）。
class LiveUaPolicy {
  const LiveUaPolicy({this.defaultUa = '', this.rules = const []});

  /// 全局默认 UA：只在订阅没写 ua、且没有规则命中时兜底。空串 = 不启用。
  final String defaultUa;

  /// 按接口的例外规则，靠前者优先命中。
  final List<LiveUaRule> rules;

  static final LiveUaPolicy none = LiveUaPolicy();

  /// 当前生效的策略；AppState 在启动 / 保存 / 恢复备份 / 子窗口 reload 时登记。
  static LiveUaPolicy current = none;

  static final RegExp _regexMeta = RegExp(r'[*()\[\]\\|^$+?]');

  bool get isEmpty => defaultUa.trim().isEmpty && rules.isEmpty;

  /// 解析 [url] 这个直播接口该用哪个 UA。
  ///
  /// [subscriptionUa] 是订阅里这条源自带的 `ua` 字段（`LiveBean.ua`）。
  /// 返回空串表示「用户没指定」，由调用方回落到内置表 / 自动探测。
  String resolve(String url, {String subscriptionUa = ''}) {
    final hit = matchRule(url);
    if (hit != null && hit.isNotEmpty) return hit;
    final sub = subscriptionUa.trim();
    if (sub.isNotEmpty) return sub;
    return defaultUa.trim();
  }

  /// 命中的第一条规则的 UA；没有规则命中返回 null（区别于「命中但 UA 是空的」）。
  String? matchRule(String url) {
    if (url.isEmpty || rules.isEmpty) return null;
    final lower = url.toLowerCase();
    for (final rule in rules) {
      final pattern = rule.pattern.trim();
      if (pattern.isEmpty) continue;
      if (_matches(pattern, rule.ua, lower)) return rule.ua.trim();
    }
    return null;
  }

  bool _matches(String pattern, String ua, String lowerUrl) {
    if (ua.trim().isEmpty) return false;
    if (!_regexMeta.hasMatch(pattern)) {
      // 普通片段 / host：按地址包含匹配（host 天然包含在 url 里）。
      return lowerUrl.contains(pattern.toLowerCase());
    }
    try {
      return RegExp(pattern, caseSensitive: false).hasMatch(lowerUrl);
    } catch (_) {
      // 正则写错时按普通片段处理，别把这条规则丢掉。
      return lowerUrl.contains(pattern.toLowerCase());
    }
  }

  /// 有效规则条数（设置页的「已配置 N 条」摘要；解析时已剔除空规则，这里等于 rules.length）。
  int get ruleCount => rules.length;

  Map<String, dynamic> toJson() => {
    'defaultUa': defaultUa,
    'rules': rules.map((e) => e.toJson()).toList(),
  };

  String toJsonString() => jsonEncode(toJson());

  /// 宽容解析：字段缺失 / 类型不对都退回默认值，绝不因为一份写坏的设置让直播全挂。
  factory LiveUaPolicy.fromJson(Map json) {
    final rules = <LiveUaRule>[];
    if (json['rules'] is List) {
      for (final item in json['rules'] as List) {
        if (item is! Map) continue;
        final rule = LiveUaRule.fromJson(item);
        if (rule.pattern.isEmpty || rule.ua.isEmpty) continue;
        // 同一片段只保留**第一条**：必须与 `matchRule` 的「靠前者优先」一致，
        // 否则同一份规则在内存里（保存后立刻用）与重启后（走了本方法去重）
        // 会给出不同的 UA。重复条目由设置页在添加时就替换掉，不会产生。
        final dup = rules.any(
          (r) => r.pattern.toLowerCase() == rule.pattern.toLowerCase(),
        );
        if (dup) continue;
        rules.add(rule);
      }
    }
    return LiveUaPolicy(
      defaultUa: (json['defaultUa'] ?? json['ua'] ?? '').toString().trim(),
      rules: rules,
    );
  }

  factory LiveUaPolicy.fromJsonString(String text) {
    if (text.trim().isEmpty) return none;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return LiveUaPolicy.fromJson(decoded);
    } catch (_) {
      // 设置损坏：退回「不启用」，不能影响直播加载。
    }
    return none;
  }
}

class SourceBean {
  const SourceBean({
    required this.key,
    required this.name,
    required this.type,
    required this.api,
    this.searchable = 1,
    this.quickSearch = 1,
    this.changeable = 1,
    this.filterable = 1,
    this.playUrl = '',
    this.ext = '',
    this.jar = '',
    this.playerType = -1,
    this.categories,
    this.timeout = 15,
    this.click = '',
    this.style = '',
    this.homePage = '',
  });

  final String key;
  final String name;
  final int type;
  final String api;
  final int searchable;
  final int quickSearch;
  final int changeable;
  final int filterable;
  final String playUrl;
  final String ext;
  final String jar;
  final int playerType;
  final List<String>? categories;
  final int timeout;
  final String click;
  final String style;
  final String homePage;

  bool get isCms => type == 0 || type == 1 || type == 4;
  bool get isJsSpider =>
      type == 3 && (api.contains('.js') || api.contains('.js?'));
  bool get isJarSpider => type == 3 && !isJsSpider && !isPySpider;
  bool get isPySpider => type == 3 && api.contains('.py');

  /// Kazumi 规则源（type=5）：搜索/选集走规则，播放页交给网页嗅探。
  bool get isKazumi => type == 5;

  /// 推荐型源（豆瓣 / 豆豆片单）：只有榜单数据，没有可播资源，
  /// 点击条目应改为按片名全源搜索。
  bool get isDouban =>
      type == 3 &&
      RegExp(
        r'douban|豆瓣|豆豆|片单',
        caseSensitive: false,
      ).hasMatch('$api $key $name');

  bool get supported =>
      isCms || isJsSpider || isPySpider || isKazumi;

  String get kindLabel {
    if (type == 0) return 'CMS XML';
    if (type == 1 || type == 4) return 'CMS JSON';
    if (isKazumi) return 'KAZUMI';
    if (isJsSpider) return 'JS';
    if (isPySpider) return 'PY';
    if (isJarSpider) return 'JAR';
    return 'TYPE $type';
  }

  String get unsupportedReason {
    if (isCms || isJsSpider || isPySpider || isKazumi) return '';
    if (type == -1) return '推送源（PUSH）暂不支持';
    if (isJarSpider) return 'JAR / DEX 源需要先下载 JVM 运行时（设置 → 播放 → JVM 运行时）';
    return '未知源类型，无法使用';
  }

  String get displayName => name.trim().isEmpty ? key : name.trim();

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'type': type,
    'api': api,
    'searchable': searchable,
    'quickSearch': quickSearch,
    'changeable': changeable,
    'filterable': filterable,
    'playUrl': playUrl,
    'ext': ext,
    'jar': jar,
    'playerType': playerType,
    if (categories != null) 'categories': categories,
    'timeout': timeout,
    'click': click,
    'style': style,
    'homePage': homePage,
  };

  factory SourceBean.fromJson(Map<String, dynamic> json) {
    final key = (json['key'] ?? '').toString().trim();
    return SourceBean(
      key: key,
      name: (json['name'] ?? key).toString(),
      type: _int(json['type']),
      api: (json['api'] ?? '').toString(),
      searchable: _int(json['searchable'], 1),
      quickSearch: _int(json['quickSearch'], 1),
      changeable: _int(json['changeable'], 1),
      filterable: _int(json['filterable'], 1),
      playUrl: (json['playUrl'] ?? '').toString(),
      ext: json['ext']?.toString() ?? '',
      jar: (json['jar'] ?? '').toString(),
      playerType: _int(json['playerType'], -1),
      categories: (json['categories'] as List?)
          ?.map((e) => e.toString())
          .toList(),
      timeout: _int(json['timeout'], 15),
      click: (json['click'] ?? '').toString(),
      style: (json['style'] ?? '').toString(),
      homePage: (json['homePage'] ?? '').toString(),
    );
  }

  static int _int(dynamic v, [int def = 0]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? def;
  }
}

class ParseBean {
  const ParseBean({
    required this.name,
    required this.url,
    this.ext = '',
    this.type = 0,
  });

  final String name;
  final String url;
  final String ext;
  final int type;

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'ext': ext,
    'type': type,
  };

  factory ParseBean.fromJson(Map<String, dynamic> json) => ParseBean(
    name: (json['name'] ?? '').toString(),
    url: (json['url'] ?? '').toString(),
    ext: json['ext']?.toString() ?? '',
    type: int.tryParse(json['type']?.toString() ?? '') ?? 0,
  );
}

/// 直播 UA 输入框的说明文案（设置页与文档共用同一措辞）。
///
/// 有些直播服务按 UA 下发**不同内容**：不带指定 UA 时列表会指向广告流，
/// 表现为「能打开但播的是广告」。留空时程序按 host 自动选择已知 UA，
/// 其余回落 `okhttp/3.12.0`；填了则只对这一个直播源生效。
///
/// 「设置 → 直播源 → 自定义直播 UA」里针对具体接口的例外规则会覆盖这里的值；
/// 那里的全局默认 UA 不会（订阅自带的 ua 优先级更高）。
const String kLiveUaHelper =
    '只作用于当前这一条直播源。留空 = 自动：已知服务（如 live.ottiptv.cc）用其指定 UA，'
    '其余用 okhttp/3.12.0。列表与频道流都会带上它。';

class LiveBean {
  const LiveBean({
    required this.name,
    required this.api,
    required this.type,
    required this.url,
    this.jar = '',
    this.ext = '',
    this.epg = '',
    this.playerType = '',
    this.timeZone = '',
    this.timeout = 15,
    this.header,
    this.ua = '',
  });

  final String name;
  final String api;
  final String type;
  final String url;
  final String jar;
  final String ext;
  final String epg;
  final String playerType;

  /// EPG 时区（IANA，如 `Asia/Shanghai`）；空 = 本机时区。
  final String timeZone;
  final int timeout;
  final Map<String, String>? header;
  final String ua;

  /// type=1 与 0 一样是普通 txt/m3u 直播源（很多订阅用它标注线路）。
  bool get supported => type == '0' || type == '1' || type == '3' || isSpider;

  /// 带蜘蛛 `api` 的直播源和 type=3 一样交给蜘蛛：订阅里常见
  /// `{"url": "清单地址", "api": "xxx.py", "ext": "快照"}` 而完全不写 type。
  bool get isSpider {
    if (type == '3') return true;
    final a = api.trim();
    if (a.isEmpty) return false;
    return a.contains('.py') || a.contains('.js') || a.startsWith('csp_');
  }

  /// 蜘蛛脚本地址：`api` 优先，纯 type=3 老写法把脚本写在 `url`。
  String get spiderApi => api.trim().isNotEmpty ? api.trim() : url.trim();

  /// 交给 `liveContent()` 的参数：清单/页面地址（上游同样传 url）。
  String get spiderInput => url.trim();

  /// 合成一个 type=3 的点播源，复用现有的 PY / JS / JAR 蜘蛛链路。
  SourceBean? get spiderSite {
    if (!isSpider) return null;
    final api = spiderApi;
    if (api.isEmpty) return null;
    if (!api.contains('.py') &&
        !api.contains('.js') &&
        !api.startsWith('csp_')) {
      return null;
    }
    return SourceBean(
      key: api,
      name: displayName,
      type: 3,
      api: api,
      jar: jar,
      ext: ext,
      timeout: timeout,
    );
  }

  String get displayName => name.trim().isEmpty ? '线路' : name;

  Map<String, dynamic> toJson() => {
    'name': name,
    'api': api,
    'type': type,
    'url': url,
    'jar': jar,
    'ext': ext,
    'epg': epg,
    'playerType': playerType,
    'timeZone': timeZone,
    'timeout': timeout,
    if (header != null) 'header': header,
    'ua': ua,
  };

  factory LiveBean.fromJson(Map<String, dynamic> json) => LiveBean(
    name: (json['name'] ?? '').toString(),
    api: (json['api'] ?? '').toString(),
    type: (json['type'] ?? '0').toString(),
    url: (json['url'] ?? '').toString(),
    jar: (json['jar'] ?? '').toString(),
    ext: json['ext']?.toString() ?? '',
    epg: (json['epg'] ?? '').toString(),
    playerType: (json['playerType'] ?? '').toString(),
    timeZone: (json['timeZone'] ?? '').toString(),
    timeout: int.tryParse(json['timeout']?.toString() ?? '') ?? 15,
    header: (json['header'] as Map?)?.map(
      (k, v) => MapEntry(k.toString(), v.toString()),
    ),
    ua: (json['ua'] ?? '').toString(),
  );
}

class SiteConfig {
  const SiteConfig({
    this.sites = const [],
    this.parses = const [],
    this.lives = const [],
    this.flags = const [],
    this.spider = '',
    this.jarCache = 'true',
    this.danmaku = '',
    this.wallpaper = '',
    this.hosts = const {},
    this.rules = const [],
    this.doh = const [],
    this.ads = const [],
    this.proxy = const [],
  });

  final List<SourceBean> sites;
  final List<ParseBean> parses;
  final List<LiveBean> lives;
  final List<String> flags;
  final String spider;
  final String jarCache;
  final String danmaku;
  final String wallpaper;
  final Map<String, String> hosts;
  final List<dynamic> rules;
  final List<String> doh;
  final List<String> ads;
  final List<dynamic> proxy;

  List<SourceBean> get usableSites => sites.where((s) => s.supported).toList();

  Map<String, dynamic> toJson() => {
    'sites': sites.map((e) => e.toJson()).toList(),
    'parses': parses.map((e) => e.toJson()).toList(),
    'lives': lives.map((e) => e.toJson()).toList(),
    'flags': flags,
    'spider': spider,
    'jarCache': jarCache,
    'danmaku': danmaku,
    'wallpaper': wallpaper,
    'hosts': hosts,
    'rules': rules,
    'doh': doh,
    'ads': ads,
    'proxy': proxy,
  };
}

class SiteReportItem {
  const SiteReportItem({
    required this.index,
    required this.key,
    required this.name,
    required this.type,
    required this.api,
    required this.status,
    required this.message,
    this.reason,
  });

  final int index;
  final String key;
  final String name;
  final int type;
  final String api;
  final String status; // OK / SKIP / DEGRADE
  final String message;
  final String? reason;

  Map<String, dynamic> toJson() => {
    'index': index,
    'key': key,
    'name': name,
    'type': type,
    'api': api,
    'status': status,
    'message': message,
    if (reason != null) 'reason': reason,
  };
}

class ImportReport {
  const ImportReport({
    required this.total,
    required this.ok,
    required this.skipped,
    required this.degraded,
    required this.items,
  });

  final int total;
  final int ok;
  final int skipped;
  final int degraded;
  final List<SiteReportItem> items;

  static const empty = ImportReport(
    total: 0,
    ok: 0,
    skipped: 0,
    degraded: 0,
    items: [],
  );

  Map<String, dynamic> toJson() => {
    'total': total,
    'ok': ok,
    'skipped': skipped,
    'degraded': degraded,
    'items': items.map((e) => e.toJson()).toList(),
  };

  factory ImportReport.fromJson(Map<String, dynamic> j) => ImportReport(
    total: (j['total'] as num?)?.toInt() ?? 0,
    ok: (j['ok'] as num?)?.toInt() ?? 0,
    skipped: (j['skipped'] as num?)?.toInt() ?? 0,
    degraded: (j['degraded'] as num?)?.toInt() ?? 0,
    items: (j['items'] as List? ?? [])
        .whereType<Map>()
        .map(
          (e) => SiteReportItem(
            index: (e['index'] as num?)?.toInt() ?? 0,
            key: (e['key'] ?? '').toString(),
            name: (e['name'] ?? '').toString(),
            type: (e['type'] as num?)?.toInt() ?? 0,
            api: (e['api'] ?? '').toString(),
            status: (e['status'] ?? 'OK').toString(),
            message: (e['message'] ?? '').toString(),
            reason: e['reason']?.toString(),
          ),
        )
        .toList(),
  );
}

/// 订阅原文的一次快照，用于刷新 / 重新导入后的回滚。
class ConfigSnapshot {
  const ConfigSnapshot({
    required this.profileId,
    required this.name,
    required this.rawJson,
    required this.savedAt,
    this.siteCount = 0,
    this.liveCount = 0,
  });

  final String profileId;
  final String name;
  final String rawJson;
  final DateTime savedAt;
  final int siteCount;
  final int liveCount;

  Map<String, dynamic> toJson() => {
    'profileId': profileId,
    'name': name,
    'rawJson': rawJson,
    'savedAt': savedAt.toIso8601String(),
    'siteCount': siteCount,
    'liveCount': liveCount,
  };

  factory ConfigSnapshot.fromJson(Map<String, dynamic> json) => ConfigSnapshot(
    profileId: (json['profileId'] ?? '').toString(),
    name: (json['name'] ?? '').toString(),
    rawJson: (json['rawJson'] ?? '').toString(),
    savedAt:
        DateTime.tryParse((json['savedAt'] ?? '').toString()) ??
        DateTime.fromMillisecondsSinceEpoch(0),
    siteCount: (json['siteCount'] as num?)?.toInt() ?? 0,
    liveCount: (json['liveCount'] as num?)?.toInt() ?? 0,
  );
}

class ConfigProfile {
  const ConfigProfile({
    required this.id,
    required this.name,
    required this.url,
    required this.rawJson,
    required this.importedAt,
    this.report = ImportReport.empty,
    this.siteCount = 0,
    this.liveCount = 0,
    this.lastRefreshAt,
    this.deletedSiteKeys = const [],
    this.addedSiteKeys = const [],
  });

  final String id;
  final String name;
  final String url;
  final String rawJson;
  final DateTime importedAt;
  final ImportReport report;
  final int siteCount;
  final int liveCount;

  /// 最近一次成功刷新订阅的时间（本地导入为空）。
  final DateTime? lastRefreshAt;

  /// 只含直播（没有点播站点）：来自 M3U / TXT 直播订阅或纯 lives 的 JSON。
  bool get isLiveOnly => siteCount == 0 && liveCount > 0;

  /// 用户手动删除过的源 key：订阅刷新时按它过滤，避免删掉的源又回来。
  final List<String> deletedSiteKeys;

  /// 用户手动导入 / 移动到该订阅的源 key：刷新时保留这些本地条目。
  final List<String> addedSiteKeys;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'rawJson': rawJson,
    'importedAt': importedAt.toIso8601String(),
    'report': report.toJson(),
    'siteCount': siteCount,
    'liveCount': liveCount,
    if (lastRefreshAt != null)
      'lastRefreshAt': lastRefreshAt!.toIso8601String(),
    if (deletedSiteKeys.isNotEmpty) 'deletedSiteKeys': deletedSiteKeys,
    if (addedSiteKeys.isNotEmpty) 'addedSiteKeys': addedSiteKeys,
  };

  factory ConfigProfile.fromJson(Map<String, dynamic> j) => ConfigProfile(
    id: (j['id'] ?? '').toString(),
    name: (j['name'] ?? '').toString(),
    url: (j['url'] ?? '').toString(),
    rawJson: (j['rawJson'] ?? '').toString(),
    importedAt:
        DateTime.tryParse((j['importedAt'] ?? '').toString()) ?? DateTime.now(),
    report: j['report'] is Map
        ? ImportReport.fromJson(Map<String, dynamic>.from(j['report'] as Map))
        : ImportReport.empty,
    siteCount: (j['siteCount'] as num?)?.toInt() ?? 0,
    liveCount: (j['liveCount'] as num?)?.toInt() ?? 0,
    lastRefreshAt: DateTime.tryParse((j['lastRefreshAt'] ?? '').toString()),
    deletedSiteKeys:
        (j['deletedSiteKeys'] as List?)?.map((e) => e.toString()).toList() ??
        const [],
    addedSiteKeys:
        (j['addedSiteKeys'] as List?)?.map((e) => e.toString()).toList() ??
        const [],
  );
}

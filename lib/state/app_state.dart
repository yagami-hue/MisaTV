import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/logging/app_log.dart';
import '../core/logging/log_redact.dart';
import '../core/net/app_http.dart';
import '../core/net/proxy_config.dart';
import '../core/net/proxy_runtime.dart';
import '../core/net/url_utils.dart';
import '../core/utils/json_utils.dart';
import '../models/dav.dart';
import '../models/drive_account.dart';
import '../models/media_server.dart';
import '../models/site_config.dart';
import '../models/source_health.dart';
import '../models/sync_settings.dart';
import '../models/user_data.dart';
import '../models/vod.dart';
import '../models/xunlei_account.dart';
import '../services/backup_data.dart';
import '../services/config_parser.dart';
import '../services/content_filter.dart';
import '../services/danmaku/danmaku_service.dart';
import '../services/danmaku/danmaku_settings.dart';
import '../services/discover/discover_service.dart';
import '../services/drive/drive_line_hint.dart';
import '../services/drive/baidu_session.dart';
import '../services/drive/bili_session.dart';
import '../services/drive/pan115_session.dart';
import '../services/drive/quark_session.dart';
import '../services/drive/uc_session.dart';
import '../services/artwork/artwork_service.dart';
import '../services/jvm/jvm_runtime.dart';
import '../services/jar_spider/spider_failure.dart';
import '../services/jar_spider/warmup_plan.dart';
import '../services/lan/lan_server.dart';
import '../services/media/local_media_service.dart';
import '../services/media/media_server_service.dart';
import '../services/party/watch_party.dart';
import '../services/py_spider/py_runtime.dart';
import '../services/kazumi/kazumi_rule.dart';
import '../services/live/epg_service.dart';
import '../services/live/live_ua_policy.dart';
import '../services/player/external_playlist.dart';
import '../services/player/external_players.dart';
import '../services/player/skip_segments.dart';
import '../services/relay/local_relay.dart';
import '../services/relay/proxy_rules.dart';
import '../services/live_service.dart';
import '../services/local_store.dart';
import '../services/parse/parse_service.dart';
import '../services/play_page_unwrap.dart';
import '../services/quotes/quote_service.dart';
import '../services/search_service.dart';
import '../services/source_circuit_breaker.dart';
import '../services/source_service.dart';
import '../services/spider_debug/spider_debug_service.dart';
import '../services/subtitle/subtitle_service.dart';
import '../services/sync/history_sync.dart';
import '../services/sync/sync_bundle.dart';
import '../services/sync/sync_device.dart';
import '../services/download/video_download_manager.dart';
import '../services/torrent/download_manager.dart';
import '../services/torrent/torrent_play.dart';
import '../services/torrent/xunlei_cloud.dart';
import '../services/webdav/dav_service.dart';

class ImportOutcome {
  const ImportOutcome({
    required this.profile,
    required this.report,
    this.warnings = const [],
    this.mergedCount = 0,
  });

  final ConfigProfile profile;
  final ImportReport report;
  final List<String> warnings;
  final int mergedCount;

  int get siteCount => report.total;
}

/// 导入前的差异预览。只解析、不落盘；确认后再走 [AppState.commitImportPreview]。
class ImportPreview {
  const ImportPreview({
    required this.text,
    required this.url,
    required this.baseUrl,
    required this.name,
    required this.siteCount,
    required this.liveCount,
    required this.added,
    required this.removed,
    required this.changed,
    this.warnings = const [],
  });

  final String text;
  final String url;
  final String baseUrl;
  final String name;
  final int siteCount;
  final int liveCount;
  final int added;
  final int removed;
  final int changed;
  final List<String> warnings;

  bool get isLiveOnly => siteCount == 0 && liveCount > 0;
}

class AppException implements Exception {
  AppException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AppState extends ChangeNotifier {
  AppState({
    required this.store,
    required this.http,
    required this.sourceService,
    required this.searchService,
    required this.liveService,
    required this.driveTokens,
  });

  final LocalStore store;
  final AppHttp http;
  final SourceService sourceService;
  final SearchService searchService;
  final LiveService liveService;
  late final ParseService parseService = ParseService(http);
  late final SubtitleService subtitleService = SubtitleService(
    tokens: () => {'assrt': assrtToken},
    customApis: () => customSubtitleApis,
  );
  late final DanmakuService danmakuService = DanmakuService(
    settingsJson: () => {'danmaku': danmakuSettings.toJsonString()},
  );
  late final QuoteService quoteService = QuoteService(http, store);
  late final DiscoverService discoverService = DiscoverService(http);

  /// 沉浸观影横图封面：按设置优先级从豆瓣 / TMDB / IMDb 解析。
  late final ArtworkService artworkService = ArtworkService(
    http,
    () => playerSettings,
  );
  late final EpgService epgService = EpgService();
  late final DavService davService = DavService(store);

  /// 多端同步设置（设备名 / WebDAV 目标 / 局域网配对码）。
  SyncSettings syncSettings = const SyncSettings();

  /// Emby / Jellyfin 服务器管理。
  late final MediaServerService mediaServers = MediaServerService(store, http);

  /// 本地媒体库（扫描用户选择的文件夹）。
  late final LocalMediaService localMedia = LocalMediaService(store);

  /// aria2 下载管理器（桌面端在 main 里接入同一个 BT 引擎）。
  final DownloadManager downloadManager = DownloadManager();

  /// 播放器「下载视频」的任务管理：记录持久化，支持暂停 / 继续 / 删除。
  late final VideoDownloadManager videoDownloads = VideoDownloadManager(
    store,
  );

  /// 局域网同步服务：给其他设备提供同步包与「一起看」房间。
  late final LanServer lanServer = LanServer(
    deviceName: () => syncDeviceName,
    token: () => syncSettings.lanToken,
    snapshot: buildSyncBundle,
    apply: applySyncBundle,
  );

  /// 「一起看」房间状态（房主 / 观众）。
  late final WatchPartyService watchParty = WatchPartyService(
    deviceName: () => syncDeviceName,
    server: () => lanServer,
  );

  /// 本机显示名：用户没填时用系统主机名。
  String get syncDeviceName {
    final custom = syncSettings.deviceName.trim();
    return custom.isEmpty ? defaultSyncDeviceName() : custom;
  }

  /// 磁力（BT）播放编排：桌面端在 main 里注入；Web 版为 null。
  TorrentPlay? torrentPlay;

  /// 蜘蛛调试服务（默认关闭）：设置页与 `--dart-define` 可开启。
  final SpiderDebugService spiderDebug = SpiderDebugService();

  /// 第三方播放器的选集列表：桌面端在 main 里注入；Web 版为 null。
  ExternalPlaylistService? externalPlaylist;

  /// 迅雷云盘（磁力离线下载）；桌面端 main 注入 TorrentPlay 时复用同一实例。
  late final XunleiCloudService xunleiCloudService = XunleiCloudService(
    store: store,
    logger: (message) => AppLog.i('xunlei', message),
    onChanged: notifyListeners,
  );

  XunleiAccount get xunleiAccount => xunleiCloudService.account;

  /// 详情页点演员 / 推荐条目后，让搜索页执行一次全源搜索（序号变化即触发）。
  String? pendingSearchKeyword;
  int pendingSearchSeq = 0;

  /// provider → Cookie；由本类维护，蜘蛛服务读取以注入 ext。
  final Map<String, String> driveTokens;

  bool ready = false;
  List<ConfigProfile> profiles = [];

  /// 订阅原文快照（每个档案最多 3 份，总量最多 12 份），回滚用。
  List<ConfigSnapshot> profileHistory = [];
  String? activeProfileId;

  /// 订阅解析出的基础配置（不含本地 Kazumi 规则源）。
  SiteConfig? _config;

  /// 换配置时同步刷新「代理规则」：TVBox `rules[].hosts` 命中的请求走本机中继。
  void _setConfig(SiteConfig? value) {
    _config = value;
    ProxyRules.current = ProxyRules.fromRules(value?.rules ?? const []);
  }

  /// 用户导入的 Kazumi 规则；启动时合并进 [config]。
  List<KazumiRule> kazumiRules = const [];

  SiteConfig? _kazumiMerged;
  SiteConfig? _kazumiMergedBase;
  int _kazumiRev = 0;

  /// 当前生效配置 = 订阅配置 + 本地 Kazumi 规则源。
  SiteConfig? get config {
    final base = _config;
    if (base == null) return null;
    if (kazumiRules.isEmpty) return base;
    final cached = _kazumiMerged;
    if (cached != null &&
        _kazumiMergedBase == base &&
        _kazumiRev == _kazumiMergedRev) {
      return cached;
    }
    final sites = <SourceBean>[...base.sites];
    final keys = {for (final site in sites) site.key};
    final deleted = activeProfile?.deletedSiteKeys.toSet() ?? const <String>{};
    for (final rule in kazumiRules) {
      final bean = rule.toSourceBean();
      if (deleted.contains(bean.key)) continue;
      if (keys.add(bean.key)) sites.add(bean);
    }
    final merged = SiteConfig(
      sites: sites,
      parses: base.parses,
      lives: base.lives,
      flags: base.flags,
      spider: base.spider,
      jarCache: base.jarCache,
      danmaku: base.danmaku,
      wallpaper: base.wallpaper,
      hosts: base.hosts,
      rules: base.rules,
      doh: base.doh,
      ads: base.ads,
      proxy: base.proxy,
    );
    _kazumiMerged = merged;
    _kazumiMergedBase = base;
    _kazumiMergedRev = _kazumiRev;
    return merged;
  }

  int _kazumiMergedRev = 0;

  String? activeSiteKey;

  /// 当前直播订阅（独立于点播档案，切换点播不会改变它）。
  String? activeLiveProfileId;

  /// 当前直播订阅解析后的配置（只取 lives；点播的 config 仍是 activeProfile）。
  SiteConfig? liveConfig;

  /// 当前直播源（按 `名称|地址` 记录），直播页与设置页共用。
  String? activeLiveKey;
  ThemeMode themeMode = ThemeMode.system;
  int accentIndex = 0;

  /// 底部导航栏尺寸：0 紧凑 / 1 标准 / 2 较大 / 3 超大。
  int navBarSize = 1;

  /// 底部导航栏是否自动隐藏（只在鼠标靠近窗口底部时滑出）。
  bool navBarAutoHide = false;

  /// 首页每行封面数：0 = 自动（按窗口宽度），4-8 = 固定列数。
  int homeColumns = 0;

  /// 首页分类浏览方式：0 = 换页（上一页 / 下一页），1 = 瀑布（滑到底自动加载）。
  int homeBrowseMode = 0;

  /// 首页顶部是否显示影视台词轮换。
  bool showMovieQuotes = true;

  /// 记住的启动窗口大小（逻辑像素）；null = 按显示器比例自动计算。
  Size? rememberedWindowSize;

  /// 首次启动的用户协议是否已同意（同意后不再弹窗）。
  bool eulaAccepted = false;
  List<FavoriteItem> favorites = [];
  List<HistoryItem> history = [];

  /// 历史墓碑：删除 / 清空的版本号。合并外部历史时用它挡住「复活」。
  HistoryTombstones historyTombstones = HistoryTombstones.empty;
  List<String> searchHistory = [];
  PlayerSettings playerSettings = const PlayerSettings();

  /// 内置代理（HTTP / SOCKS5）：Dart、JVM、Python 网络都走同一个本机桥。
  ProxyConfig proxy = const ProxyConfig();
  Map<String, DriveAccount> driveAccounts = {};
  final Set<String> _refreshingDriveSessions = {};

  /// 跳过片头片尾记录（键 `资源|集`；本集无记录时沿用资源最近一次设置）。
  Map<String, SkipRecord> skipSegments = {};

  /// 源健康度落盘防抖：一轮搜索会连续触发几十次成功/失败回调。
  Timer? _sourceHealthSaveTimer;

  /// 本地导入的直播线路：独立于订阅，切档案 / 刷新订阅都不会丢。
  List<LiveBean> localLives = [];
  String assrtToken = '';
  String customSubtitleApis = '';

  /// 自定义直播 UA 设置（默认 UA + 按接口的例外规则）；空 = 沿用自动探测。
  LiveUaPolicy liveUaPolicy = LiveUaPolicy.none;
  DanmakuSettings danmakuSettings = DanmakuSettings.defaults();
  ContentFilterSettings contentFilter = ContentFilterSettings.defaults();

  /// JVM 运行时是否就绪：就绪后 JAR / DEX 蜘蛛源才计入可用站点。
  bool jarReady = false;

  static const accentPalette = <Color>[
    Color(0xFF8FBF8F), // 抹茶绿（Kazumi 风格）
    Color(0xFF7EA6E0), // 雾蓝
    Color(0xFFE0A27E), // 暖橙
    Color(0xFFC48FD1), // 薰衣草
    Color(0xFFE07E8C), // 莓红
  ];

  Color get accentColor =>
      accentPalette[accentIndex.clamp(0, accentPalette.length - 1)];

  ConfigProfile? get activeProfile {
    for (final p in profiles) {
      if (p.id == activeProfileId) return p;
    }
    return null;
  }

  ConfigProfile? get activeLiveProfile {
    for (final p in profiles) {
      if (p.id == activeLiveProfileId) return p;
    }
    return null;
  }

  /// 点播订阅：过滤掉纯直播订阅，避免它把点播配置清空。
  List<ConfigProfile> get vodProfiles =>
      profiles.where((p) => !p.isLiveOnly).toList();

  /// 可作为直播订阅的档案（含 lives 的 JSON 或纯 M3U/TXT 订阅）。
  List<ConfigProfile> get liveProfiles =>
      profiles.where((p) => p.liveCount > 0).toList();

  SourceBean? get activeSite {
    final c = config;
    if (c == null) return null;
    for (final s in c.sites) {
      if (s.key == activeSiteKey) return s;
    }
    return fallbackSite;
  }

  /// 自动选源时优先 CMS / JS / PY，最后才用 JAR（部分 JAR 源是加固壳，未必能跑）。
  /// Kazumi 规则源的首页是通用新番榜单，不抢占默认源。
  SourceBean? get fallbackSite {
    for (final s in usableSites) {
      if (s.supported && !s.isKazumi) return s;
    }
    for (final s in usableSites) {
      if (s.supported) return s;
    }
    return usableSites.isNotEmpty ? usableSites.first : null;
  }

  /// JAR 源是否可用取决于 JVM 运行时是否已安装。
  bool isSiteUsable(SourceBean site) =>
      site.supported || (jarReady && site.isJarSpider);

  /// 当前站点是豆瓣推荐源：点击条目要改为全源搜索，而不是进详情页。
  bool get activeSiteIsDouban => activeSite?.isDouban ?? false;

  /// 条目所属站点是否是豆瓣推荐源（历史 / 收藏 / 搜索结果共用）。
  bool isDoubanSourceKey(String key) {
    if (key.isEmpty) return false;
    for (final site in config?.sites ?? const <SourceBean>[]) {
      if (site.key == key) return site.isDouban;
    }
    return false;
  }

  List<SourceBean> get usableSites =>
      config?.sites.where(isSiteUsable).toList() ?? const [];
  List<LiveBean> get lives {
    final subscription = liveConfig?.lives ?? const <LiveBean>[];
    if (localLives.isEmpty) return subscription;
    final out = <LiveBean>[...subscription];
    final seen = <String>{for (final bean in subscription) liveKeyOf(bean)};
    for (final bean in localLives) {
      if (seen.add(liveKeyOf(bean))) out.add(bean);
    }
    return out;
  }

  String liveKeyOf(LiveBean bean) => '${bean.name}|${bean.url}';

  /// 当前直播源的下标：没设置或配置里已不存在时回落到第一条。
  int get activeLiveIndex {
    final list = lives;
    if (list.isEmpty) return 0;
    final index = list.indexWhere((b) => liveKeyOf(b) == activeLiveKey);
    return index < 0 ? 0 : index;
  }

  LiveBean? get activeLive => lives.isEmpty ? null : lives[activeLiveIndex];

  Future<void> setActiveLive(LiveBean bean) async {
    final key = liveKeyOf(bean);
    if (key == activeLiveKey) return;
    activeLiveKey = key;
    await store.setActiveLiveKey(key);
    notifyListeners();
  }

  int get _subscriptionLiveCount => liveConfig?.lives.length ?? 0;

  /// 编辑一条直播源：订阅线路写回原始 JSON，本地线路写回本地列表。
  Future<bool> updateLiveSource(int index, LiveBean bean) async {
    final list = lives;
    if (index < 0 || index >= list.length) return false;
    final wasActive = activeLiveKey == liveKeyOf(list[index]);
    if (index >= _subscriptionLiveCount) {
      final localIndex = index - _subscriptionLiveCount;
      if (localIndex < 0 || localIndex >= localLives.length) return false;
      localLives[localIndex] = bean;
      await store.saveLocalLives(localLives);
      if (wasActive) {
        activeLiveKey = liveKeyOf(bean);
        await store.setActiveLiveKey(activeLiveKey);
      }
      notifyListeners();
      return true;
    }
    final ok = await _editRawLives((rawLives) {
      if (index >= rawLives.length) return;
      final old = rawLives[index];
      final entry = old is Map
          ? Map<String, dynamic>.from(old)
          : <String, dynamic>{};
      entry['name'] = bean.name;
      final type = bean.type.trim();
      entry['type'] = int.tryParse(type) ?? (type.isEmpty ? 0 : type);
      // 有的源只写 `api` 不写 `url`：沿用原字段，避免凭空多出一个 url。
      final hasUrl = (entry['url'] ?? '').toString().trim().isNotEmpty;
      if (hasUrl || entry['api'] == null) {
        entry['url'] = bean.url;
      } else {
        entry['api'] = bean.url;
      }
      if (bean.epg.trim().isEmpty) {
        entry.remove('epg');
      } else {
        entry['epg'] = bean.epg.trim();
      }
      if (bean.timeZone.trim().isEmpty) {
        entry.remove('timeZone');
      } else {
        entry['timeZone'] = bean.timeZone.trim();
      }
      // 自定义 UA：留空就删掉该字段，让加载时回落到自动探测
      // （已知服务用其指定 UA，其余用 okhttp/3.12.0）。
      if (bean.ua.trim().isEmpty) {
        entry.remove('ua');
      } else {
        entry['ua'] = bean.ua.trim();
      }
      rawLives[index] = entry;
    });
    if (ok && wasActive) {
      activeLiveKey = liveKeyOf(bean);
      await store.setActiveLiveKey(activeLiveKey);
      notifyListeners();
    }
    return ok;
  }

  /// 删除一条直播源；删掉的正好是当前线路时回落到第一条。
  Future<bool> removeLiveSource(int index) async {
    final list = lives;
    if (index < 0 || index >= list.length) return false;
    if (index >= _subscriptionLiveCount) {
      final localIndex = index - _subscriptionLiveCount;
      if (localIndex < 0 || localIndex >= localLives.length) return false;
      final removed = localLives.removeAt(localIndex);
      if (activeLiveKey == liveKeyOf(removed)) {
        activeLiveKey = lives.isNotEmpty ? liveKeyOf(lives.first) : null;
        await store.setActiveLiveKey(activeLiveKey);
      }
      await store.saveLocalLives(localLives);
      notifyListeners();
      return true;
    }
    return _editRawLives((rawLives) {
      if (index >= 0 && index < rawLives.length) rawLives.removeAt(index);
    });
  }

  /// 新增一条本地直播线路（已复制到应用数据目录）。
  Future<void> addLocalLive(LiveBean bean, {bool activate = true}) async {
    localLives = [
      ...localLives.where((e) => liveKeyOf(e) != liveKeyOf(bean)),
      bean,
    ];
    await store.saveLocalLives(localLives);
    if (activate) {
      activeLiveKey = liveKeyOf(bean);
      await store.setActiveLiveKey(activeLiveKey);
    }
    notifyListeners();
  }

  /// 在当前配置的 rawJson 里改 `lives`，重新解析后落盘。
  ///
  /// 只有 JSON 订阅能这样改；解析失败或没有 `lives` 数组时返回 false。
  Future<bool> _editRawLives(
    void Function(List<dynamic> rawLives) mutate,
  ) async {
    final profile = activeLiveProfile;
    if (profile == null) return false;
    final Map<String, dynamic> root;
    try {
      final decoded = parseJsonLenient(profile.rawJson);
      if (decoded is! Map) return false;
      root = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return false;
    }
    final rawLives = root['lives'];
    if (rawLives is! List) return false;

    mutate(rawLives);
    final rawJson = const JsonEncoder.withIndent('  ').convert(root);
    final parsed = ConfigParser.parse(rawJson, jarReady: jarReady);
    profiles = [
      for (final p in profiles)
        if (p.id == profile.id)
          ConfigProfile(
            id: p.id,
            name: p.name,
            url: p.url,
            rawJson: rawJson,
            importedAt: p.importedAt,
            report: parsed.report,
            siteCount: p.siteCount,
            liveCount: parsed.config.lives.length,
            lastRefreshAt: p.lastRefreshAt,
            deletedSiteKeys: p.deletedSiteKeys,
            addedSiteKeys: p.addedSiteKeys,
          )
        else
          p,
    ];
    liveConfig = parsed.config;
    if (profile.id == activeProfileId) {
      _setConfig(parsed.config);
    }
    final remaining = lives;
    if (remaining.isEmpty) {
      activeLiveKey = null;
    } else if (!remaining.any((b) => liveKeyOf(b) == activeLiveKey)) {
      activeLiveKey = liveKeyOf(remaining.first);
    }
    await store.setActiveLiveKey(activeLiveKey);
    await _persistProfiles();
    notifyListeners();
    return true;
  }

  ImportReport get activeReport => activeProfile?.report ?? ImportReport.empty;

  /// 安装 / 删除 JVM 运行时后刷新可用性（触发界面重算）。
  Future<void> refreshJarReady() async {
    final ready = await JvmRuntime.instance.installed();
    if (ready == jarReady) return;
    jarReady = ready;
    _syncGlobalJar();
    await _refreshReports();
    notifyListeners();
  }

  /// 体检单个源：真实调用主页并分类，失败只记录原因，不向界面抛错。
  Future<SourceHealth> probeSite(SourceBean site) async {
    if (!isSiteUsable(site)) {
      return SourceHealth(
        key: site.key,
        name: site.displayName,
        status: 'error',
        message: site.unsupportedReason.isEmpty
            ? '该源当前不可用'
            : site.unsupportedReason,
      );
    }
    try {
      final stopwatch = Stopwatch()..start();
      final result = await sourceService
          .home(site)
          .timeout(Duration(seconds: site.timeout + 25));
      stopwatch.stop();
      // 体检成功即自愈：清掉该源的连续失败与冷却，下一次聚合搜索会重新纳入。
      searchService.markSiteHealthy(site);
      return SourceHealth.fromHome(
        site,
        result,
      ).withElapsed(stopwatch.elapsedMilliseconds);
    } on TimeoutException {
      searchService.markSiteFailed(site, '主页请求超时');
      return SourceHealth.failure(site, '主页请求超时（${site.timeout + 25} 秒）');
    } catch (e) {
      searchService.markSiteFailed(site, e);
      // 体验话术：告诉用户「为什么失败 + 下一步做什么」，原文仍在日志里。
      final failure = classifySpiderFailure(
        e,
        runtimeInstalled: await runtimeStatusFor(site),
      );
      return SourceHealth.failure(site, failure.message);
    }
  }

  /// 该源依赖的运行时是否已安装；与源无关时返回 null。
  ///
  /// 用于区分「真的没装」与「装了但损坏」：两者都报“缺少运行时”，
  /// 但提示语应该不同（去安装 vs 去重装）。
  Future<bool?> runtimeStatusFor(SourceBean site) async {
    if (site.isPySpider) return PyRuntime.instance.installed();
    if (site.isJarSpider) return JvmRuntime.instance.installed();
    return null;
  }

  void _scheduleSourceHealthSave() {
    _sourceHealthSaveTimer?.cancel();
    _sourceHealthSaveTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(
        store.setSourceHealthJson(searchService.breaker.exportJsonString()),
      );
    });
  }

  /// 仍在冷却中的源（设置页「源健康」展示）。
  List<({SourceBean site, SourceCircuitRecord record})> get coolingSources {
    final out = <({SourceBean site, SourceCircuitRecord record})>[];
    final now = DateTime.now();
    for (final site in config?.sites ?? const <SourceBean>[]) {
      final key = SearchService.healthKeyOf(site);
      final record = searchService.breaker.recordOf(key);
      if (record == null || !now.isBefore(record.cooldownUntil)) continue;
      out.add((site: site, record: record));
    }
    out.sort(
      (a, b) => a.record.cooldownUntil.compareTo(b.record.cooldownUntil),
    );
    return out;
  }

  /// 手动重置某个源（不传 key 时清空全部）的健康度。
  Future<void> resetSourceHealth([String? healthKey]) async {
    searchService.breaker.reset(healthKey);
    await store.setSourceHealthJson(searchService.breaker.exportJsonString());
    notifyListeners();
  }

  Future<void> resetSourceHealthOf(SourceBean site) =>
      resetSourceHealth(SearchService.healthKeyOf(site));

  /// 批量源审计：并发 4 个 `probeSite`，结果按站点顺序流式回填。
  ///
  /// 与单源「体检」共用同一条调用链，所以成功 / 失败也会同步到健康度。
  bool auditingSources = false;
  int auditDone = 0;
  int auditTotal = 0;
  List<SourceHealth> auditResults = const [];

  Future<void> auditSources() async {
    if (auditingSources) return;
    final sites = usableSites;
    if (sites.isEmpty) return;
    auditingSources = true;
    auditDone = 0;
    auditTotal = sites.length;
    auditResults = const [];
    notifyListeners();
    final results = List<SourceHealth?>.filled(sites.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= sites.length) return;
        results[index] = await probeSite(sites[index]);
        auditDone++;
        auditResults = [for (final item in results) ?item];
        notifyListeners();
      }
    }

    await Future.wait([
      for (var i = 0; i < 4 && i < sites.length; i++) worker(),
    ]);
    auditResults = [for (final item in results) ?item];
    auditingSources = false;
    notifyListeners();
  }

  String auditReportText() {
    final buffer = StringBuffer()
      ..writeln('MisaTV 源审计')
      ..writeln(DateTime.now().toIso8601String())
      ..writeln('共 ${auditResults.length} 个源');
    for (final health in auditResults) {
      buffer.writeln(
        '${health.ok ? 'OK' : 'FAIL'}\t${health.name}\t${health.statusLabel}\t'
        '${health.elapsedMs}ms\t${health.message}',
      );
    }
    return buffer.toString();
  }

  /// JVM 安装状态变化后重算各配置的导入诊断（JAR 源不再固定降级）。
  Future<void> _refreshReports() async {
    final updated = <ConfigProfile>[];
    for (final p in profiles) {
      if (p.rawJson.trim().isEmpty) {
        updated.add(p);
        continue;
      }
      try {
        final parsed = ConfigParser.parse(p.rawJson, jarReady: jarReady);
        updated.add(
          ConfigProfile(
            id: p.id,
            name: p.name,
            url: p.url,
            rawJson: p.rawJson,
            importedAt: p.importedAt,
            report: parsed.report,
            siteCount: p.siteCount,
            liveCount: p.liveCount,
            lastRefreshAt: p.lastRefreshAt,
            deletedSiteKeys: p.deletedSiteKeys,
            addedSiteKeys: p.addedSiteKeys,
          ),
        );
      } catch (_) {
        updated.add(p);
      }
    }
    profiles = updated;
    await _persistProfiles();
  }

  void _syncGlobalJar() {
    final jar = config?.spider ?? '';
    sourceService.setGlobalJar(jar);
  }

  /// 清理不再被任何配置引用的 JAR 缓存（删除站点 / 订阅时同步回收）。
  ///
  /// 任何一个配置解析失败就放弃本次清理，避免把还在用的 JAR 误删。
  Future<void> _purgeUnusedJars() async {
    final keep = <String>{};
    for (final p in profiles) {
      if (p.rawJson.trim().isEmpty) continue;
      try {
        final parsed = ConfigParser.parse(p.rawJson, jarReady: jarReady);
        keep.addAll(sourceService.jar.jarKeysOf(parsed.config));
      } catch (_) {
        return;
      }
    }
    await sourceService.jar.purgeJarCaches(keep);
  }

  /// [playerWindow] = 独立播放器子窗口：只加载播放必需的偏好与配置，
  /// 不探测网盘登录态、不改档案、不清理 JAR 缓存，避免和主窗口互相干扰。
  Future<void> init({bool playerWindow = false}) async {
    profiles = store.loadProfiles();
    profileHistory = store.loadProfileHistory();
    // 源健康度跨启动保留：失效源在冷却期内直接跳过，重启后不用再打一遍。
    searchService.breaker.importJsonString(store.sourceHealthJson);
    searchService.onHealthChanged = _scheduleSourceHealthSave;
    activeProfileId = store.activeProfileId;
    activeSiteKey = store.activeSiteKey;
    activeLiveProfileId = store.activeLiveProfileId;
    activeLiveKey = store.activeLiveKey;
    themeMode = switch (store.themeMode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    accentIndex = store.accentIndex.clamp(0, accentPalette.length - 1);
    navBarSize = store.navBarSize.clamp(0, 3);
    navBarAutoHide = store.navBarAutoHide;
    homeColumns = store.homeColumns <= 0 ? 0 : store.homeColumns.clamp(4, 8);
    homeBrowseMode = store.homeBrowseMode == 1 ? 1 : 0;
    showMovieQuotes = store.showMovieQuotes;
    rememberedWindowSize = store.loadWindowSize();
    eulaAccepted = store.eulaAccepted;
    favorites = store.loadFavorites()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    history = store.loadHistory()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    historyTombstones = store.loadHistoryTombstones();
    searchHistory = store.loadSearchHistory();
    playerSettings = store.loadPlayerSettings();
    sourceService.js.setWorkerCount(playerSettings.jsWorkerPool ? 3 : 1);
    sourceService.jar.setKeepHostsWarm(playerSettings.keepSpiderHosts);
    proxy = ProxyConfig.fromJsonString(store.proxyJson);
    await _applyEffectiveProxy();
    skipSegments = store.loadSkipSegments();
    driveAccounts = store.loadDriveAccounts();
    if (!playerWindow) xunleiCloudService.load();
    davService.load();
    syncSettings = store.loadSyncSettings();
    mediaServers.load();
    localMedia.load();
    videoDownloads.loadIfNeeded();
    if (syncSettings.lanToken.trim().isEmpty) {
      syncSettings = syncSettings.copyWith(lanToken: newSyncPairingToken());
      unawaited(store.saveSyncSettings(syncSettings));
    }
    localLives = store.loadLocalLives();
    assrtToken = store.assrtToken;
    customSubtitleApis = store.customSubtitleApis;
    liveUaPolicy = LiveUaPolicy.fromJsonString(store.liveUaPolicyJson);
    LiveUaPolicy.current = liveUaPolicy;
    danmakuSettings = DanmakuSettings.fromJsonString(store.danmakuSettingsJson);
    contentFilter = ContentFilterSettings.fromJsonString(
      store.contentFilterJson,
    );
    kazumiRules = store
        .loadKazumiRules()
        .map(KazumiRule.fromJson)
        .where((rule) => rule.valid)
        .toList();
    // 清理旧版本遗留的搜索耗时档案（该功能已移除）。
    unawaited(store.dropLegacySourceSpeed());
    _syncDriveTokens();
    if (!playerWindow) {
      // 启动时探测已保存的网盘登录态（吸收新 __puus / 识别访客 Cookie），不阻塞首屏。
      // 115 与哔哩只做「有凭据才探」：没有凭据时 _refreshDriveSession 会直接返回。
      unawaited(_refreshDriveSession('quark'));
      unawaited(_refreshDriveSession('uc'));
      unawaited(_refreshDriveSession('baidu'));
      unawaited(_refreshDriveSession('115'));
      unawaited(_refreshDriveSession('bili'));
    }
    final active = activeProfile;
    // 老版本把纯直播订阅当成点播档案：启动时把点播切回第一个真正含站点的档案。
    if (active != null && active.isLiveOnly && activeLiveProfileId == null) {
      activeLiveProfileId = active.id;
    }
    if (active == null || active.isLiveOnly) {
      final vod = vodProfiles;
      activeProfileId = vod.isNotEmpty ? vod.first.id : null;
    }
    if (activeLiveProfileId == null) {
      final preferred = activeProfile;
      if (preferred != null && preferred.liveCount > 0) {
        activeLiveProfileId = preferred.id;
      } else if (liveProfiles.isNotEmpty) {
        activeLiveProfileId = liveProfiles.first.id;
      }
    } else if (!profiles.any(
      (p) => p.id == activeLiveProfileId && p.liveCount > 0,
    )) {
      activeLiveProfileId = liveProfiles.isNotEmpty
          ? liveProfiles.first.id
          : null;
    }
    jarReady = await JvmRuntime.instance.installed();
    if (!playerWindow &&
        jarReady &&
        profiles.any(
          (p) => p.report.items.any((i) => i.reason == 'UNSUPPORTED_JAR'),
        )) {
      await _refreshReports();
    }
    _loadActiveConfig();
    _loadActiveLiveConfig();
    _syncGlobalJar();
    if (!playerWindow) {
      await store.setActiveProfileId(activeProfileId);
      await store.setActiveLiveProfileId(activeLiveProfileId);
      await _purgeUnusedJars();
    }
    ready = true;
    notifyListeners();
    AppLog.i(
      'state',
      '初始化完成 档案=${profiles.length} 源=${config?.sites.length ?? 0} '
          '直播订阅=${activeLiveProfile?.name ?? '-'} 直播线路=${lives.length} '
          '收藏=${favorites.length} 历史=${history.length} jarReady=$jarReady',
    );
  }

  /// 独立播放器窗口关闭后，把另一个引擎写回的历史与设置重新读进主窗口。
  ///
  /// 两个窗口是不同 Flutter 引擎、不同 isolate，不能共享内存对象；子窗口
  /// 写 shared_preferences 后主窗口必须 reload 才能看到最新进度。
  Future<void> reloadUserDataFromStore() async {
    await store.reload();
    videoDownloads.mergeFromStore();
    favorites = store.loadFavorites()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    history = store.loadHistory()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    historyTombstones = store.loadHistoryTombstones();
    searchHistory = store.loadSearchHistory();
    playerSettings = store.loadPlayerSettings();
    sourceService.js.setWorkerCount(playerSettings.jsWorkerPool ? 3 : 1);
    sourceService.jar.setKeepHostsWarm(playerSettings.keepSpiderHosts);
    skipSegments = store.loadSkipSegments();
    driveAccounts = store.loadDriveAccounts();
    _syncDriveTokens();
    assrtToken = store.assrtToken;
    customSubtitleApis = store.customSubtitleApis;
    liveUaPolicy = LiveUaPolicy.fromJsonString(store.liveUaPolicyJson);
    LiveUaPolicy.current = liveUaPolicy;
    danmakuSettings = DanmakuSettings.fromJsonString(store.danmakuSettingsJson);
    contentFilter = ContentFilterSettings.fromJsonString(
      store.contentFilterJson,
    );
    notifyListeners();
  }

  void _loadActiveConfig() {
    // 换档案 / 恢复备份后，旧订阅的同关键词结果不能继续命中。
    searchService.clearCache();
    final profile = activeProfile;
    if (profile == null) {
      _setConfig(null);
      activeSiteKey = null;
      _syncGlobalJar();
      return;
    }
    try {
      final parsed = ConfigParser.parse(profile.rawJson, jarReady: jarReady);
      final effective = _withoutDeletedSites(
        parsed.config,
        profile.deletedSiteKeys,
      );
      _setConfig(effective);
      final current = activeSiteKey;
      final valid = config?.sites.any((s) => s.key == current) ?? false;
      if (!valid) {
        activeSiteKey = fallbackSite?.key;
      }
    } catch (_) {
      _setConfig(null);
      activeSiteKey = null;
    }
    // 全局 spider jar 必须跟着当前档案一起换：切换到另一份订阅后仍用旧 jar，
    // 站点类（如 DoubanAmns / DoubanGuard）会 ClassNotFoundException，
    // 表现就是「快速切换订阅后必须重启才能打开」。
    _syncGlobalJar();
  }

  /// 导入 / 更新 Kazumi 规则（同名同 key 覆盖），并立即合并到源列表。
  ///
  /// 返回本次新增的条目数（更新已有规则不算新增）。
  Future<int> importKazumiRules(List<KazumiRule> incoming) async {
    if (incoming.isEmpty) return 0;
    final map = {for (final rule in kazumiRules) rule.key: rule};
    final before = map.length;
    for (final rule in incoming) {
      if (rule.valid) map[rule.key] = rule;
    }
    kazumiRules = map.values.toList();
    _kazumiRev++;
    await store.saveKazumiRules([for (final rule in kazumiRules) rule.raw]);
    final current = activeSiteKey;
    if (current == null ||
        !(config?.sites.any((site) => site.key == current) ?? false)) {
      activeSiteKey = fallbackSite?.key;
      await store.setActiveSiteKey(activeSiteKey);
    }
    notifyListeners();
    return kazumiRules.length - before;
  }

  /// 删除一条 Kazumi 规则；若正在使用该源则切回可用源。
  Future<void> removeKazumiRule(String key) async {
    final next = kazumiRules.where((rule) => rule.key != key).toList();
    if (next.length == kazumiRules.length) return;
    kazumiRules = next;
    _kazumiRev++;
    await store.saveKazumiRules([for (final rule in kazumiRules) rule.raw]);
    final current = activeSiteKey;
    if (current != null &&
        !(config?.sites.any((site) => site.key == current) ?? false)) {
      activeSiteKey = fallbackSite?.key;
      await store.setActiveSiteKey(activeSiteKey);
    }
    notifyListeners();
  }

  /// 去掉用户已删除的源（兼容非严格 JSON 订阅：ConfigParser 能解析即可）。
  static SiteConfig _withoutDeletedSites(
    SiteConfig config,
    List<String> deletedKeys,
  ) {
    if (deletedKeys.isEmpty || config.sites.isEmpty) return config;
    final keep = [
      for (final site in config.sites)
        if (!deletedKeys.contains(site.key)) site,
    ];
    if (keep.length == config.sites.length) return config;
    return SiteConfig(
      sites: keep,
      parses: config.parses,
      lives: config.lives,
      flags: config.flags,
      spider: config.spider,
      jarCache: config.jarCache,
      danmaku: config.danmaku,
      wallpaper: config.wallpaper,
      hosts: config.hosts,
      rules: config.rules,
      doh: config.doh,
      ads: config.ads,
      proxy: config.proxy,
    );
  }

  /// 解析当前直播订阅（与点播档案完全独立）；本地直播线路追加在最后。
  void _loadActiveLiveConfig() {
    final profile = activeLiveProfile;
    liveConfig = null;
    if (profile != null) {
      try {
        liveConfig = ConfigParser.parse(
          profile.rawJson,
          jarReady: jarReady,
        ).config;
      } catch (_) {
        liveConfig = null;
      }
    }
    final availableLives = lives;
    if (availableLives.isEmpty) {
      activeLiveKey = null;
    } else if (!availableLives.any((b) => liveKeyOf(b) == activeLiveKey)) {
      activeLiveKey = liveKeyOf(availableLives.first);
    }
  }

  Future<void> setActiveSite(String key) async {
    activeSiteKey = key;
    await store.setActiveSiteKey(key);
    notifyListeners();
  }

  Future<ImportOutcome> importFromUrl(String url, {String? name}) async {
    final payload = await _loadImportUrl(url, name: name);
    return _importText(
      payload.text,
      url: payload.url,
      baseUrl: payload.baseUrl,
      name: payload.name,
    );
  }

  /// 导入前预览：拉取 / 解析订阅并与当前点播档案比较，不落盘。
  Future<ImportPreview> previewImportFromUrl(
    String url, {
    String? name,
  }) async {
    final payload = await _loadImportUrl(url, name: name);
    return _buildImportPreview(
      payload.text,
      url: payload.url,
      baseUrl: payload.baseUrl,
      name: payload.name,
    );
  }

  Future<ImportPreview> previewImportText(
    String text, {
    String? name,
  }) async {
    if (text.trim().isEmpty) throw AppException('请粘贴配置 JSON');
    return _buildImportPreview(text, url: '', baseUrl: '', name: name);
  }

  /// 确认预览后真正落盘（沿用预览阶段已经拉到的原文，避免二次请求）。
  Future<ImportOutcome> commitImportPreview(ImportPreview preview) {
    return _importText(
      preview.text,
      url: preview.url,
      baseUrl: preview.baseUrl,
      name: preview.name,
    );
  }

  Future<({String text, String url, String baseUrl, String name})>
  _loadImportUrl(String url, {String? name}) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) throw AppException('请输入订阅地址');
    // 先只读开头几十 KB：直播单常常有好几 MB 且生成很慢，整份下完再判断
    // 会让导入卡几十秒甚至超时。开头认出是 M3U / TXT 就直接登记为直播订阅，
    // 直播页打开时再按需拉整份。
    // GitHub raw 国内常被墙：探测优先走 jsDelivr 镜像，失败再回原始地址。
    final probeTargets = <String>[
      ...githubMirrorUrls(normalizeHostUrl(trimmed)),
      trimmed,
    ];
    HttpResponseText? probe;
    for (final candidate in probeTargets) {
      probe = await http.probeText(
        candidate,
        headers: const {'User-Agent': 'okhttp/3.12.0'},
        timeout: const Duration(seconds: 20),
        // 纯 HTTP 接口容易被运营商劫持到反诈页，探测也优先走 DoH 拿真实 IP。
        useDoh: candidate.toLowerCase().startsWith('http://'),
      );
      if (probe != null) break;
    }
    final probeHead = (probe?.body ?? '').trimLeft();
    final probedLive =
        probeHead.startsWith('#EXTM3U') ||
        probeHead.startsWith('#EXTINF') ||
        (!probeHead.startsWith('{') &&
            !probeHead.startsWith('[') &&
            probeHead.isNotEmpty &&
            _looksLikeLiveList(probeHead));
    if (probedLive) {
      final label = (name ?? '').trim().isNotEmpty
          ? name!.trim()
          : _nameFromUrl(trimmed, profiles.length + 1);
      final liveJson = jsonEncode({
        'lives': [
          {'name': label, 'api': trimmed, 'type': 0, 'timeout': 30},
        ],
      });
      return (text: liveJson, url: trimmed, baseUrl: '', name: label);
    }
    final res = await _fetchSubscription(trimmed);
    final raw = res.body;
    _ensureTextResponse(raw, res.contentType);
    // 有的订阅把 JSON 包成 base64 / CBC 密文，先解一层再判断形态。
    final body = ConfigParser.decodePayload(raw);
    if (_looksLikeLiveList(body)) {
      // 直播列表不是 TVBox 配置：包成只含 live 的配置，直播页即可直接使用。
      final label = (name ?? '').trim().isNotEmpty
          ? name!.trim()
          : _nameFromUrl(trimmed, profiles.length + 1);
      final liveJson = jsonEncode({
        'lives': [
          {'name': label, 'api': trimmed, 'type': 0, 'timeout': 30},
        ],
      });
      return (text: liveJson, url: trimmed, baseUrl: '', name: label);
    }
    if (!body.contains('{')) {
      throw AppException('返回内容不是 TVBox 订阅配置（可能是加密、图片或已失效的接口）');
    }
    // 实际取到配置的地址（可能是 GitHub 镜像）才是相对路径的解析基准。
    return (
      text: body,
      url: trimmed,
      baseUrl: res.url,
      name: (name ?? '').trim(),
    );
  }

  ImportPreview _buildImportPreview(
    String text, {
    required String url,
    required String baseUrl,
    String? name,
  }) {
    final body = ConfigParser.decodePayload(text);
    final parsed = ConfigParser.parse(
      body,
      baseUrl: baseUrl.isEmpty ? url : baseUrl,
      jarReady: jarReady,
    );
    if (parsed.multiUrls.isNotEmpty) {
      throw AppException('多仓订阅暂不支持导入前预览，请直接导入');
    }
    final current = activeProfile;
    final currentConfig = current == null
        ? const SiteConfig()
        : ConfigParser.parse(
            current.rawJson,
            baseUrl: current.url,
            jarReady: jarReady,
          ).config;
    final newSites = {for (final site in parsed.config.sites) site.key: site};
    final oldSites = {for (final site in currentConfig.sites) site.key: site};
    var added = 0;
    var removed = 0;
    var changed = 0;
    for (final entry in newSites.entries) {
      final old = oldSites[entry.key];
      if (old == null) {
        added++;
        continue;
      }
      if (old.api != entry.value.api ||
          old.type != entry.value.type ||
          old.name != entry.value.name) {
        changed++;
      }
    }
    for (final key in oldSites.keys) {
      if (!newSites.containsKey(key)) removed++;
    }
    final newLives = {
      for (final live in parsed.config.lives) '${live.name}|${live.url}': live,
    };
    final oldLives = {
      for (final live in currentConfig.lives) '${live.name}|${live.url}': live,
    };
    for (final key in newLives.keys) {
      if (!oldLives.containsKey(key)) added++;
    }
    for (final key in oldLives.keys) {
      if (!newLives.containsKey(key)) removed++;
    }
    final label = (name ?? '').trim().isNotEmpty
        ? name!.trim()
        : (url.isEmpty ? '本地配置' : _nameFromUrl(url, profiles.length + 1));
    return ImportPreview(
      text: body,
      url: url,
      baseUrl: baseUrl,
      name: label,
      siteCount: parsed.config.sites.length,
      liveCount: parsed.config.lives.length,
      added: added,
      removed: removed,
      changed: changed,
      warnings: parsed.warnings,
    );
  }

  /// 订阅拉取阶梯（对齐 winbox）：
  /// 中文域名先转 punycode → 纯 HTTP 接口先走 DoH 拿真实 IP（绕运营商劫持）
  /// → 默认请求 → okhttp UA + Referer → 带上本次会话 Cookie →
  /// HTTPS 域名出 HTML/劫持时再用 DoH 兜底 → 同路径换协议再试。
  ///
  /// 整条阶梯 60 秒截止，避免一串失败尝试把导入拖到几分钟。
  Future<HttpResponseText> _fetchSubscription(String url) async {
    final target = normalizeHostUrl(url);
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    final plainHttp = target.toLowerCase().startsWith('http://');
    HttpResponseText? first;
    Object? firstError;

    // 纯 HTTP 接口容易被运营商劫持（未备案域名会被跳到反诈页），
    // 先走 DoH 拿真实 IP，既快又能绕开 20 多秒的跳转超时。
    if (plainHttp) {
      final viaDoh = await _retryWithClientUa(
        target,
        deadline: deadline,
        useDoh: true,
      );
      if (viaDoh != null && !_needsUaRetry(viaDoh.body, viaDoh.contentType)) {
        return viaDoh;
      }
    }

    try {
      first = await http.getText(target, timeout: const Duration(seconds: 25));
      if (!_needsUaRetry(first.body, first.contentType)) return first;
    } catch (e) {
      firstError = e;
      // 超时也可能只是服务端不认这个 UA（例如 live.catvod.com 对 okhttp/4.x
      // 直接挂住不回包），所以仍要继续跑 UA 阶梯；真正的慢站点最多多等一轮。
    }

    // HTTPS 通常不会明文跳反诈页，真出现 HTML/劫持时再用 DoH 兜底。
    if (!plainHttp) {
      final viaDoh = await _retryWithClientUa(
        target,
        deadline: deadline,
        useDoh: true,
      );
      if (viaDoh != null && !_needsUaRetry(viaDoh.body, viaDoh.contentType)) {
        return viaDoh;
      }
    }

    final retry = await _retryWithClientUa(target, deadline: deadline);
    if (retry != null && !_needsUaRetry(retry.body, retry.contentType)) {
      return retry;
    }

    // 有些镜像先种 Cookie，第二次带 Cookie 才给内容。
    final cookie = http.cookiesFor(target);
    if (cookie.isNotEmpty) {
      final withCookie = await _retryWithClientUa(
        target,
        deadline: deadline,
        cookie: cookie,
      );
      if (withCookie != null &&
          !_needsUaRetry(withCookie.body, withCookie.contentType)) {
        return withCookie;
      }
    }

    final alt = protocolAltUrl(target);
    if (alt.isNotEmpty) {
      final altRes = await _retryWithClientUa(alt, deadline: deadline);
      if (altRes != null && !_needsUaRetry(altRes.body, altRes.contentType)) {
        return altRes;
      }
      final altDoh = await _retryWithClientUa(
        alt,
        deadline: deadline,
        useDoh: true,
      );
      if (altDoh != null && !_needsUaRetry(altDoh.body, altDoh.contentType)) {
        return altDoh;
      }
    }

    if (first != null) return first;
    throw firstError ?? AppException('订阅请求失败');
  }

  Future<HttpResponseText?> _retryWithClientUa(
    String url, {
    required DateTime deadline,
    String cookie = '',
    bool useDoh = false,
  }) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= const Duration(seconds: 2)) return null;
    final referer = siteRootOf(url);
    try {
      return await http.getText(
        url,
        headers: {
          'User-Agent': 'okhttp/3.12.0',
          if (referer.isNotEmpty) 'Referer': referer,
          if (cookie.isNotEmpty) 'Cookie': cookie,
        },
        timeout: remaining < const Duration(seconds: 25)
            ? remaining
            : const Duration(seconds: 25),
        useDoh: useDoh,
      );
    } catch (_) {
      return null;
    }
  }

  bool _needsUaRetry(String body, String contentType) {
    final type = contentType.toLowerCase();
    if (type.startsWith('image/') ||
        type.startsWith('video/') ||
        type.startsWith('audio/')) {
      // 伪装成图片的 JSON 是合法配置；真是图片就换链路再试。
      return !ConfigParser.looksLikeJsonBody(body);
    }
    final head = body.trimLeft().replaceFirst('\uFEFF', '').trimLeft();
    if (head.startsWith('<')) return true;
    if (_looksLikeLiveList(body)) return false;
    return !body.contains('{') && !body.contains('[');
  }

  /// 提前拦住图片 / 网页 / 二进制内容，避免只报「JSON 不合法」。
  void _ensureTextResponse(String body, String contentType) {
    // 图片里夹带 base64 订阅（饭太硬 /tv）是合法载体，先放行。
    if (!identical(ConfigParser.decodeEmbeddedBase64Payload(body), body)) {
      return;
    }
    final head = body.trimLeft().replaceFirst('\uFEFF', '').trimLeft();
    // 很多国产接口会把 JSON 配置伪装成 image/jpeg（挂在图床 CDN 上躲封禁，
    // 例如 tvbox.王二小放牛娃.top），正文是 JSON 就按配置处理，不看 Content-Type。
    if (ConfigParser.looksLikeJsonBody(head)) return;
    final type = contentType.toLowerCase();
    if (type.startsWith('image/') ||
        type.startsWith('video/') ||
        type.startsWith('audio/')) {
      throw AppException('该地址返回的是图片/媒体文件，不是 TVBox 配置（源可能已失效）');
    }
    if (head.isEmpty) throw AppException('订阅内容为空');
    if (head.startsWith('<')) {
      throw AppException('订阅返回的是网页而不是配置 JSON（可能被站点重定向或需要特定 UA）');
    }
    final textual =
        type.isEmpty ||
        type.contains('json') ||
        type.startsWith('text/') ||
        type.contains('javascript') ||
        type.contains('xml');
    if (!textual) {
      final probe = head.length > 1024 ? head.substring(0, 1024) : head;
      if ('\uFFFD'.allMatches(probe).length > 32) {
        throw AppException('该地址返回的是二进制内容，不是 TVBox 配置（源可能已失效）');
      }
    }
  }

  /// m3u / TVBox 直播文本（`频道名,地址`）。
  ///
  /// 只看开头：TVBox JSON 配置里也可能出现 `#EXTINF`（去广告正则里常带
  /// `#EXT-X-DISCONTINUITY…#EXTINF:3,…`），按「正文任意位置包含标记」判断
  /// 会把 JSON 订阅误当成直播单，导致点播站点一条都导不进去。
  bool _looksLikeLiveList(String body) {
    final text = body.trimLeft().replaceFirst('\uFEFF', '').trimLeft();
    if (text.isEmpty) return false;
    if (text.startsWith('{') || text.startsWith('[')) return false;
    final firstLine = text.split('\n').first.trim().toUpperCase();
    if (firstLine.startsWith('#EXTM3U') || firstLine.startsWith('#EXTINF')) {
      return true;
    }
    if (text.contains('#genre#')) return true;
    var hits = 0;
    var total = 0;
    for (final line
        in text
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .take(40)) {
      if (line.startsWith('#')) continue;
      total++;
      if (line.contains(',') &&
          RegExp(r'https?://|rtmp://|rtsp://|p3p://|mitv://').hasMatch(line)) {
        hits++;
      }
    }
    return total >= 3 && hits / total > 0.6;
  }

  Future<ImportOutcome> importFromJson(String text, {String? name}) async {
    if (text.trim().isEmpty) throw AppException('请粘贴配置 JSON');
    return _importText(text, url: '', name: name ?? '本地配置');
  }

  /// 本地文本导入（本地 .json / 本地 .py / 本地包生成的配置）。
  Future<ImportOutcome> importFromLocalText(String text, {String? name}) {
    if (text.trim().isEmpty) throw AppException('本地配置文件为空');
    return _importText(text, url: '', name: name);
  }

  /// 重新拉取某个订阅并就地替换（保留该档案已删除源的墓碑）。
  Future<ImportOutcome> refreshProfile(
    String id, {
    bool activate = true,
  }) async {
    final profile = _profileById(id);
    if (profile == null) throw AppException('配置不存在');
    final url = profile.url.trim();
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
      throw AppException('本地配置没有可刷新的订阅地址');
    }
    // 订阅内容可能换了 PY 脚本地址或直接替换了脚本内容：本次会话的旧缓存作废。
    sourceService.py.clearScriptCache();
    final sw = Stopwatch()..start();
    AppLog.i('import', '刷新订阅开始 name=${profile.name} url=${redactUrl(url)}');
    try {
      final res = await _fetchSubscription(url);
      final raw = res.body;
      _ensureTextResponse(raw, res.contentType);
      final body = ConfigParser.decodePayload(raw);
      if (_looksLikeLiveList(body)) {
        final liveJson = jsonEncode({
          'lives': [
            {'name': profile.name, 'api': url, 'type': 0},
          ],
        });
        return await _importText(
          liveJson,
          url: url,
          name: profile.name,
          replaceProfileId: id,
          activate: activate,
          requireContent: true,
        );
      }
      if (!body.contains('{')) {
        throw AppException('返回内容不是 TVBox 订阅配置（可能是加密、图片或已失效的接口）');
      }
      final outcome = await _importText(
        body,
        url: url,
        name: profile.name,
        replaceProfileId: id,
        activate: activate,
        requireContent: true,
      );
      AppLog.i(
        'import',
        '刷新订阅完成 name=${profile.name} ${sw.elapsedMilliseconds}ms',
      );
      return outcome;
    } catch (e, s) {
      AppLog.e(
        'import',
        '刷新订阅失败 name=${profile.name} url=${redactUrl(url)} ${sw.elapsedMilliseconds}ms',
        e,
        s,
      );
      rethrow;
    }
  }

  ConfigProfile? _profileById(String id) {
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 启动后的后台任务：在线订阅每次启动都静默回源一次。
  ///
  /// 源站经常直接替换失效的 API / PY 脚本，等 7 天再刷新会让用户一直用旧源；
  /// 失败时保留本地配置，不打断首屏。
  void startBackgroundTasks() {
    unawaited(_autoRefreshIfDue());
    unawaited(_warmUpJarSites());
  }

  /// 启动后台预热 JAR 源：把 JRE 下载 / dex 转换 / JVM 冷启动 / `init()` 解挑战
  /// 这些几十秒的开销挪到用户点搜索之前。
  ///
  /// 刻意做成**串行**：同时拉起多只 JVM 会互相抢 CPU 与磁盘，反而更慢，也会让
  /// 首屏卡顿。运行时没装时整段跳过（`jarReady == false`），不静默下载运行时。
  Future<void> _warmUpJarSites() async {
    if (!jarReady) return;
    // 先等一会儿：启动瞬间有窗口创建、配置解析、封面加载等更急的事要做。
    await Future<void>.delayed(const Duration(seconds: 3));
    final sites = usableSites.where((s) => s.isJarSpider).toList();
    if (sites.isEmpty) return;
    // 最多预热 kWarmUpLimit 个：避免订阅里十几个 JAR 源时把启动后的几分钟
    // 全用来开 JVM。排序用健康度（近期失败的往后）。
    final plan = buildWarmUpPlan(
      sites: sites,
      runtimeReady: jarReady,
      weightOf: (site) => searchService.breaker.failureCount(
        SearchService.healthKeyOf(site),
      ),
    );
    for (final item in plan) {
      final ok = await sourceService.jar.warmUpSite(
        item.site,
        runtimeReady: jarReady,
      );
      AppLog.i('jar', '启动预热 ${item.site.key} → ${ok ? '完成' : '跳过'}');
    }
  }

  Future<void> _autoRefreshIfDue() async {
    final profile = activeProfile;
    if (profile == null) return;
    if (!RegExp(
      r'^https?://',
      caseSensitive: false,
    ).hasMatch(profile.url.trim())) {
      return;
    }
    try {
      await refreshProfile(profile.id);
    } catch (e) {
      // 静默失败：继续使用本地已有配置。
      AppLog.w('import', '后台刷新订阅失败（继续使用本地配置）', e);
    }
  }

  void _rememberProfileSnapshot(ConfigProfile profile) {
    if (profile.rawJson.trim().isEmpty) return;
    final snapshot = ConfigSnapshot(
      profileId: profile.id,
      name: profile.name,
      rawJson: profile.rawJson,
      savedAt: DateTime.now(),
      siteCount: profile.siteCount,
      liveCount: profile.liveCount,
    );
    final list = [
      snapshot,
      ...profileHistory.where(
        (item) =>
            item.profileId != profile.id || item.rawJson != profile.rawJson,
      ),
    ];
    final perProfile = <String, int>{};
    final trimmed = <ConfigSnapshot>[];
    for (final item in list) {
      final count = perProfile[item.profileId] ?? 0;
      if (count >= 3) continue;
      perProfile[item.profileId] = count + 1;
      trimmed.add(item);
      if (trimmed.length >= 12) break;
    }
    profileHistory = trimmed;
    unawaited(store.saveProfileHistory(profileHistory));
  }

  /// 回滚到某个订阅快照；回滚前会先把当前版本记入历史，可再次撤回。
  Future<ImportOutcome> restoreProfileSnapshot(ConfigSnapshot snapshot) async {
    final profile = _profileById(snapshot.profileId);
    if (profile == null) throw AppException('原订阅已不存在，无法回滚');
    return _importText(
      snapshot.rawJson,
      url: profile.url,
      name: profile.name,
      replaceProfileId: profile.id,
    );
  }

  Future<void> clearProfileHistory() async {
    profileHistory = [];
    await store.saveProfileHistory(profileHistory);
    notifyListeners();
  }

  Future<ImportOutcome> _importText(
    String text, {
    required String url,
    String? baseUrl,
    String? name,
    String? replaceProfileId,
    bool activate = true,
    bool requireContent = false,
  }) async {
    text = ConfigParser.decodePayload(text);
    var parsed = ConfigParser.parse(
      text,
      baseUrl: baseUrl ?? url,
      jarReady: jarReady,
    );
    var warnings = <String>[...parsed.warnings];
    var mergedCount = 0;
    var rawJson = text;

    if (parsed.multiUrls.isNotEmpty) {
      final configs = <SiteConfig>[];
      final failures = <String>[];
      for (final entry in parsed.multiUrls) {
        try {
          final res = await http.getText(
            entry.url,
            timeout: const Duration(seconds: 20),
          );
          _ensureTextResponse(res.body, res.contentType);
          final sub = ConfigParser.parse(
            res.body,
            baseUrl: res.url,
            jarReady: jarReady,
          );
          if (sub.multiUrls.isNotEmpty) {
            failures.add(
              '${entry.name.isEmpty ? entry.url : entry.name}: 嵌套多仓未展开',
            );
            continue;
          }
          configs.add(sub.config);
          mergedCount++;
        } catch (e) {
          failures.add('${entry.name.isEmpty ? entry.url : entry.name}: $e');
        }
      }
      if (configs.isEmpty) {
        throw AppException('多仓订阅展开失败：${failures.take(3).join('；')}');
      }
      final merged = ConfigParser.merge(configs);
      rawJson = jsonEncode(merged.toJson());
      bool usableOf(SourceBean s) => s.supported || (jarReady && s.isJarSpider);
      parsed = ParsedConfig(
        config: merged,
        report: ConfigParser.buildImportReport([
          for (final c in configs)
            for (final s in c.sites)
              SiteReportItem(
                index: 0,
                key: s.key,
                name: s.name,
                type: s.type,
                api: s.api,
                status: usableOf(s) ? 'OK' : 'DEGRADE',
                message: usableOf(s) ? '已导入' : s.unsupportedReason,
              ),
        ]),
        warnings: [...warnings, if (failures.isNotEmpty) ...failures],
      );
      warnings = parsed.warnings;
    }

    if (requireContent &&
        parsed.config.sites.isEmpty &&
        parsed.config.lives.isEmpty) {
      throw AppException('订阅刷新结果为空，已保留原配置');
    }

    // 同一个订阅地址（或指定档案）就地替换；用户删过的源按墓碑过滤，刷新后不复活。
    ConfigProfile? existing;
    if (replaceProfileId != null) {
      existing = _profileById(replaceProfileId);
    } else if (url.isNotEmpty) {
      for (final p in profiles) {
        if (p.url == url) {
          existing = p;
          break;
        }
      }
    }
    final deletedKeys = existing?.deletedSiteKeys ?? const <String>[];
    final addedKeys = existing?.addedSiteKeys ?? const <String>[];
    final merged = mergeAddedSites(rawJson, existing, addedKeys);
    if (merged != rawJson) {
      rawJson = merged;
      parsed = ConfigParser.parse(
        rawJson,
        baseUrl: baseUrl ?? url,
        jarReady: jarReady,
      );
    }
    final pruned = _pruneDeletedSites(rawJson, deletedKeys);
    if (pruned != rawJson) {
      rawJson = pruned;
      parsed = ConfigParser.parse(
        rawJson,
        baseUrl: baseUrl ?? url,
        jarReady: jarReady,
      );
    }
    final effective = _withoutDeletedSites(parsed.config, deletedKeys);

    final now = DateTime.now();
    final profileName = (name ?? '').trim().isNotEmpty
        ? name!.trim()
        : existing?.name ?? _nameFromUrl(url, profiles.length + 1);
    final profile = ConfigProfile(
      id: existing?.id ?? 'p${now.millisecondsSinceEpoch}',
      name: profileName,
      url: url,
      rawJson: rawJson,
      importedAt: existing?.importedAt ?? now,
      report: parsed.report,
      siteCount: effective.sites.length,
      liveCount: effective.lives.length,
      lastRefreshAt: url.isEmpty ? null : now,
      deletedSiteKeys: deletedKeys,
      addedSiteKeys: addedKeys,
    );

    if (existing != null) {
      // 内容没变的刷新不记快照，避免订阅历史被同一条重复版本占满。
      if (existing.rawJson != rawJson) _rememberProfileSnapshot(existing);
      profiles = [
        for (final p in profiles)
          if (p.id == existing.id) profile else p,
      ];
    } else {
      profiles = [
        profile,
        ...profiles.where((p) => p.url.isEmpty || p.url != url),
      ];
    }

    final liveOnly = effective.sites.isEmpty && effective.lives.isNotEmpty;
    final wasActiveLive =
        activeLiveProfileId == profile.id ||
        (existing != null && activeLiveProfileId == existing.id);

    // 点播：纯直播订阅（M3U / TXT / 只有 lives 的 JSON）不碰点播档案。
    if (!liveOnly && (activate || activeProfileId == profile.id)) {
      activeProfileId = profile.id;
      _setConfig(effective);
      _syncGlobalJar();
      if (!(config?.sites.any((s) => s.key == activeSiteKey) ?? false)) {
        activeSiteKey = fallbackSite?.key;
      }
      await store.setActiveProfileId(activeProfileId);
      await store.setActiveSiteKey(activeSiteKey);
    }

    // 直播：独立选择。导入普通 JSON 时，若用户已有直播订阅则保持不动；
    // 只有纯直播订阅导入、或该档案本来就是当前直播订阅（刷新）时才更新。
    final takeLive = liveOnly
        ? (activate || wasActiveLive || activeLiveProfileId == null)
        : (wasActiveLive ||
              (activeLiveProfileId == null && parsed.config.lives.isNotEmpty));
    if (takeLive) {
      activeLiveProfileId = profile.id;
      liveConfig = parsed.config;
      final availableLives = lives;
      if (availableLives.isEmpty) {
        activeLiveKey = null;
      } else if (!availableLives.any((b) => liveKeyOf(b) == activeLiveKey)) {
        activeLiveKey = liveKeyOf(availableLives.first);
      }
      await store.setActiveLiveProfileId(activeLiveProfileId);
      await store.setActiveLiveKey(activeLiveKey);
    }
    await _persistProfiles();
    if (!liveOnly) {
      searchService.clearCache();
    }
    if (activate && !liveOnly && config != null) await _purgeUnusedJars();
    notifyListeners();
    AppLog.i(
      'import',
      '导入订阅 name=${profile.name} url=${redactUrl(url)} '
          'total=${parsed.report.total} ok=${parsed.report.ok} '
          'skip=${parsed.report.skipped} degrade=${parsed.report.degraded} '
          'merged=$mergedCount warnings=${warnings.length} '
          'liveOnly=$liveOnly liveProfile=$activeLiveProfileId',
    );

    return ImportOutcome(
      profile: profile,
      report: parsed.report,
      warnings: warnings,
      mergedCount: mergedCount,
    );
  }

  /// 把用户手动导入 / 移动到该订阅的源在刷新时补回。
  ///
  /// 目标订阅是线上 JSON 时，刷新会用远端内容覆盖本地 rawJson；这里按
  /// [addedSiteKeys] 从旧配置里取回对应条目，避免本地 PY 源 / 移动源被冲掉。
  @visibleForTesting
  static String mergeAddedSites(
    String rawJson,
    ConfigProfile? existing,
    List<String> addedKeys,
  ) {
    if (existing == null || addedKeys.isEmpty) return rawJson;
    try {
      final decoded = parseJsonLenient(rawJson);
      if (decoded is! Map) return rawJson;
      final root = Map<String, dynamic>.from(decoded);
      final current = root['sites'];
      if (current is! List && current != null) return rawJson;
      final sites = current is List ? current : <dynamic>[];
      final old = parseJsonLenient(existing.rawJson);
      if (old is! Map) return rawJson;
      final oldSites = old['sites'];
      if (oldSites is! List) return rawJson;

      final localByKey = <String, Map<String, dynamic>>{};
      for (final item in oldSites) {
        if (item is! Map) continue;
        final key = (item['key'] ?? '').toString().trim();
        if (key.isEmpty || !addedKeys.contains(key)) continue;
        localByKey[key] = Map<String, dynamic>.from(item);
      }
      if (localByKey.isEmpty) return rawJson;

      var changed = false;
      for (final entry in localByKey.entries) {
        final index = sites.indexWhere(
          (item) =>
              item is Map && (item['key'] ?? '').toString().trim() == entry.key,
        );
        if (index >= 0) {
          if (jsonEncode(sites[index]) != jsonEncode(entry.value)) {
            sites[index] = entry.value;
            changed = true;
          }
        } else {
          sites.add(entry.value);
          changed = true;
        }
      }
      if (!changed) return rawJson;
      root['sites'] = sites;
      return const JsonEncoder.withIndent('  ').convert(root);
    } catch (_) {
      return rawJson;
    }
  }

  /// 按「已删除源」墓碑过滤订阅 JSON 里的 `sites`。
  static String _pruneDeletedSites(String rawJson, List<String> deletedKeys) {
    if (deletedKeys.isEmpty) return rawJson;
    try {
      final decoded = parseJsonLenient(rawJson);
      if (decoded is! Map) return rawJson;
      final root = Map<String, dynamic>.from(decoded);
      final sites = root['sites'];
      if (sites is! List) return rawJson;
      final keep = <dynamic>[];
      for (final item in sites) {
        final key = item is Map ? (item['key'] ?? '').toString().trim() : '';
        if (key.isNotEmpty && deletedKeys.contains(key)) continue;
        keep.add(item);
      }
      root['sites'] = keep;
      return const JsonEncoder.withIndent('  ').convert(root);
    } catch (_) {
      return rawJson;
    }
  }

  String _nameFromUrl(String url, int index) {
    if (url.isEmpty) return '本地配置 $index';
    try {
      final host = Uri.parse(url).host;
      return host.isEmpty ? '配置 $index' : host;
    } catch (_) {
      return '配置 $index';
    }
  }

  /// 切换点播订阅：只换 sites / parses / 全局 jar，**不动直播订阅**。
  Future<void> activateProfile(String id) async {
    final profile = _profileById(id);
    if (profile == null) return;
    if (profile.isLiveOnly) {
      await setActiveLiveProfile(id);
      return;
    }
    activeProfileId = id;
    await store.setActiveProfileId(id);
    _loadActiveConfig();
    await store.setActiveSiteKey(activeSiteKey);
    notifyListeners();
    AppLog.i(
      'profile',
      '切换点播 id=$id name=${profile.name} sites=${profile.siteCount}',
    );
  }

  /// 切换直播订阅：只换 lives，不动点播档案。
  Future<void> setActiveLiveProfile(String id) async {
    final profile = _profileById(id);
    if (profile == null || profile.liveCount <= 0) return;
    activeLiveProfileId = id;
    await store.setActiveLiveProfileId(id);
    _loadActiveLiveConfig();
    await store.setActiveLiveKey(activeLiveKey);
    notifyListeners();
    AppLog.i(
      'live',
      '切换直播订阅 id=$id name=${profile.name} lines=${lives.length}',
    );
  }

  Future<void> removeProfile(String id) async {
    final wasLive = activeLiveProfileId == id;
    profiles = profiles.where((p) => p.id != id).toList();
    final current = activeProfile;
    if (activeProfileId == id || (current != null && current.isLiveOnly)) {
      final vod = vodProfiles;
      activeProfileId = vod.isNotEmpty ? vod.first.id : null;
      _loadActiveConfig();
      await store.setActiveProfileId(activeProfileId);
      await store.setActiveSiteKey(activeSiteKey);
    }
    if (wasLive) {
      activeLiveProfileId = liveProfiles.isNotEmpty
          ? liveProfiles.first.id
          : null;
      _loadActiveLiveConfig();
      await store.setActiveLiveProfileId(activeLiveProfileId);
      await store.setActiveLiveKey(activeLiveKey);
    }
    await _persistProfiles();
    await _purgeUnusedJars();
    notifyListeners();
  }

  Future<void> renameProfile(String id, String name) async {
    profiles = profiles
        .map(
          (p) => p.id == id
              ? ConfigProfile(
                  id: p.id,
                  name: name.trim().isEmpty ? p.name : name.trim(),
                  url: p.url,
                  rawJson: p.rawJson,
                  importedAt: p.importedAt,
                  report: p.report,
                  siteCount: p.siteCount,
                  liveCount: p.liveCount,
                  lastRefreshAt: p.lastRefreshAt,
                  deletedSiteKeys: p.deletedSiteKeys,
                  addedSiteKeys: p.addedSiteKeys,
                )
              : p,
        )
        .toList();
    await _persistProfiles();
    notifyListeners();
  }

  /// 编辑一条站点：名称 / 地址 / 类型 / 可搜索 / ext / jar / timeout。
  ///
  /// 站点按 `key` 定位：解析会跳过 type=2 等无效项，`config.sites` 的下标
  /// 不保证与 rawJson 的 `sites` 一一对应，不能按下标改写。
  Future<bool> updateSite(String key, SourceBean bean) async {
    final ok = await _editRawSites((rawSites) {
      final index = _rawSiteIndex(rawSites, key);
      if (index < 0) return;
      final old = rawSites[index];
      final entry = old is Map
          ? Map<String, dynamic>.from(old)
          : <String, dynamic>{};
      entry['name'] = bean.name;
      entry['api'] = bean.api;
      entry['type'] = bean.type;
      entry['searchable'] = bean.searchable;
      final ext = bean.ext.trim();
      if (ext.isEmpty) {
        entry.remove('ext');
      } else {
        entry['ext'] = ext;
      }
      final jar = bean.jar.trim();
      if (jar.isEmpty) {
        entry.remove('jar');
      } else {
        entry['jar'] = jar;
      }
      _writeOrRemove(entry, 'playUrl', bean.playUrl);
      _writeOrRemove(entry, 'click', bean.click);
      _writeOrRemove(entry, 'style', bean.style);
      entry['timeout'] = bean.timeout.clamp(5, 60);
      rawSites[index] = entry;
    }, markAdded: {key});
    // 站点地址被改成本地/远程的新脚本时，下次调用必须重新读取或回源。
    if (ok) {
      sourceService.py.clearScriptCache();
      // 接口内容变了：清掉该源的熔断记录，让它重新参与搜索。
      searchService.breaker.reset(SearchService.healthKeyOf(bean));
    }
    return ok;
  }

  /// 只切换「参与搜索」这一个字段：站点列表里直接点一下即可，不动名称 / 地址 /
  /// ext 等其它内容，也不会把整条站点重写成默认值。
  Future<bool> setSiteSearchable(String key, bool searchable) {
    return _editRawSites((rawSites) {
      final index = _rawSiteIndex(rawSites, key);
      if (index < 0) return;
      final old = rawSites[index];
      final entry = old is Map
          ? Map<String, dynamic>.from(old)
          : <String, dynamic>{};
      entry['searchable'] = searchable ? 1 : 0;
      rawSites[index] = entry;
    });
  }

  static void _writeOrRemove(
    Map<String, dynamic> entry,
    String key,
    String value,
  ) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      entry.remove(key);
    } else {
      entry[key] = trimmed;
    }
  }

  /// 把本地导入的站点（如批量 .py）并入当前订阅；同 key 条目就地更新。
  ///
  /// 返回 false 表示当前没有可编辑的 JSON 订阅（例如还没导入订阅）。
  Future<bool> addLocalSites(List<Map<String, dynamic>> entries) {
    final id = activeProfile?.id;
    if (id == null) return Future.value(false);
    return addSitesToProfile(id, entries);
  }

  /// 把站点并入指定订阅；同 key 条目就地合并。
  ///
  /// 目标订阅可以是当前正在使用的，也可以是另一个点播订阅。只要求它的原文
  /// 能被（宽松）JSON 解析；纯 M3U / TXT 直播订阅无法插入点播站点。
  Future<bool> addSitesToProfile(
    String profileId,
    List<Map<String, dynamic>> entries,
  ) async {
    if (entries.isEmpty) return false;
    final profile = _profileById(profileId);
    if (profile == null) return false;
    final Map<String, dynamic> root;
    try {
      final decoded = parseJsonLenient(profile.rawJson);
      if (decoded is! Map) return false;
      root = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return false;
    }
    final rawSites = root['sites'];
    if (rawSites is! List && rawSites != null) return false;
    final sites = rawSites is List ? rawSites : <dynamic>[];

    final keys = <String>{};
    for (final entry in entries) {
      final key = (entry['key'] ?? '').toString().trim();
      if (key.isEmpty) continue;
      keys.add(key);
      final index = _rawSiteIndex(sites, key);
      if (index >= 0) {
        final old = sites[index];
        final merged = old is Map
            ? Map<String, dynamic>.from(old)
            : <String, dynamic>{};
        merged.addAll(entry);
        sites[index] = merged;
      } else {
        sites.add(Map<String, dynamic>.from(entry));
      }
    }
    if (keys.isEmpty) return false;
    root['sites'] = sites;

    final rawJson = const JsonEncoder.withIndent('  ').convert(root);
    final parsed = ConfigParser.parse(rawJson, jarReady: jarReady);
    final tombstones = [
      for (final key in profile.deletedSiteKeys)
        if (!keys.contains(key)) key,
    ];
    final effective = _withoutDeletedSites(parsed.config, tombstones);
    final addedKeys = <String>{...profile.addedSiteKeys, ...keys}.toList();
    profiles = [
      for (final p in profiles)
        if (p.id == profile.id)
          ConfigProfile(
            id: p.id,
            name: p.name,
            url: p.url,
            rawJson: rawJson,
            importedAt: p.importedAt,
            report: parsed.report,
            siteCount: effective.sites.length,
            liveCount: effective.lives.length,
            lastRefreshAt: p.lastRefreshAt,
            deletedSiteKeys: tombstones,
            addedSiteKeys: addedKeys,
          )
        else
          p,
    ];
    if (profile.id == activeProfileId) {
      _setConfig(effective);
      if (!(config?.sites.any((s) => s.key == activeSiteKey) ?? false)) {
        activeSiteKey = fallbackSite?.key;
        await store.setActiveSiteKey(activeSiteKey);
      }
      searchService.clearCache();
    }
    await _persistProfiles();
    notifyListeners();
    return true;
  }

  /// 把当前订阅里选中的站点移动到另一个点播订阅。
  Future<int> moveSitesToProfile(
    Iterable<String> keys,
    String targetProfileId,
  ) async {
    final source = activeProfile;
    if (source == null || source.id == targetProfileId) return 0;
    final targets = keys
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    if (targets.isEmpty || _profileById(targetProfileId) == null) return 0;

    final Map<String, dynamic> root;
    try {
      final decoded = parseJsonLenient(source.rawJson);
      if (decoded is! Map) return 0;
      root = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return 0;
    }
    final rawSites = root['sites'];
    if (rawSites is! List) return 0;
    final entries = <Map<String, dynamic>>[];
    for (final item in rawSites) {
      if (item is! Map) continue;
      final key = (item['key'] ?? '').toString().trim();
      if (key.isEmpty || !targets.contains(key)) continue;
      entries.add(Map<String, dynamic>.from(item));
    }
    if (entries.isEmpty) return 0;

    // 先写入目标订阅，再从当前订阅删除；任一步失败都不会丢原站点。
    if (!await addSitesToProfile(targetProfileId, entries)) return 0;
    return removeSites(targets);
  }

  /// 删除一条站点；删掉的正好是当前站点时回落到第一个可用站点。
  Future<bool> removeSite(String key) async {
    final count = await removeSites([key]);
    return count > 0;
  }

  /// 批量删除站点（同时把 key 记入当前档案的墓碑，订阅刷新后不会复活）。
  Future<int> removeSites(Iterable<String> keys) async {
    final profile = activeProfile;
    if (profile == null) return 0;
    final targets = keys
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    if (targets.isEmpty) return 0;

    final Map<String, dynamic> root;
    try {
      final decoded = parseJsonLenient(profile.rawJson);
      if (decoded is! Map) {
        return await _removeSitesByTombstone(profile, targets);
      }
      root = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return await _removeSitesByTombstone(profile, targets);
    }
    final rawSites = root['sites'];
    if (rawSites is! List) {
      return await _removeSitesByTombstone(profile, targets);
    }

    var removed = 0;
    final keep = <dynamic>[];
    for (final item in rawSites) {
      final key = item is Map ? (item['key'] ?? '').toString().trim() : '';
      if (key.isNotEmpty && targets.contains(key)) {
        removed++;
        continue;
      }
      keep.add(item);
    }
    if (removed == 0) return 0;
    root['sites'] = keep;

    final rawJson = const JsonEncoder.withIndent('  ').convert(root);
    final parsed = ConfigParser.parse(rawJson, jarReady: jarReady);
    final tombstones = <String>{
      ...profile.deletedSiteKeys,
      ...targets,
    }.toList();
    final addedKeys = [
      for (final key in profile.addedSiteKeys)
        if (!targets.contains(key)) key,
    ];
    profiles = [
      for (final p in profiles)
        if (p.id == profile.id)
          ConfigProfile(
            id: p.id,
            name: p.name,
            url: p.url,
            rawJson: rawJson,
            importedAt: p.importedAt,
            report: parsed.report,
            siteCount: parsed.config.sites.length,
            liveCount: parsed.config.lives.length,
            lastRefreshAt: p.lastRefreshAt,
            deletedSiteKeys: tombstones,
            addedSiteKeys: addedKeys,
          )
        else
          p,
    ];
    _setConfig(parsed.config);
    if (!(config?.sites.any((s) => s.key == activeSiteKey) ?? false)) {
      activeSiteKey = fallbackSite?.key;
      await store.setActiveSiteKey(activeSiteKey);
    }
    await _persistProfiles();
    await _purgeUnusedJars();
    notifyListeners();
    return removed;
  }

  /// 非标准订阅（无法改写原文）也能删源：只记墓碑并从可见配置里过滤。
  Future<int> _removeSitesByTombstone(
    ConfigProfile profile,
    Set<String> targets,
  ) async {
    final SiteConfig parsed;
    try {
      parsed = ConfigParser.parse(profile.rawJson, jarReady: jarReady).config;
    } catch (_) {
      return 0;
    }
    final tombstones = <String>{
      ...profile.deletedSiteKeys,
      ...targets,
    }.toList();
    final effective = _withoutDeletedSites(parsed, tombstones);
    final removed = parsed.sites.length - effective.sites.length;
    if (removed <= 0) return 0;
    final addedKeys = [
      for (final key in profile.addedSiteKeys)
        if (!targets.contains(key)) key,
    ];
    profiles = [
      for (final p in profiles)
        if (p.id == profile.id)
          ConfigProfile(
            id: p.id,
            name: p.name,
            url: p.url,
            rawJson: p.rawJson,
            importedAt: p.importedAt,
            report: p.report,
            siteCount: effective.sites.length,
            liveCount: p.liveCount,
            lastRefreshAt: p.lastRefreshAt,
            deletedSiteKeys: tombstones,
            addedSiteKeys: addedKeys,
          )
        else
          p,
    ];
    if (profile.id == activeProfileId) {
      _setConfig(effective);
      if (!(config?.sites.any((s) => s.key == activeSiteKey) ?? false)) {
        activeSiteKey = fallbackSite?.key;
        await store.setActiveSiteKey(activeSiteKey);
      }
    }
    await _persistProfiles();
    await _purgeUnusedJars();
    notifyListeners();
    return removed;
  }

  int _rawSiteIndex(List<dynamic> rawSites, String key) {
    final target = key.trim();
    for (var i = 0; i < rawSites.length; i++) {
      final entry = rawSites[i];
      if (entry is Map && (entry['key'] ?? '').toString().trim() == target) {
        return i;
      }
    }
    return -1;
  }

  /// 在当前配置的 rawJson 里改 `sites`，重新解析后落盘。
  Future<bool> _editRawSites(
    void Function(List<dynamic> rawSites) mutate, {
    Set<String> markAdded = const {},
  }) async {
    final profile = activeProfile;
    if (profile == null) return false;
    final Map<String, dynamic> root;
    try {
      final decoded = parseJsonLenient(profile.rawJson);
      if (decoded is! Map) return false;
      root = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return false;
    }
    final rawSites = root['sites'];
    if (rawSites is! List) return false;

    mutate(rawSites);
    final rawJson = const JsonEncoder.withIndent('  ').convert(root);
    final parsed = ConfigParser.parse(rawJson, jarReady: jarReady);
    final addedKeys = <String>{
      ...profile.addedSiteKeys,
      for (final key in markAdded)
        if (key.trim().isNotEmpty) key.trim(),
    }.toList();
    profiles = [
      for (final p in profiles)
        if (p.id == profile.id)
          ConfigProfile(
            id: p.id,
            name: p.name,
            url: p.url,
            rawJson: rawJson,
            importedAt: p.importedAt,
            report: parsed.report,
            siteCount: parsed.config.sites.length,
            liveCount: parsed.config.lives.length,
            lastRefreshAt: p.lastRefreshAt,
            deletedSiteKeys: p.deletedSiteKeys,
            addedSiteKeys: addedKeys,
          )
        else
          p,
    ];
    _setConfig(parsed.config);
    if (!(config?.sites.any((s) => s.key == activeSiteKey) ?? false)) {
      activeSiteKey = fallbackSite?.key;
      await store.setActiveSiteKey(activeSiteKey);
    }
    await _persistProfiles();
    searchService.clearCache();
    notifyListeners();
    return true;
  }

  /// 云播线路返回 HTML 播放页时的直链提取（按页面地址缓存）。
  late final PlayPageUnwrap playPageUnwrap = PlayPageUnwrap(http);

  /// 把云播 `/play/<id>`、`/share/<hash>` 页面解成真正的 m3u8 直链。
  Future<PlayResult> unwrapPlayPage(PlayResult play) =>
      playPageUnwrap.unwrap(play);

  /// 蜘蛛调试的执行器：按 method 调 SourceService，并把结果序列化成文本。
  ///
  /// 只暴露公开入口，不碰内部方法；[onRequest] 交给 AppHttp 的观察者记录，
  /// 覆盖 Dart 侧的 CMS / JS / PY 请求。jar 蜘蛛走的是 JVM 内的 OkHttp，
  /// 这里看不到 —— 调试面板会明确标注这一点，不假装能看全。
  SpiderDebugRunner get spiderDebugRunner =>
      ({required String method, required Map<String, dynamic> args, required void Function(String) onRequest}) async {
    final siteKey = (args['site'] ?? '').toString();
    final site = usableSites.firstWhere(
      (s) => s.key == siteKey,
      orElse: () =>
          throw SpiderDebugException('找不到站点：$siteKey（先检查订阅）'),
    );
    final previous = AppHttp.observer;
    AppHttp.observer = (verb, url) => onRequest('$verb $url');
    try {
      switch (method) {
        case 'home':
          final result = await sourceService.home(site);
          return jsonEncode({
            'items': result.items.map((e) => e.toJson()).toList(),
            'classes': result.classes
                .map((c) => {'id': c.id, 'name': c.name})
                .toList(),
            'page': result.page,
            'pagecount': result.pagecount,
            'total': result.total,
          });
        case 'category':
          final result = await sourceService.category(
            site,
            (args['tid'] ?? '').toString(),
            (args['pg'] ?? '1').toString(),
            const {},
          );
          return jsonEncode({
            'items': result.items.map((e) => e.toJson()).toList(),
            'page': result.page,
            'pagecount': result.pagecount,
          });
        case 'detail':
          final detail = await sourceService.detail(
            site,
            (args['id'] ?? '').toString(),
          );
          return detail == null ? 'null' : jsonEncode(detail.toJson());
        case 'search':
          final items = await sourceService.search(
            site,
            (args['wd'] ?? '').toString(),
          );
          return jsonEncode({
            'items': items.map((e) => e.toJson()).toList(),
          });
        case 'live':
          final text = await sourceService.liveContent(
            site,
            (args['url'] ?? '').toString(),
          );
          return text;
        case 'play':
          final config = this.config;
          if (config == null) {
            throw const SpiderDebugException('当前没有生效的订阅配置');
          }
          final result = await sourceService.resolvePlay(
            site: site,
            config: config,
            flag: (args['flag'] ?? '').toString(),
            rawUrl: (args['url'] ?? '').toString(),
            jarReady: jarReady,
          );
          return jsonEncode(result.toJson());
        default:
          throw SpiderDebugException('不支持的 method：$method');
      }
    } on SourceException catch (e) {
      throw SpiderDebugException(e.message);
    } finally {
      AppHttp.observer = previous;
    }
  };

  /// 播放地址是否需要经本地中继：带 header / HLS / 网盘直链（需要注入 Cookie）
  /// 或开启了 m3u8 去广告时必须走中继。蜘蛛自己的 `127.0.0.1` 取流代理已带
  /// Cookie，不能再套一层中继。
  static bool needsRelayForPlay(
    PlayResult play,
    String provider, {
    bool purify = false,
  }) {
    final url = play.url.trim();
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    final localProxy =
        lower.contains('127.0.0.1') || lower.contains('localhost');
    // 本机取流地址（加固壳 JVM 的 `/chunk`、宿主的 `/proxy`）由壳自己带
    // Cookie/UA，通常不需要再套中继；而且壳的取流服务会同时发两个
    // `Content-Length`（Java `HttpExchange` 的常见写法），dart:io 的 HTTP 解析器
    // 会直接抛 `HttpException: The Content-Length header occurred more than once`，
    // 中继这边回 502，播放器只能报 invalid or unsupported media。
    //
    // ★ 唯一例外：壳的 `/proxy?…&type=mpd`（DASH）。它返回的清单里
    // `<BaseURL>` 指向 bilivideo CDN 且**要求 Referer**；直连时播放器只拿到
    // MPD 原文，去取分片不带 Referer → 403，用户侧就是「一点开就报错」。
    // 这类地址必须经中继，由中继改写 BaseURL 并注入 Referer（见 _rewriteMpd）。
    final shellDash = localProxy &&
        lower.contains('/proxy') &&
        lower.contains('type=mpd');
    if (localProxy && !shellDash) return false;
    if (shellDash) return true;
    // DASH 清单（`.mpd`）同样要经中继：它内部的 <BaseURL> 指向 CDN，
    // 少了中继注入的 Referer/UA 会 403。B 站课堂类源（wex 的 BiliGuard）
    // 返回的就是 `/proxy?do=bili&...&type=mpd` + `application/dash+xml`。
    return play.headers.isNotEmpty ||
        lower.contains('.m3u8') ||
        lower.contains('m3u8') ||
        lower.contains('.mpd') ||
        provider.isNotEmpty ||
        purify;
  }

  /// 交给播放器前的最后一步：带 header / 防盗链 / m3u8 的地址改走本地中继。
  ///
  /// - 有 header（UA / Referer / Cookie）或 HLS 清单 → 经 `/play` 注入与改写；
  /// - 网盘直链即使没有 header，也经 `/play` 注入本机登录 Cookie；
  /// - mp4 直链且无 header 时保持直连，避免多一跳；
  /// - 中继未启动（Web 版）时原样返回。
  PlayResult preparePlay(PlayResult play, {bool forceRelay = false}) {
    if (!play.playable || play.externalLink.isNotEmpty) return play;
    final relay = LocalRelay.instance;
    if (!relay.running) return play;
    final url = play.url.trim();
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return play;
    // 网盘直链可能不带 header，但依赖本机登录的 Cookie；同样必须经中继注入。
    final provider = _providerForPlay(url, play.flag);
    final lower = url.toLowerCase();
    final localProxy =
        lower.contains('127.0.0.1') || lower.contains('localhost');
    final needsRelay =
        (forceRelay && ProxyRuntime.instance.enabled && !localProxy) ||
        needsRelayForPlay(play, provider, purify: playerSettings.m3u8Purify);
    if (!needsRelay) return play;
    final wrapped = relay.playUrl(
      url,
      headers: play.headers,
      provider: provider,
    );
    if (wrapped == url) return play;
    return PlayResult(
      url: wrapped,
      parse: play.parse,
      playUrl: play.playUrl,
      flag: play.flag,
      headers: const {},
      message: play.message,
      externalLink: play.externalLink,
    );
  }

  /// 播放地址对应的网盘 provider（下载记录持久化后重新包中继用）。
  String providerForPlay(PlayResult play) => _providerForPlay(play.url, play.flag);

  String _providerForPlay(String url, String flag) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.contains('quark.cn')) return 'quark';
    if (host.contains('uc.cn') || host.contains('ucweb.com')) return 'uc';
    if (host.contains('baidu.com') ||
        host.contains('baidupcs.com') ||
        host.contains('bcebos.com')) {
      return 'baidu';
    }
    // 哔哩 CDN（bilivideo / hdslb）按 Referer 防盗链，必须经中继补头；
    // 未登录只有 360P / 480P 时同样如此。
    if (host.endsWith('bilibili.com') ||
        host.endsWith('bilivideo.com') ||
        host.endsWith('bilivideo.cn') ||
        host.endsWith('hdslb.com')) {
      return 'bili';
    }
    final hint = driveHintFromFlag(flag);
    return hint != null && hint.supported ? hint.provider : '';
  }

  /// 多档案合并导出：按 key 去重，保留可独立运行的 jar 与直播/解析配置。
  String exportMergedConfig(Iterable<String> profileIds) {
    final ids = profileIds.toSet();
    final configs = <SiteConfig>[];
    for (final profile in profiles) {
      if (ids.isNotEmpty && !ids.contains(profile.id)) continue;
      if (profile.rawJson.trim().isEmpty) continue;
      try {
        configs.add(
          ConfigParser.parse(profile.rawJson, jarReady: jarReady).config,
        );
      } catch (_) {
        // 单份坏档案不影响其余档案导出
      }
    }
    if (configs.isEmpty) throw AppException('没有可导出的配置');
    final merged = ConfigParser.mergeForExport(configs);
    return const JsonEncoder.withIndent('  ').convert(merged.toJson());
  }

  /// 导出当前应用的全部设置与本地数据（备份文件里的网盘 Cookie 为明文，界面需提示）。
  Map<String, dynamic> buildBackupData() => {
    'kind': BackupData.kind,
    'version': BackupData.version,
    'exportedAt': DateTime.now().toIso8601String(),
    'appVersion': '0.9.0',
    'profiles': profiles.map((p) => p.toJson()).toList(),
    'activeProfileId': activeProfileId ?? '',
    'activeSiteKey': activeSiteKey ?? '',
    'activeLiveProfileId': activeLiveProfileId ?? '',
    'activeLiveKey': activeLiveKey ?? '',
    'favorites': favorites.map((e) => e.toJson()).toList(),
    'history': history.map((e) => e.toJson()).toList(),
    // 墓碑要跟历史一起备份：只恢复正文的话，用户在另一台机器上删掉的条目
    // 会随着旧备份一起回来。
    'historyTombstones': historyTombstones.toJson(),
    'searchHistory': searchHistory,
    'playerSettings': playerSettings.toJson(),
    'proxy': proxy.toJson(),
    'driveAccounts': driveAccounts.values.map((e) => e.toJson()).toList(),
    'localLives': localLives.map((e) => e.toJson()).toList(),
    'kazumiRules': [for (final rule in kazumiRules) rule.raw],
    'assrtToken': assrtToken,
    'customSubtitleApis': customSubtitleApis,
    'liveUaPolicy': liveUaPolicy.toJson(),
    'danmakuSettings': danmakuSettings.toJson(),
    'contentFilter': contentFilter.toJson(),
    'themeMode': switch (themeMode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    },
    'accentIndex': accentIndex,
    'navBarSize': navBarSize,
    'navBarAutoHide': navBarAutoHide,
    'homeColumns': homeColumns,
    'homeBrowseMode': homeBrowseMode,
    'showMovieQuotes': showMovieQuotes,
  };

  /// 还原备份（原生备份或旧版 Win-Box 备份，由 [BackupData.parse] 归一）。
  Future<void> restoreBackupData(Map<String, dynamic> data) async {
    final incomingProfiles = <ConfigProfile>[];
    if (data['profiles'] is List) {
      for (final item in data['profiles'] as List) {
        if (item is! Map) continue;
        try {
          final profile = ConfigProfile.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (profile.id.trim().isEmpty || profile.rawJson.trim().isEmpty) {
            continue;
          }
          incomingProfiles.add(profile);
        } catch (_) {
          // 单份坏档案跳过
        }
      }
    }
    if (incomingProfiles.isNotEmpty) {
      profiles = incomingProfiles;
      final wanted = (data['activeProfileId'] ?? '').toString();
      final vod = vodProfiles;
      activeProfileId = vod.any((p) => p.id == wanted)
          ? wanted
          : (vod.isNotEmpty ? vod.first.id : null);
    } else if (activeProfileId == null && profiles.isNotEmpty) {
      final vod = vodProfiles;
      activeProfileId = vod.isNotEmpty ? vod.first.id : null;
    }
    activeSiteKey = (data['activeSiteKey'] ?? '').toString();
    final wantedLive = (data['activeLiveProfileId'] ?? '').toString();
    activeLiveProfileId =
        profiles.any((p) => p.id == wantedLive && p.liveCount > 0)
        ? wantedLive
        : null;
    if (activeLiveProfileId == null) {
      final preferred = activeProfile;
      activeLiveProfileId = preferred != null && preferred.liveCount > 0
          ? preferred.id
          : (liveProfiles.isNotEmpty ? liveProfiles.first.id : null);
    }
    activeLiveKey = (data['activeLiveKey'] ?? '').toString();

    if (data['favorites'] is List) {
      favorites =
          (data['favorites'] as List)
              .whereType<Map>()
              .map((e) => FavoriteItem.fromJson(Map<String, dynamic>.from(e)))
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    if (data['history'] is List) {
      history =
          (data['history'] as List)
              .whereType<Map>()
              .map((e) => HistoryItem.fromJson(Map<String, dynamic>.from(e)))
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
    // 备份里的墓碑与本地墓碑取并集（同一个 key 取更新的一方），
    // 再据此过滤掉「已删除却还在备份正文里」的条目。
    var restoredTombstones = historyTombstones;
    if (data['historyTombstones'] is Map) {
      final incoming = HistoryTombstones(
        deletedVersions: HistorySyncSnapshot.stringMapOf(
          (data['historyTombstones'] as Map)['deleted'],
        ),
        clearVersion:
            ((data['historyTombstones'] as Map)['clear'] ?? '')
                .toString()
                .trim()
                .isEmpty
            ? null
            : (data['historyTombstones'] as Map)['clear'].toString(),
      );
      restoredTombstones = _mergeTombstones(historyTombstones, incoming);
    }
    if (!restoredTombstones.isEmpty) {
      historyTombstones = restoredTombstones;
      history = [
        for (final item in history)
          if (_survivesTombstones(item, restoredTombstones)) item,
      ];
    }
    if (data['searchHistory'] is List) {
      searchHistory = (data['searchHistory'] as List)
          .map((e) => e.toString())
          .toList();
    }
    if (data['playerSettings'] is Map) {
      playerSettings = PlayerSettings.fromJson(
        Map<String, dynamic>.from(data['playerSettings'] as Map),
      );
      sourceService.js.setWorkerCount(playerSettings.jsWorkerPool ? 3 : 1);
      sourceService.jar.setKeepHostsWarm(playerSettings.keepSpiderHosts);
    }
    if (data['proxy'] is Map) {
      proxy = ProxyConfig.fromJson(
        Map<String, dynamic>.from(data['proxy'] as Map),
      );
    }
    if (data['driveAccounts'] is List) {
      final accounts = <String, DriveAccount>{};
      for (final item in data['driveAccounts'] as List) {
        if (item is! Map) continue;
        final account = DriveAccount.fromJson(Map<String, dynamic>.from(item));
        if (account.provider.isNotEmpty) accounts[account.provider] = account;
      }
      driveAccounts = accounts;
    }
    if (data['localLives'] is List) {
      localLives = (data['localLives'] as List)
          .whereType<Map>()
          .map((e) => LiveBean.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    if (data.containsKey('assrtToken')) {
      assrtToken = (data['assrtToken'] ?? '').toString();
    }
    if (data.containsKey('customSubtitleApis')) {
      customSubtitleApis = (data['customSubtitleApis'] ?? '').toString();
    }
    if (data['liveUaPolicy'] is Map) {
      liveUaPolicy = LiveUaPolicy.fromJson(
        Map<String, dynamic>.from(data['liveUaPolicy'] as Map),
      );
    }
    if (data['danmakuSettings'] is Map) {
      danmakuSettings = DanmakuSettings.fromJson(
        Map<String, dynamic>.from(data['danmakuSettings'] as Map),
      );
    }
    if (data['contentFilter'] is Map) {
      contentFilter = ContentFilterSettings.fromJson(
        Map<String, dynamic>.from(data['contentFilter'] as Map),
      );
    }
    final mode = (data['themeMode'] ?? '').toString();
    themeMode = switch (mode) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    accentIndex = ((data['accentIndex'] as num?)?.toInt() ?? accentIndex).clamp(
      0,
      accentPalette.length - 1,
    );
    navBarSize = ((data['navBarSize'] as num?)?.toInt() ?? navBarSize).clamp(
      0,
      3,
    );
    navBarAutoHide = data['navBarAutoHide'] as bool? ?? navBarAutoHide;
    homeColumns = (data['homeColumns'] as num?)?.toInt() ?? homeColumns;
    homeColumns = homeColumns <= 0 ? 0 : homeColumns.clamp(4, 8);
    homeBrowseMode =
        ((data['homeBrowseMode'] as num?)?.toInt() ?? homeBrowseMode) == 1
        ? 1
        : 0;
    showMovieQuotes = data['showMovieQuotes'] as bool? ?? showMovieQuotes;

    if (data['kazumiRules'] is List) {
      final rules = <KazumiRule>[];
      for (final item in data['kazumiRules'] as List) {
        if (item is! Map) continue;
        final rule = KazumiRule.fromJson(Map<String, dynamic>.from(item));
        if (rule.valid) rules.add(rule);
      }
      kazumiRules = rules;
      _kazumiRev++;
    }

    _loadActiveConfig();
    if (activeSiteKey == null || activeSiteKey!.isEmpty) {
      activeSiteKey = fallbackSite?.key;
    }
    _loadActiveLiveConfig();

    _syncGlobalJar();
    _syncDriveTokens();
    await _persistProfiles();
    await store.setActiveProfileId(activeProfileId);
    await store.setActiveSiteKey(activeSiteKey);
    await store.setActiveLiveProfileId(activeLiveProfileId);
    await store.setActiveLiveKey(activeLiveKey);
    await store.saveFavorites(favorites);
    await store.saveHistory(history);
    await store.saveSearchHistory(searchHistory);
    await store.savePlayerSettings(playerSettings);
    await store.setProxyJson(proxy.toJsonString());
    await ProxyRuntime.instance.apply(proxy);
    await sourceService.jar.resetForNetworkChange();
    await store.saveDriveAccounts(driveAccounts);
    await store.saveLocalLives(localLives);
    await store.setAssrtToken(assrtToken);
    await store.setCustomSubtitleApis(customSubtitleApis);
    LiveUaPolicy.current = liveUaPolicy;
    await store.saveLiveUaPolicyJson(liveUaPolicy.toJsonString());
    await store.saveDanmakuSettingsJson(danmakuSettings.toJsonString());
    await store.saveContentFilterJson(contentFilter.toJsonString());
    await store.saveKazumiRules([for (final rule in kazumiRules) rule.raw]);
    await store.setThemeMode(switch (themeMode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      _ => 'system',
    });
    await store.setAccentIndex(accentIndex);
    await store.setNavBarSize(navBarSize);
    await store.setNavBarAutoHide(navBarAutoHide);
    await store.setHomeColumns(homeColumns);
    await store.setHomeBrowseMode(homeBrowseMode);
    await store.setShowMovieQuotes(showMovieQuotes);
    await _purgeUnusedJars();
    notifyListeners();
  }

  Future<void> _persistProfiles() => store.saveProfiles(profiles);

  Future<void> acceptEula() async {
    if (eulaAccepted) return;
    eulaAccepted = true;
    await store.setEulaAccepted(true);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    await store.setThemeMode(switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
    notifyListeners();
  }

  Future<void> setAccentIndex(int index) async {
    accentIndex = index.clamp(0, accentPalette.length - 1);
    await store.setAccentIndex(accentIndex);
    notifyListeners();
  }

  /// 调整底部导航栏尺寸（0 紧凑 / 1 标准 / 2 较大 / 3 超大）。
  Future<void> setNavBarSize(int value) async {
    final next = value.clamp(0, 3);
    if (next == navBarSize) return;
    navBarSize = next;
    await store.setNavBarSize(next);
    notifyListeners();
  }

  /// 常驻 / 自动隐藏底部导航栏。
  Future<void> setNavBarAutoHide(bool value) async {
    if (value == navBarAutoHide) return;
    navBarAutoHide = value;
    await store.setNavBarAutoHide(value);
    notifyListeners();
  }

  /// 调整首页每行封面数（0 = 自动，4-8 = 固定列数）。
  Future<void> setHomeColumns(int value) async {
    final next = value <= 0 ? 0 : value.clamp(4, 8);
    if (next == homeColumns) return;
    homeColumns = next;
    await store.setHomeColumns(next);
    notifyListeners();
  }

  /// 切换首页分类浏览方式：0 = 换页，1 = 瀑布。
  Future<void> setHomeBrowseMode(int value) async {
    final next = value == 1 ? 1 : 0;
    if (next == homeBrowseMode) return;
    homeBrowseMode = next;
    await store.setHomeBrowseMode(next);
    notifyListeners();
  }

  /// 切换首页顶部影视台词轮换的显示。
  Future<void> setShowMovieQuotes(bool value) async {
    if (value == showMovieQuotes) return;
    showMovieQuotes = value;
    await store.setShowMovieQuotes(value);
    notifyListeners();
  }

  /// 记住当前窗口尺寸，下次启动按它创建；传 null 恢复自动计算。
  Future<void> setRememberedWindowSize(Size? size) async {
    rememberedWindowSize = size;
    await store.saveWindowSize(size);
    notifyListeners();
  }

  bool isFavorite(String sourceKey, String vodId) =>
      favorites.any((f) => f.sourceKey == sourceKey && f.vodId == vodId);

  Future<bool> toggleFavorite(VodDetail detail, SourceBean? site) async {
    final sourceKey = detail.sourceKey;
    final key = '$sourceKey|${detail.id}';
    final exists = favorites.any((f) => f.key == key);
    if (exists) {
      favorites = favorites.where((f) => f.key != key).toList();
      await store.saveFavorites(favorites);
      notifyListeners();
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    favorites = [
      FavoriteItem(
        key: key,
        name: detail.name,
        createdAt: now,
        updatedAt: now,
        sourceKey: sourceKey,
        sourceName: site?.displayName ?? '',
        vodId: detail.id,
        pic: detail.cleanPic,
        remarks: detail.remarks,
        year: detail.year,
        type: detail.type,
      ),
      ...favorites,
    ];
    await store.saveFavorites(favorites);
    notifyListeners();
    return true;
  }

  Future<void> updateFavorite(String key, {String? title, String? note}) async {
    favorites = favorites
        .map((f) => f.key == key ? f.copyWith(title: title, note: note) : f)
        .toList();
    await store.saveFavorites(favorites);
    notifyListeners();
  }

  Future<void> removeFavorite(String key) async {
    favorites = favorites.where((f) => f.key != key).toList();
    await store.saveFavorites(favorites);
    notifyListeners();
  }

  /// 收藏更新检测进行中（收藏页据此显示进度）。
  bool favoriteChecking = false;
  int _lastFavoriteCheckAt = 0;

  int get favoriteUpdateCount => favorites.where((f) => f.hasUpdate).length;

  /// 收藏更新指纹：备注 + 每条线路的集数与末集名。
  static String favoriteSignature(VodDetail detail) {
    final parts = <String>[detail.remarks.trim()];
    final flags = detail.flags.isNotEmpty
        ? detail.flags
        : detail.episodes.keys.toList();
    for (final flag in flags) {
      final episodes = detail.episodes[flag] ?? const <Episode>[];
      final last = episodes.isEmpty ? '' : episodes.last.name;
      parts.add('$flag:${episodes.length}:$last');
    }
    return parts.join('|');
  }

  /// 检查收藏是否有更新：按源拉取详情，比对「备注 + 集数/末集名」指纹。
  ///
  /// 首次检查只记录基线；之后指纹变化才标记 [FavoriteItem.hasUpdate]。
  /// 默认 30 分钟内不重复检查，[force] 用于页面上的手动刷新。
  Future<int> checkFavoriteUpdates({bool force = false}) async {
    if (favoriteChecking || favorites.isEmpty) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        now - _lastFavoriteCheckAt <
            const Duration(minutes: 30).inMilliseconds) {
      return 0;
    }
    favoriteChecking = true;
    notifyListeners();
    final sw = Stopwatch()..start();
    final list = List<FavoriteItem>.of(favorites);
    final sites = <String, SourceBean>{
      for (final site in config?.sites ?? const <SourceBean>[]) site.key: site,
    };
    var cursor = 0;
    var found = 0;
    Future<void> worker() async {
      while (cursor < list.length) {
        final index = cursor++;
        final fav = list[index];
        final site = sites[fav.sourceKey];
        if (site == null || !isSiteUsable(site) || fav.vodId.trim().isEmpty) {
          continue;
        }
        // 后台自动检查只碰 CMS / JS 源：PY / JAR 运行时未安装时，调用会顺带触发
        // 20 MB / 85 MB 的按需下载，不该由一次静默检查发起。手动检查才覆盖全部。
        if (!force && (site.isPySpider || site.isJarSpider)) continue;
        try {
          final detail = await sourceService
              .detail(site, fav.vodId)
              .timeout(const Duration(seconds: 20));
          if (detail == null) continue;
          final signature = favoriteSignature(detail);
          if (signature.isEmpty) continue;
          final changed =
              fav.updateSignature.isNotEmpty &&
              signature != fav.updateSignature;
          if (changed) found++;
          list[index] = fav.withUpdateCheck(
            signature: signature,
            hasUpdate: changed || fav.hasUpdate,
            updateNote: changed
                ? (detail.remarks.trim().isEmpty
                      ? '剧集有更新'
                      : detail.remarks.trim())
                : fav.updateNote,
          );
        } catch (_) {
          // 源暂时不可用：保留原状态，下次再查。
        }
      }
    }

    final workers = list.length < 3 ? list.length : 3;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    // 只回填仍在收藏里的条目：检查期间被取消收藏的不能复活。
    final checked = {for (final f in list) f.key: f};
    favorites = favorites.map((f) => checked[f.key] ?? f).toList();
    _lastFavoriteCheckAt = now;
    favoriteChecking = false;
    await store.saveFavorites(favorites);
    notifyListeners();
    AppLog.i(
      'favorite',
      '更新检查完成 共=${list.length} 新增更新=$found ${sw.elapsedMilliseconds}ms force=$force',
    );
    return found;
  }

  /// 打开收藏详情后清除「有更新」标记（指纹已在新值上，不会重复提醒）。
  Future<void> markFavoriteSeen(String key) async {
    final index = favorites.indexWhere((f) => f.key == key && f.hasUpdate);
    if (index < 0) return;
    final fav = favorites[index];
    favorites = List<FavoriteItem>.of(favorites)
      ..[index] = fav.withUpdateCheck(
        signature: fav.updateSignature,
        hasUpdate: false,
        updateNote: fav.updateNote,
      );
    await store.saveFavorites(favorites);
    notifyListeners();
  }

  HistoryItem? historyFor(String sourceKey, String vodId) {
    final key = '$sourceKey|$vodId';
    for (final h in history) {
      if (h.key == key) return h;
    }
    return null;
  }

  Future<void> recordHistory({
    required VodDetail detail,
    required SourceBean? site,
    required String flag,
    required String episodeName,
    required int episodeIndex,
    required String url,
    String rawUrl = '',
    Map<String, String> headers = const {},
    int positionMs = 0,
    int durationMs = 0,
  }) async {
    final key = '${detail.sourceKey}|${detail.id}';
    final now = DateTime.now().millisecondsSinceEpoch;
    // 历史是明文落盘的，只记防盗链需要的头；Cookie / Authorization 属于
    // 账号凭据，不能跟着历史一起写出去（网盘线路也不复用历史地址）。
    const safeHeaderKeys = {'referer', 'user-agent', 'origin'};
    final savedHeaders = <String, String>{
      for (final entry in headers.entries)
        if (safeHeaderKeys.contains(entry.key.toLowerCase()))
          entry.key: entry.value,
    };
    history = [
      HistoryItem(
        key: key,
        name: detail.name,
        updatedAt: now,
        sourceKey: detail.sourceKey,
        sourceName: site?.displayName ?? '',
        vodId: detail.id,
        pic: detail.cleanPic,
        remarks: detail.remarks,
        flag: flag,
        episodeName: episodeName,
        episodeIndex: episodeIndex,
        url: url,
        rawUrl: rawUrl,
        headers: savedHeaders,
        positionMs: positionMs,
        durationMs: durationMs,
      ),
      ...history.where((h) => h.key != key),
    ];
    final limit = playerSettings.historyLimit.clamp(30, 500).toInt();
    if (history.length > limit) {
      history = history.take(limit).toList();
    }
    await store.saveHistory(history);
    notifyListeners();
  }

  Future<void> updateHistoryProgress(
    String key,
    int positionMs,
    int durationMs,
  ) async {
    var changed = false;
    history = history.map((h) {
      if (h.key != key) return h;
      changed = true;
      return h.copyWith(
        positionMs: positionMs,
        durationMs: durationMs,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }).toList();
    if (!changed) return;
    await store.saveHistory(history);
    notifyListeners();
  }

  /// 合并两份墓碑：同一个 key 保留版本更新的一个；清空版本取更新的一方。
  static HistoryTombstones _mergeTombstones(
    HistoryTombstones a,
    HistoryTombstones b,
  ) {
    final deleted = Map<String, String>.from(a.deletedVersions);
    for (final entry in b.deletedVersions.entries) {
      final existing = deleted[entry.key];
      if (existing == null ||
          HistorySyncVersion.compare(entry.value, existing) > 0) {
        deleted[entry.key] = entry.value;
      }
    }
    final clearA = a.clearVersion;
    final clearB = b.clearVersion;
    String? clear;
    if (clearA == null) {
      clear = clearB;
    } else if (clearB == null) {
      clear = clearA;
    } else {
      clear = HistorySyncVersion.compare(clearA, clearB) >= 0 ? clearA : clearB;
    }
    return HistoryTombstones(deletedVersions: deleted, clearVersion: clear);
  }

  /// 一条历史是否不该被墓碑挡住（供备份还原过滤用）。
  static bool _survivesTombstones(
    HistoryItem item,
    HistoryTombstones tombstones,
  ) {
    final version = HistorySyncVersion.of(
      updatedAt: item.updatedAt,
      eventId: 'local:${item.key}',
    );
    final tomb = tombstones.deletedVersions[item.key];
    if (tomb != null && HistorySyncVersion.compare(version, tomb) <= 0) {
      return false;
    }
    final clear = tombstones.clearVersion;
    if (clear != null && HistorySyncVersion.compare(version, clear) <= 0) {
      return false;
    }
    return true;
  }

  Future<void> removeHistory(String key) async {
    history = history.where((h) => h.key != key).toList();
    // 留墓碑：否则独立播放器窗口 / 导入的旧备份会把这条记录带回来。
    final now = DateTime.now().millisecondsSinceEpoch;
    historyTombstones = HistoryTombstones(
      deletedVersions: {
        ...historyTombstones.deletedVersions,
        key: HistorySyncVersion.of(
          updatedAt: now,
          eventId: 'delete:$key:$now',
        ),
      },
      clearVersion: historyTombstones.clearVersion,
    );
    await store.saveHistory(history);
    await store.saveHistoryTombstones(historyTombstones);
    notifyListeners();
  }

  Future<void> clearHistory() async {
    history = [];
    // 清空是全局墓碑：版本早于它的历史一律不再接受。
    final now = DateTime.now().millisecondsSinceEpoch;
    historyTombstones = HistoryTombstones(
      deletedVersions: historyTombstones.deletedVersions,
      clearVersion: HistorySyncVersion.of(
        updatedAt: now,
        eventId: 'clear:$now',
      ),
    );
    await store.saveHistory(history);
    await store.saveHistoryTombstones(historyTombstones);
    notifyListeners();
  }

  /// 把外部历史（另一台设备 / 独立窗口 / 备份）合并进本地，遵守墓碑规则。
  ///
  /// 返回实际被采纳的事件数；0 表示本地已是最新（不会产生多余写盘）。
  Future<int> mergeExternalHistory(
    Iterable<HistorySyncEvent> events, {
    int keepLimit = 200,
  }) async {
    final result = mergeHistory(
      current: history,
      incoming: events,
      deletedVersions: historyTombstones.deletedVersions,
      clearVersion: historyTombstones.clearVersion,
      keepLimit: keepLimit,
    );
    if (result.accepted == 0) return 0;
    history = result.items;
    historyTombstones = HistoryTombstones(
      deletedVersions: result.deletedVersions,
      clearVersion: result.clearVersion,
    );
    await store.saveHistory(history);
    await store.saveHistoryTombstones(historyTombstones);
    notifyListeners();
    return result.accepted;
  }

  Future<void> addSearchKeyword(String keyword) async {
    final k = keyword.trim();
    if (k.isEmpty) return;
    searchHistory = [
      k,
      ...searchHistory.where((e) => e != k),
    ].take(30).toList();
    await store.saveSearchHistory(searchHistory);
    notifyListeners();
  }

  Future<void> clearSearchHistory() async {
    searchHistory = [];
    await store.saveSearchHistory(searchHistory);
    notifyListeners();
  }

  /// 跳转到搜索页并搜索该片名（详情页相关推荐 / 演职员共用）。
  void requestSearch(String keyword) {
    final k = keyword.trim();
    if (k.isEmpty) return;
    pendingSearchKeyword = k;
    pendingSearchSeq++;
    notifyListeners();
  }

  Future<void> setAssrtToken(String token) async {
    assrtToken = token.trim();
    await store.setAssrtToken(assrtToken);
    notifyListeners();
  }

  Future<void> setCustomSubtitleApis(String text) async {
    customSubtitleApis = text.trim();
    await store.setCustomSubtitleApis(customSubtitleApis);
    notifyListeners();
  }

  /// 保存自定义直播 UA 设置，并立刻登记到静态策略（LiveService 与中继都读它）。
  Future<void> setLiveUaPolicy(LiveUaPolicy policy) async {
    liveUaPolicy = policy;
    LiveUaPolicy.current = policy;
    await store.saveLiveUaPolicyJson(policy.toJsonString());
    notifyListeners();
  }

  /// 设置中手动添加的第三方播放器（按路径去重，id 用于推断起播参数）。
  List<ExternalPlayer> get customExternalPlayers {
    final out = <ExternalPlayer>[];
    final seen = <String>{};
    for (final entry in playerSettings.externalPlayers) {
      final path = entry.path.trim();
      if (path.isEmpty || !seen.add(path.toLowerCase())) continue;
      final name = entry.name.trim();
      out.add(
        ExternalPlayer(
          id: externalPlayerKind(path),
          name: name.isEmpty ? externalPlayerDisplayName(path) : name,
          path: path,
          isCustom: true,
        ),
      );
    }
    return out;
  }

  Future<void> setCustomExternalPlayers(List<ExternalPlayerEntry> entries) =>
      setPlayerSettings(playerSettings.copyWith(externalPlayers: entries));

  Future<void> setDanmakuSettings(DanmakuSettings settings) async {
    danmakuSettings = settings;
    await store.saveDanmakuSettingsJson(settings.toJsonString());
    notifyListeners();
  }

  Future<void> setContentFilter(ContentFilterSettings settings) async {
    contentFilter = settings;
    await store.saveContentFilterJson(settings.toJsonString());
    notifyListeners();
  }

  Future<void> setPlayerSettings(PlayerSettings settings) async {
    final jsPoolChanged = settings.jsWorkerPool != playerSettings.jsWorkerPool;
    final keepHostsChanged =
        settings.keepSpiderHosts != playerSettings.keepSpiderHosts;
    final magnetDirChanged =
        settings.magnetDownloadDir != playerSettings.magnetDownloadDir;
    playerSettings = settings;
    await store.savePlayerSettings(settings);
    if (jsPoolChanged) {
      sourceService.js.setWorkerCount(settings.jsWorkerPool ? 3 : 1);
    }
    if (keepHostsChanged) {
      sourceService.jar.setKeepHostsWarm(settings.keepSpiderHosts);
    }
    if (magnetDirChanged) {
      torrentPlay?.setDownloadDir(settings.magnetDownloadDir);
    }
    notifyListeners();
  }

  /// 迅雷云盘账号密码登录（只保存令牌，不保存密码）。
  ///
  /// 返回 [XunleiLoginStep]：`success` 表示已拿到令牌；`needSms` 表示触发了
  /// 迅雷安全验证，需要继续走 [sendXunleiSms] / [completeXunleiSmsLogin]。
  Future<XunleiLoginStep> loginXunlei({
    required String username,
    required String password,
  }) => xunleiCloudService.loginWithPassword(
    username: username,
    password: password,
  );

  Future<XunleiLoginStep> sendXunleiSms(String mobile) =>
      xunleiCloudService.sendSms(mobile: mobile);

  Future<XunleiAccount> completeXunleiSmsLogin({
    required String mobile,
    required String code,
    required String creditKey,
    required String smsToken,
  }) => xunleiCloudService.loginWithSms(
    mobile: mobile,
    code: code,
    creditKey: creditKey,
    smsToken: smsToken,
  );

  /// 用已有 refresh_token 登录，不需要密码和短信验证。
  Future<XunleiAccount> loginXunleiWithRefreshToken(String refreshToken) =>
      xunleiCloudService.loginWithRefreshToken(refreshToken);

  Future<void> logoutXunlei() => xunleiCloudService.logout();

  Future<void> setXunleiEnabled(bool enabled) =>
      xunleiCloudService.setEnabled(enabled);

  /// 保存并立即应用内置代理；常驻 JVM 只在启动时读代理属性，需要重开进程池。
  Future<void> setProxy(ProxyConfig next) async {
    if (next == proxy) return;
    proxy = next;
    await store.setProxyJson(next.toJsonString());
    await _applyEffectiveProxy();
    notifyListeners();
  }

  /// 决定「到底走哪个代理」：
  ///
  ///   1. 手动代理（设置里填了地址端口）优先；
  ///   2. 否则用「跟随系统代理 / 直连」的开关（默认直连）。
  Future<void> _applyEffectiveProxy() async {
    final source = proxy.valid
        ? '手动代理'
        : (proxy.followSystem ? '跟随系统代理' : '直连');
    await ProxyRuntime.instance.apply(proxy);
    await sourceService.jar.resetForNetworkChange();
    AppLog.i('proxy', '生效代理：$source → ${ProxyRuntime.instance.summary}');
  }

  /// 本集应使用的跳过设置（本集记录 → 同资源最近一次设置）。
  SkipResolved? skipFor(String resource, String episode) =>
      resolveSkip(skipSegments, resource, episode);

  /// 保存 / 清除整个资源的跳过设置（两项都为 0 即清除该资源全部记录）。
  Future<void> saveSkipSegment({
    required String resource,
    required String episode,
    required int intro,
    required int outro,
    String label = '',
  }) async {
    skipSegments = putResourceSkipRecord(
      skipSegments,
      resource,
      episode,
      SkipSegment(intro: intro, outro: outro),
      label: label,
    );
    await store.saveSkipSegments(skipSegments);
    notifyListeners();
  }

  /// 导出全部跳过记录（JSON，可跨设备分享）。
  String skipSegmentsJson() => jsonEncode({
    for (final entry in skipSegments.entries) entry.key: entry.value.toJson(),
  });

  /// 导入跳过记录；同键以导入文件为准，其余保留。
  Future<int> importSkipSegmentsJson(String text) async {
    final decoded = jsonDecode(text);
    if (decoded is! Map) throw AppException('片头片尾文件格式不正确');
    final incoming = <String, SkipRecord>{};
    for (final entry in decoded.entries) {
      final record = normalizeSkipRecord(entry.value);
      if (record == null) continue;
      incoming[entry.key.toString()] = record;
    }
    if (incoming.isEmpty) return 0;
    skipSegments = {...skipSegments, ...incoming};
    await store.saveSkipSegments(skipSegments);
    notifyListeners();
    return incoming.length;
  }

  Future<void> clearSkipSegments() async {
    skipSegments = {};
    await store.saveSkipSegments(skipSegments);
    notifyListeners();
  }

  void _syncDriveTokens() {
    driveTokens
      ..clear()
      ..addEntries(
        driveAccounts.entries
            .where((e) => e.value.cookie.trim().isNotEmpty)
            // 确认访客态的凭据不能注入：只会让蜘蛛返回 404 / 空数据，应该走
            // 登录 / 重新粘贴重来。哔哩不在此列 —— 它的 Cookie 是画质增强，
            // 过期 Cookie 只会降画质，filter 掉反而连 360P 的登录态也没有了。
            .where((e) => !_isGuestCredential(e.key, e.value.extra['guest']))
            .map((e) => MapEntry(e.key, e.value.cookie.trim())),
      );
  }

  /// 该凭据是否已被在线探测判为访客态（不能注入蜘蛛）。
  ///
  /// 115 同样是硬门槛（UID / CID / SEID 缺一或过期都取不到流），一并过滤；
  /// 哔哩是可选增强，**永远不丢**，否则用户配好的 Cookie 会被一次风控探测误清。
  static bool _isGuestCredential(String provider, String? guest) {
    if (guest != 'true') return false;
    return provider == 'quark' ||
        provider == 'uc' ||
        provider == 'baidu' ||
        provider == '115';
  }

  bool hasDriveAccount(String provider) {
    final account = driveAccounts[provider];
    if (account == null) return false;
    if (_isGuestCredential(provider, account.extra['guest'])) return false;
    return account.cookie.trim().isNotEmpty;
  }

  /// 该 Cookie 是否属于「可选增强」：没有也能播，只是画质 / 可用性受限。
  ///
  /// 哔哩哔哩就是这种：不登录照样能取到 360P / 480P 的 `durl`，配上 Cookie
  /// 才有高清与大会员画质。所以缺它时**不能**弹登录窗、也不能阻断播放。
  static bool isOptionalDriveProvider(String provider) => provider == 'bili';

  /// 供 JS 蜘蛛 `local` 读取的种子键（wex 系 jar 的 SharedPreferences 同义位置）。
  Map<String, String> get driveLocalSeed {
    final seed = <String, String>{};
    final ucTv = driveAccounts['uc']?.extra;
    if (ucTv != null) {
      final token = (ucTv['uctvToken'] ?? '').trim();
      final device = (ucTv['uctvDeviceId'] ?? '').trim();
      if (token.isNotEmpty) seed['Wex_ucpan_token'] = token;
      if (device.isNotEmpty) seed['Wex_ucpan_device_id'] = device;
    }
    return seed;
  }

  /// 播放 / 取流时网盘凭据疑似失效（如夸克 download 404）：按需刷新会话再重试。
  /// 对齐 winbox：蜘蛛只在 init 读一次 cookie，旧 `__puus` 必须由 `/member` 补发。
  Future<void> refreshDriveSession(String provider) async {
    if (!_refreshableProviders.contains(provider)) return;
    AppLog.i('drive', '刷新网盘会话 provider=$provider');
    await _refreshDriveSession(provider);
  }

  /// 支持在线探测登录态的 provider（其余只有 Cookie 文本，没有校验接口）。
  static const _refreshableProviders = <String>{
    'quark',
    'uc',
    'baidu',
    '115',
    'bili',
  };

  /// 探测夸克 / UC / 百度 / 115 / 哔哩登录态：吸收响应下发的新 Cookie；若确认是
  /// 访客态则标记 `extra.guest=true`，让 `hasDriveAccount` / `_syncDriveTokens`
  /// 把这条凭据当成「未登录」——否则蜘蛛会拿着访客 Cookie 去取流，只回空数据。
  Future<void> _refreshDriveSession(String provider) async {
    if (_refreshingDriveSessions.contains(provider)) return;
    final account = driveAccounts[provider];
    final cookie = account?.cookie.trim() ?? '';
    if (account == null || cookie.isEmpty) return;
    final label = switch (provider) {
      'quark' => '夸克',
      'uc' => 'UC',
      '115' => '115',
      'bili' => '哔哩哔哩',
      _ => '百度',
    };
    _refreshingDriveSessions.add(provider);
    try {
      final result = switch (provider) {
        'quark' => await refreshQuarkSession(cookie),
        'uc' => await refreshUcSession(cookie),
        '115' => await refreshPan115Session(cookie),
        'bili' => await refreshBiliSession(cookie),
        _ => await refreshBaiduSession(cookie),
      };
      final wasGuest = account.extra['guest'] == 'true';
      if (result.valid == false) {
        AppLog.w('drive', '$label会话判定为访客态（这条凭据不会再注入蜘蛛）');
        if (!wasGuest) {
          final next = account.copyWith(
            extra: {...account.extra, 'guest': 'true'},
          );
          driveAccounts = {...driveAccounts, provider: next};
          _syncDriveTokens();
          LocalRelay.instance.clearPlaySession(provider);
          await store.saveDriveAccounts(driveAccounts);
          notifyListeners();
          unawaited(sourceService.jar.resetDriveState());
        }
        return;
      }
      // 网络异常（valid=null）时保持现状，避免把访客态误清成已登录。
      if (result.valid != true) return;
      // 确认登录成功：合并新 Cookie、清掉访客标记。
      final extra = {...account.extra}..remove('guest');
      if (result.changed || wasGuest) {
        final next = account.copyWith(
          cookie: result.changed ? result.cookie : account.cookie,
          extra: extra,
          updatedAt: result.changed
              ? DateTime.now().millisecondsSinceEpoch
              : null,
        );
        driveAccounts = {...driveAccounts, provider: next};
        _syncDriveTokens();
        LocalRelay.instance.clearPlaySession(provider);
        await store.saveDriveAccounts(driveAccounts);
        notifyListeners();
        unawaited(sourceService.jar.resetDriveState());
        AppLog.i(
          'drive',
          '$label会话已更新${result.changed ? '（吸收新 __puus）' : '（清访客标记）'}',
        );
      }
    } finally {
      _refreshingDriveSessions.remove(provider);
    }
  }

  Future<void> saveDriveAccount(
    String provider,
    String cookie, {
    String? username,
    Map<String, String>? extra,
  }) async {
    final previous = driveAccounts[provider];
    final account = DriveAccount(
      provider: provider,
      cookie: cookie.trim(),
      username: (username ?? previous?.username ?? '').trim(),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      extra: extra ?? previous?.extra ?? const {},
    );
    if (account.cookie.isEmpty && (account.extra.isEmpty)) {
      throw AppException('登录凭据为空');
    }
    driveAccounts = {...driveAccounts, provider: account};
    _syncDriveTokens();
    LocalRelay.instance.clearPlaySession(provider);
    await store.saveDriveAccounts(driveAccounts);
    notifyListeners();
    AppLog.i(
      'drive',
      '保存网盘账号 provider=$provider user=${shorten(account.username, 40)}',
    );
    if (_refreshableProviders.contains(provider)) {
      unawaited(_refreshDriveSession(provider));
    }
  }

  Future<void> removeDriveAccount(String provider) async {
    driveAccounts = {...driveAccounts}..remove(provider);
    _syncDriveTokens();
    LocalRelay.instance.clearPlaySession(provider);
    await store.saveDriveAccounts(driveAccounts);
    notifyListeners();
    AppLog.i('drive', '移除网盘账号 provider=$provider');
  }

  /// 新增 / 编辑 WebDAV 服务器（保存后刷新设置页与列表）。
  Future<DavServer> saveDavServer(DavServer server) async {
    final saved = await davService.save(server);
    notifyListeners();
    return saved;
  }

  Future<void> removeDavServer(String id) async {
    await davService.remove(id);
    notifyListeners();
  }

  // ---- 多端同步 ----

  /// 打包当前的历史 / 收藏 / 片头片尾（WebDAV 与局域网共用）。
  SyncBundle buildSyncBundle() => SyncBundle(
    exportedAt: DateTime.now().millisecondsSinceEpoch,
    deviceName: syncDeviceName,
    history: HistorySyncSnapshot.fromItems(
      history,
      deletedVersions: historyTombstones.deletedVersions,
      clearVersion: historyTombstones.clearVersion,
    ),
    favorites: favorites,
    skips: skipSegments,
  );

  /// 合并另一台设备的数据包。
  Future<SyncMergeReport> applySyncBundle(SyncBundle bundle) async {
    final historyAccepted = await mergeExternalHistory(
      historyEventsOf(bundle.history),
    );
    final mergedFavorites = mergeSyncFavorites(favorites, bundle.favorites);
    final mergedSkips = mergeSyncSkips(skipSegments, bundle.skips);
    var wrote = false;
    if (mergedFavorites.changed > 0) {
      favorites = mergedFavorites.items;
      await store.saveFavorites(favorites);
      wrote = true;
    }
    if (mergedSkips.changed > 0) {
      skipSegments = mergedSkips.items;
      await store.saveSkipSegments(skipSegments);
      wrote = true;
    }
    if (wrote) notifyListeners();
    AppLog.i(
      'sync',
      '合并同步包「${bundle.deviceName}」：历史 $historyAccepted · '
          '收藏 ${mergedFavorites.changed} · 片头片尾 ${mergedSkips.changed}',
    );
    return SyncMergeReport(
      historyAccepted: historyAccepted,
      favoritesChanged: mergedFavorites.changed,
      skipsChanged: mergedSkips.changed,
      remoteDevice: bundle.deviceName,
    );
  }

  Future<void> saveSyncSettings(SyncSettings next) async {
    final token = next.lanToken.trim();
    syncSettings = next.copyWith(
      remotePath: SyncSettings.normalizeRemotePath(next.remotePath),
      lanToken: token.isEmpty ? newSyncPairingToken() : token,
    );
    await store.saveSyncSettings(syncSettings);
    notifyListeners();
  }

  /// WebDAV 双向同步：拉取远端 → 合并到本地 → 把合并结果写回远端。
  Future<SyncMergeReport> syncViaWebDav({
    required String serverId,
    String? remotePath,
  }) async {
    if (davService.byId(serverId) == null) {
      throw AppException('请选择 WebDAV 服务器');
    }
    final path = SyncSettings.normalizeRemotePath(
      remotePath ?? syncSettings.remotePath,
    );
    var report = const SyncMergeReport();
    final remoteText = await davService.getText(serverId, path);
    if (remoteText != null && remoteText.trim().isNotEmpty) {
      Map<String, dynamic>? decoded;
      try {
        final raw = jsonDecode(remoteText);
        if (raw is Map) decoded = Map<String, dynamic>.from(raw);
      } catch (_) {
        decoded = null;
      }
      if (decoded == null) {
        throw AppException('远端同步文件不是合法 JSON（$path）');
      }
      report = await applySyncBundle(SyncBundle.fromJson(decoded));
    }
    final merged = buildSyncBundle();
    await davService.putText(serverId, path, jsonEncode(merged.toJson()));
    final now = DateTime.now().millisecondsSinceEpoch;
    syncSettings = syncSettings.copyWith(
      davServerId: serverId,
      remotePath: path,
      lastSyncAt: now,
    );
    await store.saveSyncSettings(syncSettings);
    notifyListeners();
    AppLog.i('sync', 'WebDAV 同步完成：$path');
    return report.copyWith(pushed: true);
  }

  /// 局域网双向同步：拉取对端 → 合并 → 把合并结果推回对端。
  Future<SyncMergeReport> syncViaLan({
    required String baseUrl,
    required String token,
  }) async {
    final base = normalizeLanBase(baseUrl);
    if (base.isEmpty) throw AppException('请填写对方设备地址');
    final code = token.trim();
    if (code.isEmpty) throw AppException('请填写配对码');
    final query = 'token=${Uri.encodeQueryComponent(code)}';
    final remote = await LanClient.getJson(
      '$base/sync?$query',
      timeout: const Duration(seconds: 15),
    );
    final bundle = SyncBundle.fromJson(remote);
    final report = await applySyncBundle(bundle);
    final merged = buildSyncBundle();
    final reply = await LanClient.postJson(
      '$base/sync?$query',
      merged.toJson(),
      timeout: const Duration(seconds: 25),
    );
    // 对端在收到我们的数据后可能又合并出新结果，再应用一次即可两端一致。
    final replyBundle = reply['bundle'];
    if (replyBundle is Map) {
      await applySyncBundle(SyncBundle.fromJson(Map<String, dynamic>.from(replyBundle)));
    }
    syncSettings = syncSettings.copyWith(
      lastSyncAt: DateTime.now().millisecondsSinceEpoch,
    );
    await store.saveSyncSettings(syncSettings);
    notifyListeners();
    AppLog.i('sync', '局域网同步完成：$base');
    return report.copyWith(remoteDevice: bundle.deviceName);
  }

  Future<int> startLanSyncServer() async {
    final port = await lanServer.start();
    notifyListeners();
    return port;
  }

  Future<void> stopLanSyncServer() async {
    if (watchParty.hosting) watchParty.leave();
    await lanServer.stop();
    notifyListeners();
  }

  Future<List<String>> lanSyncAddresses() => lanServer.lanAddresses();

  // ---- 媒体库 ----

  Future<MediaServer> saveMediaServer(MediaServer server) async {
    final saved = await mediaServers.save(server);
    notifyListeners();
    return saved;
  }

  Future<void> removeMediaServer(String id) async {
    await mediaServers.remove(id);
    notifyListeners();
  }

  Future<void> addLocalMediaDir(String dir) async {
    await localMedia.addDir(dir);
    notifyListeners();
  }

  Future<void> removeLocalMediaDir(String dir) async {
    await localMedia.removeDir(dir);
    notifyListeners();
  }
}

import 'dart:convert';
import 'dart:ui' show Size;

import 'package:shared_preferences/shared_preferences.dart';

import '../core/platform/credential_vault.dart';
import '../core/platform/portable_app_data.dart';
import '../models/dav.dart';
import '../models/drive_account.dart';
import '../models/media_server.dart';
import '../models/site_config.dart';
import '../models/sync_settings.dart';
import '../models/user_data.dart';
import '../models/video_download_record.dart';
import '../models/xunlei_account.dart';
import 'player/skip_segments.dart';
import 'sync/history_sync.dart';

class LocalStore {
  LocalStore(this._prefs);
  final SharedPreferences _prefs;

  static const kProfiles = 'kniephos.profiles';
  static const kProfileHistory = 'kniephos.profileHistory';
  static const kKazumiRules = 'kniephos.kazumiRules';
  static const kActiveProfile = 'kniephos.activeProfile';
  static const kActiveSite = 'kniephos.activeSite';
  static const kActiveLive = 'kniephos.activeLive';
  static const kActiveLiveProfile = 'kniephos.activeLiveProfile';
  static const kThemeMode = 'kniephos.themeMode';
  static const kAccentIndex = 'kniephos.accentIndex';
  static const kNavBarSize = 'kniephos.navBarSize';
  static const kNavBarAutoHide = 'kniephos.navBarAutoHide';
  static const kHomeColumns = 'kniephos.homeColumns';
  static const kHomeBrowseMode = 'kniephos.homeBrowseMode';
  static const kShowMovieQuotes = 'kniephos.showMovieQuotes';
  static const kFavorites = 'kniephos.favorites';
  static const kHistory = 'kniephos.history';

  /// 历史墓碑（删除 / 清空留下的版本号）。没有它，多窗口或导入旧备份会把
  /// 已删除的条目复活（见 services/sync/history_sync.dart）。
  static const kHistoryTombstones = 'kniephos.historyTombstones';

  /// 源搜索耗时档案（已移除，保留键名清理旧数据用）。
  static const kSourceSpeed = 'kniephos.sourceSpeed';

  /// 源健康度（连续失败 / 冷却截止 / 最后错误），跨启动保留。
  static const kSourceHealth = 'kniephos.sourceHealth';
  static const kSearchHistory = 'kniephos.searchHistory';
  static const kPlayerSettings = 'kniephos.playerSettings';

  /// 播放器「下载视频」的任务记录（含下载请求头，写入时走凭据加密）。
  static const kVideoDownloads = 'kniephos.videoDownloads';
  static const kDriveAccounts = 'kniephos.driveAccounts';
  static const kXunleiAccount = 'kniephos.xunleiAccount';
  static const kLocalLives = 'kniephos.localLives';
  static const kAssrtToken = 'kniephos.assrtToken';
  static const kCustomSubtitleApis = 'kniephos.customSubtitleApis';
  static const kLiveUaPolicy = 'kniephos.liveUaPolicy';
  static const kDanmakuSettings = 'kniephos.danmakuSettings';
  static const kContentFilter = 'kniephos.contentFilter';
  static const kMovieQuotes = 'kniephos.movieQuotes';
  static const kEulaAccepted = 'kniephos.eulaAccepted';
  static const kSkipSegments = 'kniephos.skipSegments';
  static const kDavServers = 'kniephos.davServers';
  static const kProxy = 'kniephos.proxy';
  static const kWindowSize = 'kniephos.windowSize';

  /// 多端同步设置（设备名 / WebDAV 目标 / 局域网配对码）。
  static const kSyncSettings = 'kniephos.syncSettings';

  /// Emby / Jellyfin 服务器（API Key 与 WebDAV 密码同样走凭据加密）。
  static const kMediaServers = 'kniephos.mediaServers';

  /// 本地媒体库扫描目录。
  static const kLocalMediaDirs = 'kniephos.localMediaDirs';

  static Future<LocalStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    return LocalStore(prefs);
  }

  /// 重新从磁盘读取偏好（独立播放器窗口写回的历史/设置同步用）。
  Future<void> reload() => reloadPortablePrefs();

  List<ConfigProfile> loadProfiles() {
    final raw = _prefs.getString(kProfiles);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => ConfigProfile.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveProfiles(List<ConfigProfile> profiles) => _prefs.setString(
    kProfiles,
    jsonEncode(profiles.map((e) => e.toJson()).toList()),
  );

  /// 订阅原文快照（刷新 / 重新导入前保存，回滚用）。
  List<ConfigSnapshot> loadProfileHistory() {
    final raw = _prefs.getString(kProfileHistory);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => ConfigSnapshot.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.profileId.isNotEmpty && e.rawJson.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveProfileHistory(List<ConfigSnapshot> history) =>
      _prefs.setString(
        kProfileHistory,
        jsonEncode(history.map((e) => e.toJson()).toList()),
      );

  /// 本地导入的 Kazumi 规则（原始 JSON 数组，便于版本升级后重新解析）。
  List<Map<String, dynamic>> loadKazumiRules() {
    final raw = _prefs.getString(kKazumiRules);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map) Map<String, dynamic>.from(item),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveKazumiRules(List<Map<String, dynamic>> rules) =>
      _prefs.setString(kKazumiRules, jsonEncode(rules));

  Map<String, DriveAccount> loadDriveAccounts() {
    final raw = _prefs.getString(kDriveAccounts);
    if (raw == null || raw.isEmpty) return {};
    final plain = CredentialVault.unprotect(raw);
    if (plain == null || plain.isEmpty) return {};
    try {
      final decoded = jsonDecode(plain);
      if (decoded is! List) return {};
      final map = <String, DriveAccount>{};
      for (final item in decoded.whereType<Map>()) {
        final account = DriveAccount.fromJson(Map<String, dynamic>.from(item));
        if (account.provider.isEmpty) continue;
        map[account.provider] = account;
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveDriveAccounts(Map<String, DriveAccount> accounts) =>
      _prefs.setString(
        kDriveAccounts,
        CredentialVault.protect(
          jsonEncode(accounts.values.map((e) => e.toJson()).toList()),
        ),
      );

  XunleiAccount loadXunleiAccount() {
    final raw = _prefs.getString(kXunleiAccount) ?? '';
    if (raw.isEmpty) return const XunleiAccount();
    return XunleiAccount.fromJsonString(CredentialVault.unprotect(raw) ?? '');
  }

  Future<void> saveXunleiAccount(XunleiAccount account) => _prefs.setString(
    kXunleiAccount,
    CredentialVault.protect(account.toJsonString()),
  );

  Future<void> clearXunleiAccount() => _prefs.remove(kXunleiAccount);

  String? get activeProfileId => _prefs.getString(kActiveProfile);
  Future<void> setActiveProfileId(String? id) async {
    if (id == null || id.isEmpty) {
      await _prefs.remove(kActiveProfile);
    } else {
      await _prefs.setString(kActiveProfile, id);
    }
  }

  String? get activeSiteKey => _prefs.getString(kActiveSite);
  Future<void> setActiveSiteKey(String? key) async {
    if (key == null || key.isEmpty) {
      await _prefs.remove(kActiveSite);
    } else {
      await _prefs.setString(kActiveSite, key);
    }
  }

  /// 本地导入的直播线路（独立于订阅，切档案/刷新订阅都不丢）。
  List<LiveBean> loadLocalLives() {
    final raw = _prefs.getString(kLocalLives);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => LiveBean.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveLocalLives(List<LiveBean> lives) => _prefs.setString(
    kLocalLives,
    jsonEncode(lives.map((e) => e.toJson()).toList()),
  );

  /// 弹幕显示偏好（JSON 字符串；由 DanmakuSettings 负责宽容解析）。
  String get danmakuSettingsJson => _prefs.getString(kDanmakuSettings) ?? '';
  Future<void> saveDanmakuSettingsJson(String json) =>
      _prefs.setString(kDanmakuSettings, json);

  /// 内容过滤（JSON 字符串；由 ContentFilterSettings 负责宽容解析）。
  String get contentFilterJson => _prefs.getString(kContentFilter) ?? '';
  Future<void> saveContentFilterJson(String json) =>
      _prefs.setString(kContentFilter, json);

  /// 在线影视台词缓存（JSON：`fetchedAt` + 台词数组）。
  String get movieQuotesCacheJson => _prefs.getString(kMovieQuotes) ?? '';
  Future<void> saveMovieQuotesCacheJson(String json) =>
      _prefs.setString(kMovieQuotes, json);

  /// assrt.net 字幕接口 token（可空；空时只用免 token 的 SubtitleCat）。
  String get assrtToken =>
      CredentialVault.unprotect(_prefs.getString(kAssrtToken) ?? '') ?? '';
  Future<void> setAssrtToken(String token) => _prefs.setString(
    kAssrtToken,
    CredentialVault.protect(token.trim()),
  );

  /// 用户自定义字幕 API 配置（每行 名称@URL模板）。
  String get customSubtitleApis => _prefs.getString(kCustomSubtitleApis) ?? '';
  Future<void> setCustomSubtitleApis(String text) =>
      _prefs.setString(kCustomSubtitleApis, text.trim());

  /// 自定义直播 UA（JSON 字符串；由 LiveUaPolicy 负责宽容解析）。
  String get liveUaPolicyJson => _prefs.getString(kLiveUaPolicy) ?? '';
  Future<void> saveLiveUaPolicyJson(String json) =>
      _prefs.setString(kLiveUaPolicy, json);

  /// 当前直播订阅（独立于点播档案）。
  String? get activeLiveProfileId => _prefs.getString(kActiveLiveProfile);
  Future<void> setActiveLiveProfileId(String? id) async {
    if (id == null || id.isEmpty) {
      await _prefs.remove(kActiveLiveProfile);
    } else {
      await _prefs.setString(kActiveLiveProfile, id);
    }
  }

  String? get activeLiveKey => _prefs.getString(kActiveLive);
  Future<void> setActiveLiveKey(String? key) async {
    if (key == null || key.isEmpty) {
      await _prefs.remove(kActiveLive);
    } else {
      await _prefs.setString(kActiveLive, key);
    }
  }

  /// 首次启动的用户协议是否已同意。
  bool get eulaAccepted => _prefs.getBool(kEulaAccepted) ?? false;
  Future<void> setEulaAccepted(bool value) =>
      _prefs.setBool(kEulaAccepted, value);

  String get themeMode => _prefs.getString(kThemeMode) ?? 'system';
  Future<void> setThemeMode(String mode) => _prefs.setString(kThemeMode, mode);

  int get accentIndex => _prefs.getInt(kAccentIndex) ?? 0;
  Future<void> setAccentIndex(int index) => _prefs.setInt(kAccentIndex, index);

  /// 底部导航栏尺寸：0 紧凑 / 1 标准 / 2 较大 / 3 超大。
  int get navBarSize => _prefs.getInt(kNavBarSize) ?? 1;
  Future<void> setNavBarSize(int value) => _prefs.setInt(kNavBarSize, value);

  /// 底部导航栏是否自动隐藏（只在鼠标靠近窗口底部时滑出）。
  bool get navBarAutoHide => _prefs.getBool(kNavBarAutoHide) ?? false;
  Future<void> setNavBarAutoHide(bool value) =>
      _prefs.setBool(kNavBarAutoHide, value);

  /// 首页每行封面数：0 = 自动（按窗口宽度），4-8 = 固定列数。
  int get homeColumns => _prefs.getInt(kHomeColumns) ?? 0;
  Future<void> setHomeColumns(int value) => _prefs.setInt(kHomeColumns, value);

  /// 首页分类浏览方式：0 = 换页（上一页 / 下一页），1 = 瀑布（滑到底自动加载）。
  int get homeBrowseMode => _prefs.getInt(kHomeBrowseMode) ?? 0;
  Future<void> setHomeBrowseMode(int value) =>
      _prefs.setInt(kHomeBrowseMode, value);

  /// 首页顶部是否显示影视台词轮换。
  bool get showMovieQuotes => _prefs.getBool(kShowMovieQuotes) ?? true;
  Future<void> setShowMovieQuotes(bool value) =>
      _prefs.setBool(kShowMovieQuotes, value);

  /// 清掉旧版本遗留的耗时档案（该功能已移除，避免留一份死数据）。
  Future<void> dropLegacySourceSpeed() async {
    if (_prefs.containsKey(kSourceSpeed)) {
      await _prefs.remove(kSourceSpeed);
    }
  }

  /// 源健康度 JSON（`SourceCircuitBreaker.exportJsonString` 的产物）。
  String get sourceHealthJson => _prefs.getString(kSourceHealth) ?? '';
  Future<void> setSourceHealthJson(String json) async {
    if (json.trim().isEmpty) {
      await _prefs.remove(kSourceHealth);
    } else {
      await _prefs.setString(kSourceHealth, json);
    }
  }

  /// 内置代理配置（JSON：enabled/type/host/port/username/password）。
  String get proxyJson =>
      CredentialVault.unprotect(_prefs.getString(kProxy) ?? '') ?? '';
  Future<void> setProxyJson(String json) async {
    if (json.trim().isEmpty) {
      await _prefs.remove(kProxy);
    } else {
      await _prefs.setString(kProxy, CredentialVault.protect(json));
    }
  }

  /// 记忆的启动窗口大小（`宽x高`，逻辑像素）；null = 未记忆。
  Size? loadWindowSize() {
    final raw = _prefs.getString(kWindowSize);
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.toLowerCase().split('x');
    if (parts.length != 2) return null;
    final width = double.tryParse(parts[0].trim());
    final height = double.tryParse(parts[1].trim());
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return Size(width, height);
  }

  Future<void> saveWindowSize(Size? size) async {
    if (size == null) {
      await _prefs.remove(kWindowSize);
      return;
    }
    await _prefs.setString(
      kWindowSize,
      '${size.width.round()}x${size.height.round()}',
    );
  }

  List<FavoriteItem> loadFavorites() {
    final raw = _prefs.getString(kFavorites);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => FavoriteItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveFavorites(List<FavoriteItem> items) => _prefs.setString(
    kFavorites,
    jsonEncode(items.map((e) => e.toJson()).toList()),
  );

  List<HistoryItem> loadHistory() {
    final raw = _prefs.getString(kHistory);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => HistoryItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHistory(List<HistoryItem> items) => _prefs.setString(
    kHistory,
    jsonEncode(items.map((e) => e.toJson()).toList()),
  );

  /// 历史墓碑：`{ deleted: {key: version}, clear: version? }`。
  ///
  /// 读取失败一律回落到空墓碑，不能让一份坏数据挡住历史加载。
  HistoryTombstones loadHistoryTombstones() {
    final raw = _prefs.getString(kHistoryTombstones);
    if (raw == null || raw.isEmpty) return HistoryTombstones.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return HistoryTombstones.empty;
      final deleted = <String, String>{};
      final rawDeleted = decoded['deleted'];
      if (rawDeleted is Map) {
        for (final entry in rawDeleted.entries) {
          final key = entry.key.toString();
          final value = entry.value?.toString() ?? '';
          if (key.isEmpty || value.isEmpty) continue;
          deleted[key] = value;
        }
      }
      final clear = (decoded['clear'] ?? '').toString().trim();
      return HistoryTombstones(
        deletedVersions: deleted,
        clearVersion: clear.isEmpty ? null : clear,
      );
    } catch (_) {
      return HistoryTombstones.empty;
    }
  }

  Future<void> saveHistoryTombstones(HistoryTombstones tombstones) async {
    if (tombstones.isEmpty) {
      await _prefs.remove(kHistoryTombstones);
      return;
    }
    await _prefs.setString(
      kHistoryTombstones,
      jsonEncode({
        'deleted': tombstones.deletedVersions,
        if (tombstones.clearVersion != null) 'clear': tombstones.clearVersion,
      }),
    );
  }

  List<String> loadSearchHistory() {
    final raw = _prefs.getString(kSearchHistory);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded.map((e) => e.toString()).toList() : [];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSearchHistory(List<String> items) =>
      _prefs.setString(kSearchHistory, jsonEncode(items));

  PlayerSettings loadPlayerSettings() {
    final raw = _prefs.getString(kPlayerSettings);
    if (raw == null || raw.isEmpty) return const PlayerSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return PlayerSettings.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return const PlayerSettings();
  }

  Future<void> savePlayerSettings(PlayerSettings settings) =>
      _prefs.setString(kPlayerSettings, jsonEncode(settings.toJson()));

  List<VideoDownloadRecord> loadVideoDownloadRecords() {
    final raw = _prefs.getString(kVideoDownloads) ?? '';
    if (raw.isEmpty) return [];
    final plain = CredentialVault.unprotect(raw);
    if (plain == null || plain.isEmpty) return [];
    try {
      final decoded = jsonDecode(plain);
      if (decoded is! List) return [];
      final records = <VideoDownloadRecord>[];
      for (final item in decoded.whereType<Map>()) {
        final record = VideoDownloadRecord.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (record != null) records.add(record);
      }
      records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return records;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveVideoDownloadRecords(List<VideoDownloadRecord> records) =>
      _prefs.setString(
        kVideoDownloads,
        CredentialVault.protect(
          jsonEncode(records.map((e) => e.toJson()).toList()),
        ),
      );

  Map<String, SkipRecord> loadSkipSegments() {
    final raw = _prefs.getString(kSkipSegments);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, SkipRecord>{};
      for (final entry in decoded.entries) {
        final key = entry.key.toString();
        if (key.isEmpty) continue;
        final record = normalizeSkipRecord(entry.value);
        if (record != null) out[key] = record;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveSkipSegments(Map<String, SkipRecord> records) =>
      _prefs.setString(
        kSkipSegments,
        jsonEncode(records.map((key, value) => MapEntry(key, value.toJson()))),
      );

  /// WebDAV 服务器（只读直连；密码经 CredentialVault 加密后落盘）。
  List<DavServer> loadDavServers() {
    final raw = _prefs.getString(kDavServers);
    if (raw == null || raw.isEmpty) return [];
    final plain = CredentialVault.unprotect(raw);
    if (plain == null || plain.isEmpty) return [];
    try {
      final decoded = jsonDecode(plain);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => DavServer.fromJson(Map<String, dynamic>.from(e)))
          .where((s) => s.id.isNotEmpty && s.url.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveDavServers(List<DavServer> servers) => _prefs.setString(
    kDavServers,
    CredentialVault.protect(
      jsonEncode(servers.map((e) => e.toJson()).toList()),
    ),
  );

  /// 多端同步设置（配对码不敏感，明文落盘即可）。
  SyncSettings loadSyncSettings() {
    final raw = _prefs.getString(kSyncSettings);
    if (raw == null || raw.isEmpty) return const SyncSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const SyncSettings();
      return SyncSettings.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return const SyncSettings();
    }
  }

  Future<void> saveSyncSettings(SyncSettings settings) =>
      _prefs.setString(kSyncSettings, jsonEncode(settings.toJson()));

  List<MediaServer> loadMediaServers() {
    final raw = _prefs.getString(kMediaServers);
    if (raw == null || raw.isEmpty) return [];
    final plain = CredentialVault.unprotect(raw);
    if (plain == null || plain.isEmpty) return [];
    try {
      final decoded = jsonDecode(plain);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => MediaServer.fromJson(Map<String, dynamic>.from(e)))
          .where((s) => s.id.isNotEmpty && s.baseUrl.trim().isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMediaServers(List<MediaServer> servers) =>
      _prefs.setString(
        kMediaServers,
        CredentialVault.protect(
          jsonEncode(servers.map((e) => e.toJson()).toList()),
        ),
      );

  List<String> loadLocalMediaDirs() {
    final raw = _prefs.getString(kLocalMediaDirs);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveLocalMediaDirs(List<String> dirs) =>
      _prefs.setString(kLocalMediaDirs, jsonEncode(dirs));
}

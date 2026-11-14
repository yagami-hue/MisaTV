// 多端同步的数据包：把「历史 / 收藏 / 片头片尾」打包成一份可传输的 JSON。
//
// 历史沿用 [HistorySyncSnapshot] 的版本 + 墓碑模型（删除与清空不会被旧数据
// 复活）；收藏与片头片尾采用 last-write-wins：按各自的更新时间取新的一方。
// 合并函数是纯函数，便于单测，也让 WebDAV 与局域网两条通道共用同一套规则。
import '../../models/user_data.dart';
import '../player/skip_segments.dart';
import 'history_sync.dart';

/// 一份跨设备同步包。
class SyncBundle {
  const SyncBundle({
    this.exportedAt = 0,
    this.deviceName = '',
    this.history = const HistorySyncSnapshot(),
    this.favorites = const [],
    this.skips = const {},
  });

  /// 包结构版本；将来字段不兼容时用它拒绝/迁移。
  static const int schemaVersion = 1;

  /// 生成时间（毫秒时间戳）。
  final int exportedAt;

  /// 生成端的设备名（展示用）。
  final String deviceName;

  final HistorySyncSnapshot history;
  final List<FavoriteItem> favorites;

  /// 键为 `资源|集`（见 [skipStoreKey]）。
  final Map<String, SkipRecord> skips;

  bool get isEmpty =>
      history.isEmpty && favorites.isEmpty && skips.isEmpty;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'exportedAt': exportedAt,
    'deviceName': deviceName,
    'history': history.toJson(),
    'favorites': favorites.map((e) => e.toJson()).toList(),
    'skips': {
      for (final entry in skips.entries) entry.key: entry.value.toJson(),
    },
  };

  factory SyncBundle.fromJson(Map<String, dynamic> json) {
    final rawHistory = json['history'];
    final favorites = <FavoriteItem>[];
    final rawFavorites = json['favorites'];
    if (rawFavorites is List) {
      for (final entry in rawFavorites) {
        if (entry is! Map) continue;
        final item = FavoriteItem.fromJson(Map<String, dynamic>.from(entry));
        if (item.key.isEmpty) continue;
        favorites.add(item);
      }
    }
    final skips = <String, SkipRecord>{};
    final rawSkips = json['skips'];
    if (rawSkips is Map) {
      for (final entry in rawSkips.entries) {
        final key = entry.key.toString();
        if (key.isEmpty) continue;
        final record = normalizeSkipRecord(entry.value);
        if (record != null) skips[key] = record;
      }
    }
    return SyncBundle(
      exportedAt: (json['exportedAt'] as num?)?.toInt() ?? 0,
      deviceName: (json['deviceName'] ?? '').toString(),
      history: rawHistory is Map
          ? HistorySyncSnapshot.fromJson(
              Map<String, dynamic>.from(rawHistory),
            )
          : const HistorySyncSnapshot(),
      favorites: favorites,
      skips: skips,
    );
  }
}

/// 一次合并的结果（用于上屏与日志）。
class SyncMergeReport {
  const SyncMergeReport({
    this.historyAccepted = 0,
    this.favoritesChanged = 0,
    this.skipsChanged = 0,
    this.remoteDevice = '',
    this.pushed = false,
  });

  final int historyAccepted;
  final int favoritesChanged;
  final int skipsChanged;
  final String remoteDevice;

  /// 是否已经把合并后的数据写回远端（WebDAV）。
  final bool pushed;

  bool get hasChanges =>
      historyAccepted > 0 || favoritesChanged > 0 || skipsChanged > 0;

  SyncMergeReport copyWith({String? remoteDevice, bool? pushed}) =>
      SyncMergeReport(
        historyAccepted: historyAccepted,
        favoritesChanged: favoritesChanged,
        skipsChanged: skipsChanged,
        remoteDevice: remoteDevice ?? this.remoteDevice,
        pushed: pushed ?? this.pushed,
      );

  String get summary {
    if (!hasChanges) return '本机数据已是最新，无需合并';
    final parts = <String>[];
    if (historyAccepted > 0) parts.add('历史 $historyAccepted 条');
    if (favoritesChanged > 0) parts.add('收藏 $favoritesChanged 条');
    if (skipsChanged > 0) parts.add('片头片尾 $skipsChanged 条');
    return '已合并 ${parts.join('、')}';
  }
}

/// 收藏合并：同 key 按 `updatedAt` 取新；没有更新的一方保留本地。
({List<FavoriteItem> items, int changed}) mergeSyncFavorites(
  Iterable<FavoriteItem> local,
  Iterable<FavoriteItem> incoming,
) {
  final map = <String, FavoriteItem>{};
  for (final item in local) {
    if (item.key.isEmpty) continue;
    map[item.key] = item;
  }
  var changed = 0;
  for (final item in incoming) {
    if (item.key.isEmpty) continue;
    final current = map[item.key];
    if (current == null || item.updatedAt > current.updatedAt) {
      map[item.key] = item;
      changed++;
    }
  }
  final items = map.values.toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return (items: items, changed: changed);
}

/// 片头片尾合并：同键按写入时间 `at` 取新。
({Map<String, SkipRecord> items, int changed}) mergeSyncSkips(
  Map<String, SkipRecord> local,
  Map<String, SkipRecord> incoming,
) {
  final out = Map<String, SkipRecord>.from(local);
  var changed = 0;
  for (final entry in incoming.entries) {
    final key = entry.key.trim();
    if (key.isEmpty) continue;
    final current = out[key];
    if (current == null || entry.value.at > current.at) {
      out[key] = entry.value;
      changed++;
    }
  }
  return (items: out, changed: changed);
}

/// 把快照还原成合并事件（历史合并统一走 [mergeHistory]）。
///
/// 快照里的版本号形如 `<毫秒>|<eventId>`；取 `|` 后面的部分作为 eventId，
/// 这样重建出的版本号与来源设备完全一致，LWW 比较才有意义。
List<HistorySyncEvent> historyEventsOf(HistorySyncSnapshot snapshot) {
  final events = <HistorySyncEvent>[];
  final clear = snapshot.clearVersion;
  if (clear != null && clear.isNotEmpty) {
    events.add(
      HistorySyncEvent(
        op: HistorySyncOp.clearAll,
        eventId: _eventIdOf(clear),
        updatedAt: HistorySyncVersion.updatedAtOf(clear),
      ),
    );
  }
  for (final entry in snapshot.deletedVersions.entries) {
    if (entry.key.isEmpty || entry.value.isEmpty) continue;
    events.add(
      HistorySyncEvent(
        op: HistorySyncOp.delete,
        eventId: _eventIdOf(entry.value),
        updatedAt: HistorySyncVersion.updatedAtOf(entry.value),
        key: entry.key,
      ),
    );
  }
  for (final item in snapshot.items) {
    if (item.key.isEmpty) continue;
    final version = snapshot.itemVersions[item.key];
    final eventId = version == null || version.isEmpty
        ? 'remote:${item.key}:${item.updatedAt}'
        : _eventIdOf(version);
    final updatedAt = version == null || version.isEmpty
        ? item.updatedAt
        : HistorySyncVersion.updatedAtOf(version);
    events.add(
      HistorySyncEvent(
        op: HistorySyncOp.upsert,
        eventId: eventId,
        updatedAt: updatedAt,
        key: item.key,
        item: item,
      ),
    );
  }
  return events;
}

String _eventIdOf(String version) {
  final sep = version.indexOf('|');
  final tail = sep < 0 ? '' : version.substring(sep + 1).trim();
  return tail.isEmpty ? 'remote:$version' : tail;
}

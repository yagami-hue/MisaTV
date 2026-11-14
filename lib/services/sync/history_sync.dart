// 观看历史的 LWW（last-write-wins）同步内核（纯 Dart，可注入时钟，便于单测）。
//
// 背景：多窗口（独立播放器窗口）与未来的局域网多端同步都会把两份历史合并到一起。
// 如果只做「整份覆盖」或「按 updatedAt 取大」，会出现两个真实问题：
//
//   1. 删掉的条目会复活。A 端删除后，B 端一份较旧的快照再导入，条目又回来了；
//   2. 清空历史挡不住旧数据。清空之后再导入旧快照，历史又满了。
//
// 这里用与 Kazumi 同构的做法：把每次改动表达成**带版本号的事件**，
// 删除与清空留下**墓碑（tombstone）**。墓碑只记版本号、不占正文，
// 合并时一律「版本号大的赢」，旧数据就再也顶不掉新决定。
//
// 版本号形如 `<16 位零填充毫秒>|<eventId>`：字符串字典序 == 时间先后序，
// 同时相同时用 eventId 破平，保证各端排序结果一致（无需解析数字）。
import '../../models/user_data.dart';

/// 历史同步事件类型。
enum HistorySyncOp {
  /// 新增或更新一条历史（播放进度、当前集等）。
  upsert('upsert'),

  /// 删除单条历史，留下墓碑。
  delete('delete'),

  /// 清空全部历史，留下全局墓碑。
  clearAll('clearAll');

  const HistorySyncOp(this.value);

  final String value;

  static HistorySyncOp fromValue(String value) {
    for (final op in HistorySyncOp.values) {
      if (op.value == value) return op;
    }
    throw FormatException('未知的历史同步操作：$value');
  }
}

/// 版本号工具：`updatedAt` + `eventId` 拼成可字典序比较的字符串。
class HistorySyncVersion {
  HistorySyncVersion._();

  static String of({required int updatedAt, required String eventId}) =>
      '${updatedAt.toString().padLeft(16, '0')}|$eventId';

  /// 字典序比较（版本号本身就是为了可比较而设计的）。
  static int compare(String a, String b) => a.compareTo(b);

  /// 取版本号里的时间戳（毫秒）；解析失败返回 0。
  static int updatedAtOf(String version) {
    final sep = version.indexOf('|');
    final head = sep < 0 ? version : version.substring(0, sep);
    return int.tryParse(head.trim()) ?? 0;
  }
}

/// 一条历史同步事件。
class HistorySyncEvent {
  const HistorySyncEvent({
    required this.op,
    required this.eventId,
    required this.updatedAt,
    this.key = '',
    this.item,
  });

  final HistorySyncOp op;

  /// 事件唯一标识（`<deviceId>:<seq>`），用于同为毫秒级的并列判定。
  final String eventId;

  final int updatedAt;

  /// 目标条目键（`sourceKey|vodId`）；[HistorySyncOp.clearAll] 时为空。
  final String key;

  /// [HistorySyncOp.upsert] 的正文。
  final HistoryItem? item;

  String get version =>
      HistorySyncVersion.of(updatedAt: updatedAt, eventId: eventId);

  Map<String, dynamic> toJson() => {
    'op': op.value,
    'eventId': eventId,
    'updatedAt': updatedAt,
    if (key.isNotEmpty) 'key': key,
    if (item != null) 'item': item!.toJson(),
  };

  factory HistorySyncEvent.fromJson(Map<String, dynamic> json) {
    final op = HistorySyncOp.fromValue((json['op'] ?? '').toString());
    final rawItem = json['item'];
    return HistorySyncEvent(
      op: op,
      eventId: (json['eventId'] ?? '').toString(),
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      key: (json['key'] ?? '').toString(),
      item: op == HistorySyncOp.upsert && rawItem is Map
          ? HistoryItem.fromJson(Map<String, dynamic>.from(rawItem))
          : null,
    );
  }

  /// 由一条历史记录生成 upsert 事件。
  factory HistorySyncEvent.fromItem(
    HistoryItem item, {
    required String deviceId,
    required int seq,
  }) => HistorySyncEvent(
    op: HistorySyncOp.upsert,
    eventId: '$deviceId:$seq',
    updatedAt: item.updatedAt,
    key: item.key,
    item: item,
  );

  factory HistorySyncEvent.delete({
    required String key,
    required int updatedAt,
    required String deviceId,
    required int seq,
  }) => HistorySyncEvent(
    op: HistorySyncOp.delete,
    eventId: '$deviceId:$seq',
    updatedAt: updatedAt,
    key: key,
  );

  factory HistorySyncEvent.clear({
    required int updatedAt,
    required String deviceId,
    required int seq,
  }) => HistorySyncEvent(
    op: HistorySyncOp.clearAll,
    eventId: '$deviceId:$seq',
    updatedAt: updatedAt,
  );
}

/// 一份可序列化的同步快照：正文 + 每个条目的版本 + 墓碑 + 清空版本。
class HistoryTombstones {
  const HistoryTombstones({
    this.deletedVersions = const {},
    this.clearVersion,
  });

  static const empty = HistoryTombstones();

  /// key → 删除时的版本。
  final Map<String, String> deletedVersions;

  /// 最近一次「清空历史」的版本。
  final String? clearVersion;

  bool get isEmpty =>
      deletedVersions.isEmpty && (clearVersion?.isEmpty ?? true);

  Map<String, dynamic> toJson() => {
    'deleted': deletedVersions,
    if (clearVersion != null) 'clear': clearVersion,
  };
}

/// 一份可序列化的同步快照：正文 + 每个条目的版本 + 墓碑 + 清空版本。
class HistorySyncSnapshot {
  const HistorySyncSnapshot({
    this.items = const [],
    this.itemVersions = const {},
    this.deletedVersions = const {},
    this.clearVersion,
  });

  final List<HistoryItem> items;

  /// key → 该条目最后一次 upsert 的版本。
  final Map<String, String> itemVersions;

  /// key → 删除时的版本（墓碑）。
  final Map<String, String> deletedVersions;

  /// 最近一次「清空历史」的版本（全局墓碑）。
  final String? clearVersion;

  bool get isEmpty =>
      items.isEmpty &&
      itemVersions.isEmpty &&
      deletedVersions.isEmpty &&
      clearVersion == null;

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'items': items.map((e) => e.toJson()).toList(),
    'itemVersions': itemVersions,
    'deletedVersions': deletedVersions,
    if (clearVersion != null) 'clearVersion': clearVersion,
  };

  factory HistorySyncSnapshot.fromJson(Map<String, dynamic> json) {
    final items = <HistoryItem>[];
    final rawItems = json['items'];
    if (rawItems is List) {
      for (final entry in rawItems) {
        if (entry is! Map) continue;
        final item = HistoryItem.fromJson(Map<String, dynamic>.from(entry));
        if (item.key.isEmpty) continue;
        items.add(item);
      }
    }
    return HistorySyncSnapshot(
      items: items,
      itemVersions: _stringMap(json['itemVersions']),
      deletedVersions: _stringMap(json['deletedVersions']),
      clearVersion: (json['clearVersion'] as String?)?.trim().isEmpty ?? true
          ? null
          : json['clearVersion'] as String,
    );
  }

  static Map<String, String> _stringMap(dynamic raw) => stringMapOf(raw);

  /// 公开的字符串映射归一（供备份还原复用，与快照反序列化同一口径）。
  static Map<String, String> stringMapOf(dynamic raw) {
    if (raw is! Map) return const {};
    final out = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key.toString();
      final value = entry.value?.toString() ?? '';
      if (key.isEmpty || value.isEmpty) continue;
      out[key] = value;
    }
    return out;
  }

  /// 由当前历史列表构造快照（本地改动全部视为 upsert）。
  ///
  /// 时间戳直接取 [HistoryItem.updatedAt]，eventId 用 `local:<key>`：
  /// 同一台机器重复构造快照得到的是同一个版本号，天然幂等。
  factory HistorySyncSnapshot.fromItems(
    Iterable<HistoryItem> items, {
    Map<String, String> deletedVersions = const {},
    String? clearVersion,
  }) {
    final list = <HistoryItem>[];
    final versions = <String, String>{};
    for (final item in items) {
      if (item.key.isEmpty) continue;
      list.add(item);
      versions[item.key] = HistorySyncVersion.of(
        updatedAt: item.updatedAt,
        eventId: 'local:${item.key}',
      );
    }
    return HistorySyncSnapshot(
      items: list,
      itemVersions: versions,
      deletedVersions: deletedVersions,
      clearVersion: clearVersion,
    );
  }
}

/// 合并结果。
class HistoryMergeResult {
  const HistoryMergeResult({
    required this.items,
    required this.deletedVersions,
    required this.clearVersion,
    required this.accepted,
  });

  /// 合并后的历史（按 updatedAt 倒序，与 UI 的排序一致）。
  final List<HistoryItem> items;

  /// 合并后的墓碑表，调用方应持久化。
  final Map<String, String> deletedVersions;

  /// 合并后的清空版本，调用方应持久化。
  final String? clearVersion;

  /// 本次真正被采纳（版本更新）的事件数，便于日志与测试。
  final int accepted;
}

/// 把 [incoming] 事件流合并进现有历史 [current]。
///
/// 规则（与 Kazumi 的 HistorySyncState 同构，但按 MisaTV 的单条目模型精简）：
///   · 每个条目独立 LWW，版本号大的赢；
///   · 删除留下的墓碑版本 ≥ 后续 upsert 版本时，upsert 被丢弃（不复活）；
///   · 清空是一次全局墓碑，版本早于它的所有事件一律丢弃；
///   · 同一毫秒内的并列由 eventId 的字典序破平，保证各端结果一致。
HistoryMergeResult mergeHistory({
  required Iterable<HistoryItem> current,
  required Iterable<HistorySyncEvent> incoming,
  Map<String, String> deletedVersions = const {},
  String? clearVersion,
  int? keepLimit,
}) {
  final items = <String, HistoryItem>{};
  final versions = <String, String>{};
  for (final item in current) {
    if (item.key.isEmpty) continue;
    items[item.key] = item;
    versions[item.key] = HistorySyncVersion.of(
      updatedAt: item.updatedAt,
      eventId: 'local:${item.key}',
    );
  }
  final tombstones = Map<String, String>.from(deletedVersions);
  var clear = clearVersion;

  // 先按版本升序应用，保证「旧后到」与「旧先到」结果一致。
  final ordered = incoming.toList()
    ..sort((a, b) => HistorySyncVersion.compare(a.version, b.version));

  var accepted = 0;
  for (final event in ordered) {
    if (!_isNewerThanClear(event.version, clear)) continue;
    switch (event.op) {
      case HistorySyncOp.clearAll:
        items.clear();
        versions.clear();
        tombstones.clear();
        clear = event.version;
        accepted++;
      case HistorySyncOp.delete:
        final key = event.key.trim();
        if (key.isEmpty) continue;
        final itemVersion = versions[key];
        final tombVersion = tombstones[key];
        // 删除必须比现有正文和旧墓碑都新，才生效。
        if (itemVersion != null &&
            HistorySyncVersion.compare(event.version, itemVersion) <= 0) {
          continue;
        }
        if (tombVersion != null &&
            HistorySyncVersion.compare(event.version, tombVersion) <= 0) {
          continue;
        }
        items.remove(key);
        versions.remove(key);
        tombstones[key] = event.version;
        accepted++;
      case HistorySyncOp.upsert:
        final item = event.item;
        if (item == null || item.key.isEmpty) continue;
        final key = item.key;
        final tombVersion = tombstones[key];
        // 墓碑更新：说明这次 upsert 是「删除之前」的旧状态，丢弃。
        if (tombVersion != null &&
            HistorySyncVersion.compare(event.version, tombVersion) <= 0) {
          continue;
        }
        final existingVersion = versions[key];
        if (existingVersion != null &&
            HistorySyncVersion.compare(event.version, existingVersion) <= 0) {
          continue;
        }
        items[key] = item;
        versions[key] = event.version;
        tombstones.remove(key);
        accepted++;
    }
  }

  final merged = items.values.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  final limited = keepLimit != null && merged.length > keepLimit
      ? merged.take(keepLimit).toList()
      : merged;
  return HistoryMergeResult(
    items: limited,
    deletedVersions: tombstones,
    clearVersion: clear,
    accepted: accepted,
  );
}

bool _isNewerThanClear(String version, String? clearVersion) {
  if (clearVersion == null) return true;
  return HistorySyncVersion.compare(version, clearVersion) > 0;
}

/// 历史事件的增量打包器（供局域网同步 / 备份导出使用）。
///
/// 只保留每个条目、每个墓碑与全局清空的最后一条，内存有界；
/// 物化时统一排序，因此乱序到达也能得到相同结果。
class HistorySyncStreamMerger {
  final Map<String, HistorySyncEvent> _upserts = {};
  final Map<String, HistorySyncEvent> _deletes = {};
  HistorySyncEvent? _clear;

  void add(HistorySyncEvent event) {
    switch (event.op) {
      case HistorySyncOp.upsert:
        final key = event.item?.key ?? event.key;
        if (key.isEmpty) return;
        _keepLatest(_upserts, key, event);
      case HistorySyncOp.delete:
        if (event.key.isEmpty) return;
        _keepLatest(_deletes, event.key, event);
      case HistorySyncOp.clearAll:
        final current = _clear;
        if (current == null ||
            HistorySyncVersion.compare(event.version, current.version) > 0) {
          _clear = event;
        }
    }
  }

  void addAll(Iterable<HistorySyncEvent> events) => events.forEach(add);

  /// 物化成一个有序事件列表。
  List<HistorySyncEvent> toEvents() {
    final clear = _clear;
    final all = <HistorySyncEvent>[
      ?clear,
      ..._deletes.values,
      ..._upserts.values,
    ]..sort((a, b) => HistorySyncVersion.compare(a.version, b.version));
    return all;
  }

  bool get isEmpty =>
      _upserts.isEmpty && _deletes.isEmpty && _clear == null;

  void _keepLatest(
    Map<String, HistorySyncEvent> bucket,
    String key,
    HistorySyncEvent candidate,
  ) {
    final current = bucket[key];
    if (current == null ||
        HistorySyncVersion.compare(candidate.version, current.version) > 0) {
      bucket[key] = candidate;
    }
  }
}

import 'package:xml/xml.dart';

import '../../models/live.dart';

/// 单档节目（时间已换算成 epoch 毫秒，`start` / `end` 是便于展示的 `HH:mm`）。
class EpgProgram {
  const EpgProgram({
    required this.title,
    required this.start,
    required this.end,
    required this.startTime,
    required this.endTime,
  });

  final String title;
  final String start;
  final String end;
  final int startTime;
  final int endTime;

  String get range => '$start-$end';

  Map<String, dynamic> toJson() => {
    'title': title,
    'start': start,
    'end': end,
    'startTime': startTime,
    'endTime': endTime,
  };

  factory EpgProgram.fromJson(Map<String, dynamic> json) => EpgProgram(
    title: (json['title'] ?? '').toString(),
    start: (json['start'] ?? '').toString(),
    end: (json['end'] ?? '').toString(),
    startTime: (json['startTime'] as num?)?.toInt() ?? 0,
    endTime: (json['endTime'] as num?)?.toInt() ?? 0,
  );
}

class EpgEntry {
  const EpgEntry({this.current, this.next});

  final EpgProgram? current;
  final EpgProgram? next;

  bool get hasData => current != null || next != null;

  Map<String, dynamic> toJson() => {
    if (current != null) 'current': current!.toJson(),
    if (next != null) 'next': next!.toJson(),
  };

  factory EpgEntry.fromJson(Map<String, dynamic> json) => EpgEntry(
    current: json['current'] is Map
        ? EpgProgram.fromJson(Map<String, dynamic>.from(json['current'] as Map))
        : null,
    next: json['next'] is Map
        ? EpgProgram.fromJson(Map<String, dynamic>.from(json['next'] as Map))
        : null,
  );
}

class EpgChannelRef {
  const EpgChannelRef({
    this.tvgId = '',
    this.tvgName = '',
    required this.name,
    this.epg = '',
  });

  final String tvgId;
  final String tvgName;
  final String name;
  final String epg;
}

EpgChannelRef epgRefOf(LiveChannel channel) => EpgChannelRef(
      tvgId: channel.tvgId,
      tvgName: channel.tvgName,
      name: channel.name,
      epg: channel.epg,
    );

class XmltvChannel {
  const XmltvChannel({required this.id, required this.names, this.icon = ''});

  final String id;
  final List<String> names;
  final String icon;
}

class XmltvProgramme {
  const XmltvProgramme({
    required this.channel,
    required this.start,
    required this.stop,
    required this.title,
  });

  final String channel;
  final String start;
  final String stop;
  final String title;
}

class ParsedXmltv {
  const ParsedXmltv({required this.channels, required this.programmes});

  final List<XmltvChannel> channels;
  final List<XmltvProgramme> programmes;

  static const empty = ParsedXmltv(channels: [], programmes: []);
}

/// `+0800` / `+08:00` / `Z` / `+08` → 分钟偏移；不匹配返回 null。
int? parseTzOffset(String offset) {
  final s = offset.trim();
  if (s == 'Z' || s == 'z') return 0;
  final full = RegExp(r'^([+-])(\d{2}):?(\d{2})$').firstMatch(s);
  if (full != null) {
    final sign = full.group(1) == '-' ? -1 : 1;
    return sign * (int.parse(full.group(2)!) * 60 + int.parse(full.group(3)!));
  }
  final hour = RegExp(r'^([+-])(\d{2})$').firstMatch(s);
  if (hour != null) {
    final sign = hour.group(1) == '-' ? -1 : 1;
    return sign * int.parse(hour.group(2)!) * 60;
  }
  return null;
}

/// 常见 IANA 时区 → 固定分钟偏移；未知返回 null（按本机时区解释）。
int? zoneOffsetMinutes(String timeZone) {
  final t = timeZone.trim();
  if (t.isEmpty) return null;
  switch (t) {
    case 'UTC':
    case 'GMT':
    case 'Etc/UTC':
      return 0;
    case 'Asia/Shanghai':
    case 'Asia/Chongqing':
    case 'Asia/Harbin':
    case 'Asia/Hong_Kong':
    case 'Asia/Macau':
    case 'Asia/Taipei':
    case 'Asia/Singapore':
    case 'PRC':
      return 480;
    case 'Asia/Tokyo':
    case 'Asia/Seoul':
      return 540;
    case 'Asia/Kolkata':
      return 330;
    case 'Europe/London':
      return 0;
    case 'Europe/Paris':
      return 60;
    case 'America/New_York':
      return -300;
    case 'America/Los_Angeles':
      return -480;
  }
  final numeric = parseTzOffset(t);
  return numeric;
}

String _clockOf(int epoch) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epoch);
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

/// XMLTV 时间串 → epoch 毫秒（对齐 FongMi `EpgParser.parseFull`）。
int? parseXmltvEpoch(String source, {String timeZone = ''}) {
  final s = source.trim();
  if (s.length < 14) return null;
  final digits = s.substring(0, 14);
  if (!RegExp(r'^\d{14}$').hasMatch(digits)) return null;
  final y = int.parse(digits.substring(0, 4));
  final mo = int.parse(digits.substring(4, 6));
  final d = int.parse(digits.substring(6, 8));
  final h = int.parse(digits.substring(8, 10));
  final mi = int.parse(digits.substring(10, 12));
  final sec = int.parse(digits.substring(12, 14));
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || sec > 59) return null;
  final rest = s.substring(14).trim();
  if (rest.isNotEmpty) {
    final offset = parseTzOffset(rest);
    if (offset == null) return null;
    return DateTime.utc(y, mo, d, h, mi, sec).millisecondsSinceEpoch - offset * 60000;
  }
  final zone = zoneOffsetMinutes(timeZone);
  if (zone != null) {
    return DateTime.utc(y, mo, d, h, mi, sec).millisecondsSinceEpoch - zone * 60000;
  }
  return DateTime(y, mo, d, h, mi, sec).millisecondsSinceEpoch;
}

/// 解析单份 XMLTV（容错：结构不符 / 非法 XML → 空结果，不抛）。
ParsedXmltv parseXmltv(String xml) {
  final text = xml.trim();
  if (text.isEmpty) return ParsedXmltv.empty;
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } catch (_) {
    return ParsedXmltv.empty;
  }
  final tvNodes = doc.findAllElements('tv');
  if (tvNodes.isEmpty) return ParsedXmltv.empty;
  final tv = tvNodes.first;

  final channels = <XmltvChannel>[];
  for (final node in tv.findElements('channel')) {
    final id = (node.getAttribute('id') ?? '').trim();
    final names = <String>[];
    for (final nameNode in node.findElements('display-name')) {
      final name = nameNode.innerText.trim();
      if (name.isNotEmpty && !names.contains(name)) names.add(name);
    }
    final icons = node.findElements('icon');
    final icon = icons.isEmpty ? '' : (icons.first.getAttribute('src') ?? '').trim();
    channels.add(XmltvChannel(id: id, names: names, icon: icon));
  }

  final programmes = <XmltvProgramme>[];
  for (final node in tv.findElements('programme')) {
    final titles = node.findElements('title');
    final title = titles.isEmpty ? '' : titles.first.innerText.trim();
    programmes.add(XmltvProgramme(
      channel: (node.getAttribute('channel') ?? '').trim(),
      start: (node.getAttribute('start') ?? '').trim(),
      stop: (node.getAttribute('stop') ?? '').trim(),
      title: title,
    ));
  }
  return ParsedXmltv(channels: channels, programmes: programmes);
}

/// 把多份 XMLTV 匹配到直播频道：`键 → 节目表（按开始时间升序）`。
///
/// 每个频道同时挂在 `tvg-id` / `tvg-name` / 频道名三个键下，查询时任一命中即可。
Map<String, List<EpgProgram>> buildEpgMap(
  List<ParsedXmltv> docs,
  List<EpgChannelRef> refs, {
  String timeZone = '',
  int? fromMs,
  int? toMs,
}) {
  final out = <String, List<EpgProgram>>{};
  if (docs.isEmpty || refs.isEmpty) return out;

  final keyToIdx = <String, int>{};
  for (var i = 0; i < refs.length; i++) {
    final ref = refs[i];
    for (final key in [ref.tvgId, ref.tvgName, ref.name]) {
      if (key.isNotEmpty) keyToIdx.putIfAbsent(key, () => i);
    }
  }
  if (keyToIdx.isEmpty) return out;

  final xmlChannelById = <String, XmltvChannel>{};
  for (final doc in docs) {
    for (final channel in doc.channels) {
      if (channel.id.isNotEmpty) xmlChannelById.putIfAbsent(channel.id, () => channel);
    }
  }

  final lists = List.generate(refs.length, (_) => <EpgProgram>[]);
  final seen = List.generate(refs.length, (_) => <String>{});
  for (final doc in docs) {
    for (final programme in doc.programmes) {
      if (programme.channel.isEmpty) continue;
      var idx = keyToIdx[programme.channel];
      if (idx == null) {
        final xmlChannel = xmlChannelById[programme.channel];
        if (xmlChannel != null) {
          for (final name in xmlChannel.names) {
            final hit = keyToIdx[name];
            if (hit != null) {
              idx = hit;
              break;
            }
          }
        }
      }
      if (idx == null) continue;
      final start = parseXmltvEpoch(programme.start, timeZone: timeZone);
      final stop = parseXmltvEpoch(programme.stop, timeZone: timeZone);
      if (start == null || stop == null || stop <= start) continue;
      if (fromMs != null && stop < fromMs) continue;
      if (toMs != null && start > toMs) continue;
      final dedupe = '$start|$stop|${programme.title}';
      if (!seen[idx].add(dedupe)) continue;
      lists[idx].add(EpgProgram(
        title: programme.title,
        start: _clockOf(start),
        end: _clockOf(stop),
        startTime: start,
        endTime: stop,
      ));
    }
  }

  for (var i = 0; i < refs.length; i++) {
    final list = lists[i];
    if (list.isEmpty) continue;
    list.sort((a, b) => a.startTime.compareTo(b.startTime));
    final ref = refs[i];
    for (final key in [ref.tvgId, ref.tvgName, ref.name]) {
      if (key.isNotEmpty) out[key] = list;
    }
  }
  return out;
}

/// 当前节目 = 落在 `[start, end]` 内的第一条；下一档 = 其后第一条。
EpgEntry pickCurrentNext(List<EpgProgram>? programs, int nowMs) {
  if (programs == null || programs.isEmpty) return const EpgEntry();
  EpgProgram? current;
  EpgProgram? next;
  for (final p in programs) {
    if (current == null && p.startTime <= nowMs && nowMs <= p.endTime) current = p;
    if (next == null && p.startTime > nowMs) next = p;
  }
  return EpgEntry(current: current, next: next);
}

/// 按 `tvg-id → tvg-name → 频道名` 的顺序取节目表。
List<EpgProgram>? lookupEpg(Map<String, List<EpgProgram>> byKey, EpgChannelRef ref) {
  for (final key in [ref.tvgId, ref.tvgName, ref.name]) {
    if (key.isEmpty) continue;
    final hit = byKey[key];
    if (hit != null) return hit;
  }
  return null;
}

/// 频道 → 当前 / 下一档（UI 直接按 ref 查询）。
Map<String, EpgEntry> buildEpgEntries(
  Map<String, List<EpgProgram>> byPrograms,
  int nowMs,
) {
  final out = <String, EpgEntry>{};
  for (final entry in byPrograms.entries) {
    out[entry.key] = pickCurrentNext(entry.value, nowMs);
  }
  return out;
}

/// 按任一键查当前 / 下一档。
EpgEntry? entryOf(Map<String, EpgEntry> entries, EpgChannelRef ref) {
  for (final key in [ref.tvgId, ref.tvgName, ref.name]) {
    if (key.isEmpty) continue;
    final hit = entries[key];
    if (hit != null) return hit;
  }
  return null;
}

import '../../models/live.dart';
import 'epg.dart';

/// 可回看的地址与生成方式。
class CatchupResult {
  const CatchupResult({required this.url, required this.kind});

  final String url;

  /// `append` / `shift` / `xc` / `flussonic` / `default`。
  final String kind;
}

/// 根据频道声明与 EPG 节目生成回看地址。
///
/// 支持 M3U 常见的 catchup 约定：
/// - `append`：把 `catchup-source` 作为后缀或完整模板；
/// - `shift`：给直播地址追加 `utc` / `lutc`；
/// - `xc` / `xtream`：拼 Xtream Codes 的 `/timeshift/...` 地址；
/// - `flussonic`：改写为 `timeshift_abs-<开始秒>.m3u8`；
/// - `default` / 未写类型：按 `catchup-source` 模板处理。
///
/// 识别不了或频道没有提供回看能力时返回 null。
CatchupResult? buildCatchupUrl({
  required LiveChannel channel,
  required String liveUrl,
  required EpgProgram program,
  int? nowMs,
}) {
  final live = liveUrl.trim();
  final source = channel.catchupSource.trim();
  final type = channel.catchupType.trim().toLowerCase();
  if (live.isEmpty || program.endTime <= program.startTime) return null;
  if (source.isEmpty && type.isEmpty) return null;

  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  final startSec = program.startTime ~/ 1000;
  final endSec = program.endTime ~/ 1000;
  final nowSec = now ~/ 1000;
  final durationSec = (endSec - startSec).clamp(1, 24 * 3600);
  final start = DateTime.fromMillisecondsSinceEpoch(program.startTime);
  final values = _templateValues(
    start: start,
    startSec: startSec,
    endSec: endSec,
    nowSec: nowSec,
    durationSec: durationSec,
  );

  if (type == 'shift' || type == 'timeshift') {
    final url = _withQuery(live, {
      'utc': '$startSec',
      'lutc': '$nowSec',
    });
    return url == null ? null : CatchupResult(url: url, kind: 'shift');
  }

  if (type == 'xc' || type == 'xtream') {
    final url = _buildXtream(live, start: start, durationSec: durationSec);
    return url == null ? null : CatchupResult(url: url, kind: 'xc');
  }

  if (type == 'flussonic') {
    if (source.isNotEmpty) {
      final expanded = _expand(source, values);
      final url = _isHttp(expanded)
          ? expanded
          : _appendSuffix(live, expanded);
      return CatchupResult(url: url, kind: 'flussonic');
    }
    final url = _flussonicAbsolute(live, startSec);
    return url == null ? null : CatchupResult(url: url, kind: 'flussonic');
  }

  if (source.isEmpty) return null;
  final expanded = _expand(source, values);
  if (_isHttp(expanded)) {
    return CatchupResult(url: expanded, kind: type.isEmpty ? 'default' : type);
  }
  return CatchupResult(
    url: _appendSuffix(live, expanded),
    kind: type.isEmpty ? 'append' : type,
  );
}

Map<String, String> _templateValues({
  required DateTime start,
  required int startSec,
  required int endSec,
  required int nowSec,
  required int durationSec,
}) {
  String two(int value) => value.toString().padLeft(2, '0');
  final y = start.year.toString();
  final m = two(start.month);
  final d = two(start.day);
  final h = two(start.hour);
  final min = two(start.minute);
  final s = two(start.second);
  return {
    'utc': '$startSec',
    'lutc': '$nowSec',
    'start': '$startSec',
    'end': '$endSec',
    'duration': '$durationSec',
    'offset': '${nowSec - startSec}',
    'Y': y,
    'm': m,
    'd': d,
    'H': h,
    'M': min,
    'S': s,
    'Ymd': '$y$m$d',
    'YmdHis': '$y$m$d$h$min$s',
    'Y-m-d': '$y-$m-$d',
    'H-M': '$h-$min',
    'Y-m-d:H-M': '$y-$m-$d:$h-$min',
  };
}

String _expand(String template, Map<String, String> values) {
  return template.replaceAllMapped(
    RegExp(r'\$\{([A-Za-z0-9_:-]+)\}|\{([A-Za-z0-9_:-]+)\}'),
    (match) {
      final key = match.group(1) ?? match.group(2)!;
      return values[key] ?? match.group(0)!;
    },
  );
}

bool _isHttp(String value) =>
    RegExp(r'^https?://', caseSensitive: false).hasMatch(value);

String _appendSuffix(String base, String suffix) {
  final raw = suffix.trim();
  if (raw.isEmpty) return base;
  if (raw.startsWith('&')) return '$base$raw';
  if (raw.startsWith('?')) {
    return base.contains('?')
        ? '$base&${raw.substring(1)}'
        : '$base$raw';
  }
  return '$base${base.contains('?') ? '&' : '?'}$raw';
}

String? _withQuery(String base, Map<String, String> extra) {
  final uri = Uri.tryParse(base);
  if (uri == null) return null;
  return uri.replace(
    queryParameters: {...uri.queryParameters, ...extra},
  ).toString();
}

/// Xtream Codes: `/timeshift/<user>/<pass>/<分钟>/<YYYY-MM-DD:HH-mm>/<streamId>.<ext>`
String? _buildXtream(
  String liveUrl, {
  required DateTime start,
  required int durationSec,
}) {
  final uri = Uri.tryParse(liveUrl);
  if (uri == null) return null;
  final segments = uri.pathSegments;
  final liveIndex = segments.indexWhere((s) => s.toLowerCase() == 'live');
  if (liveIndex < 0 || liveIndex + 3 >= segments.length) return null;
  final user = segments[liveIndex + 1];
  final pass = segments[liveIndex + 2];
  final stream = segments[liveIndex + 3];
  if (user.isEmpty || pass.isEmpty || stream.isEmpty) return null;
  final streamName = stream.contains('.') ? stream : '$stream.ts';
  final minutes = (durationSec / 60).ceil().clamp(1, 24 * 60);
  String two(int value) => value.toString().padLeft(2, '0');
  final stamp =
      '${start.year}-${two(start.month)}-${two(start.day)}:'
      '${two(start.hour)}-${two(start.minute)}';
  final base = '${uri.scheme}://${uri.authority}';
  return '$base/timeshift/${Uri.encodeComponent(user)}/'
      '${Uri.encodeComponent(pass)}/$minutes/$stamp/'
      '${Uri.encodeComponent(streamName)}';
}

/// Flussonic 直播地址：`/stream/index.m3u8` → `/stream/timeshift_abs-<秒>.m3u8`。
String? _flussonicAbsolute(String liveUrl, int startSec) {
  final uri = Uri.tryParse(liveUrl);
  if (uri == null) return null;
  final segments = uri.pathSegments;
  if (segments.isEmpty) return null;
  final last = segments.last.toLowerCase();
  if (!last.endsWith('.m3u8')) return null;
  final stream = last == 'index.m3u8' ||
          last == 'mono.m3u8' ||
          last == 'playlist.m3u8'
      ? null
      : last.substring(0, last.length - '.m3u8'.length);
  final base = [...segments];
  if (stream == null) {
    if (base.length < 2) return null;
    final dir = base[base.length - 2];
    base
      ..removeLast()
      ..removeLast()
      ..add(dir);
  } else {
    base.removeLast();
    base.add(stream);
  }
  base.add('timeshift_abs-$startSec.m3u8');
  return uri.replace(pathSegments: base).toString();
}

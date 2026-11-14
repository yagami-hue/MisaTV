// HLS 清单解析（纯 Dart，便于单测）。
//
// 只解析下载所需的最小信息：码率选择、分片地址、AES-128 密钥、初始化段、
// BYTERANGE。中继已经把清单里的绝对地址改写回 `/play`，这里仍然按标准
// 相对地址解析一次，兼容没有被改写的直连清单。

/// 主清单里的一档码率。
class HlsVariant {
  const HlsVariant({
    required this.url,
    required this.bandwidth,
  });

  final String url;
  final int bandwidth;
}

class HlsByteRange {
  const HlsByteRange({required this.length, required this.offset});

  final int length;
  final int offset;

  String get value => 'bytes=$offset-${offset + length - 1}';
}

class HlsSegment {
  const HlsSegment({
    required this.url,
    required this.sequence,
    this.keyUri,
    this.ivHex,
    this.range,
  });

  final String url;
  final int sequence;

  /// AES-128 密钥地址；null = 本段未加密。
  final String? keyUri;
  final String? ivHex;
  final HlsByteRange? range;
}

class HlsPlaylist {
  const HlsPlaylist({required this.segments, this.initUri});

  final List<HlsSegment> segments;

  /// fMP4 的初始化段（`#EXT-X-MAP`）。
  final String? initUri;

  bool get hasInit => initUri != null && initUri!.isNotEmpty;
}

bool isHlsMasterPlaylist(String text) =>
    text.contains('#EXT-X-STREAM-INF');

/// 选出码率最高的一档；没有主清单信息时返回 null。
String? pickHlsVariant(String text, String base) {
  String? best;
  var bestBandwidth = -1;
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
    final bandwidth =
        int.tryParse(hlsAttribute(line, 'BANDWIDTH') ?? '') ??
        int.tryParse(hlsAttribute(line, 'AVERAGE-BANDWIDTH') ?? '') ??
        0;
    for (var j = i + 1; j < lines.length; j++) {
      final uri = lines[j].trim();
      if (uri.isEmpty || uri.startsWith('#')) continue;
      if (bandwidth > bestBandwidth) {
        bestBandwidth = bandwidth;
        best = resolveHlsUrl(base, uri);
      }
      break;
    }
  }
  return best;
}

/// 解析媒体清单。遇到不支持的加密方式（SAMPLE-AES 等）直接抛错，
/// 让上层给出「该线路暂不支持下载」的明确提示。
HlsPlaylist parseHlsMediaPlaylist(String text, String base) {
  final segments = <HlsSegment>[];
  var sequence = 0;
  String? keyUri;
  String? ivHex;
  String? initUri;
  HlsByteRange? pendingRange;
  var nextRangeOffset = 0;
  for (final raw in text.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
      sequence =
          int.tryParse(line.substring(line.indexOf(':') + 1).trim()) ??
          sequence;
      continue;
    }
    if (line.startsWith('#EXT-X-KEY:')) {
      final method = (hlsAttribute(line, 'METHOD') ?? '').toUpperCase();
      if (method.isEmpty || method == 'NONE') {
        keyUri = null;
        ivHex = null;
      } else if (method == 'AES-128') {
        final uri = hlsAttribute(line, 'URI') ?? '';
        keyUri = uri.isEmpty ? null : resolveHlsUrl(base, uri);
        ivHex = hlsAttribute(line, 'IV');
      } else {
        throw StateError('不支持的 HLS 加密方式：$method');
      }
      continue;
    }
    if (line.startsWith('#EXT-X-MAP:')) {
      final uri = hlsAttribute(line, 'URI') ?? '';
      if (uri.isNotEmpty) initUri = resolveHlsUrl(base, uri);
      continue;
    }
    if (line.startsWith('#EXT-X-BYTERANGE:')) {
      final spec = line.substring(line.indexOf(':') + 1).split('@');
      final length = int.tryParse(spec.first.trim()) ?? 0;
      final offset = spec.length > 1 ? int.tryParse(spec[1].trim()) : null;
      if (length > 0) {
        pendingRange = HlsByteRange(
          length: length,
          offset: offset ?? nextRangeOffset,
        );
      }
      continue;
    }
    if (line.startsWith('#')) continue;
    segments.add(
      HlsSegment(
        url: resolveHlsUrl(base, line),
        sequence: sequence,
        keyUri: keyUri,
        ivHex: ivHex,
        range: pendingRange,
      ),
    );
    if (pendingRange != null) {
      nextRangeOffset = pendingRange.offset + pendingRange.length;
      pendingRange = null;
    }
    sequence++;
  }
  return HlsPlaylist(segments: segments, initUri: initUri);
}

/// 读取 `#EXT-X-*` 属性（`NAME=value` 或 `NAME="value"`）。
String? hlsAttribute(String line, String name) {
  final match = RegExp(
    '(?:^|[:,])${RegExp.escape(name)}=("[^"]*"|[^,]*)',
  ).firstMatch(line);
  if (match == null) return null;
  var value = (match.group(1) ?? '').trim();
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    value = value.substring(1, value.length - 1);
  }
  return value;
}

/// 相对地址 → 绝对地址（清单里的地址可能是相对路径）。
String resolveHlsUrl(String base, String ref) {
  final value = ref.trim();
  if (value.isEmpty) return value;
  try {
    return Uri.parse(base).resolve(value).toString();
  } catch (_) {
    return value;
  }
}

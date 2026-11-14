// 搜索标题归一化与相似度匹配（纯 Dart，无 IO 依赖）。
//
// 对齐 Win-box 的 searchTitleMatching：先清洗发布信息与剧集后缀，再用
// Sørensen–Dice 2-gram 相似度兜底；季数 / 续作数字冲突时直接判 0，
// 避免「第二季」与「第三季」、「流浪地球2」与「流浪地球」互相串源。
// 这里不引入拼音库，英文缩写查询仍按整词 / 包含关系匹配。
import 'text_key.dart';

final RegExp _htmlTag = RegExp(r'<[^>]*>');
final RegExp _quotedTitle = RegExp(r'《([^》]+)》');
final RegExp _metadataTag = RegExp(r'[【\[（(]([^】\]）)]*)[】\]）)]');
final RegExp _metadataValue = RegExp(
  r'^(?:\d{4}|\d*[kp]|hd|hd中字|1080p|2160p|4k|国语|國語|粤语|粵語|日语|日語|'
  r'英语|英語|中字|中英双字|简体|繁体|超清|高清|蓝光|藍光|完整版|全集|完结|'
  r'完結|无删减|無刪減|独播|獨播|抢先|搶先|杜比|hdr|内嵌字幕|內嵌字幕|'
  r'3d|动漫|动画|国漫|日漫|电视剧|电影|综艺|纪录片|tv|ova)'
  r'(?:[\s+/·-].*)?$',
  caseSensitive: false,
);

const String _episodeNumber = '[0-9零〇一二三四五六七八九十百两兩]+';

/// 尾部的剧集 / 更新状态：`第N集`、`更新至N`、`全N集`、`01-02集`。
final RegExp _episodeSuffix = RegExp(
  '(?:第\\s*$_episodeNumber\\s*[集话話回]'
  '|(?:剧集|劇集)?更新(?:至|到)?\\s*$_episodeNumber'
  '|全\\s*$_episodeNumber\\s*[集话話]'
  '|[0-9]+\\s*[-~～至]\\s*[0-9]+\\s*[集话話]?)'
  r'.*$',
  caseSensitive: false,
  dotAll: true,
);

/// 尾部的剧集编码：`S02E05` / `E05` / `2x3`。
final RegExp _episodeCodeSuffix = RegExp(
  r'(?:\bS\d{1,2}\s*E(?:P)?\d{1,4}\b|\bE(?:P)?\d{1,4}\b|\b\d{1,2}x\d{1,4}\b)\s*$',
  caseSensitive: false,
);

/// 任意位置的发布 / 编码噪点（分辨率、动态范围、编码、片源）。
final RegExp _releaseNoise = RegExp(
  r'\b(?:2160p|1440p|1080p|1080i|720p|576p|480p|4k|8k|uhd|hdr10\+?|hdr|'
  r'hevc|x265|x264|av1|web-?dl|web-?rip|bluray|blu-?ray|remux|bdrip|hdtv)\b',
  caseSensitive: false,
);

/// 任意位置的剧集编码：`S02E05` / `E05` / `2x3`。
final RegExp _episodeCode = RegExp(
  r'\bS\d{1,2}\s*E(?:P)?\d{1,4}\b|\bE(?:P)?\d{1,4}\b|\b\d{1,2}x\d{1,4}\b',
  caseSensitive: false,
);

/// 跨源去重时可安全忽略的「状态」后缀：只去更新进度，不去具体集号。
final RegExp _statusSuffix = RegExp(
  r'(?:\s*(?:全\s*\d+\s*[集话話]|更新(?:至|到)\s*(?:第)?\s*\d+\s*[集话話]?|已?完结|已?完結|全集))\s*$',
  caseSensitive: false,
);

/// 搜索标题清洗：去掉分辨率 / 语言 / 年份等发布标签、更新状态与剧集后缀。
///
/// 季数标记（`第二季` / `S02`）会保留，方便调用方再做季数隔离。
String movieSearchTitle(String value) {
  var title = normalizeWidth(value).replaceAll(_htmlTag, '').trim();
  final quoted = _quotedTitle.firstMatch(title);
  if (quoted != null) {
    final rest = title.substring(quoted.end);
    if (_episodeSuffix.hasMatch(rest)) title = quoted.group(1)!;
  }
  title = title.replaceAllMapped(_metadataTag, (m) {
    final inner = (m.group(1) ?? '').trim();
    return _metadataValue.hasMatch(inner) ? ' ' : m.group(0)!;
  });
  title = title.replaceAll(_releaseNoise, ' ');
  title = title.replaceAll(_episodeCode, ' ');
  title = title.replaceAll(_episodeSuffix, ' ');
  title = title.replaceAll(_episodeCodeSuffix, ' ');
  title = title
      .replaceAll(
        RegExp(
          r'(?:全集|完整版|无删减|無刪減|在线观看|在線觀看|一口气看完|一口氣看完).*$',
        ),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'\s*\.\s*'), '.')
      .replaceAll(RegExp(r'\.{2,}'), '.')
      .trim();
  title = title
      .replaceAll(
        RegExp(r'^[\s《》「」『』:：-]+|[\s《》「」『』:：,，。._—-]+$'),
        '',
      )
      .trim();
  return title.isEmpty ? value.trim() : title;
}

/// 跨源去重键：清洗发布标签与「更新至 N 集」等状态，但保留具体集号，
/// 避免把「某剧 第1集」「某剧 第2集」合并成一条。
///
/// 集号会做前导零归一（`第01集` → `第1集`，`S01E01` → `S1E1`）。
String searchDedupeKey(String name, {String year = ''}) {
  var title = normalizeWidth(name).replaceAll(_htmlTag, '').trim();
  title = title.replaceAllMapped(_metadataTag, (m) {
    final inner = (m.group(1) ?? '').trim();
    return _metadataValue.hasMatch(inner) ? ' ' : m.group(0)!;
  });
  title = title.replaceAll(_releaseNoise, ' ');
  title = title.replaceAll(_statusSuffix, ' ');
  title = title.replaceAllMapped(
    RegExp(r'第\s*0*(\d+)\s*([集话話期回])'),
    (m) => '第${m.group(1)}${m.group(2)}',
  );
  title = title.replaceAllMapped(
    RegExp(r'[Ss]\s*0*(\d{1,2})\s*[Ee]\s*0*(\d{1,4})'),
    (m) => 'S${m.group(1)}E${m.group(2)}',
  );
  final key = compactTitle(title);
  return '${key.isEmpty ? compactTitle(name) : key}|${year.trim()}';
}

/// Sørensen–Dice 系数：用 2-gram 多重集合计算相似度，适合中英混合短标题。
double diceCoefficient(String a, String b) {
  if (a == b) return 1;
  if (a.length < 2 || b.length < 2) return 0;
  final bigrams = <String, int>{};
  for (var i = 0; i < a.length - 1; i++) {
    final gram = a.substring(i, i + 2);
    bigrams[gram] = (bigrams[gram] ?? 0) + 1;
  }
  var intersection = 0;
  for (var i = 0; i < b.length - 1; i++) {
    final gram = b.substring(i, i + 2);
    final count = bigrams[gram] ?? 0;
    if (count > 0) {
      bigrams[gram] = count - 1;
      intersection++;
    }
  }
  return 2.0 * intersection / ((a.length - 1) + (b.length - 1));
}

/// 标题相似度（0–100）：完全一致 > 前缀 > 包含 > Dice 模糊命中。
///
/// 只用于同一关键词下的排序；返回 0 不代表结果被丢弃。
int searchTitleScore(String query, String candidate) {
  final title = movieSearchTitle(query);
  final queryKey = compactTitle(title);
  final rawSource = normalizeWidth(candidate);
  final raw = compactTitle(candidate);
  final cleanTitle = movieSearchTitle(candidate);
  final clean = compactTitle(cleanTitle);
  if (queryKey.isEmpty || raw.isEmpty) return 0;
  if (raw == queryKey) return 100;

  // 季数冲突（第二季 vs 第三季）直接判 0，避免跨季串源。
  final querySeason = _seasonOf(title);
  final candidateSeason = _seasonOf(rawSource);
  if (querySeason != null &&
      candidateSeason != null &&
      querySeason != candidateSeason) {
    return 0;
  }

  // 1–3 个拉丁字母的短标题必须整词命中，避免 "AI" 命中 "BRAIN"。
  if (RegExp(r'^[a-z]{1,3}$').hasMatch(title.toLowerCase())) {
    final boundary = RegExp(
      '(?:^|[^a-z])${RegExp.escape(title.toLowerCase())}(?:\$|[^a-z])',
    );
    if (!boundary.hasMatch(rawSource.toLowerCase())) return 0;
  }

  final clip = RegExp(
    r'解说|解說|速看|预告|預告|片段|首播|第\s*[0-9零一二三四五六七八九十百]+\s*[集话話]',
  ).hasMatch(rawSource);
  final penalty = clip ? 15 : 0;

  if (!raw.contains(queryKey) && !clean.contains(queryKey)) {
    // 续作数字冲突：流浪地球2 ≠ 流浪地球。
    final digitEndA = RegExp(r'(?:^|\D)(\d+)$').firstMatch(queryKey)?.group(1);
    final digitEndB = RegExp(r'(?:^|\D)(\d+)$').firstMatch(clean)?.group(1);
    if (digitEndA != digitEndB && (digitEndA != null || digitEndB != null)) {
      return 0;
    }
    final similarity = diceCoefficient(queryKey, clean);
    if (similarity >= 0.75) {
      final score = (similarity * 70).round() - penalty;
      return score > 0 ? score : 1;
    }
    return 0;
  }

  final base = clean == queryKey ? 90 : (raw.startsWith(queryKey) ? 75 : 60);
  final score = base - penalty;
  return score > 0 ? score : 1;
}

int? _seasonOf(String value) {
  final cn = RegExp(
    r'第\s*([0-9零〇一二三四五六七八九十百两兩]+)\s*[季部]',
  ).firstMatch(value);
  if (cn != null) return parseChineseNumber(cn.group(1)!);
  final en = RegExp(
    r'(?:^|[^a-z0-9])s(?:eason)?\s*0*(\d{1,2})(?![0-9])',
    caseSensitive: false,
  ).firstMatch(value);
  if (en != null) return int.tryParse(en.group(1)!);
  return null;
}

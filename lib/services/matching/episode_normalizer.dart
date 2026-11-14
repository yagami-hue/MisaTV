// 集数 / 季数归一化（纯 Dart，无 IO 依赖）。
//
// 对齐 Win-box 的 episodeNormalizer：把各源五花八门的剧集标题
// （`[4K] 庆余年.S02E05`、`第05集 决战`、`EP05-06连播`、`2024-05-10期`、`SP01`）
// 解析成统一的 season / episode / dateOrdinal，供弹幕匹配、跨源同集判断使用。
import 'text_key.dart';

/// 归一化后的集数信息。
class EpisodeInfo {
  const EpisodeInfo({
    required this.raw,
    this.season,
    this.episode,
    this.episodeEnd,
    this.dateOrdinal,
    this.isSpecial = false,
    this.cleanTitle = '',
  });

  final String raw;
  final int? season;
  final int? episode;
  final int? episodeEnd;

  /// 综艺日期集：`20240510`。
  final String? dateOrdinal;
  final bool isSpecial;

  /// 去掉发布标签与季 / 集标记后的标题。
  final String cleanTitle;
}

final RegExp _special = RegExp(
  r'(?:^|[^\p{L}\p{N}])(?:SP|OVA|OAD|特别篇|番外篇?|彩蛋|花絮|前传)',
  caseSensitive: false,
  unicode: true,
);

final RegExp _specialNumber = RegExp(
  r'(?:SP|OVA|OAD|特别篇|番外篇?)\s*0*(\d{1,3})',
  caseSensitive: false,
);

final RegExp _seasonCode = RegExp(
  r'\bS(?:EASON)?\s*0*(\d{1,2})(?=[Ee\D]|$)',
  caseSensitive: false,
);

final RegExp _seasonCn = RegExp(
  r'第\s*([0-9零〇一二三四五六七八九十百两兩]+)\s*[季部]',
  unicode: true,
);

final RegExp _dateSeparated = RegExp(
  r'(?:^|\D)((?:19|20)\d{2})[-.年/](1[0-2]|0?[1-9])[-.月/]([12]\d|3[01]|0?[1-9])[日号期\s]?',
  unicode: true,
);

final RegExp _dateCompact = RegExp(
  r'(?:^|\D)((?:19|20)\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])(?=\D|$)',
  unicode: true,
);

final RegExp _episodeCode = RegExp(
  r'\b(?:S\s*\d{1,2}\s*)?E(?:P)?\s*0*(\d{1,4})'
  r'(?:\s*[-~+到至]\s*(?:E(?:P)?)?\s*0*(\d{1,4}))?\b',
  caseSensitive: false,
);

final RegExp _episodeCross = RegExp(
  r'(?:^|[^\p{L}\p{N}])0*(\d{1,2})\s*[xX]\s*0*(\d{1,4})(?=$|[^\p{L}\p{N}])',
  unicode: true,
);

final RegExp _episodeCn = RegExp(
  r'第\s*([0-9零〇一二三四五六七八九十百两兩]+)\s*'
  r'(?:[-~+到至连播]\s*(?:第)?\s*'
  r'([0-9零〇一二三四五六七八九十百两兩]+)\s*)?'
  r'[集话話期回]'
  r'(?:\s*[-~+到至连播]\s*(?:第)?\s*'
  r'([0-9零〇一二三四五六七八九十百两兩]+)\s*[集话話期回]?)?',
  unicode: true,
);

final RegExp _episodeUpdate = RegExp(
  r'(?:更新至|更新到|已更新至|至)\s*0*(\d{1,4})\s*[集话話期]?',
  unicode: true,
);

final RegExp _episodeRange = RegExp(
  r'(?:^|[^\p{L}\p{N}])0*(\d{1,4})\s*[-~+到至连播]\s*0*(\d{1,4})'
  r'\s*(?:集|话|期)?(?=$|[^\p{L}\p{N}])',
  unicode: true,
);

final RegExp _episodeStandalone = RegExp(
  r'(?:^|[^\p{L}\p{N}])0*(\d{1,4})\s*(?:集|话|期)?(?=$|[^\p{L}\p{N}])',
  unicode: true,
);

final List<RegExp> _noiseTags = [
  RegExp(r'\[[^\]]*\]'),
  RegExp(r'\([^)]*\)'),
  RegExp(r'【[^】]*】'),
  RegExp(r'（[^）]*）'),
];

final List<RegExp> _noiseWords = [
  RegExp(
    r'\b(?:2160p|1440p|1080p|1080i|720p|576p|480p|4k|8k|uhd|fhd|hd|sd)\b',
    caseSensitive: false,
  ),
  RegExp(r'\b(?:hdr10\+?|hdr|hlg|dolby[\s._-]*(?:vision)?|dovi|dv)\b',
      caseSensitive: false),
  RegExp(r'(?:4k|1080p|720p|超清|高清|标清|蓝光|原画|杜比视界|杜比音效)',
      caseSensitive: false),
  RegExp(r'\b(?:x264|h264|x265|h265|hevc|avc|av1|vc-1|vp9|10bit|8bit)\b',
      caseSensitive: false),
  RegExp(
    r'\b(?:dts(?:-hd)?|truehd|atmos|aac(?:\d\.\d)?|flac|ac3|ddp\+?|dd|mp3)\b',
    caseSensitive: false,
  ),
  RegExp(
    r'\b(?:web-?dl|web-?rip|bluray|blu-?ray|remux|bdrip|dvdrip|hdtv|tvrip|dvd)\b',
    caseSensitive: false,
  ),
  RegExp(
    r'(?:中英双字|中文字幕|国粤双语|双语字幕|官方双语|内嵌字幕|简繁中字|纯净版|抢先版|修复版|无删减版?|未删减版?|加长版|导演剪辑版|典藏版|重制版|正片|电影版|完结|全集|连播)',
    caseSensitive: false,
  ),
  RegExp(r'\.(?:mkv|mp4|ts|m2ts|avi|rmvb|flv|mov|wmv|webm)$',
      caseSensitive: false),
];

/// 把原始剧集标题解析成结构化信息。
EpisodeInfo normalizeEpisodeInfo(String raw) {
  final text = normalizeWidth(raw).trim();
  if (text.isEmpty) {
    return const EpisodeInfo(raw: '');
  }
  int? season;
  int? episode;
  int? episodeEnd;
  String? dateOrdinal;
  var isSpecial = false;

  if (_special.hasMatch(text)) {
    isSpecial = true;
    final sp = _specialNumber.firstMatch(text);
    if (sp != null) episode = int.tryParse(sp.group(1)!);
  }

  final seasonCode = _seasonCode.firstMatch(text);
  if (seasonCode != null) {
    season = int.tryParse(seasonCode.group(1)!);
  } else {
    final seasonCn = _seasonCn.firstMatch(text);
    if (seasonCn != null) season = parseChineseNumber(seasonCn.group(1)!);
  }

  final separatedDate = _dateSeparated.firstMatch(text);
  if (separatedDate != null) {
    final month = separatedDate.group(2)!.padLeft(2, '0');
    final day = separatedDate.group(3)!.padLeft(2, '0');
    dateOrdinal = '${separatedDate.group(1)}$month$day';
  } else {
    final compactDate = _dateCompact.firstMatch(text);
    if (compactDate != null) {
      dateOrdinal =
          '${compactDate.group(1)}${compactDate.group(2)}${compactDate.group(3)}';
    }
  }

  if (episode == null) {
    final code = _episodeCode.firstMatch(text);
    if (code != null) {
      episode = int.tryParse(code.group(1)!);
      if (code.group(2) != null) {
        episodeEnd = int.tryParse(code.group(2)!);
      }
    }
  }
  if (episode == null) {
    final cross = _episodeCross.firstMatch(text);
    if (cross != null) {
      season = int.tryParse(cross.group(1)!);
      episode = int.tryParse(cross.group(2)!);
    }
  }
  if (episode == null) {
    final cn = _episodeCn.firstMatch(text);
    if (cn != null) {
      episode = parseChineseNumber(cn.group(1)!);
      final end = cn.group(2) ?? cn.group(3);
      if (end != null) {
        episodeEnd = parseChineseNumber(end);
      }
    }
  }
  if (episode == null) {
    final update = _episodeUpdate.firstMatch(text);
    if (update != null) episode = int.tryParse(update.group(1)!);
  }
  // 日期集（综艺）本身已能标识集数，不再把日期里的数字当集号。
  if (episode == null && dateOrdinal == null) {
    final range = _episodeRange.firstMatch(text);
    if (range != null) {
      episode = int.tryParse(range.group(1)!);
      episodeEnd = int.tryParse(range.group(2)!);
    }
  }
  if (episode == null && dateOrdinal == null) {
    final standalone = _episodeStandalone.firstMatch(text);
    if (standalone != null) {
      final value = int.tryParse(standalone.group(1)!);
      final marked = RegExp(r'[集话期]').hasMatch(standalone.group(0)!);
      // 未标注「集 / 话 / 期」的四位数按年份处理，避免 2024 被当成第 2024 集。
      if (value != null && (marked || value < 1900 || value > 2099)) {
        episode = value;
      }
    }
  }

  var clean = text;
  for (final pattern in _noiseTags) {
    clean = clean.replaceAll(pattern, ' ');
  }
  for (final pattern in _noiseWords) {
    clean = clean.replaceAll(pattern, ' ');
  }
  clean = clean
      .replaceAll(
        RegExp(r'\bS\d{1,2}\s*E(?:P)?\d{1,4}\b', caseSensitive: false),
        ' ',
      )
      .replaceAll(
        RegExp(
          r'\bS(?:EASON)?\s*\d{1,2}(?![0-9A-Za-z])',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'第\s*[0-9零〇一二三四五六七八九十百两兩]+\s*[季部]'), ' ')
      .replaceAll(
        RegExp(
          r'\bE(?:P)?\s*\d{1,4}(?:\s*[-~+到至]\s*(?:E(?:P)?)?\s*\d{1,4})?\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(
        RegExp(r'\b\d{1,2}x\d{1,4}\b', caseSensitive: false),
        ' ',
      )
      .replaceAll(
        RegExp(
          r'第\s*[0-9零〇一二三四五六七八九十百两兩]+\s*'
          r'(?:[-~+到至连播]\s*(?:第)?\s*'
          r'[0-9零〇一二三四五六七八九十百两兩]+\s*)?'
          r'[集话話期回]'
          r'(?:\s*[-~+到至连播]\s*(?:第)?\s*'
          r'[0-9零〇一二三四五六七八九十百两兩]+\s*[集话話期回]?)?',
        ),
        ' ',
      )
      .replaceAll(RegExp(r'(?:更新至|更新到|全)\s*\d{1,4}\s*[集话話期]?'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'\s*\.\s*'), '.')
      .replaceAll(RegExp(r'\.{2,}'), '.')
      .replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '')
      .trim();

  return EpisodeInfo(
    raw: text,
    season: season,
    episode: episode,
    episodeEnd: episodeEnd,
    dateOrdinal: dateOrdinal,
    isSpecial: isSpecial,
    cleanTitle: clean,
  );
}

/// 判断两条剧集标题是否指向同一集。
///
/// 季数冲突、特别篇与正片冲突返回 false；日期集按日期比较；
/// 支持区间集（`01-02` 与 `02` 视为同一集）。
bool matchEpisodes(String target, String candidate) {
  final a = normalizeEpisodeInfo(target);
  final b = normalizeEpisodeInfo(candidate);
  if (a.isSpecial != b.isSpecial) return false;
  if (a.dateOrdinal != null && b.dateOrdinal != null) {
    return a.dateOrdinal == b.dateOrdinal;
  }
  if (a.season != null && b.season != null && a.season != b.season) {
    return false;
  }
  if (a.episode != null && b.episode != null) {
    if (a.episode == b.episode) return true;
    if (a.episodeEnd != null &&
        b.episode! >= a.episode! &&
        b.episode! <= a.episodeEnd!) {
      return true;
    }
    if (b.episodeEnd != null &&
        a.episode! >= b.episode! &&
        a.episode! <= b.episodeEnd!) {
      return true;
    }
    return false;
  }
  if (a.episode == null && b.episode == null) {
    final left = compactTitle(a.cleanTitle);
    final right = compactTitle(b.cleanTitle);
    return left.isNotEmpty && left == right;
  }
  return false;
}

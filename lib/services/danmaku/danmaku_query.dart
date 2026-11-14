// 弹幕搜索前的资源名清洗（对齐旧版 src/engine/danmaku/normalizeQuery.ts）：
// 生成搜索候选词 / 解析「集」输入框 / 候选显示压缩。
import '../matching/episode_normalizer.dart';
import 'danmaku_endpoints.dart';

final RegExp _fullWidthRe = RegExp(r'[\uFF01-\uFF5E]');
final RegExp _nonLetterNumber = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

String _fullToHalf(String s) {
  return s
      .replaceAllMapped(
        _fullWidthRe,
        (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xFEE0),
      )
      .replaceAll('\u3000', ' ');
}

String _segment(String s) {
  for (final part in s.split(RegExp(r'[-/~/·:：|_]'))) {
    final t = part.trim();
    if (t.isNotEmpty) return t;
  }
  return s;
}

/// 生成搜索候选词（去重、按原意优先，最长优先在前；最多 6 个）。
List<String> danmakuQueryCandidates(String raw) {
  if (raw.isEmpty) return const [];
  final base = _fullToHalf(raw).trim();
  final seen = <String>{};
  final out = <String>[];
  void push(String s) {
    final v = s.trim();
    if (v.isNotEmpty && v.length >= 2 && seen.add(v)) out.add(v);
  }

  // 1) 原文（半角化）
  push(base);
  // 2) 去尾部剧集标记：第N集/话/期/章、全N集、更新至N
  final noEp = base
      .replaceAll(RegExp(r'\s*(?:第)?\d+[集话期章]\s*$'), '')
      .replaceAll(RegExp(r'\s*全\d+[集话]\s*$'), '')
      .replaceAll(RegExp(r'\s*更新至\s*\d+\s*$'), '')
      .trim();
  push(noEp);
  // 3) 去掉所有符号/空格/emoji，只留文字数字
  final pureBase = base.replaceAll(_nonLetterNumber, '');
  final pureNoEp = noEp.replaceAll(_nonLetterNumber, '');
  push(pureNoEp);
  push(pureBase);
  // 4) 取第一段（拆掉 " - " 字幕组后缀 / 季数等）
  push(_segment(noEp));
  push(_segment(base));
  return out.length > 6 ? out.sublist(0, 6) : out;
}

/// 「集」输入框解析结果。
class EpisodeInput {
  const EpisodeInput({this.season, this.ep});

  /// 季号（`S02E01` / `第2季` → 2）。
  final int? season;

  /// 集号（已去前导零：`01` → `1`）。
  final String? ep;
}

/// 集号去前导零（`01`→`1`）；全零保留 `0` 以免变成空串。
String _stripEp(String v) {
  final t = v.replaceFirst(RegExp(r'^0+'), '');
  return t.isEmpty ? '0' : t;
}

/// 解析「集」输入框内容：`S01E10` / `1x10` / `E10` / `第10集` / `10` / `更新至10` / `第2季`。
/// 认不出来返回空对象（调用方回退「从资源名提取」）。
EpisodeInput parseEpisodeInput(String raw) {
  final info = normalizeEpisodeInfo(raw);
  return EpisodeInput(
    season: info.season,
    ep: info.episode == null ? null : '${info.episode}',
  );
}

/// 「集」输入框初值（由资源名生成）：`S01E10` → `S1E10`；`第10集`/末尾数字 → `10`。
String episodeFieldFromName(String name) {
  final info = normalizeEpisodeInfo(name);
  if (info.season != null && info.episode != null) {
    return 'S${info.season}E${'${info.episode}'.padLeft(2, '0')}';
  }
  return info.episode?.toString() ?? '';
}

/// 从文本里提集号：`第N话/集/期`、`SxxExx`、`更新至N`、纯数字（非年份）。
String _epNumberOf(String s) => normalizeEpisodeInfo(s).episode?.toString() ?? '';

/// 弹幕候选显示压缩：`斗破苍穹年番 第212话` → `斗破苍穹年番 · 第212集`。
String formatCandidateLabel({
  String title = '',
  String episodeTitle = '',
  String episodeNumber = '',
}) {
  final raw = _fullToHalf(title.trim());
  final ym = RegExp(r'[（(\[]?\s*((?:19|20)\d{2})\s*[）)\]]?').firstMatch(raw);
  final year = ym == null ? '' : ym.group(1)!;
  final num = episodeNumber.trim();
  final ep = _epNumberOf(episodeTitle).isNotEmpty
      ? _epNumberOf(episodeTitle)
      : (RegExp(r'^\d{1,4}$').hasMatch(num) ? _stripEp(num) : _epNumberOf(raw));
  final season = seasonOf(raw) ?? seasonOf(episodeTitle);
  var name = raw
      .replaceAll(RegExp(r'[（(\[]\s*(?:19|20)\d{2}\s*[）)\]]'), ' ')
      .replaceAll(RegExp(r'\bfrom\s*[^\s（()\u4e00-\u9fa5]+', caseSensitive: false), ' ')
      .replaceAll(
        RegExp(
          r'[（(\[【]\s*(?:3D)?(?:动漫|动画|国漫|日漫|电视剧|电影|综艺|纪录片|TV|OVA)\s*[）)\]】]',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(
        RegExp(r'第\s*(?:[0-9零〇一二三四五六七八九十百两兩]+)\s*[季部]'),
        ' ',
      )
      .replaceAll(RegExp(r'[Ss](?:eason)?\s*\d{1,2}\s*[Ee]\s*\d{1,4}'), ' ')
      .replaceAll(RegExp(r'[Ss]\s*\d{1,2}(?![0-9A-Za-z])'), ' ')
      .replaceAll(
        RegExp(r'第\s*(?:[0-9零〇一二三四五六七八九十百两兩]+)\s*[集话話期]'),
        ' ',
      )
      .replaceAll(RegExp(r'(?:更新至|全)\s*\d{1,4}\s*[集话期]?'), ' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .replaceAll(RegExp(r'[\s\-–—·:：|]+$'), '')
      .trim();
  if (name.isEmpty) name = raw; // 净化后为空但原文有内容（如纯符号名）→ 保留原文
  final nameFromEp = name.isEmpty;
  if (nameFromEp) name = episodeTitle.trim();
  if (name.isEmpty) return '';
  final parts = <String>[year.isEmpty ? name : '$name（$year）'];
  if (season != null) parts.add('第$season季');
  if (ep.isNotEmpty && !nameFromEp) parts.add('第$ep集');
  return parts.join(' · ');
}

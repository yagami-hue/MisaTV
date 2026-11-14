// 外部弹幕接口的纯函数（对齐旧版 src/engine/danmaku/endpoints.ts）：
// 地址归一、自定义接口解析、候选排序与挑选。无副作用，可独立单测。
import '../matching/episode_normalizer.dart';
import 'danmaku_models.dart';

final RegExp _schemeRe = RegExp(r'^[a-z][a-z0-9+.\-]*://', caseSensitive: false);
final RegExp _hostCharsRe = RegExp(r'^[A-Za-z0-9.\-:@\[\]%]+$');
final RegExp _trailingSlashRe = RegExp(r'/+$');
final RegExp _wwwRe = RegExp(r'^www\.', caseSensitive: false);
final RegExp _nonLetterNumber = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// 地址归一：去空白、去尾斜杠、无 scheme 补 https://；
/// 非法（无主机名 / 非 http(s) / 非 ASCII 主机）→ ''。
String normalizeEndpointBase(String url) {
  final s = url.trim();
  if (s.isEmpty) return '';
  final withScheme = _schemeRe.hasMatch(s) ? s : 'https://$s';
  // 先按「原文」校验主机段：Dart 的 Uri 会把乱码/中文行也解析出 host，
  // 只看解析结果会把「不是地址的一行」误当合法接口 → 必须拦在解析之前。
  final hostPart = withScheme.replaceFirst(_schemeRe, '').split(RegExp(r'[/?#]')).first;
  if (hostPart.isEmpty || !_hostCharsRe.hasMatch(hostPart)) return '';
  final uri = Uri.tryParse(withScheme);
  if (uri == null) return '';
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return '';
  if (uri.host.isEmpty) return '';
  return withScheme.replaceFirst(_trailingSlashRe, '');
}

/// 显示名兜底：host（去 www. 前缀）。
String endpointLabel(String url) {
  final base = normalizeEndpointBase(url);
  if (base.isEmpty) return '';
  final uri = Uri.tryParse(base);
  if (uri == null) return '';
  return uri.host.replaceFirst(_wwwRe, '');
}

/// 拼接口路径（base 先归一；path 以 / 开头）。
String joinApi(String base, String path) => normalizeEndpointBase(base) + path;

/// 是否为内置清单里的地址。
bool isBuiltinEndpoint(String url) {
  final n = normalizeEndpointBase(url);
  if (n.isEmpty) return false;
  return builtinDanmakuEndpoints.any((e) => normalizeEndpointBase(e.url) == n);
}

/// 解析自定义接口文本（一行一个）：
/// `名字@https://host/token` 或 `https://host/token`（名字缺省取 host）；
/// 空行 / `#` 注释 / 非法地址忽略；同地址去重（先出现者优先）。
List<DanmakuEndpoint> parseCustomEndpoints(String text) {
  final out = <DanmakuEndpoint>[];
  final seen = <String>{};
  for (final rawLine in text.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final at = line.lastIndexOf('@');
    var name = '';
    var url = line;
    // `名字@URL`：仅当 @ 之后是带 scheme 的地址时按名字解析。
    if (at > 0) {
      final tail = line.substring(at + 1).trim();
      if (_schemeRe.hasMatch(tail)) {
        name = line.substring(0, at).trim();
        url = tail;
      }
    }
    final base = normalizeEndpointBase(url);
    if (base.isEmpty || !seen.add(base)) continue;
    out.add(DanmakuEndpoint(
      name: name.isEmpty ? endpointLabel(base) : name,
      url: base,
      enabled: true,
    ));
  }
  return out;
}

/// 合成新接口清单 = 内置项（保留既有开关状态，缺项按内置默认开关补）+ 自定义文本解析结果。
List<DanmakuEndpoint> mergeEndpoints(List<DanmakuEndpoint> current, String customText) {
  final enabledOf = <String, bool>{};
  for (final e in current) {
    final n = normalizeEndpointBase(e.url);
    if (n.isNotEmpty) enabledOf[n] = e.enabled;
  }
  final out = <DanmakuEndpoint>[];
  for (final e in builtinDanmakuEndpoints) {
    final n = normalizeEndpointBase(e.url);
    if (n.isEmpty) continue;
    out.add(DanmakuEndpoint(
      name: e.name,
      url: n,
      enabled: enabledOf[n] ?? e.enabled,
    ));
  }
  final seen = {for (final e in out) e.url};
  for (final c in parseCustomEndpoints(customText)) {
    if (!seen.add(c.url)) continue;
    // 自定义项若之前就存在，保留其开关状态。
    out.add(c.copyWith(enabled: enabledOf[c.url] ?? true));
  }
  return out;
}

/// 自定义文本回显：从当前清单里挑出非内置项 → 每行 `名字@URL`。
String customEndpointsText(List<DanmakuEndpoint> current) {
  final lines = <String>[];
  for (final e in current) {
    if (isBuiltinEndpoint(e.url)) continue;
    final name = e.name.trim().isEmpty ? endpointLabel(e.url) : e.name;
    lines.add('$name@${normalizeEndpointBase(e.url)}');
  }
  return lines.join('\n');
}

/// 全角转半角（全角区间 \uff01-\uff5e 与表意空格）。
String _fullToHalf(String s) {
  return s
      .replaceAllMapped(
        RegExp(r'[\uFF01-\uFF5E]'),
        (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xFEE0),
      )
      .replaceAll('\u3000', ' ');
}

/// 标题净化：全角转半角 + 去所有非字母数字（用于匹配度打分）。
String cleanTitle(String s) {
  return _fullToHalf(s).toLowerCase().replaceAll(_nonLetterNumber, '');
}

/// 从资源名 / 剧名里提取**季号**：`第2季` / `Season 2` / `S01` → 2 / 1；取不到 → null。
int? seasonOf(String name) {
  final season = normalizeEpisodeInfo(name).season;
  return season != null && season >= 1 && season <= 99 ? season : null;
}

/// 标题季号与期望季的契合度：0 = 同季 / 1 = 标题无季信息（或未给期望季）/ 2 = 不同季。
int seasonRankOf(String title, [int? season]) {
  final t = seasonOf(title);
  if (t == null || season == null) return 1;
  return t == season ? 0 : 2;
}

/// 候选番剧排序 + 去重（同来源同名的只留首个）：
/// 档 0 = 净化后完全同名；档 1 = 一方包含另一方；档 2 = 其它。
/// 给了期望季号时同季排前、不同季排后；同档同季内 `episodeCount` 多者优先。
List<DanmakuAnime> rankDanmakuAnimes(
  List<DanmakuAnime> list,
  String keyword, [
  int? season,
]) {
  final k = cleanTitle(keyword);
  final seen = <String>{};
  final items = <_RankedAnime>[];
  for (var idx = 0; idx < list.length; idx++) {
    final a = list[idx];
    final key = '${a.source}::${a.title}';
    if (!seen.add(key)) continue;
    final t = cleanTitle(a.title);
    final rank = (k.isEmpty || t.isEmpty)
        ? 2
        : t == k
            ? 0
            : (t.contains(k) || k.contains(t) ? 1 : 2);
    items.add(_RankedAnime(
      anime: a,
      rank: rank,
      seasonRank: seasonRankOf(a.title, season),
      episodeCount: a.episodeCount,
      index: idx,
    ));
  }
  items.sort((x, y) {
    var c = x.rank - y.rank;
    if (c != 0) return c;
    c = x.seasonRank - y.seasonRank;
    if (c != 0) return c;
    if (season != null) {
      c = y.episodeCount - x.episodeCount;
      if (c != 0) return c;
    }
    return x.index - y.index;
  });
  return [for (final x in items) x.anime];
}

class _RankedAnime {
  _RankedAnime({
    required this.anime,
    required this.rank,
    required this.seasonRank,
    required this.episodeCount,
    required this.index,
  });

  final DanmakuAnime anime;
  final int rank;
  final int seasonRank;
  final int episodeCount;
  final int index;
}

/// 展开剧集列表时挑前 N 部：**来源多样性优先**（每个来源先取第一部，再按序补足）。
List<DanmakuAnime> pickAnimesForExpand(List<DanmakuAnime> list, int max) {
  final out = <DanmakuAnime>[];
  final used = <String>{};
  void take(DanmakuAnime a) {
    if (out.length >= max) return;
    final key = '${a.source}::${a.animeId}';
    if (!used.add(key)) return;
    out.add(a);
  }

  for (final a in list) {
    if (out.length >= max) break;
    if (!out.any((x) => x.source == a.source)) take(a);
  }
  for (final a in list) {
    if (out.length >= max) break;
    take(a);
  }
  return out;
}

/// 找到文本里第一个「独立数字」（前后都不是 ASCII 字母数字）；`maxDigits` 超长视为无。
String? _looseNumber(String text, int maxDigits) {
  for (final m in RegExp(r'\d+').allMatches(text)) {
    final before = m.start > 0 ? text.codeUnitAt(m.start - 1) : 0;
    final after = m.end < text.length ? text.codeUnitAt(m.end) : 0;
    if (_isAsciiAlnum(before) || _isAsciiAlnum(after)) continue;
    final run = m.group(0)!;
    if (run.length > maxDigits) continue;
    return run;
  }
  return null;
}

bool _isAsciiAlnum(int c) =>
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

int? _positive(String? raw) {
  if (raw == null) return null;
  final n = int.tryParse(raw);
  return n != null && n > 0 ? n : null;
}

/// 从候选里提集号（null = 没集号）：接口 `episodeNumber` 优先，其次标题显式写法。
int? epNumberOf(DanmakuCandidate c) {
  final num = _positive(c.episodeNumber.trim());
  if (num != null) return num;
  final t = c.episodeTitle.trim();
  if (t.isEmpty) return null;
  final normalized = normalizeEpisodeInfo(t).episode;
  if (normalized != null) return normalized;
  // 兜底只认「独立数字」，并排除分辨率标记（4K）与年份（2024）。
  final tail = _looseNumber(t, 4);
  if (tail == null || RegExp(r'^(?:19|20)\d{2}$').hasMatch(tail)) return null;
  return _positive(tail);
}

/// 候选是否为「第 targetEp 集」—— 接口集号字段优先，标题显式集号兜底。
bool candidateMatchesEp(DanmakuCandidate c, String targetEp) {
  final t = targetEp.replaceFirst(RegExp(r'^0+'), '').trim();
  if (t.isEmpty) return false;
  final n = epNumberOf(c);
  if (n != null) return '$n' == t;
  // 日期集 / 区间集等没有纯数字集号时，再按归一化结果比较一次。
  return matchEpisodes(targetEp, c.episodeTitle);
}

/// 候选列表**显示排序**：有集数的按集号升序排前面，没集数的保持原顺序放后面。
List<DanmakuCandidate> sortCandidatesByEp(List<DanmakuCandidate> list) {
  final withEp = <_EpCandidate>[];
  final noEp = <_IndexedCandidate>[];
  for (var i = 0; i < list.length; i++) {
    final c = list[i];
    final n = epNumberOf(c);
    if (n == null) {
      noEp.add(_IndexedCandidate(candidate: c, index: i));
    } else {
      withEp.add(_EpCandidate(candidate: c, ep: n, index: i));
    }
  }
  withEp.sort((a, b) {
    final c = a.ep - b.ep;
    return c != 0 ? c : a.index - b.index;
  });
  return [
    for (final x in withEp) x.candidate,
    for (final x in noEp) x.candidate,
  ];
}

class _EpCandidate {
  _EpCandidate({required this.candidate, required this.ep, required this.index});

  final DanmakuCandidate candidate;
  final int ep;
  final int index;
}

class _IndexedCandidate {
  _IndexedCandidate({required this.candidate, required this.index});

  final DanmakuCandidate candidate;
  final int index;
}

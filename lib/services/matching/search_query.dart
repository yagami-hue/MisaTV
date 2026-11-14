// 结构化搜索语法（纯 Dart，无 IO 依赖，便于单测）。
//
// 背景：本项目的搜索是「一个关键词广播给所有源站」。CMS 接口（`ac=videolist&wd=`）
// 只接受关键词参数，**不接受年份 / 类型 / 地区等附加条件**，蜘蛛源同理。
// 所以这里的结构化条件只能做「取回之后就地在结果上过滤」，不能下推给源站。
//
// 与 Kazumi 的 `search_parser.dart` 的关键区别：那边对接 Bangumi 远端 API，
// `sort:` / `season:` / `rank:` / `score:` / `weekday:` 都能真正下推；本项目
// 没有等价接口，因此**不实现这些字段**，避免做出一个「写了不生效」的假开关。
//
// 支持的语法（中英文冒号都认，字段名大小写不敏感）：
//
//   year:2024              精确年份
//   year:2020-2024         年份区间（`..` / `~` / `至` 等价）
//   type:电影              类型包含（可重复，多个之间是「或」）
//   area:大陆              地区包含（可重复，或）
//   -词                    排除含该词的结果
//
// 刻意**不做** `site:`：搜索页已经用 `@源名` 在 UI 层收窄 scope（见
// `search_page.dart` 的 `_atFilter` / `_pinnedSiteKey`），再实现一遍会出现
// 两套语义不同、互相打架的单源过滤。单源搜索请继续用 `@`。
//
// 未识别的 `xxx:yyy` **不当作语法**，原样留在关键词里 —— 用户搜
// `http://…` 或片名里带冒号时不会被误吃。
//
// 缺失元数据的宽容规则：`year` / `type` / `area` 为空的结果**不会被过滤掉**。
// 很多 CMS 源不带年份与类型，若按严格口径过滤，用户会看到「搜出来是 0 条」，
// 比看到几条不精确的结果更糟。过滤只淘汰「明确不匹配」的条目。

/// 一条解析后的搜索请求。
class SearchQuery {
  const SearchQuery({
    required this.raw,
    required this.keyword,
    this.year,
    this.yearMin,
    this.yearMax,
    this.types = const [],
    this.areas = const [],
    this.excludes = const [],
  });

  /// 用户原始输入（用于界面回显）。
  final String raw;

  /// 清洗掉语法标记后真正发给源站的关键词。
  final String keyword;

  /// 精确年份（与区间互斥，精确优先）。
  final int? year;
  final int? yearMin;
  final int? yearMax;

  final List<String> types;
  final List<String> areas;

  /// 排除词（用户写 `-广告`）。
  final List<String> excludes;

  bool get isEmpty => keyword.isEmpty;

  bool get hasFilters =>
      year != null ||
      yearMin != null ||
      yearMax != null ||
      types.isNotEmpty ||
      areas.isNotEmpty ||
      excludes.isNotEmpty;

  /// 生效条件的一行摘要，给搜索页顶部的提示条用；没有条件时返回空串。
  String get filterSummary {
    final parts = <String>[];
    if (year != null) {
      parts.add('$year');
    } else if (yearMin != null || yearMax != null) {
      parts.add('${yearMin ?? ''}–${yearMax ?? ''}');
    }
    if (types.isNotEmpty) parts.add(types.join('/'));
    if (areas.isNotEmpty) parts.add(areas.join('/'));
    if (excludes.isNotEmpty) {
      parts.add('排除 ${excludes.map((e) => '-$e').join(' ')}');
    }
    return parts.join(' · ');
  }

  /// 该结果是否通过过滤。缺失元数据一律放行（见文件头说明）。
  bool accepts({
    required String name,
    String year = '',
    String type = '',
    String area = '',
  }) {
    final lowerName = name.toLowerCase();
    for (final word in excludes) {
      if (lowerName.contains(word)) return false;
    }
    final itemYear = int.tryParse(RegExp(r'\d{4}').firstMatch(year)?.group(0) ?? '');
    if (this.year != null) {
      if (itemYear != null && itemYear != this.year) return false;
    } else if (yearMin != null || yearMax != null) {
      if (itemYear != null) {
        if (yearMin != null && itemYear < yearMin!) return false;
        if (yearMax != null && itemYear > yearMax!) return false;
      }
    }
    if (types.isNotEmpty && type.trim().isNotEmpty) {
      final haystack = type.toLowerCase();
      if (!types.any(haystack.contains)) return false;
    }
    if (areas.isNotEmpty && area.trim().isNotEmpty) {
      final haystack = area.toLowerCase();
      if (!areas.any(haystack.contains)) return false;
    }
    return true;
  }

  @override
  String toString() => 'SearchQuery(keyword=$keyword, year=$year, '
      'range=$yearMin..$yearMax, types=$types, areas=$areas, '
      'excludes=$excludes)';
}

/// 字段别名：中英文都认，大小写不敏感。未列出的 `xxx:` 不当作语法。
const Map<String, String> _fieldAliases = {
  'year': 'year',
  '年份': 'year',
  'type': 'type',
  '类型': 'type',
  'area': 'area',
  '地区': 'area',
};

/// 解析用户输入。
SearchQuery parseSearchQuery(String raw) {
  final input = raw.trim();
  if (input.isEmpty) {
    return const SearchQuery(raw: '', keyword: '');
  }

  final keywords = <String>[];
  final types = <String>[];
  final areas = <String>[];
  final excludes = <String>[];
  int? exactYear;
  int? yearMin;
  int? yearMax;

  // 先按空白切，再逐个判断是否是 `字段:值`。这样值里允许出现空格以外的任意字符，
  // 也不会像纯正则那样把一个字段的值吃到下一个字段里。
  for (final token in input.split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;

    // 排除词：`-广告`。单独的 `-` 视作普通关键词。
    if (token.length > 1 && token.startsWith('-') && !token.startsWith('--')) {
      final word = token.substring(1).trim().toLowerCase();
      if (word.isNotEmpty) excludes.add(word);
      continue;
    }

    final sep = _fieldSeparatorIndex(token);
    if (sep > 0) {
      final field = _fieldAliases[token.substring(0, sep).toLowerCase()];
      final value = token.substring(sep + 1).trim();
      if (field != null && value.isNotEmpty) {
        switch (field) {
          case 'year':
            final parsed = _parseYear(value);
            if (parsed != null) {
              exactYear = parsed.exact;
              yearMin = parsed.min;
              yearMax = parsed.max;
              continue; // 语法被吃掉了
            }
          case 'type':
            for (final part in _splitMulti(value)) {
              types.add(part.toLowerCase());
            }
            continue;
          case 'area':
            for (final part in _splitMulti(value)) {
              areas.add(part.toLowerCase());
            }
            continue;
        }
        // 字段名合法但值解析不了（如 `year:abcd`）：退回关键词，不要静默吞掉。
      }
    }
    keywords.add(token);
  }

  return SearchQuery(
    raw: input,
    keyword: keywords.join(' ').trim(),
    year: exactYear,
    yearMin: yearMin,
    yearMax: yearMax,
    types: types,
    areas: areas,
    excludes: excludes,
  );
}

/// 找到字段分隔位置（半角 `:` 或全角 `：`）；没有则返回 -1。
///
/// 只看**第一个**分隔符，且要求它前面是合法字段名（由 [_fieldAliases] 判定），
/// 因此 `http://x` 这类冒号不会被误判成字段。
int _fieldSeparatorIndex(String token) {
  final half = token.indexOf(':');
  final full = token.indexOf('：');
  int index;
  if (half < 0) {
    index = full;
  } else if (full < 0) {
    index = half;
  } else {
    index = half < full ? half : full;
  }
  if (index <= 0) return -1;
  final name = token.substring(0, index).toLowerCase();
  return _fieldAliases.containsKey(name) ? index : -1;
}

/// `year:` 的取值：`2024` / `2020-2024` / `2020..2024` / `2020~2024` / `2020至2024`。
({int? exact, int? min, int? max})? _parseYear(String value) {
  final single = RegExp(r'^(\d{4})$').firstMatch(value);
  if (single != null) {
    final year = int.tryParse(single.group(1)!);
    return year == null ? null : (exact: year, min: null, max: null);
  }
  final range = RegExp(r'^(\d{4})\s*(?:-|\.\.|~|～|至|到)\s*(\d{4})$')
      .firstMatch(value);
  if (range != null) {
    var a = int.tryParse(range.group(1)!);
    var b = int.tryParse(range.group(2)!);
    if (a == null || b == null) return null;
    // 容忍写反（2024-2020）。
    if (a > b) (a, b) = (b, a);
    return (exact: null, min: a, max: b);
  }
  // 半开区间：`2020..` / `..2024`。
  final openMin = RegExp(r'^(\d{4})\s*(?:\.\.|~|至|到)\s*$').firstMatch(value);
  if (openMin != null) {
    return (exact: null, min: int.tryParse(openMin.group(1)!), max: null);
  }
  final openMax = RegExp(r'^(?:\.\.|~|至|到)\s*(\d{4})$').firstMatch(value);
  if (openMax != null) {
    return (exact: null, min: null, max: int.tryParse(openMax.group(1)!));
  }
  return null;
}

/// 多值分隔：`type:电影,电视剧` / `type:电影/电视剧`。
List<String> _splitMulti(String value) => value
    .split(RegExp(r'[,/、|]'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

import '../core/utils/text_utils.dart';

class FilterOption {
  const FilterOption({this.tab = '', required this.n, required this.v});
  final String tab;
  final String n;
  final String v;
}

class FilterGroup {
  const FilterGroup({
    required this.key,
    required this.name,
    required this.values,
  });
  final String key;
  final String name;
  final List<FilterOption> values;
}

class SortClass {
  const SortClass({
    required this.id,
    required this.name,
    this.flag,
    this.filters = const [],
  });
  final String id;
  final String name;
  final String? flag;
  final List<FilterGroup> filters;
}

class VodItem {
  const VodItem({
    required this.id,
    required this.name,
    this.pic = '',
    this.remarks = '',
    this.year = '',
    this.area = '',
    this.type = '',
    this.sourceKey = '',
    this.tag = '',
    this.sourceName = '',
    this.sameFromOtherSources = 0,
  });

  final String id;
  final String name;
  final String pic;
  final String remarks;
  final String year;
  final String area;
  final String type;
  final String sourceKey;
  final String tag;
  final String sourceName;
  final int sameFromOtherSources;

  String get cleanPic => splitUrlHeadersClean(pic);
  Map<String, String> get picHeaders => splitUrlHeaders(pic);

  /// `vod_tag=1/folder`：分类文件夹（直播源的「网游 → 英雄联盟」）。
  /// 点击应进入它的分类列表，而不是打开详情页。
  bool get isFolder {
    final value = tag.trim().toLowerCase();
    return value == '1' || value == 'folder';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'pic': pic,
    'remarks': remarks,
    'year': year,
    'area': area,
    'type': type,
    'sourceKey': sourceKey,
    if (tag.isNotEmpty) 'tag': tag,
    if (sourceName.isNotEmpty) 'sourceName': sourceName,
    if (sameFromOtherSources > 0) 'sameFromOtherSources': sameFromOtherSources,
  };

  factory VodItem.fromJson(Map<String, dynamic> j) => VodItem(
    id: (j['id'] ?? '').toString(),
    name: (j['name'] ?? '').toString(),
    pic: (j['pic'] ?? '').toString(),
    remarks: (j['remarks'] ?? '').toString(),
    year: (j['year'] ?? '').toString(),
    area: (j['area'] ?? '').toString(),
    type: (j['type'] ?? '').toString(),
    sourceKey: (j['sourceKey'] ?? '').toString(),
    tag: (j['tag'] ?? '').toString(),
    sourceName: (j['sourceName'] ?? '').toString(),
    sameFromOtherSources: (j['sameFromOtherSources'] as num?)?.toInt() ?? 0,
  );
}

class Episode {
  const Episode({required this.name, required this.url});
  final String name;
  final String url;

  Map<String, dynamic> toJson() => {'name': name, 'url': url};

  factory Episode.fromJson(Map<String, dynamic> json) => Episode(
    name: (json['name'] ?? '').toString(),
    url: (json['url'] ?? '').toString(),
  );
}

class VodDetail {
  const VodDetail({
    required this.id,
    required this.name,
    this.pic = '',
    this.type = '',
    this.year = '',
    this.area = '',
    this.director = '',
    this.actor = '',
    this.des = '',
    this.remarks = '',
    this.flags = const [],
    this.episodes = const {},
    this.sourceKey = '',
  });

  final String id;
  final String name;
  final String pic;
  final String type;
  final String year;
  final String area;
  final String director;
  final String actor;
  final String des;
  final String remarks;
  final List<String> flags;
  final Map<String, List<Episode>> episodes;
  final String sourceKey;

  List<Episode> episodeList(String flag) {
    if (episodes.containsKey(flag)) return episodes[flag]!;
    if (episodes.isNotEmpty) return episodes.values.first;
    return const [];
  }

  String get cleanPic => splitUrlHeadersClean(pic);
  Map<String, String> get picHeaders => splitUrlHeaders(pic);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'pic': pic,
    'type': type,
    'year': year,
    'area': area,
    'director': director,
    'actor': actor,
    'des': des,
    'remarks': remarks,
    'flags': flags,
    'episodes': {
      for (final entry in episodes.entries)
        entry.key: entry.value.map((e) => e.toJson()).toList(),
    },
    'sourceKey': sourceKey,
  };

  factory VodDetail.fromJson(Map<String, dynamic> json) {
    final rawEpisodes = json['episodes'];
    final episodes = <String, List<Episode>>{};
    if (rawEpisodes is Map) {
      for (final entry in rawEpisodes.entries) {
        final list = entry.value;
        if (list is! List) continue;
        episodes[entry.key.toString()] = [
          for (final item in list)
            if (item is Map)
              Episode.fromJson(Map<String, dynamic>.from(item)),
        ];
      }
    }
    return VodDetail(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      pic: (json['pic'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
      year: (json['year'] ?? '').toString(),
      area: (json['area'] ?? '').toString(),
      director: (json['director'] ?? '').toString(),
      actor: (json['actor'] ?? '').toString(),
      des: (json['des'] ?? '').toString(),
      remarks: (json['remarks'] ?? '').toString(),
      flags: [
        for (final item in (json['flags'] is List ? json['flags'] as List : const []))
          item.toString(),
      ],
      episodes: episodes,
      sourceKey: (json['sourceKey'] ?? '').toString(),
    );
  }
}

/// 最终播放地址是否可以直接交给播放器。
///
/// 与 winbox 的最终校验一致：空地址、源内选集参数（`parse_api=…&url=…`）、
/// 普通相对路径、错误占位视频都不能当成可播直链；HTTP(S) 等协议地址和
/// Windows 本地绝对路径（`D:\…` / `file://`）放行。
bool isPlayableMediaUrl(String raw) {
  final url = raw.trim();
  if (url.isEmpty) return false;
  if (url.toLowerCase().contains('error.mp4')) return false;
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(url)) return true;
  if (url.toLowerCase().startsWith('file://')) return true;
  return RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(url);
}

/// 是否是「视频网站的网页播放页」而不是媒体直链。
///
/// 蜘蛛（尤其 py / 特供源）经常把 `v.qq.com/x/cover/...html` 这类网页当成
/// `parse=0` 的直链返回；直接交给播放器只会得到 `invalid or unsupported media`。
/// 命中后调用方应改走解析器 / 网页嗅探（`parse=1`）。
bool isLikelyVideoPage(String raw) {
  final url = splitUrlHeadersClean(raw).trim();
  if (url.isEmpty) return false;
  final lower = url.toLowerCase();
  if (!RegExp(r'^https?://').hasMatch(lower)) return false;
  // 带媒体扩展名的仍然是直链（含 query 的 CDN 地址）。
  if (RegExp(r'\.(m3u8|mp4|flv|ts|mkv|webm|mov|avi|mp3|m4a|m4v|mpd)($|\?)')
      .hasMatch(lower)) {
    return false;
  }
  const hosts = <String>[
    'v.qq.com',
    'iqiyi.com',
    'qiyi.com',
    'youku.com',
    'mgtv.com',
    'bilibili.com',
    'sohu.com',
    'le.com',
    'pptv.com',
    '1905.com',
    'wasu.cn',
    'ixigua.com',
    'douyin.com',
    'acfun.cn',
    'tudou.com',
    'ruyi.tv',
    'migu.cn',
  ];
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  for (final h in hosts) {
    if (host == h || host.endsWith('.$h')) return true;
  }
  return false;
}

class PlayResult {
  const PlayResult({
    required this.url,
    this.parse = 0,
    this.playUrl = '',
    this.flag = '',
    this.headers = const {},
    this.message = '',
    this.externalLink = '',
  });

  final String url;
  final int parse;
  final String playUrl;
  final String flag;
  final Map<String, String> headers;
  final String message;
  final String externalLink;

  bool get playable => externalLink.isEmpty && isPlayableMediaUrl(url);

  Map<String, dynamic> toJson() => {
    'url': url,
    'parse': parse,
    'playUrl': playUrl,
    'flag': flag,
    'headers': headers,
    'message': message,
    'externalLink': externalLink,
  };

  factory PlayResult.fromJson(Map<String, dynamic> json) => PlayResult(
    url: (json['url'] ?? '').toString(),
    parse: (json['parse'] as num?)?.toInt() ?? 0,
    playUrl: (json['playUrl'] ?? '').toString(),
    flag: (json['flag'] ?? '').toString(),
    headers: {
      for (final entry in (json['headers'] is Map ? json['headers'] as Map : const {}).entries)
        entry.key.toString(): entry.value.toString(),
    },
    message: (json['message'] ?? '').toString(),
    externalLink: (json['externalLink'] ?? '').toString(),
  );
}

class CmsResult {
  const CmsResult({
    this.classes = const [],
    this.items = const [],
    this.page = 0,
    this.pagecount = 0,
    this.total = 0,
    this.homeFallback = false,
  });

  final List<SortClass> classes;
  final List<VodItem> items;
  final int page;
  final int pagecount;
  final int total;
  final bool homeFallback;
}

class SourceException implements Exception {
  SourceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SearchPerSource {
  const SearchPerSource({
    required this.key,
    required this.name,
    required this.status,
    this.count = 0,
    this.error = '',
    this.ms = 0,
  });
  final String key;
  final String name;
  final String status; // ok / empty / error
  final int count;
  final String error;
  final int ms;
}

class SearchProgress {
  const SearchProgress({
    required this.items,
    required this.perSource,
    required this.done,
    required this.total,
    this.finished = false,
    this.sourceItems = const {},
    this.filterSummary = '',
  });
  final List<VodItem> items;
  final List<SearchPerSource> perSource;
  final int done;
  final int total;
  final bool finished;

  /// 每个源自己的原始结果（未做跨源去重），供「只看某个源」切换。
  final Map<String, List<VodItem>> sourceItems;

  /// 结构化搜索语法的生效摘要（如 `2024 · 电影`）；空串表示没有过滤条件。
  final String filterSummary;
}

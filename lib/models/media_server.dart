/// 媒体服务器类型：Emby 与 Jellyfin 的 API 结构基本一致。
enum MediaServerKind {
  emby('emby', 'Emby'),
  jellyfin('jellyfin', 'Jellyfin');

  const MediaServerKind(this.value, this.label);

  final String value;
  final String label;

  static MediaServerKind fromValue(String value) {
    for (final kind in MediaServerKind.values) {
      if (kind.value == value) return kind;
    }
    return MediaServerKind.jellyfin;
  }
}

/// 已保存的 Emby / Jellyfin 服务器。
class MediaServer {
  const MediaServer({
    required this.id,
    required this.kind,
    required this.name,
    required this.baseUrl,
    this.apiKey = '',
    this.userId = '',
    this.userName = '',
  });

  final String id;
  final MediaServerKind kind;
  final String name;

  /// 服务器地址（如 `http://192.168.1.10:8096`），尾部 `/` 会归一掉。
  final String baseUrl;

  /// API Key（Emby 在「设置 → API 密钥」创建；Jellyfin 在「控制台 → API 密钥」）。
  final String apiKey;

  /// 可选：用户 id。填了才会按用户维度列媒体库与已看进度。
  final String userId;
  final String userName;

  MediaServer copyWith({
    MediaServerKind? kind,
    String? name,
    String? baseUrl,
    String? apiKey,
    String? userId,
    String? userName,
  }) => MediaServer(
    id: id,
    kind: kind ?? this.kind,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    userId: userId ?? this.userId,
    userName: userName ?? this.userName,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.value,
    'name': name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'userId': userId,
    'userName': userName,
  };

  factory MediaServer.fromJson(Map<String, dynamic> json) => MediaServer(
    id: (json['id'] ?? '').toString(),
    kind: MediaServerKind.fromValue((json['kind'] ?? '').toString()),
    name: (json['name'] ?? '').toString(),
    baseUrl: (json['baseUrl'] ?? '').toString(),
    apiKey: (json['apiKey'] ?? '').toString(),
    userId: (json['userId'] ?? '').toString(),
    userName: (json['userName'] ?? '').toString(),
  );
}

/// 一个媒体库（Emby/Jellyfin 的 CollectionFolder / View）。
class MediaLibrary {
  const MediaLibrary({
    required this.id,
    required this.name,
    this.collectionType = '',
  });

  final String id;
  final String name;

  /// `movies` / `tvshows` / `music` …；未知为空串。
  final String collectionType;

  static MediaLibrary fromJson(Map<String, dynamic> json) => MediaLibrary(
    id: (json['Id'] ?? json['id'] ?? '').toString(),
    name: (json['Name'] ?? json['name'] ?? '').toString(),
    collectionType: (json['CollectionType'] ?? json['collectionType'] ?? '')
        .toString(),
  );
}

/// 媒体条目（电影 / 剧集 / 单集）。
class MediaItem {
  const MediaItem({
    required this.id,
    required this.name,
    this.kind = '',
    this.year = 0,
    this.overview = '',
    this.imageTag = '',
    this.seriesId = '',
    this.seriesName = '',
    this.seasonNumber = 0,
    this.episodeNumber = 0,
    this.runTimeMs = 0,
    this.positionMs = 0,
    this.played = false,
  });

  final String id;
  final String name;

  /// `Movie` / `Series` / `Episode` / `Video` …
  final String kind;
  final int year;
  final String overview;

  /// 主图 tag；空 = 没有海报。
  final String imageTag;
  final String seriesId;
  final String seriesName;
  final int seasonNumber;
  final int episodeNumber;
  final int runTimeMs;
  final int positionMs;
  final bool played;

  bool get isSeries => kind == 'Series';
  bool get isPlayable => !isSeries;

  String get subtitle {
    final parts = <String>[];
    if (seasonNumber > 0 || episodeNumber > 0) {
      parts.add('S$seasonNumber E$episodeNumber');
    }
    if (year > 0) parts.add('$year');
    return parts.join(' · ');
  }

  static MediaItem fromJson(Map<String, dynamic> json) {
    final rawUserData = json['UserData'];
    final userData = rawUserData is Map
        ? Map<String, dynamic>.from(rawUserData)
        : const <String, dynamic>{};
    final ticks = (json['RunTimeTicks'] as num?)?.toInt() ?? 0;
    final positionTicks = (userData['PlaybackPositionTicks'] as num?)?.toInt() ?? 0;
    return MediaItem(
      id: (json['Id'] ?? json['id'] ?? '').toString(),
      name: (json['Name'] ?? json['name'] ?? '').toString(),
      kind: (json['Type'] ?? json['type'] ?? '').toString(),
      year: (json['ProductionYear'] as num?)?.toInt() ?? 0,
      overview: (json['Overview'] ?? '').toString(),
      imageTag: rawImageTag(json),
      seriesId: (json['SeriesId'] ?? '').toString(),
      seriesName: (json['SeriesName'] ?? '').toString(),
      seasonNumber: (json['ParentIndexNumber'] as num?)?.toInt() ?? 0,
      episodeNumber: (json['IndexNumber'] as num?)?.toInt() ?? 0,
      runTimeMs: ticks <= 0 ? 0 : ticks ~/ 10000,
      positionMs: positionTicks <= 0 ? 0 : positionTicks ~/ 10000,
      played: userData['Played'] == true,
    );
  }

  /// 从 `ImageTags.Primary` 取主图 tag（没有则空串）。
  static String rawImageTag(Map<String, dynamic> json) {
    final tags = json['ImageTags'];
    if (tags is Map) return (tags['Primary'] ?? '').toString();
    final tag = (json['PrimaryImageTag'] ?? '').toString();
    return tag;
  }
}

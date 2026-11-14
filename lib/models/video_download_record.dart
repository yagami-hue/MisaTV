/// 手动下载的记录：把「下载视频」任务持久化，供下载管理页暂停 / 继续 / 删除。
///
/// 记录只保存下载所需的最小信息；文件本身仍放在边播缓存目录的 `downloads/`。
enum VideoDownloadStatus { downloading, paused, completed, failed, cancelled }

VideoDownloadStatus videoDownloadStatusFromName(String name) {
  for (final value in VideoDownloadStatus.values) {
    if (value.name == name) return value;
  }
  return VideoDownloadStatus.paused;
}

class VideoDownloadRecord {
  VideoDownloadRecord({
    required this.id,
    required this.title,
    required this.url,
    required this.sourceUrl,
    Map<String, String> headers = const {},
    this.provider = '',
    this.hls = false,
    this.directory = '',
    this.filePath = '',
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.completedSegments = 0,
    this.totalSegments = 0,
    this.stage = '准备中…',
    this.status = VideoDownloadStatus.downloading,
    this.error = '',
    this.createdAt = 0,
    this.updatedAt = 0,
  }) : headers = Map<String, String>.from(headers);

  final String id;
  final String title;

  /// 实际下载地址（通常是本地中继的 `/play` 地址）。
  String url;

  /// 原始线路地址，换设备 / 重启后排查用。
  final String sourceUrl;
  final Map<String, String> headers;

  /// 网盘 provider（quark / uc / baidu…），重启后续传时重新包中继要用。
  final String provider;
  final bool hls;
  String directory;

  /// 目标文件路径；直链在开始下载时就确定，`.part` 就放在它旁边。
  String filePath;
  int receivedBytes;
  int totalBytes;
  int completedSegments;
  int totalSegments;
  String stage;
  VideoDownloadStatus status;
  String error;
  final int createdAt;
  int updatedAt;

  bool get active => status == VideoDownloadStatus.downloading;

  /// 可以再次点「继续下载」（失败 / 暂停 / 被取消的任务）。
  bool get canResume =>
      status == VideoDownloadStatus.paused ||
      status == VideoDownloadStatus.failed ||
      status == VideoDownloadStatus.cancelled;

  /// 进度（0–1）；未知时返回 null。
  double? get fraction {
    if (totalBytes > 0) {
      return (receivedBytes / totalBytes).clamp(0.0, 1.0);
    }
    if (totalSegments > 0) {
      return (completedSegments / totalSegments).clamp(0.0, 1.0);
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'sourceUrl': sourceUrl,
    'headers': headers,
    'provider': provider,
    'hls': hls,
    'directory': directory,
    'filePath': filePath,
    'receivedBytes': receivedBytes,
    'totalBytes': totalBytes,
    'completedSegments': completedSegments,
    'totalSegments': totalSegments,
    'stage': stage,
    'status': status.name,
    'error': error,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  static VideoDownloadRecord? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? '').toString().trim();
    final url = (json['url'] ?? '').toString().trim();
    if (id.isEmpty || url.isEmpty) return null;
    final rawHeaders = json['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final key = entry.key.toString();
        final value = entry.value?.toString() ?? '';
        if (key.isNotEmpty && value.isNotEmpty) headers[key] = value;
      }
    }
    int asInt(Object? value) => value is int
        ? value
        : int.tryParse(value?.toString() ?? '') ?? 0;
    return VideoDownloadRecord(
      id: id,
      title: (json['title'] ?? '').toString(),
      url: url,
      sourceUrl: (json['sourceUrl'] ?? '').toString(),
      headers: headers,
      provider: (json['provider'] ?? '').toString(),
      hls: json['hls'] == true,
      directory: (json['directory'] ?? '').toString(),
      filePath: (json['filePath'] ?? '').toString(),
      receivedBytes: asInt(json['receivedBytes']),
      totalBytes: asInt(json['totalBytes']),
      completedSegments: asInt(json['completedSegments']),
      totalSegments: asInt(json['totalSegments']),
      stage: (json['stage'] ?? '').toString(),
      status: videoDownloadStatusFromName(
        (json['status'] ?? '').toString(),
      ),
      error: (json['error'] ?? '').toString(),
      createdAt: asInt(json['createdAt']),
      updatedAt: asInt(json['updatedAt']),
    );
  }
}

/// 下载目录里扫描到的文件（用于管理「只清了记录、文件还在」的情况）。
class LocalDownloadFile {
  const LocalDownloadFile({
    required this.path,
    required this.size,
    required this.modified,
    this.partial = false,
  });

  final String path;
  final int size;
  final DateTime modified;

  /// 未完成的 `.part` 临时文件。
  final bool partial;

  String get name {
    final index = path.lastIndexOf(RegExp(r'[\\/]'));
    return index >= 0 ? path.substring(index + 1) : path;
  }
}

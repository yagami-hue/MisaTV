/// 播放器「下载视频」的进度与命名辅助。
class VideoDownloadProgress {
  const VideoDownloadProgress({
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.completedSegments = 0,
    this.totalSegments = 0,
    this.stage = '准备中…',
    this.done = false,
    this.cancelled = false,
    this.paused = false,
    this.path = '',
    this.error = '',
  });

  final int receivedBytes;

  /// 总字节数；0 = 未知（HLS 分段下载时通常只能按段数估算）。
  final int totalBytes;
  final int completedSegments;
  final int totalSegments;

  /// 面向用户的一行状态（「下载中…」「合并分片…」）。
  final String stage;
  final bool done;
  final bool cancelled;

  /// 用户主动暂停：保留 `.part`，可以再次继续。
  final bool paused;

  /// 完成后的文件绝对路径。
  final String path;

  /// 失败原因（空 = 没有失败）。
  final String error;

  bool get failed => error.isNotEmpty;
  bool get active => !done && !cancelled && !failed && !paused;

  /// 进度（0–1）；未知时返回 null（界面用不确定进度条）。
  double? get fraction {
    if (totalBytes > 0) {
      return (receivedBytes / totalBytes).clamp(0.0, 1.0);
    }
    if (totalSegments > 0) {
      return (completedSegments / totalSegments).clamp(0.0, 1.0);
    }
    return null;
  }

  VideoDownloadProgress copyWith({
    int? receivedBytes,
    int? totalBytes,
    int? completedSegments,
    int? totalSegments,
    String? stage,
    bool? done,
    bool? cancelled,
    bool? paused,
    String? path,
    String? error,
  }) => VideoDownloadProgress(
    receivedBytes: receivedBytes ?? this.receivedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    completedSegments: completedSegments ?? this.completedSegments,
    totalSegments: totalSegments ?? this.totalSegments,
    stage: stage ?? this.stage,
    done: done ?? this.done,
    cancelled: cancelled ?? this.cancelled,
    paused: paused ?? this.paused,
    path: path ?? this.path,
    error: error ?? this.error,
  );
}

/// 是否是 HLS 清单地址（播放前/下载前的快速判断）。
bool looksLikeHlsUrl(String url) {
  final lower = url.toLowerCase();
  return lower.contains('.m3u8') || lower.contains('m3u8');
}

/// 文件名清洗：去掉 Windows 不允许的字符与首尾空白/点号。
String sanitizeDownloadFileName(String raw) {
  var text = raw
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  while (text.endsWith('.') || text.endsWith(' ')) {
    text = text.substring(0, text.length - 1).trimRight();
  }
  if (text.length > 120) text = text.substring(0, 120).trimRight();
  return text.isEmpty ? 'video' : text;
}

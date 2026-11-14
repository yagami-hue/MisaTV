/// 本地媒体库扫描到的视频文件。
class LocalMediaFile {
  const LocalMediaFile({
    required this.path,
    required this.name,
    this.size = 0,
    this.modifiedMs = 0,
    this.subtitle = '',
  });

  /// 绝对路径。
  final String path;

  /// 文件名（含扩展名）。
  final String name;
  final int size;
  final int modifiedMs;

  /// 所属目录（列表分组展示用）。
  final String subtitle;
}

/// 是否像视频文件（与 WebDAV 浏览同口径，多补了几个本地常见容器）。
bool isLocalVideoFile(String path) => RegExp(
  r'\.(mp4|m4v|mkv|avi|mov|webm|ts|m2ts|flv|rmvb|wmv|mpg|mpeg|iso)$',
  caseSensitive: false,
).hasMatch(path.trim());

/// aria2 下载任务（`tellActive` / `tellWaiting` / `tellStopped` 的一行）。
class DownloadTask {
  const DownloadTask({
    required this.gid,
    required this.status,
    this.totalLength = 0,
    this.completedLength = 0,
    this.downloadSpeed = 0,
    this.uploadSpeed = 0,
    this.connections = 0,
    this.seeders = 0,
    this.dir = '',
    this.fileName = '',
    this.errorCode = '',
    this.errorMessage = '',
    this.isTorrent = false,
    this.infoHash = '',
  });

  final String gid;
  final String status;
  final int totalLength;
  final int completedLength;
  final int downloadSpeed;
  final int uploadSpeed;
  final int connections;
  final int seeders;
  final String dir;
  final String fileName;
  final String errorCode;
  final String errorMessage;
  final bool isTorrent;

  /// BT 任务的 infoHash（普通 http 下载为空）；播放器「下载当前视频」据此去重。
  final String infoHash;

  /// 轮询时向 aria2 索取的字段（一次取全，减少往返）。
  static const List<String> statusKeys = [
    'gid',
    'status',
    'totalLength',
    'completedLength',
    'downloadSpeed',
    'uploadSpeed',
    'connections',
    'numSeeders',
    'dir',
    'errorCode',
    'errorMessage',
    'files',
    'bittorrent',
    'infoHash',
  ];

  bool get isActive => status == 'active';
  bool get isWaiting => status == 'waiting';
  bool get isPaused => status == 'paused';
  bool get isComplete => status == 'complete';
  bool get isError => status == 'error';
  bool get isFinished => isComplete || isError || status == 'removed';

  double get progress {
    if (totalLength <= 0) return 0;
    return (completedLength / totalLength).clamp(0.0, 1.0);
  }

  String get statusLabel => switch (status) {
    'active' => '下载中',
    'waiting' => '等待中',
    'paused' => '已暂停',
    'complete' => '已完成',
    'error' => '失败',
    'removed' => '已移除',
    _ => status.isEmpty ? '未知' : status,
  };

  /// 任务标题：BT 用种子名，普通链接用文件名。
  String get title {
    if (fileName.trim().isNotEmpty) {
      final base = fileName.split(RegExp(r'[\\/]')).last.trim();
      if (base.isNotEmpty) return base;
    }
    return isTorrent ? '磁力任务' : gid;
  }

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    final rawFiles = json['files'];
    var fileName = '';
    if (rawFiles is List && rawFiles.isNotEmpty) {
      final first = rawFiles.first;
      if (first is Map) fileName = (first['path'] ?? '').toString();
    }
    final rawBt = json['bittorrent'];
    var torrentName = '';
    if (rawBt is Map) {
      final info = rawBt['info'];
      if (info is Map) torrentName = (info['name'] ?? '').toString();
    }
    if (torrentName.trim().isNotEmpty) fileName = torrentName;
    return DownloadTask(
      gid: (json['gid'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      totalLength: _intOf(json['totalLength']),
      completedLength: _intOf(json['completedLength']),
      downloadSpeed: _intOf(json['downloadSpeed']),
      uploadSpeed: _intOf(json['uploadSpeed']),
      connections: _intOf(json['connections']),
      seeders: _intOf(json['numSeeders']),
      dir: (json['dir'] ?? '').toString(),
      fileName: fileName,
      errorCode: (json['errorCode'] ?? '').toString(),
      errorMessage: (json['errorMessage'] ?? '').toString(),
      isTorrent: rawBt is Map && rawBt.isNotEmpty,
      infoHash: (json['infoHash'] ?? '').toString(),
    );
  }

  static int _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

/// 字节数上屏（`1.2 GB` / `340 MB`）。
String formatDownloadSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100 || unit == 0
      ? value.round().toString()
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

String formatDownloadSpeed(int bytesPerSecond) =>
    '${formatDownloadSize(bytesPerSecond)}/s';

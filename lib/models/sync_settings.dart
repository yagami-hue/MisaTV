import 'dart:math';

/// 多端同步设置：本机设备名、WebDAV 目标、上次同步时间与局域网配对码。
class SyncSettings {
  const SyncSettings({
    this.deviceName = '',
    this.davServerId = '',
    this.remotePath = defaultRemotePath,
    this.lastSyncAt = 0,
    this.lanToken = '',
  });

  /// 远端同步文件的默认路径（相对 WebDAV 服务器基址）。
  static const String defaultRemotePath = '/MisaTV/sync.json';

  /// 本机设备名；空 = 使用系统主机名。
  final String deviceName;

  /// 选中的 WebDAV 服务器 id；空 = 未配置。
  final String davServerId;

  /// 远端同步文件路径（以 `/` 开头）。
  final String remotePath;

  /// 上次成功同步的时间（毫秒时间戳）。
  final int lastSyncAt;

  /// 局域网配对码：同一局域网的设备用它连本机同步服务。
  final String lanToken;

  SyncSettings copyWith({
    String? deviceName,
    String? davServerId,
    String? remotePath,
    int? lastSyncAt,
    String? lanToken,
  }) => SyncSettings(
    deviceName: deviceName ?? this.deviceName,
    davServerId: davServerId ?? this.davServerId,
    remotePath: remotePath ?? this.remotePath,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    lanToken: lanToken ?? this.lanToken,
  );

  Map<String, dynamic> toJson() => {
    'deviceName': deviceName,
    'davServerId': davServerId,
    'remotePath': remotePath,
    'lastSyncAt': lastSyncAt,
    'lanToken': lanToken,
  };

  factory SyncSettings.fromJson(Map<String, dynamic> json) {
    final path = (json['remotePath'] ?? '').toString().trim();
    return SyncSettings(
      deviceName: (json['deviceName'] ?? '').toString(),
      davServerId: (json['davServerId'] ?? '').toString(),
      remotePath: path.isEmpty ? defaultRemotePath : path,
      lastSyncAt: (json['lastSyncAt'] as num?)?.toInt() ?? 0,
      lanToken: (json['lanToken'] ?? '').toString(),
    );
  }

  /// 远端路径归一：补前导 `/`，去尾部 `/`。
  static String normalizeRemotePath(String raw) {
    var path = raw.trim();
    if (path.isEmpty) return defaultRemotePath;
    if (!path.startsWith('/')) path = '/$path';
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }
}

/// 生成局域网配对码（8 位，去掉 0/O/1/I 等易混字符）。
String newSyncPairingToken() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final random = Random.secure();
  return String.fromCharCodes(
    List.generate(8, (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length))),
  );
}

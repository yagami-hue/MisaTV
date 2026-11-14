import 'dart:convert';

/// 应用内代理配置：支持 HTTP 与 SOCKS5 上联。
///
/// 所有客户端（Dart HttpClient / JVM 蜘蛛 / Python 蜘蛛）统一走本机
/// [ProxyBridge] 的 HTTP 代理端口，由桥接层再转给上游 HTTP/SOCKS5，
/// 这样 SOCKS5 和代理认证只需要实现一次。
class ProxyConfig {
  const ProxyConfig({
    this.enabled = false,
    this.followSystem = false,
    this.type = 'http',
    this.host = '',
    this.port = 0,
    this.username = '',
    this.password = '',
  });

  /// 手动启用内置代理；true 时忽略 [followSystem]。
  final bool enabled;

  /// 跟随系统代理（Windows 的「局域网设置」/ 环境变量）。默认关：默认直连，
  /// 需要走系统代理的用户在「网络代理」里手动打开。
  final bool followSystem;

  /// `http` 或 `socks5`。
  final String type;
  final String host;
  final int port;
  final String username;
  final String password;

  bool get isSocks5 => type == 'socks5';

  bool get valid =>
      enabled && host.trim().isNotEmpty && port > 0 && port <= 65535;

  String get typeLabel => isSocks5 ? 'SOCKS5' : 'HTTP';

  String get summary {
    if (valid) {
      return '$typeLabel ${host.trim()}:$port'
          '${username.trim().isEmpty ? '' : '（带认证）'}';
    }
    return followSystem ? '跟随系统代理' : '直连';
  }

  ProxyConfig copyWith({
    bool? enabled,
    bool? followSystem,
    String? type,
    String? host,
    int? port,
    String? username,
    String? password,
  }) {
    return ProxyConfig(
      enabled: enabled ?? this.enabled,
      followSystem: followSystem ?? this.followSystem,
      type: type ?? this.type,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'followSystem': followSystem,
    'type': type,
    'host': host,
    'port': port,
    'username': username,
    'password': password,
  };

  factory ProxyConfig.fromJson(Map<String, Object?> json) {
    final rawPort = json['port'];
    final port = rawPort is num
        ? rawPort.toInt()
        : int.tryParse(rawPort?.toString() ?? '') ?? 0;
    final type = (json['type'] ?? 'http').toString().toLowerCase();
    return ProxyConfig(
      enabled: json['enabled'] == true,
      // 老配置没有这个键：按「直连」处理（新的默认行为）。
      followSystem: json['followSystem'] is bool
          ? json['followSystem'] == true
          : false,
      type: type == 'socks5' ? 'socks5' : 'http',
      host: (json['host'] ?? '').toString().trim(),
      port: port,
      username: (json['username'] ?? '').toString(),
      password: (json['password'] ?? '').toString(),
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory ProxyConfig.fromJsonString(String raw) {
    if (raw.trim().isEmpty) return const ProxyConfig();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return ProxyConfig.fromJson(Map<String, Object?>.from(decoded));
      }
    } catch (_) {}
    return const ProxyConfig();
  }

  @override
  bool operator ==(Object other) {
    return other is ProxyConfig &&
        other.enabled == enabled &&
        other.followSystem == followSystem &&
        other.type == type &&
        other.host == host &&
        other.port == port &&
        other.username == username &&
        other.password == password;
  }

  @override
  int get hashCode =>
      Object.hash(enabled, followSystem, type, host, port, username, password);
}

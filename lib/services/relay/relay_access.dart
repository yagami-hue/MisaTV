// 本机中继的访问控制与 SSRF 防护（纯逻辑，无 IO 依赖，便于单测）。

/// 中继监听在 127.0.0.1，但「本机」不等于「可信」：
///   · 任意网页的 JS 都能向 127.0.0.1 发请求（CORS 只能挡住读取响应）；
///   · DNS rebinding 还能把攻击者域名解析到 127.0.0.1，绕过「Origin == Host」判断；
///   · `/play`、`/img`、`/proxy` 会代取任意 URL，属于可被利用的 SSRF 入口。
///
/// 这里维护两条与 IO 无关的判定：
///   1. 浏览器发起的请求必须带本进程随机生成的访问令牌（[tokenMatches]）；
///   2. 已授权的浏览器请求仍不允许访问回环 / 内网 / 链路本地地址。
/// 原生播放器（fvp/libmdk、外部播放器、壳内 JVM）不发 `Origin`/`Sec-Fetch-*`，
/// 不受令牌限制，也不会被私网规则误伤（局域网 WebDAV / NAS 仍可正常播放）。
class RelayAccessPolicy {
  const RelayAccessPolicy._();

  /// 是否是浏览器发起的请求：浏览器会带上 `Origin` 或 `Sec-Fetch-*`。
  ///
  /// 原生 HTTP 客户端（Dart `HttpClient`、OkHttp、FFmpeg）不会带这些头；
  /// 顶栏直接输入地址导航时没有 `Origin`，但也一定有 `Sec-Fetch-Site`。
  static bool isBrowserRequest({
    String? origin,
    String? secFetchSite,
    String? secFetchMode,
  }) {
    return (origin?.trim().isNotEmpty ?? false) ||
        (secFetchSite?.trim().isNotEmpty ?? false) ||
        (secFetchMode?.trim().isNotEmpty ?? false);
  }

  /// 常量时间比较令牌，避免通过响应时间逐字符猜出令牌。
  static bool tokenMatches(String expected, String? provided) {
    final want = expected.trim();
    final got = provided?.trim() ?? '';
    if (want.isEmpty || got.length != want.length) return false;
    var diff = 0;
    for (var i = 0; i < want.length; i++) {
      diff |= want.codeUnitAt(i) ^ got.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// 目标地址是否指向本机 / 内网 / 链路本地（含 IPv4 简写与 IPv4-mapped IPv6）。
  static bool isPrivateTarget(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    return isPrivateHost(uri.host);
  }

  static bool isPrivateHost(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    if (host.isEmpty) return true;
    // 去掉 IPv6 的方括号（Uri.host 一般不带，手动传入时可能有）。
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.endsWith('.home.arpa')) {
      return true;
    }
    if (host.contains(':')) return _isPrivateIpv6(host);
    final ipv4 = _parseIpv4(host);
    return ipv4 != null && _isPrivateIpv4(ipv4);
  }

  static bool _isPrivateIpv6(String host) {
    final addr = host.split('%').first;
    if (addr == '::' || addr == '::1') return true;
    // IPv4-mapped / IPv4-compatible：::ffff:127.0.0.1
    final lastColon = addr.lastIndexOf(':');
    if (lastColon >= 0 && addr.substring(0, lastColon).endsWith('::ffff')) {
      final mapped = _parseIpv4(addr.substring(lastColon + 1));
      if (mapped != null) return _isPrivateIpv4(mapped);
    }
    final first = addr.split(':').first;
    if (first.isEmpty) return true;
    // fc00::/7（唯一本地地址）与 fe80::/10（链路本地）。
    if (first.startsWith('fc') || first.startsWith('fd')) return true;
    if (RegExp(r'^fe[89ab]').hasMatch(first)) return true;
    return false;
  }

  /// 兼容浏览器的 IPv4 写法：`127.0.0.1`、`127.1`、`2130706433`。
  static int? _parseIpv4(String host) {
    final parts = host.split('.');
    if (parts.isEmpty || parts.length > 4) return null;
    final nums = <int>[];
    for (final part in parts) {
      if (part.isEmpty || part.length > 10) return null;
      final value = int.tryParse(part);
      if (value == null || value < 0) return null;
      nums.add(value);
    }
    if (nums.length == 1) {
      return nums[0] <= 0xFFFFFFFF ? nums[0] : null;
    }
    final maxLast = nums.length == 2
        ? 0xFFFFFF
        : (nums.length == 3 ? 0xFFFF : 0xFF);
    for (var i = 0; i < nums.length - 1; i++) {
      if (nums[i] > 0xFF) return null;
    }
    if (nums.last > maxLast) return null;
    return switch (nums.length) {
      2 => (nums[0] << 24) | nums[1],
      3 => (nums[0] << 24) | (nums[1] << 16) | nums[2],
      _ => (nums[0] << 24) | (nums[1] << 16) | (nums[2] << 8) | nums[3],
    };
  }

  static bool _isPrivateIpv4(int value) {
    final a = (value >> 24) & 0xFF;
    final b = (value >> 16) & 0xFF;
    if (a == 0 || a == 10 || a == 127) return true;
    if (a == 169 && b == 254) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT
    if (a == 198 && (b == 18 || b == 19)) return true;
    if (a >= 224) return true; // 组播 / 保留段
    return false;
  }
}

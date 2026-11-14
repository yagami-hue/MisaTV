// 本机中继的跨站访问控制（纯逻辑，无 IO 依赖，便于单测）。
//
// 中继监听 127.0.0.1，原本对任何 Origin 都放宽 CORS。这留下一个真实风险：
// 用户用内置浏览器 / 外置浏览器打开任意网页时，该页面的 JS 可以向
// `http://127.0.0.1:9978` 发请求，读走：
//   · `/file/...` 与 `/pkg/...` 下应用数据目录里的文件（网盘 Cookie 落盘文件在内）；
//   · `/proxy?do=…` 的通用转发（借助中继的代理与凭据代取任意地址）。
// 浏览器同源策略在不放宽 CORS 时就足以挡住这两类读取，所以这里只收紧
// 「浏览器发起的跨站请求」，不影响本机原生客户端。
//
// 判定只用请求头，不涉及权限模型：
//   · 没有 `Origin`：原生播放器（fvp -> libmdk/FFmpeg）、外部播放器、壳内 JVM
//     发出的请求都不带 Origin，一律放行；
//   · `Origin` 与 `Host` 同源：允许（含中继自己的 Web 版界面与同源页面）；
//   · `Sec-Fetch-Site: cross-site`：浏览器明确告知跨站，直接拒绝；
//   · 其余带 Origin 的跨站请求：只放行 `/play`、`/img`、`/bt` 这三个「只能代取
//     媒体」的路由，且仍然逐条按来源回写 CORS 头。
enum RelayOriginVerdict {
  /// 没有 Origin（原生客户端），或同源：正常处理。
  allow,

  /// 浏览器跨站访问了敏感路由（`/file`、`/pkg`、`/proxy` 等）：拒绝。
  crossSiteDenied,

  /// 浏览器跨站但目标是媒体路由：放行，但只回写该 Origin 的 CORS 头。
  crossSiteMedia,
}

/// 跨站也允许访问的路由：都是「由中继代取远端资源」的媒体通道。
/// 它们不读本地文件，也不会把凭据交给调用方（`/play` 只回媒体字节）。
const Set<String> relayCorsMediaPaths = {'/play', '/img'};

/// 只有这些方法需要 CORS 预检；其余方法不发 `Access-Control-Allow-*`。
const String kRelayAllowMethods = 'GET,HEAD,OPTIONS';

class RelayOriginPolicy {
  const RelayOriginPolicy._();

  static bool isMediaPath(String path) =>
      relayCorsMediaPaths.contains(path) || path.startsWith('/bt/');

  /// 取 `Origin` 头的 scheme://host[:port] 小写形式；`null` 表示不存在或不可解析。
  static String? normalizeOrigin(String? origin) {
    final raw = origin?.trim() ?? '';
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    // `Origin: null`（沙箱 iframe / file:// 页面）解析不出 host，落到这里返回 null，
    // 由调用方按「无来源」处理并拒绝敏感路由。
    final port = uri.hasPort ? uri.port : (scheme == 'https' ? 443 : 80);
    return '$scheme://${uri.host.toLowerCase()}:$port';
  }

  /// `Host` 头（如 `127.0.0.1:9978`）归一成与 [normalizeOrigin] 同形的字符串。
  static String? normalizeHost(String? host) {
    final raw = host?.trim() ?? '';
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse('http://$raw');
    if (uri == null || uri.host.isEmpty) return null;
    final port = uri.hasPort ? uri.port : 80;
    return 'http://${uri.host.toLowerCase()}:$port';
  }

  /// 判定一次请求的跨站身份。
  static RelayOriginVerdict evaluate({
    required String path,
    String? origin,
    String? host,
    String? secFetchSite,
  }) {
    final self = normalizeOrigin(origin);
    if (self == null) {
      // 完全没有 Origin：原生客户端。`Origin: null` 视作跨站，但仍按路由分级。
      final rawOrigin = origin?.trim() ?? '';
      if (rawOrigin.isEmpty) return RelayOriginVerdict.allow;
      return isMediaPath(path)
          ? RelayOriginVerdict.crossSiteMedia
          : RelayOriginVerdict.crossSiteDenied;
    }
    final expected = normalizeHost(host);
    if (expected != null && self == expected) {
      return RelayOriginVerdict.allow;
    }
    // 浏览器显式声明跨站时最可信，直接按路由分级，不再猜同源。
    final site = secFetchSite?.trim().toLowerCase() ?? '';
    if (site == 'cross-site') {
      return isMediaPath(path)
          ? RelayOriginVerdict.crossSiteMedia
          : RelayOriginVerdict.crossSiteDenied;
    }
    return isMediaPath(path)
        ? RelayOriginVerdict.crossSiteMedia
        : RelayOriginVerdict.crossSiteDenied;
  }
}

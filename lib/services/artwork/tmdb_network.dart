/// TMDB 域名在网络层被「DNS 污染」时的诊断工具。
///
/// 实测（2026-11，中国大陆常见网络）：`api.themoviedb.org` 会被解析到 Facebook 的
/// 网段（`157.240.x.x`、`69.63.x.x`、`2a03:2880::/32`）或内网/保留地址，
/// 连过去自然握手超时——报「网络请求失败」但看日志只有 TimeoutException。
/// 这里只做纯判断与文案，真正的解析/请求在调用方做。
library;

/// 疑似被污染 / 明显不可用的地址。
bool looksLikePoisonedAddress(String address) {
  final ip = address.trim().toLowerCase();
  if (ip.isEmpty) return false;
  // 保留 / 本机 / 链路本地 / 测试网段：不可能承载 TMDB。
  if (ip == '0.0.0.0' || ip == '::' || ip == '::1') return true;
  if (ip.startsWith('127.') || ip.startsWith('10.')) return true;
  if (ip.startsWith('192.168.') || ip.startsWith('169.254.')) return true;
  if (ip.startsWith('198.18.') || ip.startsWith('198.19.')) return true;
  // Facebook 网段：GB 级 DNS 污染的典型返回。
  if (ip.startsWith('157.240.')) return true;
  if (RegExp(r'^69\.63\.').hasMatch(ip)) return true;
  if (RegExp(r'^2a03:2880:').hasMatch(ip)) return true;
  if (ip.startsWith('31.13.')) return true;
  return false;
}

/// 给用户看的一句话诊断。
///
/// [addresses] 是直连解析到的地址；[proxyActive] 表示当前是否已经在走代理。
String describeTmdbDns({
  required List<String> addresses,
  required bool proxyActive,
}) {
  if (proxyActive) {
    return '当前已走代理，域名由代理远端解析。';
  }
  final usable = addresses.where((a) => !looksLikePoisonedAddress(a)).toList();
  if (addresses.isEmpty) {
    return '解析不到 api.themoviedb.org 的任何地址：当前网络 DNS 有问题，改用代理即可绕过。';
  }
  if (usable.isEmpty) {
    return '当前网络把 api.themoviedb.org 解析到 ${addresses.take(2).join('、')}（Facebook/保留地址，典型 DNS 污染），'
        '直连必然超时。请在 Clash / v2rayN 打开「系统代理」后到 设置 → 播放 → 网络代理 开启「跟随系统代理」，'
        '或直接填写手动代理端口。';
  }
  return '解析到 ${usable.take(2).join('、')}，域名本身没被污染；若仍超时请检查代理是否在运行。';
}

/// 网盘手动 Cookie 输入的清洗与校验（纯函数，便于测试）。
library;

import 'dart:convert';
/// 各网盘视为「登录态」的 Cookie 名；命中任意一个即可。
const Map<String, List<String>> driveAuthCookieNames = {
  'quark': ['__puus', '__pus', '__puuk', '__pusd'],
  'uc': ['PUVID', '__puus', '__pus', 'drive_uc'],
  'baidu': ['BDUSS'],
  // 115 的网盘接口靠 UID + CID + SEID 三件套鉴权，任一缺失都会被判未登录。
  '115': ['UID', 'CID', 'SEID'],
  // 哔哩哔哩只认 SESSDATA；没有它也能播 360P / 480P，有它才能拿高清与大会员画质。
  'bili': ['SESSDATA'],
};

/// Cookie 应该来自的域名，用于输入提示。
const Map<String, String> driveCookieDomains = {
  'quark': 'pan.quark.cn',
  'uc': 'drive.uc.cn',
  'baidu': 'pan.baidu.com',
  '115': '115.com',
  'bili': 'bilibili.com',
  'thunder': 'pan.xunlei.com',
  'guangya': 'guangyapan.com',
};

/// 除登录态字段外还必须齐全的 Cookie（缺了会被服务端判成半个会话）。
///
/// 115 是「三件套」：只有 UID 没有 CID / SEID 时 `api.115.com` 直接回
/// 「登录失败」，蜘蛛侧表现为播放地址为空。
const Map<String, List<String>> driveRequiredCookieNames = {
  '115': ['UID', 'CID', 'SEID'],
};
bool isTokenDriveProvider(String provider) =>
    provider == 'thunder' || provider == 'guangya';

String normalizeDriveTokenInput(String raw) {
  var value = raw.trim();
  if ((value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))) {
    if (value.length >= 2) {
      value = value.substring(1, value.length - 1).trim();
    }
  }
  if (value.toLowerCase().startsWith('bearer ')) {
    value = value.substring(7).trim();
  }
  if (value.startsWith('{') && value.endsWith('}')) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        final candidates = [
          decoded['refresh_token'],
          decoded['refreshToken'],
          decoded['access_token'],
          decoded['accessToken'],
          decoded['token'],
        ];
        for (final c in candidates) {
          if (c is String && c.trim().isNotEmpty) {
            return c.trim();
          }
        }
      }
    } catch (_) {}
  }
  return value;
}

/// 该 Cookie 是否已具备完整会话（登录态字段 + 必需字段）。
bool driveCookieIsComplete(String provider, String cookie) {
  if (isTokenDriveProvider(provider)) return cookie.trim().isNotEmpty;
  if (!driveCookieHasAuth(provider, cookie)) return false;
  final required = driveRequiredCookieNames[provider] ?? const [];
  if (required.isEmpty) return true;
  final names = driveCookieNames(cookie);
  return required.every(names.contains);
}

const Set<String> _cookieAttributes = {
  'path',
  'domain',
  'expires',
  'max-age',
  'secure',
  'httponly',
  'samesite',
  'priority',
  'partitioned',
};

/// 把用户粘贴的内容清洗成 `a=b; c=d`。
///
/// 支持：
///   · 请求头里的原始 Cookie 串；
///   · 带 `Cookie:` 前缀的整段请求头；
///   · 从 cURL 里复制的 `-H 'Cookie: ...'`（只取 Cookie 这一段）；
///   · 每行一个 `a=b` 的列表；
///   · `Set-Cookie` 形式（会丢掉 Path / Domain / Expires 等属性）。
String normalizeDriveCookieInput(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  final prefix = text.toLowerCase().indexOf('cookie:');
  if (prefix >= 0) text = text.substring(prefix + 7);
  // cURL 里 Cookie 值后面通常跟着引号，取到引号之前即可。
  final quote = text.indexOf(RegExp("['\"]"));
  if (quote >= 0) text = text.substring(0, quote);
  text = text
      .replaceAll('\\\r\n', ' ')
      .replaceAll('\\\n', ' ')
      .replaceAll('\r', '\n');
  final jar = <String, String>{};
  for (final part in text.split(RegExp(r'[;\n]'))) {
    final segment = part.trim();
    if (segment.isEmpty) continue;
    final eq = segment.indexOf('=');
    if (eq <= 0) continue;
    final name = segment.substring(0, eq).trim();
    final value = segment.substring(eq + 1).trim();
    if (name.isEmpty || value.isEmpty) continue;
    if (name.contains(RegExp(r'[=;,\s]'))) continue;
    if (_cookieAttributes.contains(name.toLowerCase())) continue;
    jar[name] = value;
  }
  return jar.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
}

/// 已清洗 Cookie 里出现的字段名。
Set<String> driveCookieNames(String cookie) {
  final names = <String>{};
  for (final part in cookie.split(';')) {
    final segment = part.trim();
    final eq = segment.indexOf('=');
    if (eq <= 0) continue;
    names.add(segment.substring(0, eq).trim());
  }
  return names;
}

/// 是否包含该网盘的登录态字段（只做粗筛，最终以在线校验为准）。
bool driveCookieHasAuth(String provider, String cookie) {
  if (isTokenDriveProvider(provider)) return cookie.trim().isNotEmpty;
  final required = driveAuthCookieNames[provider] ?? const [];
  if (required.isEmpty) return cookie.trim().isNotEmpty;
  final names = driveCookieNames(cookie);
  return required.any(names.contains);
}

/// 缺少登录态字段时给用户看的提示。
String driveCookieMissingHint(String provider) {
  if (isTokenDriveProvider(provider)) return 'Token 为空';
  final names = driveAuthCookieNames[provider] ?? const [];
  if (names.isEmpty) return 'Cookie 为空';
  final required = driveRequiredCookieNames[provider] ?? const [];
  if (required.length > 1) {
    return 'Cookie 里没有找到完整的登录态字段（需要同时包含 '
        '${required.join(' / ')}），请确认复制的是已登录状态下的完整 Cookie';
  }
  return 'Cookie 里没有找到登录态字段（${names.join(' / ')}），'
      '请确认复制的是已登录状态下的完整 Cookie';
}

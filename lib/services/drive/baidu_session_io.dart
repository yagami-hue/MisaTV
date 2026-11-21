import 'dart:convert';
import 'dart:io';

import 'quark_session_io.dart'
    show QuarkSessionResult, mergeSetCookies, sanitizeCookie;

const _baiduUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.6478.61 Safari/537.36';
const _baiduReferer = 'https://pan.baidu.com/';
const _baiduTokenUrl =
    'https://pan.baidu.com/api/gettemplatevariable'
    '?fields=%5B%22bdstoken%22%2C%22uk%22%5D&channel=chunlei&web=1&app_id=250528'
    '&clienttype=0';

/// 探测百度登录态并吸收响应里的新 Cookie（不写盘，调用方决定是否保存）。
///
/// 只有 BDUSS 没有 pan 域 STOKEN 的「半个会话」会在 playerContent 里报
/// `JsonObject.get(...) is null` / errno -6；`/api/gettemplatevariable`
/// 返回 errno -6 即未登录。
Future<QuarkSessionResult> refreshBaiduSession(String cookie) async {
  final original = cookie.trim();
  if (original.isEmpty) {
    return const QuarkSessionResult(cookie: '', changed: false, valid: null);
  }
  final base = sanitizeCookie(original);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final request = await client.getUrl(Uri.parse(_baiduTokenUrl));
    request.headers
      ..set(HttpHeaders.userAgentHeader, _baiduUa)
      ..set(HttpHeaders.refererHeader, _baiduReferer)
      ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*')
      ..set(HttpHeaders.cookieHeader, base);
    final response = await request.close().timeout(const Duration(seconds: 15));
    final body = await response.transform(utf8.decoder).join();
    final setCookies = <String>[];
    response.headers.forEach((name, values) {
      if (name.toLowerCase() == 'set-cookie') setCookies.addAll(values);
    });

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // 非 JSON（网关错误页）→ 状态未知
    }
    final errno = (json?['errno'] as num?)?.toInt();
    final valid = response.statusCode == 200 && errno == 0;
    // -6 = 未登录 / 会话失效；其它负值是接口临时错误，不能误判成游客态。
    final guest = errno == -6;
    final merged = mergeSetCookies(base, setCookies);
    final resMap = json?['result'];
    final uk = resMap is Map ? '${resMap['uk'] ?? ''}'.trim() : '';
    return QuarkSessionResult(
      cookie: merged,
      changed: merged != original,
      valid: valid ? true : (guest ? false : null),
      userId: uk,
    );
  } catch (_) {
    return QuarkSessionResult(cookie: original, changed: false, valid: null);
  } finally {
    client.close(force: true);
  }
}

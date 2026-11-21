import 'dart:convert';
import 'dart:io';

/// 夸克会话探测 / 刷新结果。
///
/// [valid]：
///   · true  = `/member` 返回 code 0，确认是登录态；
///   · false = 明确是访客（`require login [guest]` / 31001）；
///   · null  = 网络异常，无法判断（调用方应保持原状，不能误判成登出）。
class QuarkSessionResult {
  const QuarkSessionResult({
    required this.cookie,
    required this.changed,
    this.valid,
    this.userId = '',
  });

  final String cookie;
  final bool changed;
  final bool? valid;
  final String userId;
}

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 '
    'Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';
const _referer = 'https://pan.quark.cn/';
const _memberUrl = 'https://drive-pc.quark.cn/1/clouddrive/member'
    '?pr=ucpro&fr=pc&uc_param_str=&fetch_subscribe=true&_ch=home&fetch_identity=true';

/// 清掉历史版本合并出错留下的坏键（键名带 `$`，如 `$1__puus`）：
/// 这类键不会被服务端识别，还会让同名 `Set-Cookie` 永远命中不到、吞掉新的 `__puus`。
String sanitizeCookie(String cookie) => cookie
    .split(';')
    .map((seg) => seg.trim())
    .where((seg) {
      final eq = seg.indexOf('=');
      if (eq <= 0) return false;
      return !seg.substring(0, eq).contains(r'$');
    })
    .join('; ');

/// 上游 `Set-Cookie` 合并进账号 Cookie（同名覆盖、新键追加），对齐 winbox 的
/// `mergeSetCookies`：夸克常在校验/下载响应里下发新的 `__puus`，不合并就会一直用旧值。
String mergeSetCookies(String base, Iterable<String> setCookies) {
  var out = base.trim();
  for (final line in setCookies) {
    final pair = line.split(';').first.trim();
    final eq = pair.indexOf('=');
    if (eq <= 0) continue;
    final key = pair.substring(0, eq).trim();
    if (key.isEmpty) continue;
    final value = pair.substring(eq + 1).trim();
    final reg = RegExp(
      '(^|;\\s*)${RegExp.escape(key)}=[^;]*',
      caseSensitive: false,
    );
    // Dart 的 replaceFirst 不解析 `$1`（会按字面量插入），必须用映射版取分组。
    out = reg.hasMatch(out)
        ? out.replaceFirstMapped(reg, (m) => '${m.group(1) ?? ''}$key=$value')
        : (out.isEmpty ? '$key=$value' : '$out; $key=$value');
  }
  return out;
}

/// 探测夸克登录态并吸收响应里的新 `__puus`（不写盘，调用方决定是否保存）。
Future<QuarkSessionResult> refreshQuarkSession(String cookie) async {
  final original = cookie.trim();
  if (original.isEmpty) {
    return const QuarkSessionResult(cookie: '', changed: false, valid: null);
  }
  // 先修掉历史坏键，再合并新 Set-Cookie（否则同名替换永远命不中）。
  final base = sanitizeCookie(original);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final request = await client.getUrl(Uri.parse(_memberUrl));
    request.headers
      ..set(HttpHeaders.userAgentHeader, _ua)
      ..set(HttpHeaders.refererHeader, _referer)
      ..set('Origin', 'https://pan.quark.cn')
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
    final code = json?['code'];
    final valid = response.statusCode == 200 && code == 0;
    final guest = response.statusCode == 401 || code == 31001;
    final merged = mergeSetCookies(base, setCookies);
    return QuarkSessionResult(
      cookie: merged,
      changed: merged != original,
      valid: valid ? true : (guest ? false : null),
    );
  } catch (_) {
    return QuarkSessionResult(cookie: original, changed: false, valid: null);
  } finally {
    client.close(force: true);
  }
}

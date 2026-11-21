/// Web 预览版不做夸克会话探测：视为「状态未知」，保留原 Cookie。
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

String mergeSetCookies(String base, Iterable<String> setCookies) => base;

Future<QuarkSessionResult> refreshQuarkSession(String cookie) async {
  return QuarkSessionResult(cookie: cookie, changed: false, valid: null);
}

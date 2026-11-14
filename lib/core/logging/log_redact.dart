/// 日志脱敏：只保留 URL 的协议 / 主机 / 路径与查询参数**键名**，不写值。
///
/// 网盘直链、m3u8、解析接口的 query 里常带 token / auth_key / Cookie，
/// 原样落盘会把登录态写进日志，排查时也不该把这些外传。
String redactUrl(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return '';
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(text)) {
    return shorten(text, 240);
  }
  try {
    final uri = Uri.parse(text);
    final port = uri.hasPort ? ':${uri.port}' : '';
    final keys = uri.queryParameters.keys.where((k) => k.isNotEmpty).toList();
    final query = keys.isEmpty ? '' : '?<${keys.join(',')}>';
    return '${uri.scheme}://${uri.host}$port${uri.path}$query';
  } catch (_) {
    return shorten(text, 240);
  }
}

/// 把文本里 URL 的 query **值**打码，只留键名。
///
/// 异常字符串常带完整地址（`ClientException ... uri=https://api.themoviedb.org/3/?api_key=…`），
/// 原样进日志和界面提示就等于把 Key 写进磁盘，这里统一遮掉。
String redactQueryValues(String text) => text.replaceAllMapped(
  RegExp(r'([?&][A-Za-z0-9_.\-]+=)[^&\s)"\]]+'),
  (m) => '${m.group(1)}<hidden>',
);

/// 截断过长文本（堆栈 / 蜘蛛返回的原文）。
String shorten(String text, [int max = 400]) {
  final value = text.trim();
  if (value.length <= max) return value;
  return '${value.substring(0, max)}…';
}

/// 只保留异常类型 + 首行信息，避免把整段堆栈塞进单行消息。
///
/// 异常文本经常带完整请求地址（`ClientException ... uri=https://x/?api_key=…`），
/// 这里同时把 query 值打码，保证所有落盘入口都拿不到明文凭据。
String errorBrief(Object? error) {
  if (error == null) return '';
  final text = redactQueryValues(
    error.toString().replaceAll('\n', ' ').trim(),
  );
  return shorten(text, 300);
}

import 'dart:async';

/// 面向用户的统一错误分类。
///
/// 各服务层原本把 `SocketException` / `TimeoutException` / `HandshakeException`
/// 的英文原文直接透到界面，用户只能看到一串技术细节、也不知道下一步做什么。
/// 这里按异常文本归纳成少数几类，统一给出「结论 + 下一步」。
///
/// 只做文本判定，不改变调用链；判断不出来时退回 [AppErrorKind.unknown]。
enum AppErrorKind {
  network,
  timeout,
  tls,
  auth,
  notFound,
  rateLimited,
  server,
  httpStatus,
  format,
  cancelled,
  unknown,
}

class AppErrorInfo {
  const AppErrorInfo({
    required this.kind,
    required this.title,
    required this.hint,
    this.retryable = true,
  });

  final AppErrorKind kind;
  final String title;
  final String hint;
  final bool retryable;

  /// 给界面用的一行文案。
  String get message => hint.isEmpty ? title : '$title（$hint）';
}

/// 把任意异常归到一个用户能理解的类别。
///
/// [statusCode] 已知时优先按状态码判断；否则读取异常文本里的关键字。
AppErrorInfo describeAppError(Object? error, {int? statusCode}) {
  if (statusCode != null) return _fromStatus(statusCode);
  final text = error?.toString() ?? '';
  final lower = text.toLowerCase();
  final httpCode = RegExp(r'http\s*(\d{3})').firstMatch(lower);
  if (httpCode != null) {
    final code = int.tryParse(httpCode.group(1) ?? '');
    if (code != null) return _fromStatus(code);
  }
  if (text.isEmpty) {
    return const AppErrorInfo(
      kind: AppErrorKind.unknown,
      title: '请求失败',
      hint: '可到设置 → 运行日志查看详情',
      retryable: false,
    );
  }
  if (error is TimeoutException ||
      lower.contains('timeout') ||
      lower.contains('timed out') ||
      lower.contains('超时')) {
    return const AppErrorInfo(
      kind: AppErrorKind.timeout,
      title: '请求超时',
      hint: '检查网络或代理后重试',
    );
  }
  if (lower.contains('handshake') ||
      lower.contains('certificate') ||
      lower.contains('tls') ||
      lower.contains('证书')) {
    return const AppErrorInfo(
      kind: AppErrorKind.tls,
      title: '证书校验失败',
      hint: '检查系统时间、代理证书或更换网络',
    );
  }
  if (lower.contains('socketexception') ||
      lower.contains('connection refused') ||
      lower.contains('connection reset') ||
      lower.contains('connection closed') ||
      lower.contains('failed host lookup') ||
      lower.contains('network is unreachable') ||
      lower.contains('网络请求失败') ||
      lower.contains('网络连接失败')) {
    return const AppErrorInfo(
      kind: AppErrorKind.network,
      title: '网络请求失败',
      hint: '检查网络与代理设置后重试',
    );
  }
  if (lower.contains('formatexception') ||
      lower.contains('unexpected character') ||
      lower.contains('json 解析')) {
    return const AppErrorInfo(
      kind: AppErrorKind.format,
      title: '返回内容格式不正确',
      hint: '可能是源站变更或网络劫持，换源或稍后重试',
    );
  }
  if (lower.contains('cancel') || text.contains('取消')) {
    return const AppErrorInfo(
      kind: AppErrorKind.cancelled,
      title: '已取消',
      hint: '',
      retryable: false,
    );
  }
  return const AppErrorInfo(
    kind: AppErrorKind.unknown,
    title: '请求失败',
    hint: '可到设置 → 运行日志查看详情',
  );
}

AppErrorInfo _fromStatus(int code) {
  if (code == 401 || code == 403) {
    return const AppErrorInfo(
      kind: AppErrorKind.auth,
      title: '需要登录或权限不足',
      hint: '更新网盘 / 站点凭据后重试',
    );
  }
  if (code == 404) {
    return const AppErrorInfo(
      kind: AppErrorKind.notFound,
      title: '资源不存在（HTTP 404）',
      hint: '源站可能已删除该内容，换源试试',
    );
  }
  if (code == 429) {
    return const AppErrorInfo(
      kind: AppErrorKind.rateLimited,
      title: '请求过于频繁（HTTP 429）',
      hint: '稍等一会儿再试',
    );
  }
  if (code >= 500) {
    return AppErrorInfo(
      kind: AppErrorKind.server,
      title: '站点服务异常（HTTP $code）',
      hint: '稍后重试或换源',
    );
  }
  return AppErrorInfo(
    kind: AppErrorKind.httpStatus,
    title: '请求失败（HTTP $code）',
    hint: '稍后重试或换源',
  );
}

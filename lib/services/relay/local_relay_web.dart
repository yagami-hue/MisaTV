/// Web 预览版没有本地 HTTP 服务；播放继续用原地址直连。
class LocalRelay {
  LocalRelay._();
  static final LocalRelay instance = LocalRelay._();

  bool get running => false;
  int get port => 0;
  String get baseUrl => '';

  Future<void> start({
    required String fileRoot,
    required Map<String, String> Function() driveTokens,
    required List<dynamic> Function() rules,
    required bool Function() purifyEnabled,
    String Function(String id)? davAuth,
    dynamic btSource,
    int Function()? jvmProxyPort,
    String Function()? cacheDir,
    bool Function()? cacheEnabled,
    int Function()? cacheLimitMb,
  }) async {}

  Future<void> stop() async {}

  Future<int> streamCacheBytes() async => 0;

  Future<int> streamCacheEntryCount() async => 0;

  String get streamCacheDir => '';

  Future<void> clearStreamCache() async {}

  void clearPlaySession([String? provider]) {}

  String playUrl(
    String url, {
    Map<String, String> headers = const {},
    String provider = '',
  }) => url;
}

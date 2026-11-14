import 'update_service.dart';

class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();
  @override
  String toString() => '已取消下载';
}

/// Web 版不支持应用内更新下载（浏览器无法替换正在运行的前端资源）。
class UpdateDownloader {
  static Future<String> download(
    AppRelease release, {
    required void Function(int received, int total) onProgress,
    bool Function()? isCancelled,
  }) {
    throw UnsupportedError('Web 版请通过 Release 页面下载新版本');
  }

  static Future<void> revealDownload(String path) async {}
}

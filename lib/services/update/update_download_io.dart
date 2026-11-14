import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import 'update_service.dart';

class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();
  @override
  String toString() => '已取消下载';
}

/// 应用内更新下载：支持断点续传、大小与 SHA-256 校验。
class UpdateDownloader {
  static Future<String> download(
    AppRelease release, {
    required void Function(int received, int total) onProgress,
    bool Function()? isCancelled,
  }) async {
    final url = release.downloadUrl.trim();
    if (url.isEmpty) throw StateError('该版本没有可直下的安装包');
    final dir = await _downloadDir();
    final name = _safeName(release.assetName, release.version);
    final target = File(p.join(dir.path, name));
    final part = File('${target.path}.part');
    final existing = await part.exists() ? await part.length() : 0;

    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'MisaTV-updater')
        ..set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (existing > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.drain<void>();
        throw HttpException('下载失败 HTTP ${response.statusCode}');
      }
      final append = response.statusCode == 206 && existing > 0;
      final total =
          (response.contentLength >= 0 ? response.contentLength : 0) +
          (append ? existing : 0);
      final sink = part.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      var received = append ? existing : 0;
      onProgress(received, total);
      await for (final chunk in response) {
        if (isCancelled?.call() ?? false) {
          await sink.flush();
          await sink.close();
          throw const UpdateDownloadCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.flush();
      await sink.close();

      if (release.assetSize > 0 && await part.length() != release.assetSize) {
        await part.delete();
        throw StateError('安装包大小校验失败，请重试');
      }
      final digest = release.assetDigest.trim().toLowerCase();
      if (digest.startsWith('sha256:')) {
        final expected = digest.substring(7).trim();
        final actual = await sha256.bind(part.openRead()).first;
        if (actual.toString().toLowerCase() != expected) {
          await part.delete();
          throw StateError('安装包 SHA-256 校验失败，请重试');
        }
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      AppLog.i('update', '更新包已下载：${target.path}');
      return target.path;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> revealDownload(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else {
        await Process.run('xdg-open', [p.dirname(path)]);
      }
    } catch (e) {
      AppLog.w('update', '打开下载目录失败：$e');
    }
  }

  static Future<Directory> _downloadDir() async {
    try {
      final dir = await getDownloadsDirectory();
      if (dir != null) return dir;
    } catch (_) {
      // 某些平台没有下载目录，回落到临时目录。
    }
    return Directory.systemTemp;
  }

  static String _safeName(String assetName, String version) {
    final raw = assetName.trim().isEmpty
        ? 'MisaTV-$version.zip'
        : assetName.trim();
    return raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}

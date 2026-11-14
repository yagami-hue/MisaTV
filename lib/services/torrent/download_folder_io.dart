import 'dart:io';

/// 在系统文件管理器中打开下载目录。
Future<void> openDownloadFolder(String dir) async {
  final path = dir.trim();
  if (path.isEmpty) return;
  try {
    if (Platform.isWindows) {
      await Process.run('explorer', [path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else {
      await Process.run('xdg-open', [path]);
    }
  } catch (_) {
    // 打不开目录不算功能失败，调用方无需感知。
  }
}

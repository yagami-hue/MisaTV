import 'package:flutter/foundation.dart';

import '../../models/video_download.dart';
import '../../models/video_download_record.dart';

/// 浏览器版没有可写的本地目录：保留接口，任务立即给出可读错误。
class VideoDownloadTask {
  VideoDownloadTask._();

  static VideoDownloadTask start({
    required String url,
    Map<String, String> headers = const {},
    required String fileName,
    String? sourceUrl,
    bool? hls,
    String? outputDir,
    String? targetPath,
  }) {
    final task = VideoDownloadTask._();
    task.progress.value = const VideoDownloadProgress(
      stage: '不可用',
      error: '浏览器版不支持下载视频，请使用桌面版',
    );
    return task;
  }

  final ValueNotifier<VideoDownloadProgress> progress =
      ValueNotifier(const VideoDownloadProgress());

  String directory = '';

  void cancel() {}

  void pause() {}

  void dispose() {
    progress.dispose();
  }
}

String videoDownloadDir() => '';

String videoDownloadExtension(String url, [String fallback = 'mp4']) => fallback;

String allocateDownloadPath(String dir, String title, String url) => '';

Future<void> deleteDownloadFile(String path) async {}

Future<List<LocalDownloadFile>> scanVideoDownloadFiles() async => const [];

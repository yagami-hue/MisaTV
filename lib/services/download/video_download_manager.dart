import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import '../../models/video_download.dart';
import '../../models/video_download_record.dart';
import '../local_store.dart';
import '../relay/local_relay.dart';
import 'video_download_service.dart';

/// 手动下载的编排：持久化记录、串起下载任务，并提供暂停 / 继续 / 删除。
///
/// 任务本身仍由 [VideoDownloadTask] 执行；这里只保存「下载了什么、下到哪、
/// 能不能续传」。边播缓存由 [LocalRelay] 自己管理，管理页只做统计与清空。
class VideoDownloadManager extends ChangeNotifier {
  VideoDownloadManager(this._store);

  final LocalStore _store;
  final List<VideoDownloadRecord> _records = [];
  final Map<String, VideoDownloadTask> _tasks = {};
  final Map<String, VoidCallback> _listeners = {};
  bool _loaded = false;
  Timer? _saveTimer;

  /// 按创建时间倒序的记录（内部可变，对外只读）。
  List<VideoDownloadRecord> get records =>
      UnmodifiableListView<VideoDownloadRecord>(_records);

  bool get hasActive => _tasks.isNotEmpty;

  VideoDownloadRecord? byId(String id) {
    for (final record in _records) {
      if (record.id == id) return record;
    }
    return null;
  }

  /// 从本地存储恢复记录；上次没下完的任务标记为「已暂停」。
  void loadIfNeeded() {
    if (_loaded) return;
    _loaded = true;
    _records
      ..clear()
      ..addAll(_store.loadVideoDownloadRecords());
    var changed = false;
    for (final record in _records) {
      if (record.status == VideoDownloadStatus.downloading) {
        record.status = VideoDownloadStatus.paused;
        record.stage = '已暂停（上次未完成）';
        changed = true;
      }
    }
    if (changed) _saveNow();
  }

  /// 独立播放器窗口关闭后重新读盘：把子窗口新写的记录合并进来。
  ///
  /// 同 id 以内存中的为准（本窗口可能正在下载，不能被打断或回退进度）。
  void mergeFromStore() {
    final persisted = _store.loadVideoDownloadRecords();
    final known = {for (final record in _records) record.id};
    var added = false;
    for (final record in persisted) {
      if (known.contains(record.id)) continue;
      if (record.status == VideoDownloadStatus.downloading) {
        record
          ..status = VideoDownloadStatus.paused
          ..stage = '已暂停（上次未完成）';
      }
      _records.add(record);
      added = true;
    }
    if (!added) return;
    _records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    notifyListeners();
    _saveSoon();
  }

  /// 开始下载当前视频；返回的任务可交给进度弹窗展示。
  VideoDownloadTask start({
    required String title,
    required String url,
    String? sourceUrl,
    Map<String, String> headers = const {},
    String provider = '',
    bool hls = false,
  }) {
    loadIfNeeded();
    if (kIsWeb) throw StateError('浏览器版不支持下载视频，请使用桌面版');
    final dir = videoDownloadDir();
    if (dir.trim().isEmpty) {
      throw StateError('还没有可用的下载目录（边播缓存未启用）');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final fileName = sanitizeDownloadFileName(title);
    final record = VideoDownloadRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: fileName,
      url: url,
      sourceUrl: sourceUrl ?? url,
      headers: headers,
      provider: provider,
      hls: hls,
      directory: dir,
      filePath: hls ? '' : allocateDownloadPath(dir, fileName, sourceUrl ?? url),
      status: VideoDownloadStatus.downloading,
      createdAt: now,
      updatedAt: now,
    );
    _records.insert(0, record);
    notifyListeners();
    _saveSoon();
    final task = _spawn(record);
    return task;
  }

  void pause(String id) {
    final task = _tasks[id];
    if (task == null) return;
    task.pause();
  }

  /// 重新开始一个暂停 / 失败 / 被取消的任务。
  Future<void> resume(String id) async {
    loadIfNeeded();
    final record = byId(id);
    if (record == null || _tasks.containsKey(id)) return;
    if (record.status == VideoDownloadStatus.completed) return;
    if (record.directory.trim().isEmpty) {
      record.directory = videoDownloadDir();
    }
    if (!record.hls && record.filePath.trim().isEmpty) {
      record.filePath = allocateDownloadPath(
        record.directory,
        record.title,
        record.sourceUrl.isNotEmpty ? record.sourceUrl : record.url,
      );
    }
    record
      ..status = VideoDownloadStatus.downloading
      ..error = ''
      ..stage = '准备中…'
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    _saveSoon();
    _spawn(record, refreshUrl: true);
  }

  /// 按创建的记录实际执行下载并接上进度监听。
  ///
  /// [refreshUrl] = true 时重新包一层中继：`/play` 里的 `p=` / `hk=` / `ck=`
  /// 都是进程内 token，应用重启后失效，直接续传只会拿到 404。
  VideoDownloadTask _spawn(
    VideoDownloadRecord record, {
    bool refreshUrl = false,
  }) {
    if (refreshUrl) record.url = _refreshUrl(record);
    final task = VideoDownloadTask.start(
      url: record.url,
      sourceUrl: record.sourceUrl,
      headers: record.headers,
      fileName: record.title,
      hls: record.hls,
      outputDir: record.directory.isEmpty ? null : record.directory,
      targetPath: record.hls ? null : record.filePath,
    );
    _attach(record.id, task);
    return task;
  }

  /// 用原始线路地址重新生成中继下载地址；拿不到就沿用记录里的地址。
  String _refreshUrl(VideoDownloadRecord record) {
    final relay = LocalRelay.instance;
    if (!relay.running) return record.url;
    if (!record.url.startsWith('${relay.baseUrl}/play')) return record.url;
    final source = record.sourceUrl.trim();
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(source)) {
      return record.url;
    }
    final rewritten = relay.playUrl(
      source,
      headers: record.headers,
      provider: record.provider,
    );
    return rewritten.isEmpty ? record.url : rewritten;
  }

  /// 删除记录；[deleteFile] = true 时连同文件（及 `.part`）一起删除。
  Future<void> remove(String id, {bool deleteFile = true}) async {
    final record = byId(id);
    if (record == null) return;
    final task = _tasks[id];
    task?.cancel();
    _detach(id);
    _records.remove(record);
    notifyListeners();
    _saveNow();
    if (deleteFile) {
      await deleteDownloadFile(record.filePath);
    }
  }

  /// 只清记录、不删文件（文件之后会出现在管理页的「其他文件」里）。
  Future<void> clearRecords({bool deleteFiles = false}) async {
    final pending = List<VideoDownloadRecord>.from(_records);
    for (final id in List<String>.from(_tasks.keys)) {
      _tasks[id]?.cancel();
      _detach(id);
    }
    _records.clear();
    notifyListeners();
    _saveNow();
    if (deleteFiles) {
      for (final record in pending) {
        await deleteDownloadFile(record.filePath);
      }
    }
  }

  void _attach(String id, VideoDownloadTask task) {
    _tasks[id] = task;
    void listener() => _onProgress(id, task);
    _listeners[id] = listener;
    task.progress.addListener(listener);
    _onProgress(id, task);
  }

  void _detach(String id) {
    final listener = _listeners.remove(id);
    final task = _tasks.remove(id);
    if (listener != null && task != null) {
      task.progress.removeListener(listener);
    }
  }

  void _onProgress(String id, VideoDownloadTask task) {
    final record = byId(id);
    if (record == null) {
      _detach(id);
      return;
    }
    final progress = task.progress.value;
    if (record.directory.isEmpty && task.directory.isNotEmpty) {
      record.directory = task.directory;
    }
    record
      ..receivedBytes = progress.receivedBytes
      ..totalBytes = progress.totalBytes
      ..completedSegments = progress.completedSegments
      ..totalSegments = progress.totalSegments
      ..stage = progress.stage
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    if (progress.error.isNotEmpty) {
      record
        ..status = VideoDownloadStatus.failed
        ..error = progress.error;
    } else if (progress.done) {
      record
        ..status = VideoDownloadStatus.completed
        ..error = '';
      if (progress.path.isNotEmpty) record.filePath = progress.path;
    } else if (progress.paused) {
      record.status = VideoDownloadStatus.paused;
    } else if (progress.cancelled) {
      record.status = VideoDownloadStatus.cancelled;
    } else {
      record.status = VideoDownloadStatus.downloading;
    }
    notifyListeners();
    final terminal = !progress.active;
    if (terminal) {
      _detach(id);
      _saveNow();
      if (progress.done) {
        AppLog.i('download', '视频下载完成：${record.filePath}');
      }
    } else {
      _saveSoon();
    }
  }

  /// 进度回调很密集，磁盘只按 800ms 节流写一次。
  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _saveNow);
  }

  void _saveNow() {
    _saveTimer?.cancel();
    _saveTimer = null;
    unawaited(_store.saveVideoDownloadRecords(_records));
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    for (final id in List<String>.from(_tasks.keys)) {
      _tasks[id]?.cancel();
      _detach(id);
    }
    super.dispose();
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/errors/app_error.dart';
import '../../core/logging/app_log.dart';
import '../../models/download_task.dart';
import 'aria2_sidecar.dart';
import 'magnet.dart';

/// aria2 下载管理器：任务列表 + 添加 / 暂停 / 继续 / 删除。
///
/// 与磁力播放共用同一个 [Aria2Sidecar]（同一个 aria2 进程），
/// 所以正在边下边播的磁力任务也会出现在列表里 —— 这是刻意的：
/// 用户能看到「它还在下」，也能手动暂停。
class DownloadManager extends ChangeNotifier {
  Aria2Sidecar Function()? _engineProvider;

  /// 桌面端在 main 里把 TorrentPlay 的引擎接进来；Web 版保持 null。
  void attach(Aria2Sidecar Function() engine) => _engineProvider = engine;

  Aria2Sidecar? get engine => _engineProvider?.call();
  bool get available => engine != null;

  List<DownloadTask> tasks = const [];
  int downloadSpeed = 0;
  int uploadSpeed = 0;
  int activeCount = 0;
  int waitingCount = 0;
  bool loading = false;
  String error = '';

  Timer? _timer;
  int _seq = 0;

  String get downloadDir => engine?.dir ?? '';

  /// 拉一次任务列表。[quiet] 为轮询调用，不显示整页 loading。
  Future<void> refresh({bool quiet = false}) async {
    final aria = engine;
    if (aria == null) {
      tasks = const [];
      error = '下载引擎只在桌面版可用';
      notifyListeners();
      return;
    }
    final seq = ++_seq;
    if (!quiet) {
      loading = true;
      error = '';
      notifyListeners();
    }
    try {
      if (!await aria.ensure()) {
        if (seq != _seq) return;
        error = 'BT 引擎不可用（缺少 aria2c.exe）';
        tasks = const [];
        return;
      }
      final active = await aria.tellActive();
      final waiting = await aria.tellWaiting(num: 200);
      final stopped = await aria.tellStopped(num: 200);
      final stat = await aria.globalStat();
      if (seq != _seq) return;
      final merged = <DownloadTask>[];
      final seen = <String>{};
      for (final row in [...active, ...waiting, ...stopped]) {
        final task = DownloadTask.fromJson(row);
        if (task.gid.isEmpty || !seen.add(task.gid)) continue;
        merged.add(task);
      }
      tasks = merged;
      downloadSpeed = _intOf(stat['downloadSpeed']);
      uploadSpeed = _intOf(stat['uploadSpeed']);
      activeCount = _intOf(stat['numActive']);
      waitingCount = _intOf(stat['numWaiting']);
      error = '';
    } catch (e) {
      if (seq != _seq) return;
      error = describeAppError(e).message;
      AppLog.w('download', '刷新下载任务失败', e);
    } finally {
      if (seq == _seq) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void startPolling([Duration interval = const Duration(seconds: 2)]) {
    _timer ??= Timer.periodic(interval, (_) {
      unawaited(refresh(quiet: true));
    });
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  /// 添加 http/https/ftp/磁力任务。
  Future<void> add(String uri, {String? dir}) async {
    final aria = engine;
    if (aria == null) throw StateError('下载引擎只在桌面版可用');
    final text = uri.trim();
    if (text.isEmpty) throw const FormatException('请填写下载地址或磁力链接');
    if (!await aria.ensure()) {
      throw StateError('BT 引擎不可用（缺少 aria2c.exe）');
    }
    final target = text.toLowerCase().startsWith('magnet:')
        ? withTrackers(text)
        : text;
    final targetDir = (dir ?? aria.dir).trim();
    final options = <String, String>{
      'dir': targetDir.isEmpty ? aria.dir : targetDir,
      'seed-time': '0',
    };
    await aria.addDownload([target], options);
    // 新任务可能还在等待队列，稍等一拍再刷新更接近真实状态。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await refresh(quiet: true);
  }

  Future<void> pauseTask(String gid) async {
    final aria = engine;
    if (aria == null) return;
    await aria.pause(gid);
    await refresh(quiet: true);
  }

  Future<void> resumeTask(String gid) async {
    final aria = engine;
    if (aria == null) return;
    await aria.unpause(gid);
    await refresh(quiet: true);
  }

  /// 删除任务：活动任务先 remove，再从结果列表里清掉。
  ///
  /// aria2 不会删除已下载的文件 —— 对用户来说这更安全（误删代价太大）。
  Future<void> removeTask(String gid) async {
    final aria = engine;
    if (aria == null) return;
    await aria.remove(gid);
    try {
      await aria.removeDownloadResult(gid);
    } catch (_) {
      // 活动任务可能还没有 result 记录。
    }
    await refresh(quiet: true);
  }

  /// 清空「已完成 / 失败 / 已移除」的记录（不动正在下载的任务）。
  Future<void> clearFinished() async {
    final aria = engine;
    if (aria == null) return;
    for (final task in tasks.where((e) => e.isFinished)) {
      try {
        await aria.removeDownloadResult(task.gid);
      } catch (_) {
        // 单条清理失败不影响其他任务。
      }
    }
    await refresh(quiet: true);
  }

  Future<void> pauseAll() async {
    final aria = engine;
    if (aria == null) return;
    await aria.pauseAll();
    await refresh(quiet: true);
  }

  Future<void> resumeAll() async {
    final aria = engine;
    if (aria == null) return;
    await aria.unpauseAll();
    await refresh(quiet: true);
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }

  static int _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

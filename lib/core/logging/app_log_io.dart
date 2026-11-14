import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'log_redact.dart';

/// 应用运行日志：落盘到 `<userdata>/logs/app-YYYY-MM-DD*.log`。
///
/// - 按天分文件；单文件超过 8 MB 自动续号（`.1.log`、`.2.log`…）；
/// - 启动时清理 14 天前的旧日志；
/// - 网络地址只记录协议/主机/路径与 query 的键名（见 [redactUrl]），不落 token；
/// - 唯一写入口是主 isolate；JS 蜘蛛 worker 的错误由主 isolate 的服务层记录。
class AppLog {
  AppLog._();

  static const _capBytes = 8 * 1024 * 1024;
  static const _keepDays = 14;

  static Directory? _dir;
  static IOSink? _sink;
  static Timer? _flushTimer;
  static String _day = '';
  static int _seq = 0;
  static int _bytes = 0;
  static bool _initialized = false;
  static bool _closed = false;

  static bool get initialized => _initialized;

  static String get directory => _dir?.path ?? '';

  static String get currentFile =>
      _sink == null ? '' : p.join(_dir!.path, _nameFor(_day, _seq));

  static Future<void> init({String? supportDir}) async {
    if (_initialized || _closed) return;
    try {
      final base = supportDir ?? (await getApplicationSupportDirectory()).path;
      final dir = Directory(p.join(base, 'logs'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _dir = dir;
      _cleanOldFiles(dir);
      _openToday();
      _initialized = true;
      _flushTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(flush()),
      );
      i('app', '===== MisaTV 启动 =====');
      i('app', '数据目录: ${p.dirname(dir.path)}');
      i(
        'app',
        '系统: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      );
      i('app', 'Dart: ${Platform.version.split(' ').first}');
    } catch (e) {
      _initialized = false;
      debugPrint('[AppLog] 初始化失败: $e');
    }
  }

  static void i(String tag, String message) => _write('I', tag, message);

  static void w(
    String tag,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) => _write('W', tag, message, error, stack);

  static void e(
    String tag,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) => _write('E', tag, message, error, stack);

  static Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {}
  }

  static Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _initialized = false;
  }

  /// 打开日志目录（设置页「运行日志」用）。
  static Future<void> openDirectory() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [dir.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir.path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [dir.path]);
      }
    } catch (_) {}
  }

  static void _write(
    String level,
    String tag,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) {
    final line = _line(level, tag, message, error);
    final buffer = StringBuffer(line);
    if (stack != null) {
      final frames = stack.toString().split('\n');
      for (final frame in frames.take(24)) {
        buffer.write('\n    $frame');
      }
    }
    _append(buffer.toString());
    if (kDebugMode) debugPrint(buffer.toString());
  }

  static String _line(String level, String tag, String message, Object? error) {
    final now = DateTime.now();
    final ts =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    final err = error == null ? '' : ' | error=${errorBrief(error)}';
    // 消息体里也可能拼进完整 URL：统一遮掉 query 值，避免 token 落盘。
    final body = redactQueryValues(message.replaceAll('\n', ' / '));
    return '$ts [$level][$tag] $body$err';
  }

  static void _append(String text) {
    if (_sink == null || _day.isEmpty) return;
    // 跨零点自动切到新一天的文件；单文件写满则续号。
    _openToday();
    if (_bytes >= _capBytes) _openToday(forceNext: true);
    final target = _sink;
    if (target == null) return;
    try {
      final line = '$text\n';
      target.write(line);
      _bytes += line.length;
    } catch (e) {
      debugPrint('[AppLog] 写入失败: $e');
    }
  }

  static void _openToday({bool forceNext = false}) {
    final now = DateTime.now();
    final day =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    if (day != _day || forceNext) {
      _day = day;
      _seq = forceNext ? _seq + 1 : _nextSeq(day);
      _closeSink();
      final file = File(p.join(_dir!.path, _nameFor(day, _seq)));
      _sink = file.openWrite(mode: FileMode.append);
      _bytes = file.existsSync() ? file.lengthSync() : 0;
    }
  }

  static int _nextSeq(String day) {
    for (var i = 0; i < 99; i++) {
      final f = File(p.join(_dir!.path, _nameFor(day, i)));
      if (!f.existsSync()) return i;
      if (f.lengthSync() < _capBytes) return i;
    }
    return 99;
  }

  static String _nameFor(String day, int seq) =>
      seq <= 0 ? 'app-$day.log' : 'app-$day.$seq.log';

  static void _cleanOldFiles(Directory dir) {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: _keepDays));
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith('app-') || !name.endsWith('.log')) continue;
        if (entity.lastModifiedSync().isBefore(cutoff)) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  static void _closeSink() {
    final sink = _sink;
    _sink = null;
    try {
      sink?.flush();
      sink?.close();
    } catch (_) {}
  }
}

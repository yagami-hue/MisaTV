import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/local_media.dart';
import '../local_store.dart';
import '../relay/local_relay.dart';

/// 本地媒体库：扫描用户选择的文件夹，列出视频文件。
///
/// 播放走本地中继的 `/media?path=`（支持 Range，播放器可以拖动）。
class LocalMediaService {
  LocalMediaService(this._store);

  final LocalStore _store;

  List<String> dirs = const [];
  List<LocalMediaFile> files = const [];
  bool scanning = false;
  String error = '';

  void load() {
    dirs = _store.loadLocalMediaDirs();
  }

  Future<void> addDir(String raw) async {
    final path = p.normalize(p.absolute(raw.trim()));
    if (raw.trim().isEmpty) throw const FormatException('请选择文件夹');
    if (!await Directory(path).exists()) {
      throw const FormatException('文件夹不存在');
    }
    if (dirs.contains(path)) return;
    dirs = [...dirs, path];
    await _store.saveLocalMediaDirs(dirs);
  }

  Future<void> removeDir(String path) async {
    dirs = dirs.where((e) => e != path).toList();
    files = files.where((e) => p.isWithin(path, e.path) == false).toList();
    await _store.saveLocalMediaDirs(dirs);
  }

  /// 重新扫描全部目录；[limit] 防止超大媒体库把内存撑爆。
  Future<List<LocalMediaFile>> scan({int limit = 800}) async {
    if (dirs.isEmpty) {
      files = const [];
      return files;
    }
    scanning = true;
    error = '';
    final out = <LocalMediaFile>[];
    try {
      for (final dir in dirs) {
        if (out.length >= limit) break;
        final directory = Directory(dir);
        if (!await directory.exists()) continue;
        try {
          await for (final entity in directory.list(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is! File) continue;
            final path = entity.path;
            if (!isLocalVideoFile(path)) continue;
            final lower = path.toLowerCase();
            if (lower.contains('@eadir') || lower.contains('/.#')) continue;
            try {
              final stat = await entity.stat();
              out.add(
                LocalMediaFile(
                  path: path,
                  name: p.basename(path),
                  size: stat.size,
                  modifiedMs: stat.modified.millisecondsSinceEpoch,
                  subtitle: p.basename(p.dirname(path)),
                ),
              );
            } catch (_) {
              // 单个文件 stat 失败（权限 / 被删除）不影响其余文件。
            }
            if (out.length >= limit) break;
          }
        } catch (e) {
          error = '部分目录读取失败：$e';
        }
      }
      out.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
      files = out;
      return files;
    } finally {
      scanning = false;
    }
  }
}

/// 本地文件 → 可给播放器使用的地址（中继没有启动时返回空串）。
String localMediaPlayUrl(String path) {
  final relay = LocalRelay.instance;
  if (!relay.running || path.trim().isEmpty) return '';
  return '${relay.baseUrl}/media?path=${Uri.encodeQueryComponent(path)}';
}

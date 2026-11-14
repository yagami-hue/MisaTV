import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// 便携数据目录名：放在软件安装目录内。
///
/// 不能叫 `data`——那是 Flutter 自带 `data/app.so`、`data/flutter_assets` 的位置。
const portableDataDirName = 'userdata';

/// 把应用数据目录与运行时下载目录切到软件安装目录（`<exe 目录>/userdata`）。
///
/// 之前这些都在 `%APPDATA%\com.kniephos\MisaTV`（JRE / Python / 加固壳桥 / mpv
/// 整合包 / aria2 / jar 缓存 / 订阅与登录态）。改为便携目录后，复制/移动整个
/// 软件文件夹即可连带数据与运行时一起搬走；升级解压到同一目录也不会丢。
///
/// 首次启用时把旧目录整体搬过来（同盘 rename，跨盘/占用退化为复制）。
/// 安装目录不可写（如装进 Program Files）或调试运行时返回 null，调用方继续用
/// 系统默认目录，避免应用因写权限直接不可用。
Future<String?> enablePortableAppData() async {
  if (!Platform.isWindows) return null;
  // 调试运行的 exe 在 build 目录：不搬用户真实数据，免得每次换构建目录都重新搬一遍。
  if (kDebugMode) return null;

  final target = Directory(
    p.join(File(Platform.resolvedExecutable).parent.path, portableDataDirName),
  );
  if (!_writable(target)) return null;

  if (!File(p.join(target.path, 'shared_preferences.json')).existsSync()) {
    final appData = Platform.environment['APPDATA'] ?? '';
    if (appData.isNotEmpty) {
      // 旧名目录先搬，随后当前名目录覆盖合并（同名文件以较新的 MisaTV 为准）。
      for (final path in [
        p.join(appData, 'com.kniephos', 'Kniephos'),
        p.join(appData, 'com.kniephos', 'MisaTV'),
      ]) {
        final from = Directory(path);
        if (from.existsSync()) await _moveInto(from, target);
      }
    }
  }

  // 之后所有 getApplicationSupportDirectory()（运行时目录、缓存、中继 fileRoot…）
  // 与 shared_preferences 都落到便携目录。
  PathProviderPlatform.instance = _PortablePathProvider(target.path);
  SharedPreferencesStorePlatform.instance = PortablePrefsStore(target.path);
  return target.path;
}

/// 重新从磁盘读取偏好。
///
/// 独立播放器窗口（另一个引擎）写入的进度/设置，主窗口必须显式 reload
/// 才能看到；本工程自带的 PortablePrefsStore 还有一层文件缓存，先失效。
Future<void> reloadPortablePrefs() async {
  final store = SharedPreferencesStorePlatform.instance;
  if (store is PortablePrefsStore) store.invalidateCache();
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
  } catch (_) {
    // 读取失败时保持当前内存值
  }
}

bool _writable(Directory dir) {
  try {
    dir.createSync(recursive: true);
    final probe = File(p.join(dir.path, '.write-test'));
    probe.writeAsStringSync('ok', flush: true);
    probe.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

/// 把旧数据目录搬到便携目录：能整目录改名就改名，否则「偏好文件优先」复制后删源。
///
/// 注意：**绝不能删已存在的 to 目录**。老实现里 `to.listSync().isEmpty` 就
/// `to.delete(recursive: true)` 再 rename —— 只要迁移中途任一步失败（跨盘、
/// 杀软锁文件、进程被杀），用户看到的就是「userdata 整个消失」。
/// 现在只允许 rename 到一个**不存在**的目标；已存在就走逐文件合并复制。
Future<void> _moveInto(Directory from, Directory to) async {
  try {
    if (!to.existsSync()) {
      await from.rename(to.path);
      await _writeMarker(to);
      return;
    }
    // 目标已存在：只在两边都没有偏好文件时才做整目录替换（此时没有数据可丢）。
    final toHasPrefs =
        File(p.join(to.path, 'shared_preferences.json')).existsSync();
    final fromHasPrefs =
        File(p.join(from.path, 'shared_preferences.json')).existsSync();
    if (!toHasPrefs && !fromHasPrefs && to.listSync().isEmpty) {
      from.renameSync(to.path);
      await _writeMarker(to);
      return;
    }
  } catch (_) {
    // 跨盘 / 被占用 → 走复制
  }
  try {
    await _copyInto(from, to);
    await _writeMarker(to);
    // 复制成功才删源；删不掉（杀软/占用）就留作备份。
    try {
      await from.delete(recursive: true);
    } catch (_) {}
  } catch (_) {
    // 极端情况（无权限）：保留原目录，按新目录重新开始（不影响启动）。
  }
}

Future<void> _writeMarker(Directory to) async {
  try {
    await File(p.join(to.path, '.migrated-portable')).writeAsString('portable', flush: true);
  } catch (_) {}
}

Future<void> _copyInto(Directory from, Directory to) async {
  await to.create(recursive: true);
  // 偏好文件最小也最重要：先拷它，哪怕后面大目录复制被打断也不丢订阅与登录态。
  final prefs = File(p.join(from.path, 'shared_preferences.json'));
  if (prefs.existsSync()) {
    try {
      await prefs.copy(p.join(to.path, 'shared_preferences.json'));
    } catch (_) {}
  }
  await for (final entity in from.list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (name == 'shared_preferences.json') continue;
    final targetPath = p.join(to.path, name);
    if (entity is Directory) {
      await _copyInto(entity, Directory(targetPath));
    } else if (entity is File) {
      try {
        await entity.copy(targetPath);
      } catch (_) {
        // 被占用/正在写入的单文件跳过
      }
    }
  }
}

/// 只改写 support 目录，临时目录 / 文档 / 下载等仍用系统默认位置。
class _PortablePathProvider extends PathProviderPlatform {
  _PortablePathProvider(this.root) : _delegate = PathProviderPlatform.instance;

  final String root;
  final PathProviderPlatform _delegate;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() => _delegate.getApplicationCachePath();

  @override
  Future<String?> getTemporaryPath() => _delegate.getTemporaryPath();

  @override
  Future<String?> getApplicationDocumentsPath() => _delegate.getApplicationDocumentsPath();

  @override
  Future<String?> getLibraryPath() => _delegate.getLibraryPath();

  @override
  Future<String?> getDownloadsPath() => _delegate.getDownloadsPath();

  @override
  Future<String?> getExternalStoragePath() => _delegate.getExternalStoragePath();

  @override
  Future<List<String>?> getExternalCachePaths() => _delegate.getExternalCachePaths();

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) =>
      _delegate.getExternalStoragePaths(type: type);
}

/// shared_preferences 的 Windows 实现固定读 `PathProviderWindows()`，不跟随
/// [PathProviderPlatform.instance]，所以这里自带一个同样格式（JSON 全量映射）
/// 的文件存储，把 `shared_preferences.json` 落到便携目录。
class PortablePrefsStore extends SharedPreferencesStorePlatform {
  PortablePrefsStore(this.root);

  final String root;
  static const _defaultPrefix = 'flutter.';

  Map<String, Object>? _cache;

  /// 丢弃文件缓存，下次读取重新从磁盘加载。
  ///
  /// 独立播放器窗口是另一个 Flutter 引擎/isolate，它写回的历史与设置
  /// 主窗口看不到；同步前必须先让本 isolate 的缓存失效。
  void invalidateCache() => _cache = null;

  File get _file => File(p.join(root, 'shared_preferences.json'));

  Future<Map<String, Object>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final data = <String, Object>{};
    try {
      final file = _file;
      var raw = '';
      if (file.existsSync()) raw = await file.readAsString();
      // 主文件为空 / 损坏时，尝试从上次中断的 .tmp 恢复：
      // 进程在 rename 之前被强杀会留下完整的 .tmp，里面才是最新数据。
      if (raw.trim().isEmpty) {
        final temp = File('${file.path}.tmp');
        if (temp.existsSync()) {
          try {
            final recovered = await temp.readAsString();
            if (recovered.trim().isNotEmpty) {
              raw = recovered;
              // 恢复成功后立即落成正式文件，避免下次再走这条路径。
              try {
                await temp.copy(file.path);
              } catch (_) {}
            }
          } catch (_) {}
        }
      }
      if (raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value != null) data[entry.key.toString()] = value as Object;
          }
        }
      }
    } catch (_) {
      // 损坏时按空偏好处理（与原插件一致）
    }
    return _cache = data;
  }

  Future<bool> _save(Map<String, Object> data) async {
    final file = _file;
    // 原子写：先写临时文件再 rename 覆盖。
    //
    // 直接 writeAsString 覆盖原文件时，进程若在这期间被强杀（关窗走
    // TerminateProcess，见 windows/runner/main.cpp），文件会被截断成 0 字节。
    // 下次启动读到空内容 → 订阅 / 收藏 / 历史 / 登录态全部"消失"。
    // rename 是同一卷上的原子替换：要么是旧内容，要么是新内容，不会是半截。
    final temp = File('${file.path}.tmp');
    try {
      await file.parent.create(recursive: true);
      await temp.writeAsString(jsonEncode(data), flush: true);
      if (file.existsSync()) {
        // Windows 上 rename 覆盖已存在文件会失败，先删再改名。
        // 两步之间仍可能被杀，但此时旧文件已完整写入磁盘，最坏情况是
        // 停留在「旧版本」，而不是「空文件」。
        try {
          file.deleteSync();
        } catch (_) {}
      }
      await temp.rename(file.path);
      return true;
    } catch (_) {
      try {
        if (temp.existsSync()) temp.deleteSync();
      } catch (_) {}
      return false;
    }
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final data = await _load();
    data[key] = value;
    return _save(data);
  }

  @override
  Future<bool> remove(String key) async {
    final data = await _load();
    data.remove(key);
    return _save(data);
  }

  @override
  Future<bool> clear() =>
      clearWithParameters(ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)));

  @override
  Future<bool> clearWithPrefix(String prefix) =>
      clearWithParameters(ClearParameters(filter: PreferencesFilter(prefix: prefix)));

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final filter = parameters.filter;
    final data = await _load();
    data.removeWhere(
      (key, _) => key.startsWith(filter.prefix) && (filter.allowList?.contains(key) ?? true),
    );
    return _save(data);
  }

  @override
  Future<Map<String, Object>> getAll() =>
      getAllWithParameters(GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)));

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(GetAllParameters(filter: PreferencesFilter(prefix: prefix)));

  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters parameters) async {
    final filter = parameters.filter;
    final data = Map<String, Object>.from(await _load());
    data.removeWhere(
      (key, _) =>
          !key.startsWith(filter.prefix) || !(filter.allowList?.contains(key) ?? true),
    );
    return data;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 播放中继的磁盘缓存。
///
/// 「边播边缓存」把播放器已经下行的分片顺手写到本地：重新拖回看过的位置、
/// 或者第二天重看同一集时，直接读盘不再回源。
///
/// 只缓存**整段 GET 的小文件**（HLS 分片、封面图之类）：
/// 带 Range 的请求、m3u8 清单、gzip 响应、以及超过 [maxEntryBytes] 的响应
/// 都不进缓存 —— 大文件交给播放器自己的内存缓冲，免得一轮播放就把盘塞满。
class StreamDiskCache {
  StreamDiskCache({
    required this.dir,
    required this.enabled,
    required this.limitMb,
  });

  /// 缓存根目录（`<应用数据>/cache/stream`）。
  final String dir;

  /// 是否启用；由设置页的开关实时决定，不重启也能生效。
  final bool Function() enabled;

  /// 容量上限（MB），超出按「最久未使用」淘汰。
  final int Function() limitMb;

  /// 单条上限：分片一般 2–8MB，超过 64MB 的多半是整片 MP4，不缓存。
  static const int maxEntryBytes = 64 * 1024 * 1024;

  final Map<String, int> _sizes = {};

  /// 最近一次命中的时间：淘汰按它排序，避免每次都 stat 整个目录。
  final Map<String, DateTime> _touched = {};

  /// 条目 Content-Type：命中是高频路径，首次读 `.json` 后缓存在内存里，
  /// 后续不再为每个分片多做两次磁盘 IO。
  final Map<String, String> _types = {};

  /// 已经确认存在的分片目录，避免每个分片都 create 一次。
  final Set<String> _readyDirs = {};

  int _bytes = 0;
  bool _indexed = false;
  String _indexedDir = '';

  /// 正在后台构建的索引；`null` = 没有进行中的扫描。
  Future<void>? _indexing;

  /// 缓存键：地址的 sha1。分片地址通常自带签名、随清单变化，直接哈希即可。
  static String keyOf(String url) => sha1.convert(utf8.encode(url)).toString();

  static String _sep() => Platform.pathSeparator;

  File _entry(String key) {
    final shard = key.length >= 2 ? key.substring(0, 2) : '00';
    return File('$dir${_sep()}$shard${_sep()}$key');
  }

  /// `downloads/` 是播放器「下载视频」的落盘目录：它和缓存共用同一个根路径，
  /// 但不参与 LRU 淘汰，也不会被「清空播放缓存」删掉。
  String get _downloadsDir => '$dir${_sep()}downloads';
  String get _downloadsPrefix => '$_downloadsDir${_sep()}';

  File _meta(String key) => File('${_entry(key).path}.json');

  /// 后台预热索引：应用启动后就把目录扫完，首个分片不必再等这次扫描。
  ///
  /// 扫描期间的请求不再阻塞等待（见 [open]），最多是暂时不参与淘汰。
  void warmUp() {
    if (dir.isEmpty || _indexed) return;
    unawaited(_ensureIndex());
  }

  Future<void> _ensureIndex() {
    if (dir.isEmpty || (_indexed && _indexedDir == dir)) {
      return Future<void>.value();
    }
    final pending = _indexing;
    if (pending != null) return pending;
    final task = _buildIndex();
    _indexing = task;
    return task;
  }

  Future<void> _buildIndex() async {
    try {
      _sizes.clear();
      _touched.clear();
      _bytes = 0;
      _indexedDir = dir;
      final root = Directory(dir);
      if (!await root.exists()) {
        _indexed = true;
        return;
      }
      await for (final entity in root.list(recursive: true)) {
        if (entity is! File) continue;
        final path = entity.path;
        // 下载目录与缓存共用根路径，但不能被当成缓存条目索引 / 淘汰。
        if (path.startsWith(_downloadsPrefix)) continue;
        if (path.endsWith('.tmp')) {
          // 上次进程被杀留下的半截文件
          try {
            await entity.delete();
          } catch (_) {}
          continue;
        }
        if (path.endsWith('.json')) continue;
        // 扫描期间可能已经有新分片落盘：不要重复计入。
        if (_sizes.containsKey(path)) continue;
        try {
          final stat = await entity.stat();
          if (stat.size <= 0) continue;
          _sizes[path] = stat.size;
          _touched[path] = _touched[path] ?? stat.modified;
          _bytes += stat.size;
        } catch (_) {}
      }
      _indexed = true;
    } catch (_) {
      // 目录不可读时保留已扫到的部分；标记为已索引，避免每个分片都重扫一遍。
      _indexed = true;
    } finally {
      _indexing = null;
    }
  }

  /// 命中则返回可读条目，并把 mtime 刷新（LRU 不误删仍在用的分片）。
  Future<StreamCacheEntry?> lookup(String key) async {
    if (dir.isEmpty || !enabled()) return null;
    final file = _entry(key);
    try {
      // 直接 stat：存在 + 大小一次拿到，失败即未命中。
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      if (stat.size <= 0) {
        _drop(file.path);
        return null;
      }
      var contentType = _types[file.path];
      if (contentType == null) {
        contentType = await _readContentType(key);
        _types[file.path] = contentType;
      }
      // 只更新内存里的访问时间：命中是高频路径，不该每次都写盘。
      _touched[file.path] = DateTime.now();
      return StreamCacheEntry(
        file: file,
        contentType: contentType,
        length: stat.size,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String> _readContentType(String key) async {
    try {
      final decoded = jsonDecode(await _meta(key).readAsString());
      if (decoded is Map && decoded['type'] is String) {
        final type = (decoded['type'] as String).trim();
        if (type.isNotEmpty) return type;
      }
    } catch (_) {}
    return 'application/octet-stream';
  }

  /// 未命中时开一个写入口；返回 null 表示这次响应不进缓存。
  Future<StreamCacheWriter?> open(
    String key, {
    required String contentType,
    required int length,
  }) async {
    if (dir.isEmpty || !enabled()) return null;
    if (length <= 0 || length > maxEntryBytes) return null;
    if (_indexed) {
      // 索引已就绪：淘汰只动内存记账，文件删除异步进行，不占取流路径。
      _evictFor(length);
    } else {
      // 首次启用 / 刚启动：后台补索引，本次分片先照常落盘。
      // 若在这里 await 整目录扫描，首片会被拖住几百毫秒到数秒。
      unawaited(_ensureIndex());
    }
    final entry = _entry(key);
    try {
      final parent = entry.parent;
      if (!_readyDirs.contains(parent.path)) {
        await parent.create(recursive: true);
        _readyDirs.add(parent.path);
      }
      final tmp = File('${entry.path}.tmp');
      if (await tmp.exists()) await tmp.delete();
      return StreamCacheWriter._(
        cache: this,
        key: key,
        entry: entry,
        tmp: tmp,
        sink: tmp.openWrite(),
        contentType: contentType,
      );
    } catch (_) {
      return null;
    }
  }

  void _evictFor(int incoming) {
    final limit = limitMb() * 1024 * 1024;
    if (limit <= 0 || _bytes + incoming <= limit) return;
    // 按内存里记录的访问时间排序，不再逐个 stat 文件 —— 这一步在每个分片
    // 落盘前都会跑，全量磁盘 IO 会把边播缓存本身变成新的卡顿源。
    final paths = _sizes.keys.toList()
      ..sort((a, b) {
        final ta = _touched[a];
        final tb = _touched[b];
        if (ta == null && tb == null) return 0;
        if (ta == null) return -1;
        if (tb == null) return 1;
        return ta.compareTo(tb);
      });
    for (final path in paths) {
      if (_bytes + incoming <= limit) break;
      _drop(path);
    }
  }

  /// 从索引里移除一条：记账同步完成，删文件异步进行。
  void _drop(String path) {
    final size = _sizes.remove(path);
    _touched.remove(path);
    _types.remove(path);
    if (size != null) _bytes -= size;
    unawaited(_deleteEntry(File(path)));
  }

  Future<void> _deleteEntry(File file) async {
    try {
      await file.delete();
    } catch (_) {}
    try {
      await File('${file.path}.json').delete();
    } catch (_) {}
  }

  void _put(String path, int length, String contentType) {
    final old = _sizes[path];
    if (old != null) _bytes -= old;
    _sizes[path] = length;
    _touched[path] = DateTime.now();
    _types[path] = contentType;
    _bytes += length;
  }

  /// 清空缓存目录（设置页的「清空缓存」）。保留下载视频目录。
  Future<void> clear() async {
    if (dir.isEmpty) return;
    final root = Directory(dir);
    try {
      if (await root.exists()) {
        await for (final entity in root.list()) {
          if (entity is Directory && entity.path == _downloadsDir) continue;
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    _sizes.clear();
    _touched.clear();
    _types.clear();
    _readyDirs.clear();
    _bytes = 0;
    _indexed = true;
    _indexedDir = dir;
    _indexing = null;
  }

  /// 当前占用字节数（设置页展示用）。
  Future<int> totalBytes() async {
    if (dir.isEmpty) return 0;
    await _ensureIndex();
    return _bytes;
  }

  /// 缓存条目数（下载管理页展示用；`downloads/` 不参与统计）。
  Future<int> entryCount() async {
    if (dir.isEmpty) return 0;
    await _ensureIndex();
    return _sizes.length;
  }
}

class StreamCacheEntry {
  const StreamCacheEntry({
    required this.file,
    required this.contentType,
    required this.length,
  });

  final File file;
  final String contentType;
  final int length;
}

/// 写入器：一边转发给播放器，一边把同样的字节写进 `<key>.tmp`，
/// 流正常结束后 rename 成正式条目并记录 content-type。
class StreamCacheWriter {
  StreamCacheWriter._({
    required this.cache,
    required this.key,
    required this.entry,
    required this.tmp,
    required this.sink,
    required this.contentType,
  });

  final StreamDiskCache cache;
  final String key;
  final File entry;
  final File tmp;
  final String contentType;
  final IOSink sink;
  bool _done = false;
  int _written = 0;

  void add(List<int> chunk) {
    if (_done) return;
    try {
      sink.add(chunk);
      _written += chunk.length;
    } catch (_) {
      _done = true;
    }
  }

  Future<void> commit() async {
    if (_done) return;
    _done = true;
    try {
      await sink.close();
      if (await entry.exists()) {
        try {
          await entry.delete();
        } catch (_) {}
      }
      await tmp.rename(entry.path);
      try {
        await File('${entry.path}.json')
            .writeAsString(jsonEncode({'type': contentType}));
      } catch (_) {}
      // 记账用实际写入量：上游截断时按声明长度会少算占用。
      cache._put(entry.path, _written, contentType);
    } catch (_) {
      await abort();
    }
  }

  Future<void> abort() async {
    _done = true;
    try {
      await sink.close();
    } catch (_) {}
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }
}

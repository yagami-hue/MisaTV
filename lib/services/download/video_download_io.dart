import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart' as pc;

import '../../core/errors/app_error.dart';
import '../../core/logging/app_log.dart';
import '../../models/video_download.dart';
import '../../models/video_download_record.dart';
import '../relay/local_relay.dart';
import 'hls_playlist.dart';

/// 下载目录：复用「边播边缓存」的磁盘路径，放在它下面的 `downloads/`。
///
/// 缓存池按 LRU 清理，下载文件放在子目录里并由缓存清理逻辑跳过，
/// 因此「清空播放缓存」不会误删已下载的视频。
String videoDownloadDir() {
  final root = LocalRelay.instance.streamCacheDir.trim();
  if (root.isEmpty) return '';
  return p.join(root, 'downloads');
}

/// 直链下载可用的扩展名（取自 URL 路径）；识别不了时用 [fallback]。
String videoDownloadExtension(String url, [String fallback = 'mp4']) {
  try {
    final segments = Uri.parse(url).pathSegments;
    if (segments.isNotEmpty) {
      final ext = p.extension(segments.last).replaceFirst('.', '').toLowerCase();
      if (RegExp(r'^(mp4|m4v|mkv|mov|webm|flv|ts|avi|wmv|rmvb)$')
          .hasMatch(ext)) {
        return ext;
      }
    }
  } catch (_) {}
  return fallback;
}

/// 给直链下载分配一个不会覆盖已有文件的路径（同名追加 `(2)`）。
///
/// 已存在的 `.part` 也算占用：那条半截文件属于上一次失败的任务，
/// 新任务继续写同一个文件会把两段内容拼坏。
String allocateDownloadPath(String dir, String title, String url) {
  final root = dir.trim();
  if (root.isEmpty) return '';
  final name = sanitizeDownloadFileName(title);
  final ext = videoDownloadExtension(url);
  var candidate = p.join(root, '$name.$ext');
  var index = 2;
  while (File(candidate).existsSync() ||
      File('$candidate.part').existsSync()) {
    candidate = p.join(root, '$name ($index).$ext');
    index++;
  }
  return candidate;
}

/// 删除一个下载文件以及它的 `.part` 临时文件。
Future<void> deleteDownloadFile(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return;
  for (final item in [trimmed, '$trimmed.part']) {
    try {
      final file = File(item);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// 扫描下载目录：用来展示「记录已清除、文件还在」的条目。
Future<List<LocalDownloadFile>> scanVideoDownloadFiles() async {
  final root = videoDownloadDir();
  if (root.isEmpty) return const [];
  final directory = Directory(root);
  if (!await directory.exists()) return const [];
  final files = <LocalDownloadFile>[];
  try {
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      try {
        final stat = await entity.stat();
        files.add(
          LocalDownloadFile(
            path: entity.path,
            size: stat.size,
            modified: stat.modified,
            partial: name.endsWith('.part'),
          ),
        );
      } catch (_) {}
    }
  } catch (_) {}
  files.sort((a, b) => b.modified.compareTo(a.modified));
  return files;
}

/// 单次视频下载（HLS 分片合并 / 直链文件）。
///
/// 走本地中继的 `/play` 地址下载：Referer / UA / Cookie / 网盘凭据都由中继注入，
/// 与播放器实际取流是同一条路径 —— 这也是「复用边下边播链路」的含义。
class VideoDownloadTask {
  VideoDownloadTask._(
    this._url,
    this._sourceUrl,
    this._headers,
    this._fileName,
    this._outputDir,
    this._hls,
    this._targetPath,
  );

  static VideoDownloadTask start({
    required String url,
    Map<String, String> headers = const {},
    required String fileName,
    String? sourceUrl,
    bool? hls,
    String? outputDir,
    String? targetPath,
  }) {
    final task = VideoDownloadTask._(
      url,
      sourceUrl ?? url,
      Map<String, String>.from(headers),
      sanitizeDownloadFileName(fileName),
      outputDir,
      hls,
      targetPath,
    );
    unawaited(task._run());
    return task;
  }

  final ValueNotifier<VideoDownloadProgress> progress =
      ValueNotifier(const VideoDownloadProgress());

  final String _url;
  final String _sourceUrl;
  final Map<String, String> _headers;
  final String _fileName;
  final String? _outputDir;
  final bool? _hls;

  /// 续传用的固定目标路径（直链）；为空时自动分配不重名的文件名。
  final String? _targetPath;

  /// 实际写入目录（开始下载后才有值）。
  String directory = '';

  bool _cancelled = false;
  bool _paused = false;
  bool _disposed = false;
  HttpClient? _client;
  IOSink? _sink;

  void cancel() {
    _cancelled = true;
  }

  /// 暂停：停止读流并保留已完成的部分（直链下次用 Range 续传）。
  void pause() {
    _cancelled = true;
    _paused = true;
  }

  void dispose() {
    _disposed = true;
    progress.dispose();
  }

  Future<void> _run() async {
    try {
      final dir = (_outputDir ?? videoDownloadDir()).trim();
      if (dir.isEmpty) {
        throw StateError('还没有可用的下载目录（边播缓存未启用）');
      }
      final target = Directory(dir);
      await target.create(recursive: true);
      directory = target.path;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 20);
      _client = client;
      final isHls = _hls ?? looksLikeHlsUrl(_sourceUrl);
      if (isHls) {
        await _runHls(client, target);
      } else {
        await _runDirect(client, target);
      }
      if (_cancelled) {
        _emit(progress.value.copyWith(cancelled: true, stage: '已取消'));
      } else {
        _emit(progress.value.copyWith(done: true, stage: '已完成'));
        AppLog.i('download', '视频下载完成：${progress.value.path}');
      }
    } catch (e) {
      if (_cancelled || e is _DownloadCancelled) {
        if (_paused) {
          _emit(progress.value.copyWith(paused: true, stage: '已暂停'));
        } else {
          _emit(progress.value.copyWith(cancelled: true, stage: '已取消'));
        }
      } else {
        final message = e is StateError || e is FormatException
            ? '$e'
            : describeAppError(e).message;
        _emit(
          progress.value.copyWith(
            error: message,
            stage: '下载失败',
          ),
        );
        AppLog.w('download', '视频下载失败', e);
      }
      // 失败时保留 .part：直链再次点击可以断点续传。
      await _closeSink();
    } finally {
      _client?.close(force: true);
      _client = null;
    }
  }

  void _emit(VideoDownloadProgress next) {
    if (_disposed) return;
    progress.value = next;
  }

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    try {
      await sink?.close();
    } catch (_) {}
  }

  // ---- 直链文件 ----

  Future<void> _runDirect(HttpClient client, Directory dir) async {
    final ext = videoDownloadExtension(_sourceUrl);
    final target = _targetPath != null && _targetPath.isNotEmpty
        ? File(_targetPath)
        : _uniqueFile(dir, ext);
    final tmp = File('${target.path}.part');
    var received = 0;
    try {
      if (await tmp.exists()) received = await tmp.length();
    } catch (_) {
      received = 0;
    }
    var total = 0;
    var lastEmit = 0;
    // 中继会把网盘 CDN 的单次响应夹到 32MB（规避跨度限速）：响应 EOF 不代表
    // 文件结束，要按已收字节继续请求剩余部分，直到 Content-Range 报的总长。
    while (true) {
      final res = await _get(
        client,
        _url,
        range: received > 0 ? 'bytes=$received-' : null,
      );
      final append = res.statusCode == 206 && received > 0;
      if (!append) received = 0;
      final reported = _contentRangeTotal(res);
      if (reported != null && reported > 0) {
        total = reported;
      } else if (!append && res.contentLength > 0) {
        total = res.contentLength;
      } else if (total <= 0 && res.contentLength > 0) {
        total = received + res.contentLength;
      }
      final sink = append
          ? tmp.openWrite(mode: FileMode.append)
          : tmp.openWrite();
      _sink = sink;
      _emit(
        VideoDownloadProgress(
          receivedBytes: received,
          totalBytes: total > 0 ? total : 0,
          stage: '下载中…',
        ),
      );
      final before = received;
      await for (final chunk in res) {
        if (_cancelled) {
          await sink.close();
          _sink = null;
          if (!_paused) await _delete(tmp);
          throw const _DownloadCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastEmit >= 120) {
          lastEmit = now;
          _emit(
            progress.value.copyWith(
              receivedBytes: received,
              totalBytes: total > 0 ? total : 0,
              stage: '下载中…',
            ),
          );
        }
      }
      await sink.close();
      _sink = null;
      if (_cancelled) {
        if (!_paused) await _delete(tmp);
        throw const _DownloadCancelled();
      }
      if (total <= 0 || received >= total) break;
      if (received <= before) {
        // 服务器既没给完也没有进展：不要 commit 半截文件，保留 .part 供续传。
        throw StateError('下载未完成（$received/$total 字节），可稍后重试续传');
      }
    }
    final path = await _commit(tmp, target);
    _emit(
      progress.value.copyWith(
        receivedBytes: received,
        totalBytes: total > 0 ? total : received,
        path: path,
        stage: '已完成',
      ),
    );
  }

  // ---- HLS ----

  Future<void> _runHls(HttpClient client, Directory dir) async {
    var mediaUrl = _url;
    var text = await _fetchText(client, mediaUrl);
    if (isHlsMasterPlaylist(text)) {
      final variant = pickHlsVariant(text, mediaUrl);
      if (variant == null) throw StateError('HLS 主清单里没有可用码率');
      mediaUrl = variant;
      text = await _fetchText(client, mediaUrl);
    }
    final playlist = parseHlsMediaPlaylist(text, mediaUrl);
    if (playlist.segments.isEmpty) throw StateError('HLS 清单里没有分片');
    final ext = playlist.initUri == null ? 'ts' : 'mp4';
    final target = _uniqueFile(dir, ext);
    final tmp = File('${target.path}.part');
    await _delete(tmp);
    final sink = tmp.openWrite();
    _sink = sink;
    var received = 0;
    final keys = <String, Uint8List>{};
    final total = playlist.segments.length;
    _emit(
      VideoDownloadProgress(
        totalSegments: total,
        stage: '下载分片 0/$total',
      ),
    );
    try {
      final initUri = playlist.initUri;
      if (initUri != null && initUri.isNotEmpty) {
        final init = await _fetchBytes(client, initUri);
        sink.add(init);
        received += init.length;
      }
      var done = 0;
      for (final segment in playlist.segments) {
        if (_cancelled) throw const _DownloadCancelled();
        var data = await _fetchBytes(
          client,
          segment.url,
          range: segment.range?.value,
        );
        final keyUri = segment.keyUri;
        if (keyUri != null && keyUri.isNotEmpty) {
          final key = keys[keyUri] ?? await _fetchBytes(client, keyUri);
          keys[keyUri] = key;
          data = _decryptAes128(
            data,
            key,
            _ivFor(segment.ivHex, segment.sequence),
          );
        }
        sink.add(data);
        received += data.length;
        done++;
        _emit(
          progress.value.copyWith(
            receivedBytes: received,
            completedSegments: done,
            totalSegments: total,
            stage: '下载分片 $done/$total',
          ),
        );
      }
    } on _DownloadCancelled {
      await sink.close();
      _sink = null;
      await _delete(tmp);
      rethrow;
    } catch (e) {
      await sink.close();
      _sink = null;
      await _delete(tmp);
      rethrow;
    }
    await sink.close();
    _sink = null;
    if (_cancelled) {
      await _delete(tmp);
      throw const _DownloadCancelled();
    }
    final path = await _commit(tmp, target);
    _emit(
      progress.value.copyWith(
        receivedBytes: received,
        totalBytes: received,
        path: path,
        stage: '已完成',
      ),
    );
  }

  // ---- HTTP ----

  Future<HttpClientResponse> _get(
    HttpClient client,
    String url, {
    String? range,
  }) async {
    final uri = Uri.parse(url);
    final req = await client.getUrl(uri);
    for (final entry in _headers.entries) {
      req.headers.set(entry.key, entry.value);
    }
    if (range != null && range.isNotEmpty) {
      req.headers.set(HttpHeaders.rangeHeader, range);
    }
    final res = await req.close();
    if (res.statusCode != 200 && res.statusCode != 206) {
      await res.drain<void>();
      throw StateError('请求失败（HTTP ${res.statusCode}）');
    }
    return res;
  }

  /// 从 `Content-Range: bytes a-b/total` 里取总长；没有或无法解析返回 null。
  int? _contentRangeTotal(HttpClientResponse res) {
    final raw = res.headers.value(HttpHeaders.contentRangeHeader) ?? '';
    final slash = raw.lastIndexOf('/');
    if (slash < 0) return null;
    return int.tryParse(raw.substring(slash + 1).trim());
  }

  Future<String> _fetchText(HttpClient client, String url) async {
    const maxBytes = 8 * 1024 * 1024;
    final res = await _get(client, url);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
      if (builder.length > maxBytes) {
        throw StateError('HLS 清单过大');
      }
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<Uint8List> _fetchBytes(
    HttpClient client,
    String url, {
    String? range,
  }) async {
    final res = await _get(client, url, range: range);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      if (_cancelled) throw const _DownloadCancelled();
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  // ---- 解密 / 文件 ----

  Uint8List _decryptAes128(Uint8List data, Uint8List key, Uint8List iv) {
    if (key.length != 16) throw StateError('HLS 密钥长度不是 16 字节');
    if (data.isEmpty) return data;
    if (data.length % 16 != 0) throw StateError('HLS 分片长度不是 16 的倍数');
    final cipher = pc.CBCBlockCipher(pc.AESEngine())
      ..init(false, pc.ParametersWithIV(pc.KeyParameter(key), iv));
    final out = Uint8List(data.length);
    for (var offset = 0; offset < data.length; offset += 16) {
      cipher.processBlock(data, offset, out, offset);
    }
    // PKCS7 去填充（HLS AES-128 规范要求）。
    final pad = out.last;
    if (pad >= 1 && pad <= 16 && out.length >= pad) {
      var valid = true;
      for (var i = out.length - pad; i < out.length; i++) {
        if (out[i] != pad) {
          valid = false;
          break;
        }
      }
      if (valid) return Uint8List.sublistView(out, 0, out.length - pad);
    }
    return out;
  }

  Uint8List _ivFor(String? hex, int sequence) {
    if (hex != null) {
      final clean = hex.replaceFirst(RegExp(r'^0x', caseSensitive: false), '');
      if (clean.length == 32) {
        final bytes = <int>[];
        for (var i = 0; i < 32; i += 2) {
          final byte = int.tryParse(clean.substring(i, i + 2), radix: 16);
          if (byte == null) break;
          bytes.add(byte);
        }
        if (bytes.length == 16) return Uint8List.fromList(bytes);
      }
    }
    final iv = Uint8List(16);
    var value = sequence;
    for (var i = 15; i >= 0 && value > 0; i--) {
      iv[i] = value & 0xff;
      value >>= 8;
    }
    return iv;
  }

  File _uniqueFile(Directory dir, String ext) {
    var candidate = File(p.join(dir.path, '$_fileName.$ext'));
    var index = 2;
    while (candidate.existsSync()) {
      candidate = File(p.join(dir.path, '$_fileName ($index).$ext'));
      index++;
    }
    return candidate;
  }

  Future<String> _commit(File tmp, File target) async {
    if (await target.exists()) {
      try {
        await target.delete();
      } catch (_) {}
    }
    await tmp.rename(target.path);
    return target.path;
  }

  Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

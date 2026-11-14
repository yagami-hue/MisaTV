import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:gbk_codec/gbk_codec.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/live.dart';
import '../../models/site_config.dart';
import 'epg.dart';

/// 直播 EPG（XMLTV）加载与缓存。
///
/// 规则对齐 FongMi/TV `EpgParser.refreshReason`：文件缺失 / 非当天 / 超过 6 小时才回源；
/// 回源失败时退回旧缓存，不阻断直播播放。
class EpgService {
  static const _ttl = Duration(hours: 6);
  static const _timeout = Duration(seconds: 30);

  final Map<String, _CachedText> _memory = {};

  Future<Map<String, EpgEntry>> loadFor({
    required LiveBean bean,
    required List<LiveChannel> channels,
    bool refresh = false,
  }) async {
    final programs = await loadProgramsFor(
      bean: bean,
      channels: channels,
      refresh: refresh,
    );
    if (programs.isEmpty) return const {};
    return buildEpgEntries(
      programs,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 完整节目表（键与 [loadFor] 一致），供节目单与直播回看使用。
  ///
  /// 只保留最近 7 天到未来 1 天的节目，避免整份 XMLTV 常驻内存。
  Future<Map<String, List<EpgProgram>>> loadProgramsFor({
    required LiveBean bean,
    required List<LiveChannel> channels,
    bool refresh = false,
  }) async {
    final refs = <EpgChannelRef>[];
    for (final channel in channels) {
      final ref = epgRefOf(channel);
      if (ref.tvgId.isNotEmpty || ref.tvgName.isNotEmpty || ref.name.isNotEmpty) {
        refs.add(ref);
      }
    }
    final urls = collectEpgUrls(bean.epg, refs);
    if (urls.isEmpty || refs.isEmpty) return const {};

    final docs = <ParsedXmltv>[];
    for (final url in urls) {
      try {
        final xml = await _loadText(url, refresh: refresh);
        if (xml.trim().isNotEmpty) docs.add(parseXmltv(xml));
      } catch (_) {
        // 单份 EPG 失败不影响其它来源
      }
    }
    if (docs.isEmpty) return const {};

    final now = DateTime.now().millisecondsSinceEpoch;
    return buildEpgMap(
      docs,
      refs,
      timeZone: bean.timeZone,
      fromMs: now - const Duration(days: 7).inMilliseconds,
      toMs: now + const Duration(days: 1).inMilliseconds,
    );
  }

  Future<String> _loadText(String url, {required bool refresh}) async {
    final now = DateTime.now();
    final cached = _memory[url];
    if (!refresh && cached != null && now.difference(cached.at) < _ttl) {
      return cached.text;
    }

    final file = File(p.join((await _cacheDir()).path, '${_hash(url)}.xml'));
    if (!refresh && file.existsSync()) {
      final mtime = file.lastModifiedSync();
      if (now.difference(mtime) < _ttl && _isSameDay(mtime, now)) {
        final text = await file.readAsString();
        _memory[url] = _CachedText(now, text);
        return text;
      }
    }

    try {
      final text = await _fetch(url);
      try {
        await file.writeAsString(text);
      } catch (_) {
        // 磁盘缓存失败只影响下次启动，不影响本次
      }
      _memory[url] = _CachedText(now, text);
      return text;
    } catch (_) {
      if (file.existsSync()) {
        final text = await file.readAsString();
        _memory[url] = _CachedText(now, text);
        return text;
      }
      rethrow;
    }
  }

  Future<Directory> _cacheDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'epg'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  String _hash(String url) => crypto.md5.convert(utf8.encode(url)).toString().substring(0, 16);

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<String> _fetch(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = false;
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      req.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Safari/537.36');
      req.headers.set('Accept', '*/*');
      final res = await req.close().timeout(_timeout);
      if (res.statusCode >= 400) {
        throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
      }
      var bytes = await res.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      if (bytes.length > 1 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
        bytes = gzip.decode(bytes);
      }
      return _decodeXml(bytes);
    } finally {
      client.close(force: true);
    }
  }

  String _decodeXml(List<int> bytes) {
    if (bytes.isEmpty) return '';
    final head = latin1.decode(bytes.take(256).toList(), allowInvalid: true);
    final match = RegExp(r'''encoding\s*=\s*["']([\w-]+)["']''', caseSensitive: false).firstMatch(head);
    final encoding = (match?.group(1) ?? 'utf-8').toLowerCase();
    final text = (encoding == 'gbk' || encoding == 'gb2312' || encoding == 'gb18030')
        ? gbk.decode(bytes)
        : utf8.decode(bytes, allowMalformed: true);
    return text.replaceFirst('\uFEFF', '');
  }
}

/// 收集本线路要用的 XMLTV 地址：线路级 `epg`（逗号分隔）为主，频道级 `epg` 兜底。
///
/// 含 `{` 的模板地址、非 http 地址、不含 `xml` / `gz` 的条目一律跳过（与上游同口径）。
List<String> collectEpgUrls(String liveEpg, List<EpgChannelRef> refs) {
  final out = <String>[];
  void push(String raw) {
    final t = raw.trim();
    if (t.isEmpty || t.contains('{') || !RegExp(r'^https?://', caseSensitive: false).hasMatch(t)) return;
    final low = t.toLowerCase();
    if (!low.contains('xml') && !low.contains('gz')) return;
    if (!out.contains(t)) out.add(t);
  }

  for (final item in liveEpg.split(',')) {
    push(item);
  }
  for (final ref in refs) {
    push(ref.epg);
  }
  return out;
}

class _CachedText {
  const _CachedText(this.at, this.text);
  final DateTime at;
  final String text;
}

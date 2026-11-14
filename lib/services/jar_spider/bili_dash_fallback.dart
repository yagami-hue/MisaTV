import 'dart:convert';

import '../../core/logging/app_log.dart';
import '../../core/logging/log_redact.dart';
import '../../core/net/app_http.dart';
import '../../models/vod.dart';

/// B 站「壳只下发 DASH」的回退取流。
///
/// 背景（实测于 wex 的 BiliGuard，即「高中课堂 / 少儿教育」这类源）：
///   · 壳的 playerContent 返回 `127.0.0.1:<jvm>/proxy?do=bili&aid=..&cid=..&qn=..&type=mpd`
///     且 format 为 application/dash+xml；把 type 换成 m3u8 / mp4 仍然是 dash+xml。
///   · 内置播放内核是 libmdk + 随包 ffmpeg：后者只编进 dash muxer(dashenc)，
///     没有 dashdec 解复用器，mdk 也不认 MPD，因此该地址必报
///     invalid or unsupported media，用户侧就是「一点开就失败」。
///   · 但 ffmpeg 的 mov,mp4 解复用器完整支持 fMP4，且 B 站官方 playurl 的
///     fnval=1 分支返回 durl（单文件 mp4，音轨已在内），这是可播的。
///
/// 所以这里的职责：把「壳的 DASH 代理地址」翻译成「官方 durl 直链」。
/// 只做 fnval=1，不碰需要 wbi 签名的 fnval=16。
class BiliDashFallback {
  BiliDashFallback._();

  /// 壳的 DASH 代理地址特征：本机 /proxy + type=mpd。
  static bool looksLikeShellDash(String url) {
    final lower = url.trim().toLowerCase();
    if (lower.isEmpty) return false;
    if (!lower.contains('/proxy')) return false;
    return lower.contains('type=mpd') || lower.contains('type%3dmpd');
  }

  /// 从壳的地址里解出 aid / cid。
  static ({int aid, int cid})? parseIds(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    final q = uri.queryParameters;
    final aid = int.tryParse((q['aid'] ?? q['avid'] ?? q['av'] ?? '').trim());
    final cid = int.tryParse((q['cid'] ?? '').trim());
    if (aid == null || cid == null || aid <= 0 || cid <= 0) return null;
    return (aid: aid, cid: cid);
  }

  /// 依次尝试的画质：先 720P，再 480P / 360P。
  ///
  /// 不按 Cookie 推断可用画质：页面只给 360P 时 64 会回空 durl，
  /// 逐个退比猜更可靠，且每个请求都很轻。
  static const List<int> qualityLadder = [64, 32, 16];

  /// 取带音轨的单文件 mp4；拿不到返回 null（调用方保留原有失败路径）。
  ///
  /// cookie 是哔哩登录 Cookie（可空）。不登录同样能拿到 360P / 480P 的 durl，
  /// 所以这里不把「没 Cookie」当失败。
  static Future<PlayResult?> resolve(
    AppHttp http,
    String shellUrl, {
    String cookie = '',
    String flag = '',
  }) async {
    final ids = parseIds(shellUrl);
    if (ids == null) {
      AppLog.w('bili', 'DASH 回退无法解出 aid/cid url=${redactUrl(shellUrl)}');
      return null;
    }
    for (final qn in qualityLadder) {
      final play = await _fetch(http, ids.aid, ids.cid, qn, cookie, flag);
      if (play != null) return play;
    }
    AppLog.w(
      'bili',
      'DASH 回退未取到 durl aid=${ids.aid} cid=${ids.cid} '
          'tried=${qualityLadder.join("/")}',
    );
    return null;
  }

  static Future<PlayResult?> _fetch(
    AppHttp http,
    int aid,
    int cid,
    int qn,
    String cookie,
    String flag,
  ) async {
    const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/126.0.0.0 Safari/537.36';
    final url = 'https://api.bilibili.com/x/player/playurl?avid=$aid&cid=$cid'
        '&qn=$qn&fnval=1&fnver=0&fourk=0&platform=html5';
    final headers = <String, String>{
      // html5 分支不需要 wbi 签名；带上站点 Referer/UA 才不会被判爬虫。
      'Referer': 'https://www.bilibili.com/',
      'User-Agent': ua,
      if (cookie.trim().isNotEmpty) 'Cookie': cookie.trim(),
    };
    try {
      final res = await http.getText(
        url,
        headers: headers,
        timeout: const Duration(seconds: 12),
      );
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return null;
      final code = (decoded['code'] as num?)?.toInt() ?? -1;
      if (code != 0) return null;
      final data = decoded['data'];
      if (data is! Map) return null;
      // fnval=1 走 durl；若站方仍回 dash 分支（只有 dash 没有 durl），放弃。
      final durl = data['durl'];
      if (durl is! List || durl.isEmpty) return null;
      final first = durl.first;
      if (first is! Map) return null;
      final direct = (first['url'] ?? '').toString().trim();
      if (direct.isEmpty) return null;
      if (durl.length > 1) {
        AppLog.w('bili', 'durl 为多段（${durl.length}），按第一段播放 qn=$qn');
      }
      AppLog.i(
        'bili',
        'DASH 回退成功 qn=$qn format=${data['format']} '
            'size=${first['size']} url=${redactUrl(direct)}',
      );
      return PlayResult(
        url: direct,
        flag: flag,
        headers: {
          'Referer': 'https://www.bilibili.com/',
          'User-Agent': ua,
        },
      );
    } catch (e) {
      AppLog.w('bili', 'DASH 回退请求失败 qn=$qn: $e');
      return null;
    }
  }
}

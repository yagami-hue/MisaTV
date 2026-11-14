import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/services/jar_spider/bili_dash_fallback.dart';

/// B 站 DASH 回退：壳只给 MPD 时改走官方 durl 拿单文件 mp4。
///
/// 背景：内置内核（libmdk + 随包 ffmpeg）只编进 dash muxer、没有 dashdec，
/// MPD 必播不了；而 durl 返回的 mp4 音轨已在内，内核对 mov/mp4 能解。
void main() {
  group('识别壳的 DASH 地址', () {
    test('本机 /proxy + type=mpd 才算', () {
      expect(
        BiliDashFallback.looksLikeShellDash(
          'http://127.0.0.1:19973/proxy?do=bili&aid=1&cid=2&type=mpd',
        ),
        isTrue,
      );
      expect(
        BiliDashFallback.looksLikeShellDash(
          'http://127.0.0.1:19973/proxy?do=bili&aid=1&cid=2&type=m3u8',
        ),
        isFalse,
        reason: 'HLS 不归这条回退管',
      );
      expect(
        BiliDashFallback.looksLikeShellDash('https://cdn.test/a.mp4'),
        isFalse,
      );
      expect(BiliDashFallback.looksLikeShellDash(''), isFalse);
    });

    test('从 query 里解出 aid / cid', () {
      final ids = BiliDashFallback.parseIds(
        'http://127.0.0.1:19973/proxy?do=bili&aid=116901208397383'
            '&cid=39854541041&qn=32&type=mpd',
      );
      expect(ids?.aid, 116901208397383);
      expect(ids?.cid, 39854541041);
    });

    test('缺 aid / cid 时返回 null', () {
      expect(BiliDashFallback.parseIds('http://a.test/proxy?do=bili'), isNull);
      expect(
        BiliDashFallback.parseIds('http://a.test/proxy?aid=1'),
        isNull,
        reason: '缺 cid 不足以取 playurl',
      );
      expect(BiliDashFallback.parseIds(''), isNull);
    });
  });

  group('durl 取流', () {
    /// 记录请求过的 qn，便于断言画质回退顺序。
    ({AppHttp http, List<int> seen}) mock(
      Map<int, String> available, {
      int code = 0,
    }) {
      final seen = <int>[];
      final client = MockClient((req) async {
        final qn = int.tryParse(req.url.queryParameters['qn'] ?? '') ?? 0;
        seen.add(qn);
        // 每次都必须带 fnval=1（durl 分支），带成 16 就是 dash，本轮修复的前提。
        expect(req.url.queryParameters['fnval'], '1');
        final url = available[qn];
        final body = url == null
            ? jsonEncode({'code': 0, 'data': <String, dynamic>{}})
            : jsonEncode({
                'code': code,
                'data': {
                  'format': 'mp4',
                  'durl': [
                    {'order': 1, 'size': 123, 'url': url},
                  ],
                },
              });
        return http.Response(body, 200,
            headers: {'content-type': 'application/json'});
      });
      return (http: AppHttp(client: client), seen: seen);
    }

    test('720P 可用时直接用 720P 的 mp4', () async {
      final m = mock({64: 'https://cdn.test/720.mp4'});
      final play = await BiliDashFallback.resolve(
        m.http,
        'http://127.0.0.1:19973/proxy?do=bili&aid=1&cid=2&qn=32&type=mpd',
      );
      expect(play?.url, 'https://cdn.test/720.mp4');
      expect(m.seen, [64], reason: '首个画质就命中，不该继续试');
      expect(play!.headers['Referer'], contains('bilibili.com'));
      expect(play.headers['User-Agent'], isNotEmpty);
    });

    test('高画质为空时按 64 → 32 → 16 逐个回退', () async {
      final m = mock({16: 'https://cdn.test/360.mp4'});
      final play = await BiliDashFallback.resolve(
        m.http,
        'http://127.0.0.1:19973/proxy?do=bili&aid=1&cid=2&type=mpd',
      );
      expect(play?.url, 'https://cdn.test/360.mp4');
      expect(m.seen, [64, 32, 16]);
    });

    test('全部画质都没有 durl 时返回 null（交回原有失败路径）', () async {
      final m = mock({});
      final play = await BiliDashFallback.resolve(
        m.http,
        'http://127.0.0.1:19973/proxy?do=bili&aid=1&cid=2&type=mpd',
      );
      expect(play, isNull);
      expect(m.seen, BiliDashFallback.qualityLadder);
    });

    test('业务 code 非 0 视为失败', () async {
      final m = mock({64: 'https://cdn.test/720.mp4'}, code: -404);
      final play = await BiliDashFallback.resolve(
        m.http,
        'http://127.0.0.1:19973/proxy?do=bili&aid=1&cid=2&type=mpd',
      );
      expect(play, isNull);
    });

    test('解不出 aid/cid 时不发请求', () async {
      var hits = 0;
      final client = MockClient((_) async {
        hits++;
        return http.Response('{}', 200);
      });
      final play = await BiliDashFallback.resolve(
        AppHttp(client: client),
        'http://127.0.0.1:19973/proxy?do=bili&type=mpd',
      );
      expect(play, isNull);
      expect(hits, 0);
    });
  });
}

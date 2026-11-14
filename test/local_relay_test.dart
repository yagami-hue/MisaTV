import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/models/dav.dart';
import 'package:kniephos/services/discover/cover_images.dart';
import 'package:kniephos/services/relay/proxy_rules.dart';
import 'package:kniephos/services/relay/local_relay.dart';
import 'package:kniephos/services/torrent/bt_stream.dart';

/// `/bt` 测试用的假会话源（不依赖 aria2）。
class _FakeBtSource implements BtStreamSource {
  _FakeBtSource({required this.path, required this.length});

  final String path;
  final int length;
  bool ready = true;
  final List<(int, int)> gates = [];

  @override
  BtStreamInfo? resolveStream(String infoHash, int fileIndex) {
    if (fileIndex != 1) return null;
    if (infoHash.length != 40) return null;
    return BtStreamInfo(
      absPath: path,
      length: length,
      fileOffset: 0,
      pieceLength: 1024,
    );
  }

  @override
  Future<bool> waitCovered(
    String infoHash,
    int fileIndex,
    int start,
    int end, {
    Duration? timeout,
    Duration? stall,
    bool Function()? isCancelled,
  }) async {
    gates.add((start, end));
    return ready;
  }
}

void main() {
  late HttpServer upstream;
  late HttpServer jvmProxy;
  late Directory root;
  late LocalRelay relay;
  late _FakeBtSource bt;
  final hash = List<String>.filled(40, 'b').join();
  final cookieSeen = <String>[];
  var deadHits = 0;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('kniephos-relay-');
    File('${root.path}/hello.txt').writeAsStringSync('local-file-ok');
    final btFile = File('${root.path}/bt-source.bin');
    btFile.writeAsBytesSync(List<int>.generate(4096, (i) => i % 256));
    bt = _FakeBtSource(path: btFile.path, length: 4096);

    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      final res = req.response;
      if (req.uri.path == '/dav-only') {
        res.write('auth:${req.headers.value(HttpHeaders.authorizationHeader)}');
        await res.close();
        return;
      }
      if (req.uri.path == '/index.mpd') {
        // B 站（wex 的 BiliGuard）下发的 DASH 清单：分片地址在 <BaseURL> 里，
        // 且 CDN 按 Referer 防盗链 —— 与 m3u8 一样必须改写回中继。
        res.headers.set('content-type', 'application/dash+xml');
        res.write(
          '<?xml version="1.0"?>\n'
          '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011">\n'
          '<Period>\n'
          '<AdaptationSet>\n'
          '<Representation id="32_7" bandwidth="36943">\n'
          '<BaseURL>http://127.0.0.1:${upstream.port}/bili-cdn.mp4</BaseURL>\n'
          '<SegmentBase indexRange="938-6005"><Initialization range="0-937"/></SegmentBase>\n'
          '</Representation>\n'
          '</AdaptationSet>\n'
          '</Period>\n'
          '</MPD>\n',
        );
        await res.close();
        return;
      }
      if (req.uri.path == '/index.m3u8') {
        res.headers.set('content-type', 'application/vnd.apple.mpegurl');
        res.write(
          '#EXTM3U\n'
          '#EXTINF:6.0,\n'
          'seg1.ts\n'
          '#EXT-X-CUE-OUT:30\n'
          '#EXTINF:6.0,\n'
          'ad.ts\n'
          '#EXT-X-CUE-IN\n'
          '#EXTINF:6.0,\n'
          'seg2.ts\n'
          '#EXT-X-ENDLIST\n',
        );
        await res.close();
        return;
      }
      if (req.uri.path == '/protected.mp4') {
        res.write('seen:${req.headers.value('x-test')}');
        await res.close();
        return;
      }
      if (req.uri.path == '/dup-cache.mp4') {
        // 上游 CDN 常见写法：同名 cache-control 下发多次。
        res.headers.add('cache-control', 'no-cache');
        res.headers.add('cache-control', 'no-store');
        res.write('dup-cache-ok');
        await res.close();
        return;
      }
      if (req.uri.path == '/live.txt') {
        res.headers.set('content-type', 'text/plain; charset=utf-8');
        res.write('央视,#genre#\nCCTV1,http://a.test/1.m3u8\n');
        await res.close();
        return;
      }
      if (req.uri.path == '/hotlink.jpg') {
        res.headers.set('content-type', 'image/jpeg');
        res.write('ref:${req.headers.value(HttpHeaders.refererHeader) ?? ''}');
        await res.close();
        return;
      }
      if (req.uri.path == '/ua-only') {
        res.write('ua:${req.headers.value(HttpHeaders.userAgentHeader) ?? ''}');
        await res.close();
        return;
      }
      if (req.uri.path == '/bili-cdn.mp4') {
        // 哔哩 CDN 的防盗链：没有 bilibili.com 的 Referer 就 403。
        final referer =
            req.headers.value(HttpHeaders.refererHeader) ?? '';
        if (!referer.contains('bilibili.com')) {
          res.statusCode = 403;
          await res.close();
          return;
        }
        res.write('ref:$referer');
        await res.close();
        return;
      }
      if (req.uri.path == '/headers') {
        res.write(
          'cookie:${req.headers.value(HttpHeaders.cookieHeader) ?? ''}\n',
        );
        res.write('ua:${req.headers.value(HttpHeaders.userAgentHeader) ?? ''}');
        await res.close();
        return;
      }
      if (req.uri.path == '/cookie-session.mp4') {
        // 模拟网盘会话中途过期：第一次 403 并下发刷新后的 __puus，
        // 带上新 Cookie 后才给 200。
        final cookie =
            req.headers.value(HttpHeaders.cookieHeader) ?? '';
        cookieSeen.add(cookie);
        if (!cookie.contains('__puus=fresh')) {
          res.statusCode = 403;
          res.headers.add(
            HttpHeaders.setCookieHeader,
            '__puus=fresh; Path=/; HttpOnly',
          );
          res.write('expired');
          await res.close();
          return;
        }
        res.write('ok:$cookie');
        await res.close();
        return;
      }
      if (req.uri.path == '/always-403.mp4') {
        deadHits++;
        res.statusCode = 403;
        await res.close();
        return;
      }
      if (req.uri.path == '/redirect-ua') {
        // 跨源 302（127.0.0.1 → localhost）：模拟百度 dlink → baidupcs CDN。
        res.statusCode = HttpStatus.found;
        res.headers.set(
          HttpHeaders.locationHeader,
          'http://localhost:${upstream.port}/headers',
        );
        await res.close();
        return;
      }
      if (req.uri.path == '/redirect-m3u8') {
        res.statusCode = HttpStatus.found;
        res.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${upstream.port}/sub/index.m3u8',
        );
        await res.close();
        return;
      }
      if (req.uri.path == '/sub/index.m3u8') {
        res.headers.set('content-type', 'application/vnd.apple.mpegurl');
        res.write('#EXTM3U\n#EXTINF:1.0,\nseg1.ts\n#EXT-X-ENDLIST\n');
        await res.close();
        return;
      }
      if (req.uri.path == '/range-echo') {
        res.write(
          'range:${req.headers.value(HttpHeaders.rangeHeader) ?? ''}',
        );
        await res.close();
        return;
      }
      res.statusCode = 404;
      await res.close();
    });

    // 假「常驻 JVM 宿主代理」：壳自己的 do=… 路由交给它，中继只负责原样转发。
    jvmProxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    jvmProxy.listen((req) async {
      req.response.headers.set('content-type', 'application/vnd.apple.mpegurl');
      req.response.write(
        'jvm:${req.uri.query}|range=${req.headers.value(HttpHeaders.rangeHeader) ?? ''}',
      );
      await req.response.close();
    });

    relay = LocalRelay.instance;
    await relay.start(
      fileRoot: root.path,
      driveTokens: () => const {},
      rules: () => const [],
      purifyEnabled: () => true,
      davAuth: (id) => id == 'srv-1' ? 'Basic dGVzdDp0ZXN0' : '',
      btSource: () => bt,
      jvmProxyPort: () => jvmProxy.port,
      externalEpisodeResolver: (token, index) async {
        if (token != 'demo') return null;
        return 'http://127.0.0.1:${upstream.port}/ua-only';
      },
    );
  });

  tearDownAll(() async {
    await relay.stop();
    await upstream.close(force: true);
    await jvmProxy.close(force: true);
    await root.delete(recursive: true);
  });

  Future<({int status, List<int> bytes, HttpHeaders headers})> fetch(
    String url, {
    Map<String, String> headers = const {},
    bool followRedirects = true,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url))
        ..followRedirects = followRedirects;
      headers.forEach(req.headers.set);
      final res = await req.close();
      final bytes = <int>[];
      await for (final chunk in res) {
        bytes.addAll(chunk);
      }
      return (status: res.statusCode, bytes: bytes, headers: res.headers);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> get(String url) async {
    final result = await fetch(url);
    expect(result.status, 200);
    return utf8.decode(result.bytes);
  }

  test('/img 注入 Referer（豆瓣图床反盗链）', () async {
    final target = 'http://127.0.0.1:${upstream.port}/hotlink.jpg';
    final wrapped = doubanCoverUrl(target);
    expect(wrapped, isNotNull);
    expect(wrapped, contains('/img?'));
    expect(await get(wrapped!), 'ref:https://m.douban.com/');
  });

  test('/play 未提供 UA 时补浏览器 UA（网盘直链 403 防护）', () async {
    final target = 'http://127.0.0.1:${upstream.port}/ua-only';
    final body = await get(relay.playUrl(target));
    expect(body, startsWith('ua:Mozilla/5.0'));
  });

  test('/play 哔哩 CDN 未配 Cookie 也补 Referer（否则 403 播不了低画质）', () async {
    // 未登录时只有 360P / 480P，但 CDN 照样按 Referer 防盗链；
    // 中继不能因为「没配 Cookie」就跳过这段补头。
    final target = 'http://127.0.0.1:${upstream.port}/bili-cdn.mp4';
    final body = await get(relay.playUrl(target, provider: 'bili'));
    expect(body, contains('ref:https://www.bilibili.com/'));
  });

  test('DASH(MPD)：<BaseURL> 递归改写回中继，分片才不会缺 Referer', () async {
    // 内置内核播不了 DASH，但中继仍要把清单改对：外部播放器 / 未来内核要用；
    // 而且改写后的 BaseURL 经中继取流时会带上 Referer（B 站 CDN 否则 403）。
    final target = 'http://127.0.0.1:${upstream.port}/index.mpd';
    final body = await get(relay.playUrl(target, provider: 'bili'));
    expect(body, contains('<MPD'));
    expect(body, contains('${relay.baseUrl}/play?'),
        reason: 'BaseURL 必须换成中继地址');
    expect(
      body.contains('127.0.0.1:${upstream.port}/bili-cdn.mp4'),
      isFalse,
      reason: '原始 CDN 地址不能留在清单里，否则分片绕开中继、丢 Referer',
    );
  });

  test('m3u8：去广告 + 分片/密钥递归改写回中继', () async {
    final target = 'http://127.0.0.1:${upstream.port}/index.m3u8';
    final body = await get(relay.playUrl(target));
    expect(body.contains('ad.ts'), isFalse);
    expect(body.contains('seg1.ts'), isTrue);
    expect(body.contains('seg2.ts'), isTrue);
    expect(body.contains('${relay.baseUrl}/play?'), isTrue);
    expect(body.contains('#EXT-X-ENDLIST'), isTrue);
  });

  test('/play 透传自定义 header', () async {
    final target = 'http://127.0.0.1:${upstream.port}/protected.mp4';
    final wrapped = relay.playUrl(target, headers: const {'X-Test': 'ok'});
    final body = await get(wrapped);
    expect(body, 'seen:ok');
  });

  test('/play 手动跟随 302：保留自定义 UA，跨源丢弃 Cookie', () async {
    // Dart 的 followRedirects 会把新请求的 UA 换成默认 Dart/x.y，百度 CDN
    // 按 UA 判防盗链就会 403。手动跟随必须保住 UA，同时不把本机 Cookie 外泄。
    final target = 'http://127.0.0.1:${upstream.port}/redirect-ua';
    final body = await get(
      relay.playUrl(
        target,
        headers: const {
          'User-Agent': 'CustomUA/1.0',
          'Cookie': 'session=secret',
        },
      ),
    );
    expect(body, contains('ua:CustomUA/1.0'));
    expect(body, isNot(contains('session=secret')));
  });

  test('/play 302 后的 m3u8 相对分片按最终地址解析', () async {
    // 重定向后仍用旧地址当 base，相对分片会指到 /seg1.ts（404）。
    final target = 'http://127.0.0.1:${upstream.port}/redirect-m3u8';
    final body = await get(relay.playUrl(target));
    final decoded = Uri.decodeComponent(body);
    expect(decoded, contains('${upstream.port}/sub/seg1.ts'));
    expect(decoded, isNot(contains('${upstream.port}/seg1.ts')));
  });

  test('/play 只对网盘线路夹取 Range，普通线路原样透传', () async {
    final target = 'http://127.0.0.1:${upstream.port}/range-echo';
    final clamped = await fetch(
      relay.playUrl(target, provider: 'quark'),
      headers: const {'Range': 'bytes=0-'},
    );
    expect(utf8.decode(clamped.bytes), 'range:bytes=0-33554431');
    final plain = await fetch(
      relay.playUrl(target, provider: 'bili'),
      headers: const {'Range': 'bytes=0-'},
    );
    expect(utf8.decode(plain.bytes), 'range:bytes=0-');
  });

  test('/play 请求头换成短 token，URL 不带 Cookie 明文', () async {
    final target = 'http://127.0.0.1:${upstream.port}/headers';
    final cookie =
        'session=abc; ${List.generate(120, (i) => 'k$i=v$i').join('; ')}';
    final headers = {'Cookie': cookie, 'User-Agent': 'TestUA'};
    final wrapped = relay.playUrl(target, headers: headers);
    expect(wrapped, isNot(contains('cookie=')));
    expect(wrapped.length, lessThan(500));
    // 相同 URL + 相同请求头复用同一个 token，不会给每个 HLS 分片建新表项。
    expect(relay.playUrl(target, headers: headers), wrapped);
    final body = await get(wrapped);
    expect(body, contains('cookie:$cookie'));
    expect(body, contains('ua:TestUA'));
  });

  test('/play 403 时记录 Set-Cookie 并用刷新后的 Cookie 重试一次', () async {
    cookieSeen.clear();
    final target = 'http://127.0.0.1:${upstream.port}/cookie-session.mp4';
    final body = await get(relay.playUrl(target, provider: 'cookie-test'));
    expect(body, contains('__puus=fresh'));
    expect(cookieSeen.length, 2);
    expect(cookieSeen.first, isNot(contains('__puus=fresh')));
    expect(cookieSeen.last, contains('__puus=fresh'));
  });

  test('/play 会话 Cookie 与账号 Cookie 合并，同名以新值覆盖', () async {
    cookieSeen.clear();
    final target = 'http://127.0.0.1:${upstream.port}/cookie-session.mp4';
    final headers = {
      'Cookie': '__pus=old; __puus=stale; foo=bar',
    };
    final body = await get(
      relay.playUrl(target, headers: headers, provider: 'cookie-merge'),
    );
    expect(body, contains('__pus=old'));
    expect(body, contains('foo=bar'));
    expect(body, contains('__puus=fresh'));
    expect(body, isNot(contains('__puus=stale')));
    expect(cookieSeen.length, 2);
  });

  test('/play 后续分片直接复用会话 Cookie，不再触发 403', () async {
    cookieSeen.clear();
    final target = 'http://127.0.0.1:${upstream.port}/cookie-session.mp4';
    final url = relay.playUrl(target, provider: 'cookie-keep');
    await get(url);
    cookieSeen.clear();
    final body = await get(url);
    expect(cookieSeen.length, 1);
    expect(cookieSeen.single, contains('__puus=fresh'));
    expect(body, contains('__puus=fresh'));
  });

  test('/play 403 且没有新 Cookie 时只请求一次，不无限重试', () async {
    deadHits = 0;
    final target = 'http://127.0.0.1:${upstream.port}/always-403.mp4';
    final result = await fetch(
      relay.playUrl(target, provider: 'cookie-dead'),
    );
    expect(result.status, 403);
    expect(deadHits, 1);
  });

  test('/play 超长目标地址换短 token，URL 不超过 FFmpeg 上限', () async {
    final longTarget =
        'http://127.0.0.1:${upstream.port}/headers?x=${'a' * 4000}';
    final wrapped = relay.playUrl(longTarget);
    expect(wrapped.length, lessThan(500));
    expect(wrapped, contains('p='));
    final body = await get(wrapped);
    expect(body, contains('ua:'));
  });

  test('/play 上游重复 cache-control 不把分片变成 502', () async {
    final target = 'http://127.0.0.1:${upstream.port}/dup-cache.mp4';
    final body = await get(relay.playUrl(target));
    expect(body, 'dup-cache-ok');
  });

  test('/file 按应用数据目录提供本地文件', () async {
    final body = await get('${relay.baseUrl}/file/hello.txt');
    expect(body, 'local-file-ok');
  });

  test('/proxy?do=ck 应答 ok（加固壳据此识别 9978 宿主代理）', () async {
    expect(await get('${relay.baseUrl}/proxy?do=ck'), 'ok');
  });

  test('壳路由 do=hmys 原样转发到常驻 JVM 并透传 Range', () async {
    final query = Uri(
      queryParameters: {
        'do': 'hmys',
        'type': 'm3u8',
        'url': 'aHR0cHM6Ly9leGFtcGxlLmNvbS9hLm0zdTg=',
        'ck': 'abc',
        'sign': 'def',
      },
    ).query;
    final result = await fetch(
      '${relay.baseUrl}/proxy?$query',
      headers: const {'Range': 'bytes=0-10'},
    );
    expect(result.status, 200);
    expect(utf8.decode(result.bytes), 'jvm:$query|range=bytes=0-10');
  });

  test('/proxy?do=live 解 base64url 并原样回传', () async {
    final liveUrl = 'http://127.0.0.1:${upstream.port}/live.txt';
    final ext = base64Url.encode(utf8.encode(liveUrl)).replaceAll('=', '');
    final body = await get('${relay.baseUrl}/proxy?do=live&type=txt&ext=$ext');
    expect(body, contains('CCTV1'));
  });

  test('/play?dav= 注入 Basic Authorization', () async {
    final target = 'http://127.0.0.1:${upstream.port}/dav-only';
    final wrapped = wrapDavPlayUrl(relay.baseUrl, target, 'srv-1');
    expect(await get(wrapped), 'auth:Basic dGVzdDp0ZXN0');
    // 未知服务器不注入（保持无认证）。
    final anonymous = wrapDavPlayUrl(relay.baseUrl, target, 'srv-x');
    expect(await get(anonymous), 'auth:null');
  });

  test('/ext 选集按需解析后 302 到播放地址', () async {
    final result = await fetch(
      '${relay.baseUrl}/ext/demo/1',
      followRedirects: false,
    );
    expect(result.status, HttpStatus.found);
    expect(
      result.headers.value(HttpHeaders.locationHeader),
      'http://127.0.0.1:${upstream.port}/ua-only',
    );
    final unknown = await fetch(
      '${relay.baseUrl}/ext/unknown/1',
      followRedirects: false,
    );
    expect(unknown.status, HttpStatus.badGateway);
  });

  test('/bt 按 Range 取流并做首片门控', () async {
    final result = await fetch(
      '${relay.baseUrl}/bt/$hash/1',
      headers: {'range': 'bytes=0-1023'},
    );
    expect(result.status, 206);
    expect(result.headers.value('content-range'), 'bytes 0-1023/4096');
    expect(result.bytes.length, 1024);
    expect(result.bytes[0], 0);
    expect(result.bytes[1], 1);
    expect(bt.gates.first, (0, 1023));
  });

  test('/bt 无 Range 时回整段', () async {
    final result = await fetch('${relay.baseUrl}/bt/$hash/1');
    expect(result.status, 200);
    expect(result.bytes.length, 4096);
  });

  test('/bt 会话不存在 → 404；门控失败 → 503', () async {
    final missing = await fetch('${relay.baseUrl}/bt/$hash/2');
    expect(missing.status, 404);
    bt.ready = false;
    final blocked = await fetch(
      '${relay.baseUrl}/bt/$hash/1',
      headers: {'range': 'bytes=0-99'},
    );
    expect(blocked.status, 503);
    bt.ready = true;
  });

  test('代理规则：命中的地址改走中继通用代理口，未命中的保持直连', () async {
    final port = upstream.port;
    ProxyRules.current = ProxyRules.fromRules([
      {
        'name': 'proxy',
        'hosts': ['live.txt'],
      },
    ]);
    ProxyRules.relayBase = () => relay.baseUrl;
    addTearDown(() {
      ProxyRules.current = ProxyRules.none;
      ProxyRules.relayBase = () => '';
    });
    final http = AppHttp();
    addTearDown(http.close);

    // 命中：地址被改写成中继的 /proxy?do=proxy，正文由中继取回。
    final routed = await http.getText('http://127.0.0.1:$port/live.txt');
    expect(routed.url, contains('/proxy?do=proxy&url='));
    expect(routed.body, contains('CCTV1'));

    // 未命中：仍然直连，地址不变。
    final direct = await http.getText('http://127.0.0.1:$port/ua-only');
    expect(direct.url, 'http://127.0.0.1:$port/ua-only');
    expect(direct.body, startsWith('ua:'));
  });

  group('跨站访问控制', () {
    test('跨站读 /file 被拒绝，原生客户端（无 Origin）照常可读', () async {
      final ok = await fetch('${relay.baseUrl}/file/hello.txt');
      expect(ok.status, 200);
      expect(utf8.decode(ok.bytes), 'local-file-ok');

      // 浏览器从第三方页面发起：带 Origin 且跨站 → 403，且不会回显 CORS。
      final blocked = await fetch(
        '${relay.baseUrl}/file/hello.txt',
        headers: {'origin': 'https://evil.example'},
      );
      expect(blocked.status, HttpStatus.forbidden);
      expect(
        blocked.headers.value('access-control-allow-origin'),
        isNull,
        reason: '拒绝时不能回写 CORS 头，否则页面仍能读到正文',
      );
    });

    test('跨站读 /pkg 被拒绝', () async {
      final blocked = await fetch(
        '${relay.baseUrl}/pkg/anything',
        headers: {'origin': 'https://evil.example'},
      );
      expect(blocked.status, HttpStatus.forbidden);
    });

    test('跨站访问 /proxy 被拒绝（防止借中继凭据代取任意地址）', () async {
      final target = Uri.encodeComponent(
        'http://127.0.0.1:${upstream.port}/ua-only',
      );
      final blocked = await fetch(
        '${relay.baseUrl}/proxy?do=proxy&url=$target',
        headers: {'origin': 'https://evil.example'},
      );
      expect(blocked.status, HttpStatus.forbidden);
    });

    test('跨站访问 /play：带访问令牌才过令牌闸，随后仍受私网 SSRF 限制', () async {
      final target = 'http://127.0.0.1:${upstream.port}/ua-only';
      final url = '${relay.playUrl(target)}&rt=${relay.accessToken}';
      final result = await fetch(
        url,
        headers: {'origin': 'https://player.example'},
      );
      // 测试上游在 127.0.0.1：令牌通过后，浏览器请求仍被私网规则拦下。
      expect(result.status, HttpStatus.forbidden);
      expect(
        utf8.decode(result.bytes),
        contains('禁止访问本机/内网地址'),
        reason: '不是令牌问题，而是已授权的浏览器也不许借中继访问内网',
      );
      expect(
        result.headers.value('access-control-allow-origin'),
        'https://player.example',
      );
      expect(result.headers.value('vary'), contains('Origin'));
    });

    test('浏览器请求没有令牌一律拒绝（含跨站 / 同源）', () async {
      final noToken = await fetch(
        relay.playUrl('http://127.0.0.1:${upstream.port}/ua-only'),
        headers: {'origin': 'https://player.example'},
      );
      expect(noToken.status, HttpStatus.forbidden);

      final wrongToken = await fetch(
        '${relay.playUrl('http://127.0.0.1:${upstream.port}/ua-only')}'
        '&rt=not-the-token',
        headers: {'origin': 'https://player.example'},
      );
      expect(wrongToken.status, HttpStatus.forbidden);
    });

    test('同源请求也要令牌，防止 DNS rebinding', () async {
      final origin = 'http://127.0.0.1:${relay.port}';
      final denied = await fetch(
        '${relay.baseUrl}/file/hello.txt',
        headers: {'origin': origin},
      );
      expect(denied.status, HttpStatus.forbidden);

      final result = await fetch(
        '${relay.baseUrl}/file/hello.txt?rt=${relay.accessToken}',
        headers: {'origin': origin},
      );
      expect(result.status, 200);
      expect(
        result.headers.value('access-control-allow-origin'),
        origin,
      );
    });

    test('已授权的浏览器请求也不能借中继访问内网（SSRF）', () async {
      final target = Uri.encodeComponent(
        'http://127.0.0.1:${upstream.port}/ua-only',
      );
      final viaProxy = await fetch(
        '${relay.baseUrl}/proxy?do=proxy&url=$target&rt=${relay.accessToken}',
        headers: {'origin': 'https://player.example'},
      );
      expect(viaProxy.status, HttpStatus.forbidden);

      final viaPlay = await fetch(
        '${relay.playUrl('http://127.0.0.1:${upstream.port}/ua-only')}'
        '&rt=${relay.accessToken}',
        headers: {'origin': 'https://player.example'},
      );
      expect(viaPlay.status, HttpStatus.forbidden);
    });

    test('壳的 do=ck 探测（无 Origin）仍回 ok，宿主代理握手不受影响', () async {
      final result = await fetch('${relay.baseUrl}/proxy?do=ck');
      expect(result.status, 200);
      expect(utf8.decode(result.bytes), 'ok');
    });

    test('跨站 OPTIONS 预检不泄漏敏感路由', () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req = await client.openUrl(
        'OPTIONS',
        Uri.parse('${relay.baseUrl}/file/hello.txt'),
      );
      req.headers.set('origin', 'https://evil.example');
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, HttpStatus.forbidden);
      expect(res.headers.value('access-control-allow-origin'), isNull);
    });
  });
}

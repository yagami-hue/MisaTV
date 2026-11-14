import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/jar_spider/jar_spider.dart';

/// 壳内 `/chunk` 取流服务的地址改写。
///
/// 背景（实测）：加固壳自己决定并发与分片大小，写死在 `MyPan$*MineProvider` 里
/// —— 会员 `thread=32 / chunk=64(KB)`、非会员 `thread=16 / chunk=512`。
/// 而壳的服务端（`merge.j.c`）把 thread 夹到 `[1,10]`、chunk 当 KB 用，
/// 所以壳发 16/32 都被砍成 10，白丢并发；64KB 的分片又过小。
///
/// 同一夸克直链实测（thread 固定 10）：
///   256KB → 6.8 MB/s · 512KB → 13.0 · 1024KB → 19.1 · **2048KB → 25.9** · 4096KB → 17.0
void main() {
  group('chunk 地址改写', () {
    test('thread 夹到服务端上限 10、chunk 提到 2MB', () {
      const url =
          'http://127.0.0.1:19979/chunk?id=abc123&thread=16&chunk=512&hk=xyz';
      final tuned = JarSpiderService.tuneChunkUrl(url);
      final uri = Uri.parse(tuned);
      expect(uri.host, '127.0.0.1');
      expect(uri.port, 19979);
      expect(uri.path, '/chunk');
      expect(uri.queryParameters['thread'], '10');
      expect(uri.queryParameters['chunk'], '2048');
      // 其它参数原样保留
      expect(uri.queryParameters['id'], 'abc123');
      expect(uri.queryParameters['hk'], 'xyz');
    });

    test('会员档（thread=32 / chunk=64）同样被归一到上限档', () {
      const url = 'http://127.0.0.1:19979/chunk?id=abc&thread=32&chunk=64';
      final uri = Uri.parse(JarSpiderService.tuneChunkUrl(url));
      expect(uri.queryParameters['thread'], '10');
      expect(uri.queryParameters['chunk'], '2048');
    });

    test('其它参数按原始字节保留，不重编码签名', () {
      const url =
          'http://127.0.0.1:19979/chunk?id=abc&sign=a/b+c%3D&thread=16&chunk=512';
      final tuned = JarSpiderService.tuneChunkUrl(url);
      expect(tuned, contains('sign=a/b+c%3D'));
      expect(tuned, contains('thread=10'));
      expect(tuned, contains('chunk=2048'));
    });

    test('缺少 thread 时补上上限值', () {
      const url = 'http://127.0.0.1:19979/chunk?id=abc&chunk=512';
      final uri = Uri.parse(JarSpiderService.tuneChunkUrl(url));
      expect(uri.queryParameters['thread'], '10');
      expect(uri.queryParameters['chunk'], '2048');
    });

    test('非 /chunk 地址一律原样返回', () {
      const remote = 'https://cdn.example.com/video.mp4';
      expect(JarSpiderService.tuneChunkUrl(remote), remote);
      const proxy = 'http://127.0.0.1:19979/proxy?do=pan&url=x';
      expect(JarSpiderService.tuneChunkUrl(proxy), proxy);
    });

    test('缺少 chunk 参数时不动（不是本壳的 /chunk 形态）', () {
      const url = 'http://127.0.0.1:19979/chunk?id=abc';
      expect(JarSpiderService.tuneChunkUrl(url), url);
    });

    test('非法 URL 不抛异常', () {
      expect(
        () => JarSpiderService.tuneChunkUrl('http://127.0.0.1:99999/chunk'),
        returnsNormally,
      );
    });
  });

  group('本机取流地址识别', () {
    test('只认 127.0.0.1 / localhost 的 /chunk', () {
      expect(
        JarSpiderService.isLocalChunkPlayUrl(
          'http://127.0.0.1:19979/chunk?id=1',
        ),
        isTrue,
      );
      expect(
        JarSpiderService.isLocalChunkPlayUrl('http://localhost:1/chunk'),
        isTrue,
      );
      expect(
        JarSpiderService.isLocalChunkPlayUrl('http://10.0.0.1:1/chunk'),
        isFalse,
      );
      expect(
        JarSpiderService.isLocalChunkPlayUrl('http://127.0.0.1:1/proxy'),
        isFalse,
      );
      expect(
        JarSpiderService.isLocalChunkPlayUrl('https://127.0.0.1:1/chunk'),
        isFalse,
      );
    });
  });
}

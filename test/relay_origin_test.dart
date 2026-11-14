import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/relay/relay_origin.dart';

void main() {
  group('normalizeOrigin', () {
    test('补默认端口并统一小写', () {
      expect(RelayOriginPolicy.normalizeOrigin('http://127.0.0.1:9978'),
          'http://127.0.0.1:9978');
      expect(RelayOriginPolicy.normalizeOrigin('https://Example.COM'),
          'https://example.com:443');
      expect(RelayOriginPolicy.normalizeOrigin('HTTP://A.Test:80'),
          'http://a.test:80');
    });

    test('空值 / 不可解析 / 非法 scheme 返回 null', () {
      expect(RelayOriginPolicy.normalizeOrigin(null), isNull);
      expect(RelayOriginPolicy.normalizeOrigin(''), isNull);
      // 沙箱 iframe 与 file:// 页面发的是字面量 "null"。
      expect(RelayOriginPolicy.normalizeOrigin('null'), isNull);
      expect(RelayOriginPolicy.normalizeOrigin('file://x'), isNull);
      expect(RelayOriginPolicy.normalizeOrigin('chrome-extension://abc'), isNull);
    });
  });

  group('normalizeHost', () {
    test('Host 头归一成 http://host:port', () {
      expect(RelayOriginPolicy.normalizeHost('127.0.0.1:9978'),
          'http://127.0.0.1:9978');
      expect(RelayOriginPolicy.normalizeHost('localhost'), 'http://localhost:80');
      expect(RelayOriginPolicy.normalizeHost(null), isNull);
      expect(RelayOriginPolicy.normalizeHost('  '), isNull);
    });
  });

  group('evaluate', () {
    test('没有 Origin：原生播放器 / 外部播放器 / 壳内 JVM 一律放行', () {
      for (final path in ['/play', '/file/TVBox/bili_cookie.txt', '/proxy']) {
        expect(
          RelayOriginPolicy.evaluate(path: path),
          RelayOriginVerdict.allow,
          reason: '无 Origin 的 $path 必须放行',
        );
      }
    });

    test('同源请求放行（含中继自己的页面）', () {
      expect(
        RelayOriginPolicy.evaluate(
          path: '/file/x.txt',
          origin: 'http://127.0.0.1:9978',
          host: '127.0.0.1:9978',
        ),
        RelayOriginVerdict.allow,
      );
    });

    test('跨站访问敏感路由被拒绝', () {
      for (final path in [
        '/file/TVBox/bili_cookie.txt',
        '/pkg/some.jar',
        '/proxy',
        '/proxy?do=pan',
        '/ext/token/0',
        '/',
      ]) {
        expect(
          RelayOriginPolicy.evaluate(
            path: path,
            origin: 'https://evil.example',
            host: '127.0.0.1:9978',
          ),
          RelayOriginVerdict.crossSiteDenied,
          reason: '跨站访问 $path 必须拒绝',
        );
      }
    });

    test('跨站访问媒体路由仍放行（逐条回写 CORS）', () {
      for (final path in ['/play', '/img', '/bt/aaaa/0']) {
        expect(
          RelayOriginPolicy.evaluate(
            path: path,
            origin: 'https://cdn.example',
            host: '127.0.0.1:9978',
          ),
          RelayOriginVerdict.crossSiteMedia,
          reason: '跨站访问 $path 应放行',
        );
      }
    });

    test('Sec-Fetch-Site: cross-site 时即使 Host 对不上也按路由分级', () {
      expect(
        RelayOriginPolicy.evaluate(
          path: '/file/x',
          origin: 'http://127.0.0.1:9978',
          host: null,
          secFetchSite: 'cross-site',
        ),
        RelayOriginVerdict.crossSiteDenied,
      );
      expect(
        RelayOriginPolicy.evaluate(
          path: '/play',
          origin: 'http://127.0.0.1:9978',
          host: null,
          secFetchSite: 'cross-site',
        ),
        RelayOriginVerdict.crossSiteMedia,
      );
    });

    test('Origin: null（沙箱 iframe）按跨站处理，不能读文件', () {
      expect(
        RelayOriginPolicy.evaluate(
          path: '/file/TVBox/bili_cookie.txt',
          origin: 'null',
          host: '127.0.0.1:9978',
        ),
        RelayOriginVerdict.crossSiteDenied,
      );
      expect(
        RelayOriginPolicy.evaluate(
          path: '/play',
          origin: 'null',
          host: '127.0.0.1:9978',
        ),
        RelayOriginVerdict.crossSiteMedia,
      );
    });
  });

  test('isMediaPath 覆盖 /bt 子路径但不覆盖 /bt', () {
    expect(RelayOriginPolicy.isMediaPath('/bt/abc/0'), isTrue);
    expect(RelayOriginPolicy.isMediaPath('/play'), isTrue);
    expect(RelayOriginPolicy.isMediaPath('/img'), isTrue);
    expect(RelayOriginPolicy.isMediaPath('/file/x'), isFalse);
    expect(RelayOriginPolicy.isMediaPath('/bt'), isFalse);
  });
}

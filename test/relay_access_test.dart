import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/relay/relay_access.dart';

void main() {
  group('isBrowserRequest', () {
    test('原生客户端不带 Origin / Sec-Fetch-*', () {
      expect(RelayAccessPolicy.isBrowserRequest(), isFalse);
      expect(
        RelayAccessPolicy.isBrowserRequest(origin: ' ', secFetchSite: ''),
        isFalse,
      );
    });

    test('浏览器请求任意一个头即可识别', () {
      expect(
        RelayAccessPolicy.isBrowserRequest(origin: 'http://evil.test'),
        isTrue,
      );
      expect(
        RelayAccessPolicy.isBrowserRequest(secFetchSite: 'cross-site'),
        isTrue,
      );
      expect(
        RelayAccessPolicy.isBrowserRequest(secFetchMode: 'no-cors'),
        isTrue,
      );
    });
  });

  group('tokenMatches', () {
    test('长度 / 内容完全一致才通过', () {
      expect(RelayAccessPolicy.tokenMatches('abc123', 'abc123'), isTrue);
      expect(RelayAccessPolicy.tokenMatches('abc123', ' abc123 '), isTrue);
      expect(RelayAccessPolicy.tokenMatches('abc123', 'abc124'), isFalse);
      expect(RelayAccessPolicy.tokenMatches('abc123', 'abc12'), isFalse);
      expect(RelayAccessPolicy.tokenMatches('abc123', null), isFalse);
      expect(RelayAccessPolicy.tokenMatches('', ''), isFalse);
    });
  });

  group('isPrivateHost', () {
    test('回环 / 内网 / 链路本地', () {
      for (final host in [
        'localhost',
        'app.localhost',
        'router.local',
        '127.0.0.1',
        '127.1',
        '2130706433',
        '10.0.0.8',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.1.1',
        '169.254.169.254',
        '100.64.0.1',
        '198.18.0.1',
        '0.0.0.0',
        '::1',
        '::',
        'fc00::1',
        'fd12:3456::1',
        'fe80::1',
        '::ffff:192.168.1.1',
      ]) {
        expect(
          RelayAccessPolicy.isPrivateHost(host),
          isTrue,
          reason: '$host 应判定为内网',
        );
      }
    });

    test('公网地址不误伤', () {
      for (final host in [
        '8.8.8.8',
        '1.1.1.1',
        '11.0.0.1',
        '172.32.0.1',
        '192.169.1.1',
        'example.com',
        'cdn.example.com',
        '2400:3200::1',
      ]) {
        expect(
          RelayAccessPolicy.isPrivateHost(host),
          isFalse,
          reason: '$host 不应判定为内网',
        );
      }
    });
  });

  group('isPrivateTarget', () {
    test('只拦截 http(s) 私网目标', () {
      expect(
        RelayAccessPolicy.isPrivateTarget('http://127.0.0.1:8080/admin'),
        isTrue,
      );
      expect(
        RelayAccessPolicy.isPrivateTarget('https://192.168.1.1/'),
        isTrue,
      );
      expect(
        RelayAccessPolicy.isPrivateTarget('https://example.com/a.m3u8'),
        isFalse,
      );
      expect(RelayAccessPolicy.isPrivateTarget('ftp://127.0.0.1/x'), isFalse);
      expect(RelayAccessPolicy.isPrivateTarget('not a url'), isFalse);
    });
  });
}

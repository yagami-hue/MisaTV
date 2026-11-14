import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/net/proxy_config.dart';
import 'package:kniephos/core/net/system_proxy.dart';

void main() {
  group('系统代理解析', () {
    test('裸 host:port 按 HTTP 处理', () {
      final proxy = SystemProxy.parseProxyUrl('127.0.0.1:7897');
      expect(proxy, isNotNull);
      expect(proxy!.type, 'http');
      expect(proxy.host, '127.0.0.1');
      expect(proxy.port, 7897);
      expect(proxy.valid, isTrue);
    });

    test('带 scheme：http / https 走 HTTP，socks5 走 SOCKS5', () {
      expect(SystemProxy.parseProxyUrl('http://10.0.0.2:8080')!.type, 'http');
      expect(SystemProxy.parseProxyUrl('https://10.0.0.2:8443')!.type, 'http');
      final socks = SystemProxy.parseProxyUrl('socks5://10.0.0.2:1080')!;
      expect(socks.type, 'socks5');
      expect(socks.port, 1080);
    });

    test('分协议写法：http= 优先，其次 https=、socks=', () {
      final http = SystemProxy.fromWindowsSettings(
        proxyEnable: true,
        proxyServer:
            'http=127.0.0.1:7890;https=127.0.0.1:7890;socks=127.0.0.1:7891',
      )!;
      expect(http.type, 'http');
      expect(http.port, 7890);

      final socks = SystemProxy.fromWindowsSettings(
        proxyEnable: true,
        proxyServer: 'socks=127.0.0.1:7891',
      )!;
      expect(socks.type, 'socks5');
      expect(socks.port, 7891);
    });

    test('系统代理关闭时不采用注册表里的值', () {
      expect(
        SystemProxy.fromWindowsSettings(
          proxyEnable: false,
          proxyServer: '127.0.0.1:7897',
        ),
        isNull,
      );
    });

    test('环境变量优先，大小写都认', () {
      final fromEnv = SystemProxy.fromEnvironment(const {
        'HTTP_PROXY': 'http://127.0.0.1:8888',
      })!;
      expect(fromEnv.port, 8888);
      expect(
        SystemProxy.fromEnvironment(const {
          'https_proxy': 'http://127.0.0.1:9999',
        })!.port,
        9999,
      );
      expect(SystemProxy.fromEnvironment(const {}), isNull);
    });

    test('无效值不产生代理', () {
      for (final raw in [
        '',
        '   ',
        'host',
        'host:',
        ':7890',
        'host:0',
        'host:70000',
        'ftp://host:21',
      ]) {
        expect(SystemProxy.parseProxyUrl(raw), isNull, reason: raw);
      }
    });
  });

  group('ProxyConfig.followSystem', () {
    test('默认直连，老配置缺键也按直连', () {
      expect(const ProxyConfig().followSystem, isFalse);
      expect(
        ProxyConfig.fromJsonString('{"enabled":true}').followSystem,
        isFalse,
      );
      expect(
        ProxyConfig.fromJsonString('{"followSystem":true}').followSystem,
        isTrue,
      );
    });

    test('JSON 往返保留 followSystem', () {
      const config = ProxyConfig(enabled: false, followSystem: false);
      expect(
        ProxyConfig.fromJsonString(config.toJsonString()).followSystem,
        isFalse,
      );
      expect(config.copyWith(followSystem: true).followSystem, isTrue);
    });
  });
}

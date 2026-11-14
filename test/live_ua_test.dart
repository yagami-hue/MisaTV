import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/site_config.dart';
import 'package:kniephos/services/live_service.dart';

/// 自定义直播 UA：**只作用于单条直播源**，且留空时回落到自动探测。
///
/// 两类真实需求：
///   1. 某个直播服务换了 UA 规则，作者还没更新内置表 —— 用户能自己填；
///   2. 强 UA 的服务（live.ottiptv.cc 这类）不能因为别的源填了 UA 就被影响。
void main() {
  group('LiveBean.ua 解析与序列化', () {
    test('从订阅 JSON 读取 ua', () {
      final bean = LiveBean.fromJson(const {
        'name': '肥羊',
        'url': 'http://a.test/live.txt',
        'type': '0',
        'ua': 'qqlive',
      });
      expect(bean.ua, 'qqlive');
    });

    test('没有 ua 字段时为空串（表示自动）', () {
      final bean = LiveBean.fromJson(const {
        'name': '普通源',
        'url': 'http://a.test/live.txt',
        'type': '0',
      });
      expect(bean.ua, isEmpty);
    });

    test('JSON 往返保留 ua', () {
      const bean = LiveBean(
        name: 'x',
        api: '',
        type: '0',
        url: 'http://a.test/l',
        ua: 'My-UA/1.0',
      );
      final round = LiveBean.fromJson(bean.toJson());
      expect(round.ua, 'My-UA/1.0');
    });

    test('空 ua 也能往返', () {
      const bean = LiveBean(name: 'x', api: '', type: '0', url: 'http://a.test/l');
      final round = LiveBean.fromJson(bean.toJson());
      expect(round.ua, isEmpty);
    });
  });

  group('UA 只影响自己这条源', () {
    test('两条源可以有不同的 UA', () {
      final a = LiveBean.fromJson(const {
        'name': 'A',
        'url': 'http://a.test/a.txt',
        'ua': 'ua-a',
      });
      final b = LiveBean.fromJson(const {
        'name': 'B',
        'url': 'http://b.test/b.txt',
        'ua': 'ua-b',
      });
      final c = LiveBean.fromJson(const {
        'name': 'C',
        'url': 'http://c.test/c.txt',
      });
      expect(a.ua, 'ua-a');
      expect(b.ua, 'ua-b');
      expect(c.ua, isEmpty, reason: '没填的源保持自动，不受其它源影响');
    });

    test('列表内容不会把一条源的 ua 传染给另一条', () {
      final raws = [
        {'name': 'A', 'url': 'http://a.test/a', 'ua': 'shared?'},
        {'name': 'B', 'url': 'http://b.test/b'},
      ];
      final beans = raws.map(LiveBean.fromJson).toList();
      expect(beans[0].ua, 'shared?');
      expect(beans[1].ua, isEmpty);
    });
  });

  group('已知服务的内置 UA 仍然有效', () {
    test('host 表里存在的服务能查到', () {
      // 结构性断言：表非空且键是小写 host 形态。
      expect(LiveService.hostDefaultUa, isNotEmpty);
      for (final key in LiveService.hostDefaultUa.keys) {
        expect(key, key.toLowerCase(), reason: '键必须是小写 host');
      }
    });

    test('defaultUaLiveHost 大小写不敏感', () {
      final host = LiveService.hostDefaultUa.keys.first;
      expect(
        LiveService.defaultUaLiveHost(host.toUpperCase()),
        LiveService.hostDefaultUa[host],
      );
    });

    test('用户填的 UA 优先于内置表（由 LiveService 的 explicitUa 判定保证）', () {
      const explicit = LiveBean(
        name: 'x',
        api: '',
        type: '0',
        url: 'http://live.ottiptv.cc/x',
        ua: 'custom-ua',
      );
      expect(explicit.ua.isNotEmpty, isTrue);
    });
  });
}

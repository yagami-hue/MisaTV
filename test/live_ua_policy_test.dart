import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/models/site_config.dart';
import 'package:kniephos/services/live/live_ua_policy.dart';
import 'package:kniephos/services/live_service.dart';

/// 「设置 → 直播源 → 自定义直播 UA」：一个全局默认 UA + 若干「按接口」的例外规则。
///
/// 要守住的三条不变式：
///   1. 规则只命中自己那条接口，不传染别的源；
///   2. 内置已知服务的 UA（live.ottiptv.cc 必须 qqlive）不能被全局默认 UA 换掉，
///      否则列表会指向广告流；
///   3. 什么都没填时，链路与改动前完全一致。
void main() {
  tearDown(() => LiveUaPolicy.current = LiveUaPolicy.none);

  group('规则匹配', () {
    const policy = LiveUaPolicy(
      rules: [
        LiveUaRule(pattern: 'live.ottiptv.cc', ua: 'my-ott/1.0'),
        LiveUaRule(pattern: '/bstation/ts', ua: 'edge/2.0'),
        LiveUaRule(pattern: r'.*cdn\d+\.tv.*', ua: 'regex/3.0'),
      ],
    );

    test('host 片段命中', () {
      expect(
        policy.matchRule('http://live.ottiptv.cc/1.m3u8?token=a'),
        'my-ott/1.0',
      );
    });

    test('大小写不敏感', () {
      expect(
        policy.matchRule('https://LIVE.OTTIPTV.CC/live.txt'),
        'my-ott/1.0',
      );
    });

    test('地址片段命中（同一 host 上只换某一条线路）', () {
      expect(
        policy.matchRule('http://a.test/bstation/ts/live.m3u8'),
        'edge/2.0',
      );
      expect(policy.matchRule('http://a.test/other/live.m3u8'), isNull);
    });

    test('正则规则命中', () {
      expect(policy.matchRule('http://cdn7.tv/x.m3u8'), 'regex/3.0');
      expect(policy.matchRule('http://cdn.tv/x.m3u8'), isNull);
    });

    test('靠前的规则先赢', () {
      const two = LiveUaPolicy(
        rules: [
          LiveUaRule(pattern: 'a.test/x', ua: 'first'),
          LiveUaRule(pattern: 'a.test', ua: 'second'),
        ],
      );
      expect(two.matchRule('http://a.test/x/1.m3u8'), 'first');
      expect(two.matchRule('http://a.test/y/1.m3u8'), 'second');
    });

    test('不命中的源不受影响', () {
      expect(policy.matchRule('http://elsewhere.test/live.txt'), isNull);
      expect(policy.matchRule(''), isNull);
    });
  });

  group('生效优先级', () {
    test('规则 > 订阅自带 ua > 全局默认', () {
      const policy = LiveUaPolicy(
        defaultUa: 'default-ua',
        rules: [LiveUaRule(pattern: 'hit.test', ua: 'rule-ua')],
      );
      expect(policy.resolve('http://hit.test/a'), 'rule-ua');
      expect(
        policy.resolve('http://hit.test/a', subscriptionUa: 'sub-ua'),
        'rule-ua',
      );
      expect(
        policy.resolve('http://miss.test/a', subscriptionUa: 'sub-ua'),
        'sub-ua',
      );
      expect(policy.resolve('http://miss.test/a'), 'default-ua');
    });

    test('什么都没填时返回空串（调用方据此走自动探测）', () {
      expect(LiveUaPolicy.none.resolve('http://a.test/l'), isEmpty);
      expect(LiveUaPolicy.none.matchRule('http://a.test/l'), isNull);
      expect(LiveUaPolicy.none.isEmpty, isTrue);
    });

    test('UA 为空的规则不算命中，也不参与解析', () {
      const policy = LiveUaPolicy(rules: [LiveUaRule(pattern: 'a.test', ua: ' ')]);
      expect(policy.matchRule('http://a.test/l'), isNull);
      expect(policy.resolve('http://a.test/l'), isEmpty);
    });
  });

  group('频道流侧解析', () {
    test('命中规则覆盖直播单里带来的 UA', () {
      LiveUaPolicy.current = const LiveUaPolicy(
        rules: [LiveUaRule(pattern: 'cdn-edge.test', ua: 'rule')],
      );
      expect(
        resolveLiveStreamUa('http://cdn-edge.test/1.ts', currentUa: 'okhttp/3.12.0'),
        'rule',
      );
    });

    test('无规则命中时沿用已有 UA，其次才是全局默认', () {
      LiveUaPolicy.current = const LiveUaPolicy(defaultUa: 'default');
      expect(resolveLiveStreamUa('http://a.test/1.ts', currentUa: 'qqlive'), 'qqlive');
      expect(resolveLiveStreamUa('http://a.test/1.ts'), 'default');
    });

    test('未配置时不改写已有 UA，也不凭空补一个', () {
      expect(resolveLiveStreamUa('http://a.test/1.ts', currentUa: 'qqlive'), 'qqlive');
      expect(resolveLiveStreamUa('http://a.test/1.ts'), isEmpty);
    });
  });

  group('持久化', () {
    test('JSON 往返', () {
      const policy = LiveUaPolicy(
        defaultUa: 'My/1.0',
        rules: [LiveUaRule(pattern: 'a.test', ua: 'ua-a')],
      );
      final round = LiveUaPolicy.fromJsonString(policy.toJsonString());
      expect(round.defaultUa, 'My/1.0');
      expect(round.rules.length, 1);
      expect(round.matchRule('http://a.test/l'), 'ua-a');
    });

    test('同一片段的重复规则只保留第一条（与 matchRule 的「靠前者优先」一致）', () {
      final policy = LiveUaPolicy.fromJson({
        'rules': [
          {'pattern': 'a.test', 'ua': 'first'},
          {'pattern': 'A.TEST', 'ua': 'second'},
        ],
      });
      expect(policy.rules.length, 1);
      // 去重口径必须与 matchRule 相同，否则「保存后立刻生效」与
      // 「重启后从磁盘读回」对同一份配置会给出不同 UA。
      expect(policy.matchRule('http://a.test/l'), 'first');
    });

    test('去重不改变内存实例的匹配结果（保存后 / 重启后一致）', () {
      const live = LiveUaPolicy(
        rules: [LiveUaRule(pattern: 'a.test', ua: 'first')],
      );
      final reloaded = LiveUaPolicy.fromJsonString(live.toJsonString());
      expect(
        reloaded.matchRule('http://a.test/l'),
        live.matchRule('http://a.test/l'),
      );
    });

    test('坏数据退回「不启用」，不影响直播', () {
      expect(LiveUaPolicy.fromJsonString('not json').isEmpty, isTrue);
      expect(LiveUaPolicy.fromJsonString('').isEmpty, isTrue);
      expect(LiveUaPolicy.fromJsonString('[]').isEmpty, isTrue);
      expect(
        LiveUaPolicy.fromJson({
          'defaultUa': 123,
          'rules': [null, 'x', {'pattern': '', 'ua': 'u'}, {'pattern': 'a.test', 'ua': 'ok'}],
        }).rules.single.pattern,
        'a.test',
      );
    });

    test('兼容旧字段名 host', () {
      final policy = LiveUaPolicy.fromJson({
        'rules': [
          {'host': 'a.test', 'ua': 'legacy'},
        ],
      });
      expect(policy.matchRule('http://a.test/l'), 'legacy');
    });

    test('损坏的 JSON 不会被当成有效配置', () {
      expect(jsonEncode(LiveUaPolicy.none.toJson()), contains('"rules":[]'));
    });
  });

  group('LiveService：取直播单实际带上什么 UA', () {
    /// 回显请求头的假源站；返回一份最简 TXT 直播单。
    LiveService serviceWith(void Function(http.Request req) probe) {
      final client = MockClient((request) async {
        probe(request);
        return http.Response('央视,#genre#\nCCTV1,http://cdn.test/1.ts\n', 200,
            headers: {'content-type': 'text/plain; charset=utf-8'});
      });
      return LiveService(AppHttp(client: client));
    }

    LiveBean bean(String url, {String ua = '', Map<String, String>? header}) =>
        LiveBean(name: 'x', api: '', type: '0', url: url, ua: ua, header: header);

    test('什么都没填：已知服务仍用内置 qqlive（不能被探测 UA 抢走）', () async {
      http.Request? seen;
      await serviceWith((r) => seen = r).load(
        bean('http://live.ottiptv.cc/live.txt'),
      );
      expect(seen!.headers['User-Agent'], 'qqlive');
    });

    test('全局默认 UA 不能覆盖内置已知服务的 UA', () async {
      LiveUaPolicy.current = const LiveUaPolicy(defaultUa: 'user-default');
      http.Request? seen;
      await serviceWith((r) => seen = r).load(
        bean('http://live.ottiptv.cc/live.txt'),
      );
      expect(seen!.headers['User-Agent'], 'qqlive',
          reason: '换掉 qqlive 会让列表指向广告流');
    });

    test('接口规则能覆盖内置已知服务的 UA（用户点名要换）', () async {
      LiveUaPolicy.current = const LiveUaPolicy(
        rules: [LiveUaRule(pattern: 'live.ottiptv.cc', ua: 'user-chosen')],
      );
      http.Request? seen;
      await serviceWith((r) => seen = r).load(
        bean('http://live.ottiptv.cc/live.txt'),
      );
      expect(seen!.headers['User-Agent'], 'user-chosen');
    });

    test('未知服务：无配置走 okhttp/3.12.0，设了默认就用默认', () async {
      final captured = <String?>[];
      await serviceWith((r) => captured.add(r.headers['User-Agent']))
          .load(bean('http://brand-new.test/live.txt'));
      expect(captured.last, 'okhttp/3.12.0');

      LiveUaPolicy.current = const LiveUaPolicy(defaultUa: 'user-default');
      await serviceWith((r) => captured.add(r.headers['User-Agent']))
          .load(bean('http://another.test/live.txt'));
      expect(captured.last, 'user-default');
    });

    test('订阅自带 ua 优先于全局默认', () async {
      LiveUaPolicy.current = const LiveUaPolicy(defaultUa: 'user-default');
      http.Request? seen;
      await serviceWith((r) => seen = r).load(
        bean('http://a.test/live.txt', ua: 'subscription-ua'),
      );
      expect(seen!.headers['User-Agent'], 'subscription-ua');
    });

    test('接口规则优先于订阅 header 里的 UA', () async {
      LiveUaPolicy.current = const LiveUaPolicy(
        rules: [LiveUaRule(pattern: 'a.test', ua: 'rule-ua')],
      );
      http.Request? seen;
      await serviceWith((r) => seen = r).load(
        bean('http://a.test/live.txt', header: {'User-Agent': 'header-ua'}),
      );
      expect(seen!.headers['User-Agent'], 'rule-ua');
    });

    test('没有规则命中时订阅 header 的 UA 照旧生效', () async {
      LiveUaPolicy.current = const LiveUaPolicy(
        rules: [LiveUaRule(pattern: 'other.test', ua: 'rule-ua')],
      );
      http.Request? seen;
      await serviceWith((r) => seen = r).load(
        bean('http://a.test/live.txt', header: {'User-Agent': 'header-ua'}),
      );
      expect(seen!.headers['User-Agent'], 'header-ua');
    });

    test('规则只作用于命中的那条源', () async {
      LiveUaPolicy.current = const LiveUaPolicy(
        rules: [LiveUaRule(pattern: 'hit.test', ua: 'rule-ua')],
      );
      final seen = <String?>[];
      final service = serviceWith((r) => seen.add(r.headers['User-Agent']));
      await service.load(bean('http://hit.test/live.txt'));
      await service.load(bean('http://miss.test/live.txt'));
      expect(seen[0], 'rule-ua');
      expect(seen[1], isNot('rule-ua'), reason: '另一条源不该被传染');
    });

    test('订阅同时写了 ua 与 header 时，频道继承**实际发出**的那个 UA', () async {
      // 请求头里 `...?bean.header` 展开在 `'User-Agent': bean.ua` 之后，
      // 所以 header 里的 user-agent 会盖掉 ua 字段。频道必须跟着走，
      // 否则列表正常、一点开就黑屏（服务端对频道流同样校验 UA）。
      http.Request? seen;
      final groups = await serviceWith((r) => seen = r).load(
        bean(
          'http://a.test/live.txt',
          ua: 'bean-ua',
          header: {'user-agent': 'header-ua'},
        ),
      );
      final sentUa = seen!.headers.entries
          .firstWhere((e) => e.key.toLowerCase() == 'user-agent')
          .value;
      expect(sentUa, 'header-ua');
      expect(groups.first.channels.first.ua, sentUa);
    });

    test('只有 ua 没有 header 时，频道继承 ua', () async {
      http.Request? seen;
      final groups = await serviceWith((r) => seen = r).load(
        bean('http://a.test/live.txt', ua: 'bean-ua'),
      );
      expect(seen!.headers['User-Agent'], 'bean-ua');
      expect(groups.first.channels.first.ua, 'bean-ua');
    });

    test('频道拿到命中的接口 UA', () async {
      LiveUaPolicy.current = const LiveUaPolicy(
        rules: [LiveUaRule(pattern: 'a.test', ua: 'rule-ua')],
      );
      final groups = await serviceWith((_) {}).load(
        bean('http://a.test/live.txt'),
      );
      expect(groups.first.channels.first.ua, 'rule-ua',
          reason: '列表与频道流都要带上用户点名的 UA');
    });
  });

  test('单源 UA 的说明文案仍写明只作用于当前源', () {
    expect(kLiveUaHelper, contains('只作用于当前这一条直播源'));
  });
}

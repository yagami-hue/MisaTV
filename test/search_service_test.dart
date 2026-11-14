import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/models/site_config.dart';
import 'package:kniephos/models/vod.dart';
import 'package:kniephos/services/cms_source.dart';
import 'package:kniephos/services/jar_spider_service.dart';
import 'package:kniephos/services/js_spider_service.dart';
import 'package:kniephos/services/py_spider_service.dart';
import 'package:kniephos/services/search_service.dart';
import 'package:kniephos/services/source_circuit_breaker.dart';
import 'package:kniephos/services/source_service.dart';

class _FakeCms extends CmsSource {
  _FakeCms(
    this.itemsBySite, {
    Set<String>? failing,
  }) : failing = failing ?? <String>{},
       super(AppHttp());

  final Map<String, List<VodItem>> itemsBySite;

  /// 在这些站点 key 上抛出源站错误，用于熔断测试。
  final Set<String> failing;
  int calls = 0;
  final Map<String, int> callsBySite = {};

  /// 最近一次传给源站的关键词（验证结构化语法没有混进关键词）。
  String lastKeyword = '';

  @override
  Future<List<VodItem>> search(SourceBean site, String keyword) async {
    calls++;
    lastKeyword = keyword;
    callsBySite[site.key] = (callsBySite[site.key] ?? 0) + 1;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (failing.contains(site.key)) {
      throw StateError('源站不可用');
    }
    return itemsBySite[site.key] ?? const [];
  }
}

SourceService _service(CmsSource cms) => SourceService(
  cms,
  JsSpiderService(),
  PySpiderService(),
  JarSpiderService(),
);

VodItem _item(String name, {String id = '1'}) => VodItem(
  id: id,
  name: name,
  year: '2026',
  sourceKey: 'a',
);

VodItem _siteItem(String siteKey, String name) => VodItem(
  id: '$siteKey-$name',
  name: name,
  year: '2026',
  sourceKey: siteKey,
  sourceName: siteKey.toUpperCase(),
);

void main() {
  test('同源同关键词命中短 TTL 缓存，clearCache 后重新请求', () async {
    final cms = _FakeCms({
      'a': [_item('测试片名')],
    });
    final service = SearchService(_service(cms));
    final site = SourceBean(
      key: 'a',
      name: 'A',
      type: 0,
      api: 'https://example.com/a',
    );

    await service.search('测试片名', [site]).toList();
    final first = cms.calls;
    expect(first, 1);

    // 第二次命中缓存。
    await service.search('测试片名', [site]).toList();
    expect(cms.calls, first);

    service.clearCache();
    await service.search('测试片名', [site]).toList();
    expect(cms.calls, first + 1);
  });

  test('多源并发合并：同一片名去重并标注来源数', () async {
    final cms = _FakeCms({
      'a': [_siteItem('a', '同一部片')],
      'b': [_siteItem('b', '同一部片')],
    });
    final service = SearchService(_service(cms));
    final sites = [
      SourceBean(key: 'a', name: 'A', type: 0, api: 'https://e.com/a'),
      SourceBean(key: 'b', name: 'B', type: 0, api: 'https://e.com/b'),
    ];

    final events = await service.search('同一部片', sites).toList();
    final last = events.last;
    expect(last.finished, isTrue);
    expect(last.items.length, 1, reason: '同名同源应合并成一条');
    expect(last.items.single.sameFromOtherSources, 1);
    expect(last.sourceItems['a']!.length, 1);
    expect(last.sourceItems['b']!.length, 1);
  });

  test('空关键词直接完成，不发起请求', () async {
    final cms = _FakeCms({});
    final service = SearchService(_service(cms));
    final events = await service.search('   ', const []).toList();
    expect(events.single.finished, isTrue);
    expect(cms.calls, 0);
  });

  group('熔断', () {
    test('连续失败两次后冷却跳过，冷却结束探活成功即自愈', () async {
      var now = DateTime(2026, 1, 1, 12);
      final breaker = SourceCircuitBreaker(clock: () => now);
      final failing = {'b'};
      final cms = _FakeCms({
        'a': [_siteItem('a', '测试片A')],
        'b': [_siteItem('b', '测试片B')],
      }, failing: failing);
      final service = SearchService(_service(cms), breaker: breaker);
      final siteA = SourceBean(
        key: 'a',
        name: 'A',
        type: 0,
        api: 'https://example.com/a',
      );
      final siteB = SourceBean(
        key: 'b',
        name: 'B',
        type: 0,
        api: 'https://example.com/b',
      );
      final sites = [siteA, siteB];
      final healthB = SearchService.healthKeyOf(siteB);

      // 第一次失败：只记账，不阻断。
      await service.search('测试', sites).toList();
      expect(cms.callsBySite['b'], 1);
      expect(breaker.failureCount(healthB), 1);
      expect(breaker.isAvailable(healthB), isTrue);

      // 第二次连续失败：进入 15 分钟冷却。
      await service.search('测试', sites).toList();
      expect(cms.callsBySite['b'], 2);
      expect(breaker.isAvailable(healthB), isFalse);

      // 冷却期内：跳过该源，不再打源站，但进度仍正常完成。
      final third = await service.search('测试', sites).toList();
      final thirdLast = third.last;
      expect(cms.callsBySite['b'], 2);
      expect(thirdLast.finished, isTrue);
      expect(thirdLast.done, 2);
      expect(thirdLast.total, 2);
      final coolingStatus = thirdLast.perSource.firstWhere((s) => s.key == 'b');
      expect(coolingStatus.status, 'error');
      expect(coolingStatus.error, contains('冷却'));
      expect(thirdLast.sourceItems['b'], isEmpty);

      // 冷却结束自动放行；这次成功 → 计数清零。
      now = now.add(const Duration(minutes: 15));
      failing.clear();
      final fourth = await service.search('测试', sites).toList();
      expect(cms.callsBySite['b'], 3);
      expect(breaker.isAvailable(healthB), isTrue);
      expect(breaker.failureCount(healthB), 0);
      expect(fourth.last.items.length, 2);
    });

    test('全部源冷却时立即完成，不发起任何请求', () async {
      final now = DateTime(2026, 1, 1, 12);
      final breaker = SourceCircuitBreaker(clock: () => now);
      final cms = _FakeCms({});
      final service = SearchService(_service(cms), breaker: breaker);
      final sites = [
        SourceBean(key: 'a', name: 'A', type: 0, api: 'https://example.com/a'),
        SourceBean(key: 'b', name: 'B', type: 0, api: 'https://example.com/b'),
      ];
      for (final site in sites) {
        final key = SearchService.healthKeyOf(site);
        breaker.recordFailure(key, 'timeout');
        breaker.recordFailure(key, 'timeout');
      }

      final events = await service.search('测试', sites).toList();
      expect(events.length, 1);
      final last = events.single;
      expect(last.finished, isTrue);
      expect(last.done, 2);
      expect(last.total, 2);
      expect(last.items, isEmpty);
      expect(last.perSource.every((s) => s.status == 'error'), isTrue);
      expect(cms.calls, 0);
    });
  });

  group('代际：旧搜索不再污染新结果', () {
    test('新搜索开始后，旧搜索迟到的结果被代际号丢弃', () async {
      final gate = Completer<void>();
      final cms = _SlowFirstCms(gate);
      final service = SearchService(_service(cms));
      final site = SourceBean(
        key: 'a',
        name: 'A',
        type: 0,
        api: 'https://example.com/a',
      );

      final firstEvents = <SearchProgress>[];
      final firstSub = service.search('旧词', [site]).listen(firstEvents.add);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      final second = await service.search('新词', [site]).toList();
      expect(second.last.finished, isTrue);
      expect(second.last.items.map((e) => e.name), contains('新词结果'));

      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await firstSub.cancel();
      expect(firstEvents, isEmpty);
    });

    test('过期的失败不计入熔断器，避免污染后续搜索', () async {
      final gate = Completer<void>();
      final cms = _SlowFirstCms(gate, throwOnSlow: true);
      final service = SearchService(_service(cms));
      final site = SourceBean(
        key: 'a',
        name: 'A',
        type: 0,
        api: 'https://example.com/a',
      );
      final healthKey = SearchService.healthKeyOf(site);

      final firstSub = service.search('旧词', [site]).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await service.search('新词', [site]).toList();

      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await firstSub.cancel();

      expect(service.breaker.failureCount(healthKey), 0);
      expect(service.breaker.isAvailable(healthKey), isTrue);
    });
  });

  group('结构化搜索语法', () {
    VodItem itemWith({
      required String name,
      String year = '',
      String type = '',
      String area = '',
    }) => VodItem(
      id: name,
      name: name,
      year: year,
      type: type,
      area: area,
      sourceKey: 'a',
    );

    test('year 过滤生效，且语法不进关键词', () async {
      final cms = _FakeCms({
        'a': [
          itemWith(name: '甲', year: '2024'),
          itemWith(name: '乙', year: '2019'),
        ],
      });
      final service = SearchService(_service(cms));
      final site = SourceBean(
        key: 'a',
        name: 'A',
        type: 0,
        api: 'https://example.com/a',
      );

      final events = await service.search('甲 year:2024', [site]).toList();
      final last = events.last;
      expect(last.items.map((e) => e.name), ['甲']);
      expect(last.filterSummary, '2024');
      expect(cms.lastKeyword, '甲');
    });

    test('缺失年份的结果不会被误杀', () async {
      final cms = _FakeCms({
        'a': [
          itemWith(name: '片名 有年份', year: '2020'),
          itemWith(name: '片名 没年份'),
        ],
      });
      final service = SearchService(_service(cms));
      final site = SourceBean(
        key: 'a',
        name: 'A',
        type: 0,
        api: 'https://example.com/a',
      );

      // 标题都含关键词「片名」，因此相关性过滤不会介入；年份过滤按缺失放行。
      final events = await service.search('片名 year:2024', [site]).toList();
      expect(
        events.last.items.map((e) => e.name),
        ['片名 没年份'],
        reason: '元数据缺失应放行，只淘汰明确不匹配的',
      );
    });

    test('排除词淘汰结果，也会作用于「只看单源」', () async {
      final cms = _FakeCms({
        'a': [
          itemWith(name: '正片'),
          itemWith(name: '正片解说'),
        ],
      });
      final service = SearchService(_service(cms));
      final site = SourceBean(
        key: 'a',
        name: 'A',
        type: 0,
        api: 'https://example.com/a',
      );

      final events = await service.search('正片 -解说', [site]).toList();
      final last = events.last;
      expect(last.items.map((e) => e.name), ['正片']);
      expect(last.sourceItems['a']!.map((e) => e.name), ['正片']);
      expect(cms.lastKeyword, '正片');
    });

    test('未知字段不当作语法，原样发给源站', () async {
      final cms = _FakeCms({
        'a': [itemWith(name: '甲')],
      });
      final service = SearchService(_service(cms));
      final site = SourceBean(
        key: 'a',
        name: 'A',
        type: 0,
        api: 'https://example.com/a',
      );
      await service.search('甲 site:abc', [site]).toList();
      expect(cms.lastKeyword, contains('site:abc'));
    });
  });

  group('不做相关性过滤（避免误杀）', () {
    test('与关键词毫无关系的条目也会保留：只排序，不丢弃', () async {
      // 任何基于字符串的相关性判定都会误杀译名与别名
      // （「NARUTO」与「火影忍者」在字符串层面毫无关系）。
      // 误杀的代价是「这个源搜不到东西」，比多显示几条噪音严重得多。
      const all = [
        '火影忍者',
        '火影忍者 疾风传',
        'NARUTO',
        'Naruto Shippuden',
        '军事',
        '南北',
        'HD中字',
        '歌曲：93首',
        '军火女王 第1季【日语】',
      ];

      final cms = _FakeCms({
        'a': [
          for (final name in all) VodItem(id: name, name: name, sourceKey: 'a'),
        ],
      });
      final service = SearchService(_service(cms));
      final site = SourceBean(
        key: 'a',
        name: 'A',
        type: 0,
        api: 'https://example.com/a',
      );

      final events = await service.search('火影忍者', [site]).toList();
      final names = events.last.items.map((e) => e.name).toSet();
      for (final name in all) {
        expect(names, contains(name), reason: '$name 不该被丢弃');
      }
      expect(names.length, all.length);
    });

    test('相关度只影响排序：完全命中的排最前', () async {
      final cms = _FakeCms({
        'a': [
          VodItem(id: '1', name: '军事', sourceKey: 'a'),
          VodItem(id: '2', name: '火影忍者', sourceKey: 'a'),
          VodItem(id: '3', name: '南北', sourceKey: 'a'),
        ],
      });
      final service = SearchService(_service(cms));
      final site = SourceBean(
        key: 'a',
        name: 'A',
        type: 0,
        api: 'https://example.com/a',
      );

      final events = await service.search('火影忍者', [site]).toList();
      final names = events.last.items.map((e) => e.name).toList();
      expect(names.length, 3, reason: '三条都要在');
      expect(names.first, '火影忍者', reason: '完全命中的应排最前');
    });

    test('结构化语法仍然生效（那是用户显式写的条件）', () async {
      final cms = _FakeCms({
        'a': [
          VodItem(id: '1', name: '火影忍者', year: '2024', sourceKey: 'a'),
          VodItem(id: '2', name: '火影忍者', year: '2019', sourceKey: 'a'),
          VodItem(id: '3', name: '火影忍者 影视解说', year: '2024', sourceKey: 'a'),
        ],
      });
      final service = SearchService(_service(cms));
      final site = SourceBean(
        key: 'a',
        name: 'A',
        type: 0,
        api: 'https://example.com/a',
      );
      // 年份与排除词是用户显式写的，按它们筛。
      final events = await service.search(
        '火影忍者 year:2024 -解说',
        [site],
      ).toList();
      expect(events.last.items.map((e) => e.year).toSet(), {'2024'});
      expect(
        events.last.items.map((e) => e.name),
        isNot(contains('火影忍者 影视解说')),
      );
    });
  });

  group('蜘蛛池并发', () {
    test('多个蜘蛛源同时发出，总耗时接近最慢的一个而不是累加', () async {
      const keys = ['s1', 's2', 's3', 's4', 's5'];
      final js = _SlowJsSpider(keys, delay: const Duration(milliseconds: 300));
      final service = SearchService(
        SourceService(
          CmsSource(AppHttp()),
          js,
          PySpiderService(),
          JarSpiderService(),
        ),
      );
      final sites = [
        for (final key in keys)
          SourceBean(key: key, name: key, type: 3, api: 'https://e.com/$key.js'),
      ];

      final sw = Stopwatch()..start();
      await service.search('片', sites).toList();
      sw.stop();

      // 并发 5 约 300ms；退化到并发 3 会 600ms 左右，串行 1500ms。
      expect(
        sw.elapsedMilliseconds,
        lessThan(900),
        reason: '蜘蛛源应并发执行，实际 ${sw.elapsedMilliseconds}ms',
      );
      expect(js.maxConcurrent, greaterThan(1));
    });
  });
}

/// 每个源都耗时固定的 JS 蜘蛛，用于验证并发度。
class _SlowJsSpider extends JsSpiderService {
  _SlowJsSpider(this.keys, {required this.delay});

  final List<String> keys;
  final Duration delay;
  int concurrent = 0;
  int maxConcurrent = 0;

  @override
  Future<List<VodItem>> search(SourceBean site, String keyword) async {
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    try {
      await Future<void>.delayed(delay);
      return keys.contains(site.key)
          ? [_siteItem(site.key, '${site.key} 结果')]
          : const [];
    } finally {
      concurrent--;
    }
  }
}

/// 第一次调用慢（等 [gate]），之后的调用立即返回，便于构造「旧搜索迟到」。
class _SlowFirstCms extends CmsSource {
  _SlowFirstCms(this.gate, {this.throwOnSlow = false}) : super(AppHttp());

  final Completer<void> gate;
  final bool throwOnSlow;
  int calls = 0;

  @override
  Future<List<VodItem>> search(SourceBean site, String keyword) async {
    calls++;
    if (calls == 1) {
      await gate.future;
      if (throwOnSlow) throw StateError('旧搜索失败');
      return [_siteItem(site.key, '旧词结果')];
    }
    return [_siteItem(site.key, '新词结果')];
  }
}

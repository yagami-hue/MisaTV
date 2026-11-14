import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/site_config.dart';
import 'package:kniephos/services/jar_spider/warmup_plan.dart';

SourceBean _jar(String key, {int searchable = 1}) => SourceBean(
  key: key,
  name: key,
  type: 3,
  api: 'https://e.com/$key.jar',
  searchable: searchable,
);

SourceBean _js(String key) =>
    SourceBean(key: key, name: key, type: 3, api: 'https://e.com/$key.js');

SourceBean _cms(String key) =>
    SourceBean(key: key, name: key, type: 0, api: 'https://e.com/$key');

void main() {
  test('运行时未就绪时不预热任何源', () {
    final plan = buildWarmUpPlan(
      sites: [_jar('a'), _jar('b')],
      runtimeReady: false,
      weightOf: (_) => 100,
    );
    expect(plan, isEmpty);
  });

  test('只挑 JAR 源，跳过 JS / CMS', () {
    final plan = buildWarmUpPlan(
      sites: [_js('js1'), _cms('cms1'), _jar('a')],
      runtimeReady: true,
      weightOf: (_) => 100,
    );
    expect(plan.map((e) => e.site.key), ['a']);
  });

  test('不预热用户关闭了参与搜索的源', () {
    final plan = buildWarmUpPlan(
      sites: [_jar('off', searchable: 0), _jar('on')],
      runtimeReady: true,
      weightOf: (_) => 100,
    );
    expect(plan.map((e) => e.site.key), ['on']);
  });

  test('按实测耗时升序：快的先预热', () {
    final weights = {'slow': 9000, 'fast': 200, 'mid': 3000};
    final plan = buildWarmUpPlan(
      sites: [_jar('slow'), _jar('fast'), _jar('mid')],
      runtimeReady: true,
      weightOf: (site) => weights[site.key] ?? 30000,
    );
    expect(plan.map((e) => e.site.key), ['fast', 'mid', 'slow']);
  });

  test('最多只预热 kWarmUpLimit 个', () {
    final sites = [for (var i = 0; i < 10; i++) _jar('j$i')];
    final plan = buildWarmUpPlan(
      sites: sites,
      runtimeReady: true,
      weightOf: (_) => 100,
    );
    expect(plan.length, kWarmUpLimit);
    // 同权重时保持原顺序。
    expect(plan.map((e) => e.site.key), ['j0', 'j1', 'j2']);
  });

  test('已知快源优先于未知源，未知源不会挤掉有档案的', () {
    final weights = {'known': 500};
    final plan = buildWarmUpPlan(
      sites: [_jar('unknown1'), _jar('known'), _jar('unknown2')],
      runtimeReady: true,
      weightOf: (site) => weights[site.key] ?? 30000,
    );
    expect(plan.first.site.key, 'known');
  });

  test('自定义 limit 生效，limit<=0 返回空', () {
    final sites = [for (var i = 0; i < 5; i++) _jar('j$i')];
    expect(
      buildWarmUpPlan(
        sites: sites,
        runtimeReady: true,
        weightOf: (_) => 1,
        limit: 2,
      ).length,
      2,
    );
    expect(
      buildWarmUpPlan(
        sites: sites,
        runtimeReady: true,
        weightOf: (_) => 1,
        limit: 0,
      ),
      isEmpty,
    );
  });

  test('空订阅返回空计划', () {
    expect(
      buildWarmUpPlan(
        sites: const [],
        runtimeReady: true,
        weightOf: (_) => 1,
      ),
      isEmpty,
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/matching/search_query.dart';

void main() {
  group('基本解析', () {
    test('纯关键词原样保留', () {
      final q = parseSearchQuery('流浪地球');
      expect(q.keyword, '流浪地球');
      expect(q.hasFilters, isFalse);
      expect(q.filterSummary, isEmpty);
    });

    test('空输入', () {
      final q = parseSearchQuery('   ');
      expect(q.keyword, isEmpty);
      expect(q.isEmpty, isTrue);
    });

    test('精确年份被吃出关键词，不发给源站', () {
      final q = parseSearchQuery('流浪地球 year:2019');
      expect(q.keyword, '流浪地球');
      expect(q.year, 2019);
      expect(q.hasFilters, isTrue);
      expect(q.filterSummary, '2019');
    });

    test('年份区间', () {
      final q = parseSearchQuery('剧 year:2020-2024');
      expect(q.keyword, '剧');
      expect(q.yearMin, 2020);
      expect(q.yearMax, 2024);
      expect(q.filterSummary, '2020–2024');
    });

    test('区间写法都支持，写反也能纠正', () {
      for (final raw in ['2020..2024', '2020~2024', '2020至2024', '2020-2024']) {
        final q = parseSearchQuery('x year:$raw');
        expect(q.yearMin, 2020, reason: raw);
        expect(q.yearMax, 2024, reason: raw);
      }
      final reversed = parseSearchQuery('x year:2024-2020');
      expect(reversed.yearMin, 2020);
      expect(reversed.yearMax, 2024);
    });

    test('半开区间', () {
      expect(parseSearchQuery('x year:2020..').yearMin, 2020);
      expect(parseSearchQuery('x year:2020..').yearMax, isNull);
      expect(parseSearchQuery('x year:..2024').yearMax, 2024);
      expect(parseSearchQuery('x year:..2024').yearMin, isNull);
    });

    test('type / area 支持多值与中文别名', () {
      final q = parseSearchQuery('x type:电影,电视剧 area:大陆/香港');
      expect(q.types, ['电影', '电视剧']);
      expect(q.areas, ['大陆', '香港']);

      final alias = parseSearchQuery('x 类型:动漫 地区:日本');
      expect(alias.types, ['动漫']);
      expect(alias.areas, ['日本']);
    });

    test('site: 不是本项目语法（单源搜索用 @源名）', () {
      final q = parseSearchQuery('x site:abc');
      expect(q.keyword, contains('site:abc'));
      expect(q.hasFilters, isFalse);
    });

    test('排除词', () {
      final q = parseSearchQuery('流浪地球 -解说 -预告');
      expect(q.keyword, '流浪地球');
      expect(q.excludes, ['解说', '预告']);
    });

    test('全角冒号也认', () {
      final q = parseSearchQuery('x year：2024');
      expect(q.year, 2024);
      expect(q.keyword, 'x');
    });

    test('字段名大小写不敏感', () {
      expect(parseSearchQuery('x YEAR:2024').year, 2024);
      expect(parseSearchQuery('x Type:电影').types, ['电影']);
    });
  });

  group('不能误吃正常输入', () {
    test('未知字段原样留在关键词里', () {
      final q = parseSearchQuery('复仇者联盟：终局之战');
      expect(q.keyword, '复仇者联盟：终局之战');
      expect(q.hasFilters, isFalse);
    });

    test('URL 里的冒号不被当成字段', () {
      final q = parseSearchQuery('http://example.com/a');
      expect(q.keyword, 'http://example.com/a');
      expect(q.hasFilters, isFalse);
    });

    test('已知字段但值非法时退回关键词，不静默丢弃', () {
      final q = parseSearchQuery('x year:abcd');
      expect(q.keyword, contains('year:abcd'));
      expect(q.year, isNull);
    });

    test('单独的减号是普通关键词', () {
      final q = parseSearchQuery('X - 战警');
      expect(q.keyword, contains('-'));
      expect(q.excludes, isEmpty);
    });

    test('字段无值时不吞掉', () {
      final q = parseSearchQuery('x year:');
      expect(q.keyword, contains('year:'));
    });
  });

  group('过滤：缺失元数据放行', () {
    final q = parseSearchQuery('x year:2024');

    test('年份匹配通过', () {
      expect(q.accepts(name: 'x', year: '2024'), isTrue);
    });

    test('年份不匹配被拒绝', () {
      expect(q.accepts(name: 'x', year: '2020'), isFalse);
    });

    test('年份缺失时放行（CMS 源常不带年份）', () {
      expect(q.accepts(name: 'x'), isTrue);
      expect(q.accepts(name: 'x', year: ''), isTrue);
      expect(q.accepts(name: 'x', year: '未知'), isTrue);
    });

    test('年份串里抽得出 4 位数字即可（如「2024-03-01」）', () {
      expect(q.accepts(name: 'x', year: '2024-03-01'), isTrue);
      expect(q.accepts(name: 'x', year: '2021-03-01'), isFalse);
    });
  });

  group('过滤：类型与地区', () {
    test('类型包含匹配，缺失放行', () {
      final q = parseSearchQuery('x type:电影');
      expect(q.accepts(name: 'x', type: '动作电影'), isTrue);
      expect(q.accepts(name: 'x', type: '电视剧'), isFalse);
      expect(q.accepts(name: 'x'), isTrue);
    });

    test('多类型之间是或', () {
      final q = parseSearchQuery('x type:电影,电视剧');
      expect(q.accepts(name: 'x', type: '电视剧'), isTrue);
      expect(q.accepts(name: 'x', type: '综艺'), isFalse);
    });

    test('地区同样规则', () {
      final q = parseSearchQuery('x area:大陆');
      expect(q.accepts(name: 'x', area: '中国大陆'), isTrue);
      expect(q.accepts(name: 'x', area: '美国'), isFalse);
      expect(q.accepts(name: 'x'), isTrue);
    });
  });

  group('过滤：排除词', () {
    test('命中排除词即淘汰，与元数据缺失无关', () {
      final q = parseSearchQuery('流浪地球 -解说');
      expect(q.accepts(name: '流浪地球 解说版'), isFalse);
      expect(q.accepts(name: '流浪地球'), isTrue);
    });

    test('排除词大小写不敏感', () {
      final q = parseSearchQuery('x -TRAILER');
      expect(q.accepts(name: 'movie trailer 2024'), isFalse);
    });
  });

  group('组合与摘要', () {
    test('多个条件可叠加', () {
      final q = parseSearchQuery('流浪地球 year:2019 type:电影 -解说');
      expect(q.keyword, '流浪地球');
      expect(q.year, 2019);
      expect(q.types, ['电影']);
      expect(q.excludes, ['解说']);
      expect(q.filterSummary, '2019 · 电影 · 排除 -解说');
    });

    test('没有条件时摘要为空', () {
      expect(parseSearchQuery('x').filterSummary, isEmpty);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/danmaku/danmaku_endpoints.dart';
import 'package:kniephos/services/danmaku/danmaku_models.dart';
import 'package:kniephos/services/danmaku/danmaku_query.dart';
import 'package:kniephos/services/matching/episode_normalizer.dart';
import 'package:kniephos/services/matching/text_key.dart';
import 'package:kniephos/services/matching/title_matching.dart';

void main() {
  group('标题归一化', () {
    test('去掉元数据标签、发布噪点与更新状态', () {
      expect(
        movieSearchTitle('[4K] 庆余年 第二季 更新至30集'),
        '庆余年 第二季',
      );
      expect(movieSearchTitle('庆余年.S02E05.2024.HDR'), '庆余年.2024');
      expect(movieSearchTitle('《庆余年》第05集'), '庆余年');
    });

    test('Dice 系数', () {
      expect(diceCoefficient('庆余年', '庆余年'), 1);
      expect(diceCoefficient('', '庆余年'), 0);
      expect(diceCoefficient('庆余年', '庆余年传奇'), greaterThan(0.5));
      expect(diceCoefficient('庆余年', '流浪地球'), 0);
    });

    test('相似度：精确 > 前缀 > 包含 > 模糊', () {
      expect(searchTitleScore('庆余年', '庆余年'), 100);
      expect(searchTitleScore('庆余年', '庆余年 第1集'), greaterThanOrEqualTo(75));
      expect(searchTitleScore('庆余年', '庆余年传奇'), 75);
      expect(searchTitleScore('庆余年', '年余庆'), 0);
    });

    test('季数与续作数字隔离', () {
      expect(searchTitleScore('庆余年 第二季', '庆余年 第三季'), 0);
      expect(
        searchTitleScore('庆余年 第二季', '庆余年 第二季 更新至30集'),
        greaterThanOrEqualTo(90),
      );
      expect(searchTitleScore('流浪地球2', '流浪地球'), 0);
      expect(searchTitleScore('流浪地球2', '流浪地球2 4K'), greaterThan(0));
    });

    test('短英文标题必须整词命中', () {
      expect(searchTitleScore('AI', 'BRAIN'), 0);
      expect(searchTitleScore('AI', 'AI 2026'), greaterThan(0));
    });

    test('跨源去重键：忽略发布标签与更新进度，但保留具体集号', () {
      expect(
        searchDedupeKey('[4K] 某剧 (国语) 更新至30集', year: '2026'),
        searchDedupeKey('某剧', year: '2026'),
      );
      expect(
        searchDedupeKey('某剧【动漫】', year: '2026'),
        searchDedupeKey('某剧', year: '2026'),
      );
      expect(
        searchDedupeKey('某剧 第01集', year: '2026'),
        searchDedupeKey('某剧 第1集', year: '2026'),
      );
      expect(
        searchDedupeKey('某剧 第1集', year: '2026'),
        isNot(searchDedupeKey('某剧 第2集', year: '2026')),
      );
      expect(
        searchDedupeKey('某剧 S01E01', year: '2026'),
        searchDedupeKey('某剧 S1E1', year: '2026'),
      );
    });
  });

  group('中文数字', () {
    test('解析常见中文数字', () {
      expect(parseChineseNumber('十'), 10);
      expect(parseChineseNumber('十二'), 12);
      expect(parseChineseNumber('二十'), 20);
      expect(parseChineseNumber('二十三'), 23);
      expect(parseChineseNumber('一百零五'), 105);
      expect(parseChineseNumber('随便'), isNull);
    });
  });

  group('集数归一化', () {
    test('季集编码', () {
      final info = normalizeEpisodeInfo('庆余年.S02E05.1080p');
      expect(info.season, 2);
      expect(info.episode, 5);
      expect(info.cleanTitle, '庆余年');
    });

    test('第 N 集 / 中文数字 / 更新至', () {
      expect(normalizeEpisodeInfo('第05集 决战').episode, 5);
      expect(normalizeEpisodeInfo('第十二集').episode, 12);
      expect(normalizeEpisodeInfo('更新至30集').episode, 30);
      expect(normalizeEpisodeInfo('至8').episode, 8);
      expect(normalizeEpisodeInfo('随便').episode, isNull);
    });

    test('综艺日期 / 特别篇 / 区间集', () {
      final variety = normalizeEpisodeInfo('2024-05-10期 下集预告');
      expect(variety.dateOrdinal, '20240510');
      expect(variety.episode, isNull);
      expect(normalizeEpisodeInfo('20240510').dateOrdinal, '20240510');

      final special = normalizeEpisodeInfo('SP01');
      expect(special.isSpecial, isTrue);
      expect(special.episode, 1);

      final range = normalizeEpisodeInfo('第05-06集');
      expect(range.episode, 5);
      expect(range.episodeEnd, 6);
    });

    test('不把年份和分辨率误当集号', () {
      expect(normalizeEpisodeInfo('2024').episode, isNull);
      expect(normalizeEpisodeInfo('4K').episode, isNull);
      expect(normalizeEpisodeInfo('1080p').episode, isNull);
    });

    test('同集判断', () {
      expect(matchEpisodes('第5集', 'EP05'), isTrue);
      expect(matchEpisodes('第5集', '第6集'), isFalse);
      expect(matchEpisodes('第二季 第5集', '第三季 第5集'), isFalse);
      expect(matchEpisodes('01-02', '第2集'), isTrue);
      expect(matchEpisodes('2024-05-10期', '20240510'), isTrue);
      expect(matchEpisodes('SP01', '第1集'), isFalse);
    });
  });

  group('弹幕查询归一化', () {
    test('集号输入支持中文数字与日期', () {
      expect(parseEpisodeInput('第十二集').ep, '12');
      expect(parseEpisodeInput('更新至30集').ep, '30');
      expect(parseEpisodeInput('2024-05-10期').ep, isNull);
    });

    test('资源名生成集号输入', () {
      expect(episodeFieldFromName('斗罗大陆.S02E03.1080p'), 'S2E03');
      expect(episodeFieldFromName('某剧 第十二集'), '12');
      expect(episodeFieldFromName('2024-05-10期'), '');
    });

    test('候选显示支持中文数字集号', () {
      expect(
        formatCandidateLabel(title: '某剧 第二季 第十二集'),
        '某剧 · 第2季 · 第12集',
      );
      expect(seasonOf('第二季'), 2);
    });

    test('epNumberOf 支持中文数字与更新状态', () {
      const candidate = DanmakuCandidate(episodeId: 1, episodeTitle: '第十二集');
      expect(epNumberOf(candidate), 12);
      const update = DanmakuCandidate(episodeId: 2, episodeTitle: '更新至30集');
      expect(epNumberOf(update), 30);
    });
  });
}

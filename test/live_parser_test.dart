import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/live_parser.dart';
import 'package:kniephos/services/live_service.dart';

void main() {
  group('LiveParser txt', () {
    test('分组、多 URL、合并与去重', () {
      const txt = '''
央视频道,#genre#
CCTV1,http://a/1.m3u8#http://a/2.m3u8
CCTV1,http://a/1.m3u8#http://a/3.m3u8
坏频道,not-a-url
地方,#genre#
CCTV2,http://b/1.m3u8\$LR•IPV4『线路1』
''';
      final groups = LiveParser.parseToGroups(txt);
      expect(groups.length, 2);
      final cctv = groups.first.channels.first;
      expect(cctv.name, 'CCTV1');
      expect(cctv.urls.length, 3);
      expect(groups[1].channels.first.urls.first, contains(r'$LR•IPV4'));
    });

    test('Ungrouped 归一为直播', () {
      const txt = 'Ungrouped,#genre#\n频道,http://x/1.m3u8';
      final groups = LiveParser.parseToGroups(txt);
      expect(groups.first.group, '直播');
    });
  });

  group('LiveService 已知直播 UA', () {
    test('live.ottiptv.cc 固定 qqlive（host 不区分大小写）', () {
      expect(LiveService.defaultUaLiveHost('live.ottiptv.cc'), 'qqlive');
      expect(LiveService.defaultUaLiveHost('LIVE.OTTIPTV.CC'), 'qqlive');
      expect(LiveService.defaultUaLiveHost('other.example.com'), isNull);
    });
  });

  group('LiveParser m3u', () {
    test('分组、台标、EPG 子串怪癖', () {
      const m3u = '''
#EXTM3U x-tvg-url="http://epg/list.xml"
#EXTINF:-1 tvg-id="1" tvg-name="CCTV1" tvg-logo="http://logo/1.png" group-title="央视",CCTV1
http://live/1.m3u8
#EXTINF:-1 group-title="卫视",卫视台
http://live/2.m3u8
''';
      final groups = LiveParser.parseToGroups(m3u);
      expect(groups.length, 2);
      expect(groups.first.group, '央视');
      final ch = groups.first.channels.first;
      expect(ch.name, 'CCTV1');
      expect(ch.logo, 'http://logo/1.png');
      // 刻意复刻：tvg-url 正则会命中 x-tvg-url
      expect(ch.epg, 'http://epg/list.xml');
      expect(groups[1].channels.first.name, '卫视台');
    });

    test('JSON 数组格式', () {
      const json = '''
      [{"group":"组1_密码","channels":[{"name":"CCTV1","urls":["http://a/1.m3u8\$线路1","http://a/2.m3u8"],"logo":"http://l"}]}]
      ''';
      final groups = LiveParser.parseToGroups(json);
      expect(groups.first.group, '组1_密码');
      expect(groups.first.channels.first.urls.length, 2);
    });
  });
}

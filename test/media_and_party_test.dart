import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/local_media.dart';
import 'package:kniephos/models/media_server.dart';
import 'package:kniephos/services/party/party_room.dart';
import 'package:kniephos/services/party/watch_party.dart';

void main() {
  group('媒体服务器配置', () {
    test('JSON 往返保留类型与 API Key', () {
      const server = MediaServer(
        id: 'm1',
        kind: MediaServerKind.emby,
        name: '客厅',
        baseUrl: 'http://192.168.1.10:8096',
        apiKey: 'secret',
        userId: 'u1',
        userName: '爸爸',
      );
      final restored = MediaServer.fromJson(server.toJson());
      expect(restored.kind, MediaServerKind.emby);
      expect(restored.baseUrl, 'http://192.168.1.10:8096');
      expect(restored.apiKey, 'secret');
      expect(restored.userId, 'u1');
    });

    test('未知类型回落到 Jellyfin', () {
      expect(MediaServerKind.fromValue('plex'), MediaServerKind.jellyfin);
      expect(MediaServerKind.fromValue('emby'), MediaServerKind.emby);
    });

    test('条目解析：集号、时长与已看进度', () {
      final item = MediaItem.fromJson({
        'Id': 'e1',
        'Name': '试播集',
        'Type': 'Episode',
        'SeriesId': 's1',
        'SeriesName': '某剧',
        'ParentIndexNumber': 1,
        'IndexNumber': 2,
        'RunTimeTicks': 600000000,
        'ImageTags': {'Primary': 'tag123'},
        'UserData': {'PlaybackPositionTicks': 120000000, 'Played': false},
      });
      expect(item.subtitle, 'S1 E2');
      expect(item.runTimeMs, 60000);
      expect(item.positionMs, 12000);
      expect(item.imageTag, 'tag123');
      expect(item.isSeries, isFalse);
    });
  });

  group('本地媒体文件判定', () {
    test('常见容器都算视频', () {
      expect(isLocalVideoFile(r'D:\movies\a.mkv'), isTrue);
      expect(isLocalVideoFile('/mnt/a.MP4'), isTrue);
      expect(isLocalVideoFile('/mnt/a.nfo'), isFalse);
    });
  });

  group('一起看', () {
    test('房主地址归一：补协议、去尾斜杠', () {
      expect(normalizeLanBase(' 192.168.1.5:9979/ '), 'http://192.168.1.5:9979');
      expect(normalizeLanBase('http://host:1///'), 'http://host:1');
      expect(normalizeLanBase(''), '');
    });

    test('房间状态 JSON 往返', () {
      const state = PartyState(
        title: '某剧',
        episodeName: '第 3 集',
        episodeIndex: 2,
        positionMs: 61000,
        playing: true,
        updatedAt: 123,
        sender: '客厅',
      );
      final restored = PartyState.fromJson(state.toJson());
      expect(restored.title, '某剧');
      expect(restored.episodeIndex, 2);
      expect(restored.positionMs, 61000);
      expect(restored.playing, isTrue);
      expect(restored.sender, '客厅');
    });

    test('房间只有发布后才是 open', () {
      final room = PartyRoom();
      expect(room.open, isFalse);
      room
        ..code = 'ABC123'
        ..hostName = '客厅';
      expect(room.open, isFalse);
      room.publish(const PartyState(title: '某剧', updatedAt: 1));
      expect(room.open, isTrue);
      expect(room.revision, 1);
      room.clear();
      expect(room.open, isFalse);
      expect(room.revision, 0);
    });
  });
}

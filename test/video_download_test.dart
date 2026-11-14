import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/video_download.dart';
import 'package:kniephos/models/video_download_record.dart';
import 'package:kniephos/services/download/hls_playlist.dart';
import 'package:kniephos/services/download/video_download_manager.dart';
import 'package:kniephos/services/download/video_download_service.dart';
import 'package:kniephos/services/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('HLS 主清单', () {
    test('识别主清单并按码率选最高一档', () {
      const text = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
high/index.m3u8
#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=1200000
mid/index.m3u8
''';
      expect(isHlsMasterPlaylist(text), isTrue);
      expect(
        pickHlsVariant(text, 'https://cdn.example.com/vod/master.m3u8'),
        'https://cdn.example.com/vod/high/index.m3u8',
      );
    });

    test('绝对地址原样返回，无码率信息时返回 null', () {
      expect(
        pickHlsVariant(
          '#EXT-X-STREAM-INF:BANDWIDTH=1000\nhttps://a.example.com/x.m3u8',
          'https://cdn.example.com/master.m3u8',
        ),
        'https://a.example.com/x.m3u8',
      );
      expect(pickHlsVariant('#EXTM3U\n', 'https://a.example.com/m.m3u8'), isNull);
    });

    test('媒体清单不会被误判为主清单', () {
      expect(
        isHlsMasterPlaylist('#EXTM3U\n#EXTINF:4,\nseg0.ts\n'),
        isFalse,
      );
    });
  });

  group('媒体清单', () {
    test('解析分片 / 序号 / 相对地址', () {
      const text = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:7
#EXTINF:4.0,
seg0.ts
#EXTINF:4.0,
sub/seg1.ts
''';
      final playlist = parseHlsMediaPlaylist(
        text,
        'https://cdn.example.com/live/index.m3u8',
      );
      expect(playlist.segments.length, 2);
      expect(playlist.segments[0].url, 'https://cdn.example.com/live/seg0.ts');
      expect(playlist.segments[0].sequence, 7);
      expect(playlist.segments[1].url, 'https://cdn.example.com/live/sub/seg1.ts');
      expect(playlist.segments[1].sequence, 8);
      expect(playlist.hasInit, isFalse);
    });

    test('解析 AES-128 密钥、IV 与初始化段', () {
      const text = '''
#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x0102030405060708090a0b0c0d0e0f10
#EXTINF:4.0,
seg0.m4s
''';
      final playlist = parseHlsMediaPlaylist(
        text,
        'https://cdn.example.com/vod/media.m3u8',
      );
      expect(playlist.initUri, 'https://cdn.example.com/vod/init.mp4');
      expect(playlist.hasInit, isTrue);
      final segment = playlist.segments.single;
      expect(segment.keyUri, 'https://cdn.example.com/vod/key.bin');
      expect(segment.ivHex, '0x0102030405060708090a0b0c0d0e0f10');
    });

    test('KEY 声明为 NONE 时后续分片不加密', () {
      const text = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:4.0,
enc.ts
#EXT-X-KEY:METHOD=NONE
#EXTINF:4.0,
plain.ts
''';
      final playlist = parseHlsMediaPlaylist(
        text,
        'https://cdn.example.com/vod/media.m3u8',
      );
      expect(playlist.segments[0].keyUri, isNotNull);
      expect(playlist.segments[1].keyUri, isNull);
      expect(playlist.segments[1].ivHex, isNull);
    });

    test('BYTERANGE 省略偏移时接着上一段结束位置', () {
      const text = '''
#EXTM3U
#EXTINF:4.0,
#EXT-X-BYTERANGE:100@0
a.ts
#EXTINF:4.0,
#EXT-X-BYTERANGE:50
b.ts
''';
      final playlist = parseHlsMediaPlaylist(
        text,
        'https://cdn.example.com/vod/media.m3u8',
      );
      expect(playlist.segments[0].range?.value, 'bytes=0-99');
      expect(playlist.segments[1].range?.value, 'bytes=100-149');
    });

    test('不支持的加密方式抛 StateError', () {
      const text = '''
#EXTM3U
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key"
#EXTINF:4.0,
seg0.ts
''';
      expect(
        () => parseHlsMediaPlaylist(
          text,
          'https://cdn.example.com/vod/media.m3u8',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('hlsAttribute', () {
    test('带引号与不带引号的属性都能取到', () {
      const line = '#EXT-X-KEY:METHOD=AES-128,URI="k.bin",IV=0x01';
      expect(hlsAttribute(line, 'METHOD'), 'AES-128');
      expect(hlsAttribute(line, 'URI'), 'k.bin');
      expect(hlsAttribute(line, 'IV'), '0x01');
      expect(hlsAttribute(line, 'NOPE'), isNull);
    });
  });

  group('下载辅助', () {
    test('识别 HLS 地址', () {
      expect(looksLikeHlsUrl('https://a.com/x/index.M3U8?t=1'), isTrue);
      expect(looksLikeHlsUrl('https://a.com/x/file.mp4'), isFalse);
      expect(looksLikeHlsUrl(''), isFalse);
    });

    test('文件名清洗：非法字符、尾部点号与空名', () {
      expect(sanitizeDownloadFileName(' 名侦探柯南/第1集: 测试? '), '名侦探柯南_第1集_ 测试_');
      expect(sanitizeDownloadFileName('name...'), 'name');
      expect(sanitizeDownloadFileName('   '), 'video');
      expect(sanitizeDownloadFileName('a\u0000b'), 'a_b');
    });

    test('文件名超长时截断到 120 字符', () {
      final name = sanitizeDownloadFileName('集' * 200);
      expect(name.length, 120);
    });
  });

  group('VideoDownloadProgress', () {
    test('优先按字节算进度，其次按分段数', () {
      expect(
        const VideoDownloadProgress(receivedBytes: 50, totalBytes: 200)
            .fraction,
        0.25,
      );
      expect(
        const VideoDownloadProgress(completedSegments: 3, totalSegments: 4)
            .fraction,
        0.75,
      );
      expect(const VideoDownloadProgress().fraction, isNull);
    });

    test('分段进度不会超过 1', () {
      expect(
        const VideoDownloadProgress(completedSegments: 5, totalSegments: 4)
            .fraction,
        1.0,
      );
    });

    test('active / failed 状态', () {
      expect(const VideoDownloadProgress().active, isTrue);
      expect(const VideoDownloadProgress(done: true).active, isFalse);
      expect(const VideoDownloadProgress(cancelled: true).active, isFalse);
      expect(const VideoDownloadProgress(paused: true).active, isFalse);
      expect(const VideoDownloadProgress(error: 'x').failed, isTrue);
      expect(const VideoDownloadProgress(error: 'x').active, isFalse);
    });

    test('copyWith 保留未指定字段', () {
      const origin = VideoDownloadProgress(
        receivedBytes: 1,
        totalBytes: 2,
        stage: '下载中…',
      );
      final next = origin.copyWith(receivedBytes: 2, done: true);
      expect(next.receivedBytes, 2);
      expect(next.totalBytes, 2);
      expect(next.stage, '下载中…');
      expect(next.done, isTrue);
    });
  });

  group('下载记录', () {
    test('JSON 往返保留状态、请求头与进度', () {
      final record = VideoDownloadRecord(
        id: '1',
        title: '剧集 01',
        url: 'http://127.0.0.1:9978/play?u=x',
        sourceUrl: 'https://a.com/x.m3u8',
        headers: const {'Referer': 'https://a.com'},
        hls: true,
        directory: '/tmp/downloads',
        filePath: '/tmp/downloads/剧集 01.ts',
        receivedBytes: 10,
        totalBytes: 100,
        completedSegments: 2,
        totalSegments: 10,
        stage: '下载分片 2/10',
        status: VideoDownloadStatus.paused,
        createdAt: 100,
        updatedAt: 200,
      );
      final restored = VideoDownloadRecord.fromJson(record.toJson());
      expect(restored, isNotNull);
      expect(restored!.title, '剧集 01');
      expect(restored.headers['Referer'], 'https://a.com');
      expect(restored.hls, isTrue);
      expect(restored.status, VideoDownloadStatus.paused);
      expect(restored.fraction, 0.1);
      expect(restored.updatedAt, 200);
    });

    test('缺字段 / 未知状态时保持可读', () {
      final record = VideoDownloadRecord.fromJson({
        'id': '2',
        'url': 'https://a.com/x.mp4',
        'status': 'weird',
      });
      expect(record, isNotNull);
      expect(record!.status, VideoDownloadStatus.paused);
      expect(record.title, '');
      expect(VideoDownloadRecord.fromJson({'id': '', 'url': ''}), isNull);
    });

    test('状态与可续传判断', () {
      final record = VideoDownloadRecord(
        id: '3',
        title: 'x',
        url: 'https://a.com/x.mp4',
        sourceUrl: 'https://a.com/x.mp4',
      );
      expect(record.active, isTrue);
      record.status = VideoDownloadStatus.failed;
      expect(record.canResume, isTrue);
      record.status = VideoDownloadStatus.completed;
      expect(record.canResume, isFalse);
    });
  });

  group('下载目录助手', () {
    test('同名文件自动追加序号', () async {
      final dir = await Directory.systemTemp.createTemp('kniephos_dl_');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final sep = Platform.pathSeparator;
      File('${dir.path}$sep剧集 01.mp4').writeAsStringSync('x');
      final second = allocateDownloadPath(
        dir.path,
        '剧集 01',
        'https://a.com/x.mp4',
      );
      expect(second, endsWith('剧集 01 (2).mp4'));
      File(second).writeAsStringSync('y');
      final third = allocateDownloadPath(
        dir.path,
        '剧集 01',
        'https://a.com/x.mp4',
      );
      expect(third, endsWith('剧集 01 (3).mp4'));
    });

    test('deleteDownloadFile 同时删除 .part', () async {
      final dir = await Directory.systemTemp.createTemp('kniephos_dl_');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final sep = Platform.pathSeparator;
      final target = File('${dir.path}${sep}a.mp4');
      final part = File('${target.path}.part');
      target.writeAsStringSync('done');
      part.writeAsStringSync('half');
      await deleteDownloadFile(target.path);
      expect(target.existsSync(), isFalse);
      expect(part.existsSync(), isFalse);
    });
  });

  group('下载记录持久化', () {
    test('保存后能读回；上次未完成的任务恢复为暂停', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await LocalStore.create();
      final record = VideoDownloadRecord(
        id: 'r1',
        title: '测试视频',
        url: 'https://a.com/x.mp4',
        sourceUrl: 'https://a.com/x.mp4',
        headers: const {'User-Agent': 'test'},
        status: VideoDownloadStatus.downloading,
        createdAt: 1,
        updatedAt: 1,
      );
      await store.saveVideoDownloadRecords([record]);
      final loaded = store.loadVideoDownloadRecords();
      expect(loaded.single.title, '测试视频');
      expect(loaded.single.headers['User-Agent'], 'test');

      final manager = VideoDownloadManager(store);
      manager.loadIfNeeded();
      expect(manager.records.single.status, VideoDownloadStatus.paused);
      expect(manager.records.single.stage, contains('上次未完成'));

      await manager.clearRecords();
      expect(manager.records, isEmpty);
      manager.dispose();
    });
  });
}

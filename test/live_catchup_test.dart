import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/live.dart';
import 'package:kniephos/services/live/catchup.dart';
import 'package:kniephos/services/live/epg.dart';

LiveChannel _channel({
  String catchupType = '',
  String catchupSource = '',
}) => LiveChannel(
  name: '测试频道',
  urls: const ['http://example.com/live/stream.m3u8'],
  catchupType: catchupType,
  catchupSource: catchupSource,
);

EpgProgram _program({
  int startHour = 12,
  int durationMinutes = 30,
}) {
  final start = DateTime(2026, 1, 1, startHour);
  final end = start.add(Duration(minutes: durationMinutes));
  return EpgProgram(
    title: '测试节目',
    start: '12:00',
    end: '12:30',
    startTime: start.millisecondsSinceEpoch,
    endTime: end.millisecondsSinceEpoch,
  );
}

void main() {
  group('直播回看地址', () {
    test('append：catchup-source 作为后缀并替换占位符', () {
      final program = _program();
      final result = buildCatchupUrl(
        channel: _channel(
          catchupType: 'append',
          catchupSource: '?utc={utc}&lutc={lutc}',
        ),
        liveUrl: 'http://example.com/live/stream.m3u8',
        program: program,
        nowMs: program.endTime + 60000,
      );
      expect(result, isNotNull);
      expect(result!.kind, 'append');
      expect(result.url, contains('/live/stream.m3u8?utc='));
      expect(result.url, contains('lutc='));
    });

    test('append：catchup-source 是完整 URL 模板', () {
      final program = _program();
      final result = buildCatchupUrl(
        channel: _channel(
          catchupType: 'append',
          catchupSource: 'http://archive.test/{Ymd}/{Y-m-d:H-M}.m3u8',
        ),
        liveUrl: 'http://example.com/live/stream.m3u8',
        program: program,
      );
      expect(result?.url, 'http://archive.test/20260101/2026-01-01:12-00.m3u8');
    });

    test('append：source 没有问号时自动补分隔符', () {
      final program = _program();
      final result = buildCatchupUrl(
        channel: _channel(
          catchupType: 'append',
          catchupSource: 'start={utc}',
        ),
        liveUrl: 'http://example.com/live/stream.m3u8',
        program: program,
      );
      expect(result?.url, contains('/live/stream.m3u8?start='));
    });

    test('shift：追加 utc 与 lutc，保留原查询参数', () {
      final program = _program();
      final result = buildCatchupUrl(
        channel: _channel(catchupType: 'shift'),
        liveUrl: 'http://example.com/live/stream.m3u8?token=abc',
        program: program,
        nowMs: program.endTime + 120000,
      );
      expect(result, isNotNull);
      expect(result!.kind, 'shift');
      expect(result.url, contains('token=abc'));
      expect(result.url, contains('utc=${program.startTime ~/ 1000}'));
      expect(result.url, contains('lutc='));
    });

    test('xc：拼 Xtream Codes timeshift 地址', () {
      final program = _program();
      final result = buildCatchupUrl(
        channel: _channel(catchupType: 'xc'),
        liveUrl: 'http://host:8080/live/user/pass/123.m3u8',
        program: program,
      );
      expect(result, isNotNull);
      expect(result!.kind, 'xc');
      expect(
        result.url,
        'http://host:8080/timeshift/user/pass/30/2026-01-01:12-00/123.m3u8',
      );
    });

    test('flussonic：改写为 timeshift_abs 地址', () {
      final program = _program();
      final result = buildCatchupUrl(
        channel: _channel(catchupType: 'flussonic'),
        liveUrl: 'http://host/stream/index.m3u8',
        program: program,
      );
      expect(result, isNotNull);
      expect(result!.kind, 'flussonic');
      expect(
        result.url,
        'http://host/stream/timeshift_abs-${program.startTime ~/ 1000}.m3u8',
      );
    });

    test('没有声明回看 / 非法地址 / 零时长返回 null', () {
      final program = _program();
      expect(
        buildCatchupUrl(
          channel: _channel(),
          liveUrl: 'http://example.com/live.m3u8',
          program: program,
        ),
        isNull,
      );
      expect(
        buildCatchupUrl(
          channel: _channel(catchupType: 'shift'),
          liveUrl: '',
          program: program,
        ),
        isNull,
      );
      final zero = EpgProgram(
        title: '坏节目',
        start: '12:00',
        end: '12:00',
        startTime: program.startTime,
        endTime: program.startTime,
      );
      expect(
        buildCatchupUrl(
          channel: _channel(catchupType: 'shift'),
          liveUrl: 'http://example.com/live.m3u8',
          program: zero,
        ),
        isNull,
      );
    });
  });
}

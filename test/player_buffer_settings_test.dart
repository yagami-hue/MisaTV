import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/user_data.dart';

void main() {
  group('播放缓冲 / 边播缓存设置', () {
    test('默认值：预缓冲 1s、最大 15s、缓存关、上限 1 GB', () {
      final settings = PlayerSettings.fromJson({});
      expect(settings.bufferMinSec, 1.0);
      expect(settings.bufferMaxSec, 15.0);
      expect(settings.bufferTuned, isFalse);
      expect(settings.streamCache, isFalse);
      expect(settings.streamCacheMb, 1024);
    });

    test('没调过缓冲的旧配置升级到新默认值，调过的保持原样', () {
      // 旧版本没写 bufferTuned：当时的 1s / 4s 是默认值，不是用户选择。
      final legacy = PlayerSettings.fromJson({
        'bufferMinSec': 1.0,
        'bufferMaxSec': 4.0,
      });
      expect(legacy.bufferMaxSec, 15.0);
      expect(legacy.bufferTuned, isFalse);

      final tuned = PlayerSettings.fromJson({
        'bufferMinSec': 2.5,
        'bufferMaxSec': 30.0,
        'bufferTuned': true,
      });
      expect(tuned.bufferMinSec, 2.5);
      expect(tuned.bufferMaxSec, 30.0);
      expect(tuned.bufferTuned, isTrue);
    });

    test('copyWith → toJson → fromJson 往返保持设置', () {
      final settings = PlayerSettings.fromJson({}).copyWith(
        bufferMinSec: 2.5,
        bufferMaxSec: 30,
        bufferTuned: true,
        streamCache: true,
        streamCacheMb: 2048,
      );
      final restored = PlayerSettings.fromJson(settings.toJson());
      expect(restored.bufferMinSec, 2.5);
      expect(restored.bufferMaxSec, 30.0);
      expect(restored.bufferTuned, isTrue);
      expect(restored.streamCache, isTrue);
      expect(restored.streamCacheMb, 2048);
    });

    test('越界 / 非法值收敛到合法区间，旧配置缺字段走默认', () {
      final settings = PlayerSettings.fromJson({
        'bufferMinSec': -3,
        'bufferMaxSec': 9999,
        'bufferTuned': true,
        'streamCacheMb': 1,
      });
      expect(settings.bufferMinSec, 0.2);
      expect(settings.bufferMaxSec, 120.0);
      expect(settings.streamCacheMb, 128);
      expect(settings.streamCache, isFalse);
    });

    test('copyWith 不传时保留已有缓冲设置', () {
      final settings = PlayerSettings.fromJson({}).copyWith(
        bufferMinSec: 3,
        streamCache: true,
      );
      final again = settings.copyWith(volume: 0.5);
      expect(again.bufferMinSec, 3.0);
      expect(again.streamCache, isTrue);
      expect(again.bufferMaxSec, settings.bufferMaxSec);
    });
  });
}

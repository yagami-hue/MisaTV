import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/player/sleep_timer.dart';

void main() {
  group('固定时长', () {
    test('设定后状态正确，剩余时间随时钟减少', () {
      var now = DateTime(2026, 1, 1, 23, 0);
      var fired = 0;
      final timer = SleepTimer(
        clock: () => now,
        onExpire: () => fired++,
      );
      timer.startForDuration(const Duration(minutes: 30));

      expect(timer.active, isTrue);
      expect(timer.state.mode, SleepTimerMode.duration);
      expect(timer.state.remainingMs(now.millisecondsSinceEpoch), 30 * 60 * 1000);

      now = now.add(const Duration(minutes: 10));
      expect(timer.state.remainingMs(now.millisecondsSinceEpoch), 20 * 60 * 1000);
      expect(timer.state.progress(now.millisecondsSinceEpoch), closeTo(1 / 3, 0.01));
      expect(fired, 0);

      timer.dispose();
    });

    test('重复设定会覆盖旧值', () {
      final now = DateTime(2026, 1, 1);
      final timer = SleepTimer(clock: () => now, onExpire: () {});
      timer.startForDuration(const Duration(minutes: 60));
      timer.startForDuration(const Duration(minutes: 15));
      expect(timer.state.totalMs, 15 * 60 * 1000);
      timer.dispose();
    });

    test('时长为 0 视为取消', () {
      final timer = SleepTimer(onExpire: () {});
      timer.startForDuration(Duration.zero);
      expect(timer.active, isFalse);
      timer.dispose();
    });

    test('checkExpired 在超过截止时间后触发（补上休眠期间的到期）', () {
      var now = DateTime(2026, 1, 1);
      var fired = 0;
      final timer = SleepTimer(clock: () => now, onExpire: () => fired++);
      timer.startForDuration(const Duration(minutes: 5));
      // 模拟系统休眠：真实 Timer 不走，时钟却已越过截止时间。
      now = now.add(const Duration(minutes: 10));
      expect(fired, 0);
      timer.checkExpired();
      expect(fired, 1);
      expect(timer.active, isFalse);
      timer.dispose();
    });

    test('未到期时 checkExpired 不触发', () {
      var now = DateTime(2026, 1, 1);
      var fired = 0;
      final timer = SleepTimer(clock: () => now, onExpire: () => fired++);
      timer.startForDuration(const Duration(minutes: 30));
      now = now.add(const Duration(minutes: 1));
      timer.checkExpired();
      expect(fired, 0);
      timer.dispose();
    });
  });

  group('播完当前视频', () {
    test('非该模式时 handleVideoEnded 返回 false（正常连播）', () {
      final timer = SleepTimer(onExpire: () {});
      expect(timer.handleVideoEnded(), isFalse);
      timer.dispose();
    });

    test('该模式下返回 true 并触发到期', () {
      var fired = 0;
      final timer = SleepTimer(onExpire: () => fired++);
      timer.startAtEndOfVideo();
      expect(timer.state.mode, SleepTimerMode.endOfVideo);
      expect(timer.handleVideoEnded(), isTrue);
      expect(fired, 1);
      expect(timer.active, isFalse);
      timer.dispose();
    });

    test('到期后自动复位，不重复触发', () {
      var fired = 0;
      final timer = SleepTimer(onExpire: () => fired++);
      timer.startAtEndOfVideo();
      timer.handleVideoEnded();
      timer.handleVideoEnded();
      expect(fired, 1);
      timer.dispose();
    });

    test('endOfVideo 模式没有倒计时剩余时间', () {
      final timer = SleepTimer(onExpire: () {});
      timer.startAtEndOfVideo();
      expect(timer.state.remainingMs(0), isNull);
      expect(timer.state.progress(0), isNull);
      timer.dispose();
    });
  });

  group('取消与状态回调', () {
    test('取消后不再触发', () {
      final now = DateTime(2026, 1, 1);
      var fired = 0;
      final timer = SleepTimer(clock: () => now, onExpire: () => fired++);
      timer.startForDuration(const Duration(minutes: 5));
      timer.cancel();
      timer.checkExpired();
      expect(fired, 0);
      expect(timer.active, isFalse);
      timer.dispose();
    });

    test('状态变化会回调', () {
      final states = <SleepTimerMode?>[];
      final timer = SleepTimer(
        onExpire: () {},
        onChanged: (s) => states.add(s.mode),
      );
      timer.startForDuration(const Duration(minutes: 5));
      timer.cancel();
      expect(states, [SleepTimerMode.duration, null]);
      timer.dispose();
    });

    test('重复 cancel 不重复回调', () {
      final states = <SleepTimerMode?>[];
      final timer = SleepTimer(
        onExpire: () {},
        onChanged: (s) => states.add(s.mode),
      );
      timer.cancel();
      timer.cancel();
      expect(states, isEmpty);
      timer.dispose();
    });
  });

  group('时长格式化', () {
    test('分:秒 与 时:分:秒', () {
      expect(SleepTimer.formatDuration(30 * 1000), '00:30');
      expect(SleepTimer.formatDuration(90 * 1000), '01:30');
      expect(SleepTimer.formatDuration(30 * 60 * 1000), '30:00');
      expect(SleepTimer.formatDuration(65 * 60 * 1000), '1:05:00');
    });

    test('向上取整：剩 0.4 秒显示 1 秒，不显示 0', () {
      expect(SleepTimer.formatDuration(400), '00:01');
      expect(SleepTimer.formatDuration(1), '00:01');
    });

    test('0 与负值不崩溃', () {
      expect(SleepTimer.formatDuration(0), '00:00');
      expect(() => SleepTimer.formatDuration(-100), returnsNormally);
    });
  });
}

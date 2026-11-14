import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/jar_spider/payload_selection.dart';

void main() {
  group('精确记录（index[className]）', () {
    test('文件存在就收，即使目标类判定不含也收', () {
      // 精确记录代表「本类验证成功过」，不该被启发式否掉。
      final r = judgePayloadEntry(
        entryKind: 'exact',
        fileExists: true,
        containsWanted: false,
        wantedKnown: true,
      );
      expect(r.accept, isTrue);
      expect(r.reason, 'exact-record');
    });

    test('文件不存在则跳过', () {
      final r = judgePayloadEntry(
        entryKind: 'exact',
        fileExists: false,
        containsWanted: true,
        wantedKnown: true,
      );
      expect(r.accept, isFalse);
      expect(r.reason, 'missing-file');
    });
  });

  group('默认记录（*）绝对不能无条件当候选', () {
    test('不含目标类时跳过（这是「以前能用突然不行」的根因）', () {
      // 实测：c3bb107b 的 * 指向 b66f…，里面一个 Wex 类都没有。
      // 旧代码把它塞进候选，占掉候选位并可能被优先试跑。
      final r = judgePayloadEntry(
        entryKind: 'star',
        fileExists: true,
        containsWanted: false,
        wantedKnown: true,
      );
      expect(r.accept, isFalse);
      expect(r.reason, 'star-lacks-target');
    });

    test('含目标类时收下', () {
      final r = judgePayloadEntry(
        entryKind: 'star',
        fileExists: true,
        containsWanted: true,
        wantedKnown: true,
      );
      expect(r.accept, isTrue);
      expect(r.reason, 'star-has-target');
    });

    test('目标类未知时只能放行（预热等场景）', () {
      final r = judgePayloadEntry(
        entryKind: 'star',
        fileExists: true,
        containsWanted: false,
        wantedKnown: false,
      );
      expect(r.accept, isTrue);
      expect(r.reason, 'star-no-target');
    });

    test('文件不存在则跳过', () {
      final r = judgePayloadEntry(
        entryKind: 'star',
        fileExists: false,
        containsWanted: true,
        wantedKnown: true,
      );
      expect(r.accept, isFalse);
    });
  });

  group('真实数据回归：一个 key 下多只壳的聚合包', () {
    // 复刻 D 盘实测的 c3bb107b 目录结构。
    const starPackage = 'b66f1b8f6a90fe9b865a1e5ec40a5dce.r2.jar';
    const wexPackage = '80dbe70af76c8458093245ff74b455eb.r2.jar';

    // 简化模型：包 → 是否含某类。
    bool packageContains(String pkg, String cls) {
      if (pkg == wexPackage) {
        return cls.startsWith('Wex') || cls == 'Wogg';
      }
      return cls == 'AppV7' || cls == 'Bili';
    }

    test('已记录的 Wex 壳走精确记录，命中正确的包', () {
      final r = judgePayloadEntry(
        entryKind: 'exact',
        fileExists: true,
        containsWanted: packageContains(wexPackage, 'WexNewHuYa'),
        wantedKnown: true,
      );
      expect(r.accept, isTrue);
    });

    test('未记录的新 Wex 壳：默认包被跳过，不会误加载', () {
      // 新壳（订阅热更新带来的）：index 里没有精确记录，
      // 只能看 `*` 指向的 starPackage —— 它不含任何 Wex 类。
      final r = judgePayloadEntry(
        entryKind: 'star',
        fileExists: true,
        containsWanted: packageContains(starPackage, 'WexSomeNewShell'),
        wantedKnown: true,
      );
      expect(
        r.accept,
        isFalse,
        reason: '默认包不含目标类时必须跳过，让全量扫描找正确的包',
      );
    });

    test('star 恰好指向含该类的包时仍然可用', () {
      final r = judgePayloadEntry(
        entryKind: 'star',
        fileExists: true,
        containsWanted: packageContains(starPackage, 'AppV7'),
        wantedKnown: true,
      );
      expect(r.accept, isTrue);
    });
  });
}

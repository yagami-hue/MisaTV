import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/source_circuit_breaker.dart';

void main() {
  late DateTime now;
  late SourceCircuitBreaker breaker;

  setUp(() {
    now = DateTime(2026, 1, 1, 12);
    breaker = SourceCircuitBreaker(clock: () => now);
  });

  test('首次失败只记账，不阻断下一次搜索', () {
    expect(breaker.recordFailure('a', 'timeout'), Duration.zero);
    expect(breaker.isAvailable('a'), isTrue);
    expect(breaker.failureCount('a'), 1);
    expect(breaker.cooldownRemaining('a'), Duration.zero);
  });

  test('不同连续失败次数触发阶梯冷却', () {
    breaker.recordFailure('a', 'timeout');
    expect(
      breaker.recordFailure('a', 'timeout'),
      const Duration(minutes: 15),
    );
    expect(breaker.isAvailable('a'), isFalse);

    now = now.add(const Duration(minutes: 15));
    expect(breaker.isAvailable('a'), isTrue);
    expect(
      breaker.recordFailure('a', 'timeout'),
      const Duration(hours: 2),
    );

    now = now.add(const Duration(hours: 2));
    expect(breaker.isAvailable('a'), isTrue);
    expect(
      breaker.recordFailure('a', 'timeout'),
      const Duration(hours: 24),
    );
    expect(breaker.cooldownRemaining('a'), const Duration(hours: 24));
  });

  test('成功一次立即自愈，冷却结束自动放行', () {
    breaker.recordFailure('a', 'timeout');
    breaker.recordFailure('a', 'timeout');
    expect(breaker.isAvailable('a'), isFalse);

    breaker.recordSuccess('a');
    expect(breaker.failureCount('a'), 0);
    expect(breaker.isAvailable('a'), isTrue);
    expect(breaker.coolingCount, 0);
  });

  test('手动重置单个源或全部源', () {
    breaker.recordFailure('a', 'timeout');
    breaker.recordFailure('a', 'timeout');
    breaker.recordFailure('b', 'timeout');
    breaker.recordFailure('b', 'timeout');
    expect(breaker.coolingCount, 2);

    breaker.reset('a');
    expect(breaker.isAvailable('a'), isTrue);
    expect(breaker.isAvailable('b'), isFalse);

    breaker.reset();
    expect(breaker.coolingCount, 0);
    expect(breaker.isAvailable('b'), isTrue);
  });

  test('错误文本截断，避免长堆栈常驻内存', () {
    breaker.recordFailure('a', 'x' * 1000);
    final record = breaker.recordOf('a');
    expect(record, isNotNull);
    expect(record!.lastError.length, lessThanOrEqualTo(301));
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/spider_debug/spider_debug_service.dart';

SpiderDebugRunner _echoRunner({String output = 'ok'}) =>
    ({required method, required args, required onRequest}) async {
      onRequest('GET https://example.com/$method');
      return output;
    };

void main() {
  group('开关与安全边界', () {
    test('默认关闭：create 直接抛异常', () {
      final service = SpiderDebugService();
      expect(service.enabled, isFalse);
      expect(
        () => service.create(),
        throwsA(isA<SpiderDebugException>()),
      );
    });

    test('开启后可以创建会话，id 足够长', () {
      final service = SpiderDebugService()..enabled = true;
      final session = service.create();
      expect(session.id.length, 32);
      expect(service.sessionCount, 1);
    });

    test('会话数量有上限', () {
      final service = SpiderDebugService(maxSessions: 2)..enabled = true;
      service.create();
      service.create();
      expect(
        () => service.create(),
        throwsA(isA<SpiderDebugException>()),
      );
    });

    test('未知 session 返回 null（不能靠猜 id 操作别人会话）', () {
      final service = SpiderDebugService()..enabled = true;
      expect(service.find('不存在'), isNull);
      expect(service.find(null), isNull);
      expect(service.find(''), isNull);
    });

    test('closeAll 之后旧会话不可用', () {
      final service = SpiderDebugService()..enabled = true;
      final session = service.create();
      service.closeAll();
      expect(service.find(session.id), isNull);
      expect(service.sessionCount, 0);
    });
  });

  group('TTL 过期', () {
    test('空闲超过 TTL 的会话被 find 清理', () {
      var now = DateTime(2026, 1, 1, 12);
      final service = SpiderDebugService(clock: () => now)
        ..enabled = true;
      final session = service.create();

      // 未过期：还能拿到。
      now = now.add(const Duration(minutes: 5));
      expect(service.find(session.id), isNotNull);

      // 超过 15 分钟 TTL：应被清掉。
      now = now.add(const Duration(minutes: 20));
      expect(service.find(session.id), isNull);
    });

    test('访问会续期', () {
      var now = DateTime(2026, 1, 1, 12);
      final service = SpiderDebugService(clock: () => now)..enabled = true;
      final session = service.create();

      now = now.add(const Duration(minutes: 10));
      service.find(session.id); // 续期
      now = now.add(const Duration(minutes: 10));
      expect(service.find(session.id), isNotNull, reason: '续期后不该过期');
    });
  });

  group('执行与代际', () {
    test('正常执行返回 done 与请求记录', () async {
      final session = SpiderDebugSession(id: 's1');
      final snapshot = await session.run(
        runner: _echoRunner(output: '{"items":[]}'),
        method: 'home',
        args: const {'site': 'a'},
      );
      expect(snapshot.state, 'done');
      expect(snapshot.result, '{"items":[]}');
      expect(snapshot.requests.single, contains('example.com/home'));
      expect(snapshot.method, 'home');
    });

    test('执行失败进入 error 状态并保留错误文本', () async {
      final session = SpiderDebugSession(id: 's1');
      final snapshot = await session.run(
        runner: ({required method, required args, required onRequest}) async {
          throw StateError('源站炸了');
        },
        method: 'search',
        args: const {},
      );
      expect(snapshot.state, 'error');
      expect(snapshot.result, contains('源站炸了'));
    });

    test('执行中再 run 被拒绝（一次只允许一个请求）', () async {
      final session = SpiderDebugSession(id: 's1');
      final gate = Completer<void>();
      final first = session.run(
        runner: ({required method, required args, required onRequest}) async {
          await gate.future;
          return 'done';
        },
        method: 'home',
        args: const {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(session.busy, isTrue);
      expect(
        () => session.run(
          runner: _echoRunner(),
          method: 'home',
          args: const {},
        ),
        throwsA(isA<SpiderDebugException>()),
      );
      gate.complete();
      await first;
    });

    test('超时把会话标记为 timedout', () async {
      final session = SpiderDebugSession(id: 's1');
      final snapshot = await session.run(
        runner: ({required method, required args, required onRequest}) =>
            Completer<String>().future, // 永不完成
        method: 'home',
        args: const {},
        timeout: const Duration(milliseconds: 60),
      );
      expect(snapshot.state, 'timedout');
      expect(snapshot.result, contains('超时'));
    });

    test('超时后迟到的结果不会覆盖快照', () async {
      final session = SpiderDebugSession(id: 's1');
      final gate = Completer<String>();
      final timedOut = await session.run(
        runner: ({required method, required args, required onRequest}) =>
            gate.future,
        method: 'home',
        args: const {},
        timeout: const Duration(milliseconds: 40),
      );
      expect(timedOut.state, 'timedout');

      // 让执行体完成：它属于上一个代际，不能写进快照。
      gate.complete('迟到的结果');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(session.state, SpiderDebugState.timedOut);
      expect(session.snapshot().result, isNot(contains('迟到的结果')));
    });

    test('cancel 把进行中的请求标记为 cancelled', () async {
      final session = SpiderDebugSession(id: 's1');
      final gate = Completer<void>();
      final running = session.run(
        runner: ({required method, required args, required onRequest}) async {
          await gate.future;
          return 'late';
        },
        method: 'home',
        args: const {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final cancelled = session.cancel();
      expect(cancelled.state, 'cancelled');
      gate.complete();
      await running;
      expect(session.state, SpiderDebugState.cancelled);
    });

    test('请求记录有上限', () async {
      final session = SpiderDebugSession(id: 's1');
      final snapshot = await session.run(
        runner: ({required method, required args, required onRequest}) async {
          for (var i = 0; i < SpiderDebugSession.maxRequests + 50; i++) {
            onRequest('GET https://example.com/$i');
          }
          return 'ok';
        },
        method: 'home',
        args: const {},
      );
      expect(snapshot.requests.length, SpiderDebugSession.maxRequests);
    });

    test('会话关闭后拒绝执行', () async {
      final session = SpiderDebugSession(id: 's1')..close();
      expect(
        () => session.run(
          runner: _echoRunner(),
          method: 'home',
          args: const {},
        ),
        throwsA(isA<SpiderDebugException>()),
      );
    });
  });

  group('请求解析', () {
    test('只接受白名单 method', () {
      expect(
        parseSpiderDebugRequest(const {'method': 'home'}).method,
        'home',
      );
      expect(
        () => parseSpiderDebugRequest(const {'method': 'init'}),
        throwsA(isA<SpiderDebugException>()),
      );
      expect(
        () => parseSpiderDebugRequest(const {}),
        throwsA(isA<SpiderDebugException>()),
      );
    });

    test('timeout 越界被拒绝', () {
      expect(
        () => parseSpiderDebugRequest(const {'method': 'home', 'timeout': 0}),
        throwsA(isA<SpiderDebugException>()),
      );
      expect(
        () =>
            parseSpiderDebugRequest(const {'method': 'home', 'timeout': 301}),
        throwsA(isA<SpiderDebugException>()),
      );
      expect(
        parseSpiderDebugRequest(const {'method': 'home', 'timeout': 30})
            .timeout
            .inSeconds,
        30,
      );
    });

    test('args 非 Map 时回落到空', () {
      final parsed = parseSpiderDebugRequest(const {
        'method': 'home',
        'args': 'oops',
      });
      expect(parsed.args, isEmpty);
    });
  });

  test('响应是合法 JSON 且含关键字段', () {
    const snapshot = SpiderDebugSnapshot(
      session: 's1',
      state: 'done',
      result: 'ok',
      elapsedMs: 12,
      requests: ['GET https://a.test/x'],
      method: 'home',
    );
    final decoded = jsonDecode(encodeSpiderDebugResponse(snapshot));
    expect(decoded, isA<Map>());
    expect(decoded['state'], 'done');
    expect(decoded['session'], 's1');
    expect(decoded['elapsed'], 12);
  });
}

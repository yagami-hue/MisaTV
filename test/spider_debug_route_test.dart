import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/relay/local_relay.dart';
import 'package:kniephos/services/spider_debug/spider_debug_service.dart';

/// 端到端验证 `/debug/spider`：默认关闭、跨站拒绝、正常执行。
void main() {
  late Directory root;
  late LocalRelay relay;
  late SpiderDebugService debug;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('kniephos-debug-');
    relay = LocalRelay.instance;
    debug = SpiderDebugService();
    await relay.start(
      fileRoot: root.path,
      driveTokens: () => const {},
      rules: () => const [],
      purifyEnabled: () => false,
    );
    relay.debugService = debug;
    relay.spiderDebugRunner =
        ({required String method, required Map<String, dynamic> args, required void Function(String) onRequest}) async {
          onRequest('GET https://example.com/$method');
          return '{"ok":true,"method":"$method"}';
        };
  });

  tearDownAll(() async {
    debug.closeAll();
    await relay.stop();
    await root.delete(recursive: true);
  });

  setUp(() => debug.closeAll());

  Future<({int status, String body})> call(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('${relay.baseUrl}$path'));
      headers.forEach(req.headers.set);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(body);
      }
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      return (status: res.statusCode, body: text);
    } finally {
      client.close(force: true);
    }
  }

  test('默认关闭：建会话返回 403', () async {
    debug.enabled = false;
    final result = await call('POST', '/debug/spider/session');
    expect(result.status, 403);
    expect(result.body, contains('未开启'));
  });

  test('开启后可以建会话并执行', () async {
    debug.enabled = true;
    final created = await call('POST', '/debug/spider/session');
    expect(created.status, 200);
    final session = (jsonDecode(created.body) as Map)['session'] as String;
    expect(session.length, 32);

    final run = await call(
      'POST',
      '/debug/spider?session=$session',
      body: jsonEncode({'method': 'home', 'args': {'site': 'a'}}),
    );
    expect(run.status, 200);
    final decoded = jsonDecode(run.body) as Map;
    expect(decoded['state'], 'done');
    expect('${decoded['result']}', contains('"method":"home"'));
    expect((decoded['requests'] as List).single, contains('example.com/home'));
  });

  test('跨站请求即使开启也被拒绝', () async {
    debug.enabled = true;
    final blocked = await call(
      'POST',
      '/debug/spider/session',
      headers: {'origin': 'https://evil.example'},
    );
    expect(blocked.status, 403);
  });

  test('无效 session 返回 401，不泄漏是否存在', () async {
    debug.enabled = true;
    final result = await call(
      'POST',
      '/debug/spider?session=ffff',
      body: jsonEncode({'method': 'home'}),
    );
    expect(result.status, 401);
    expect(result.body, contains('不存在或已过期'));
  });

  test('非法 method 返回 409', () async {
    debug.enabled = true;
    final created = await call('POST', '/debug/spider/session');
    final session = (jsonDecode(created.body) as Map)['session'] as String;
    final result = await call(
      'POST',
      '/debug/spider?session=$session',
      body: jsonEncode({'method': 'destroyEverything'}),
    );
    expect(result.status, 409);
    expect(result.body, contains('不支持'));
  });

  test('请求体不是 JSON 返回 400', () async {
    debug.enabled = true;
    final created = await call('POST', '/debug/spider/session');
    final session = (jsonDecode(created.body) as Map)['session'] as String;
    final result = await call(
      'POST',
      '/debug/spider?session=$session',
      body: 'not-json',
    );
    expect(result.status, 400);
  });

  test('GET 读取快照；DELETE 关闭会话', () async {
    debug.enabled = true;
    final created = await call('POST', '/debug/spider/session');
    final session = (jsonDecode(created.body) as Map)['session'] as String;

    final snapshot = await call('GET', '/debug/spider?session=$session');
    expect(snapshot.status, 200);
    expect((jsonDecode(snapshot.body) as Map)['state'], 'idle');

    final removed = await call('DELETE', '/debug/spider?session=$session');
    expect(removed.status, 200);
    // 关掉之后同一个 id 不可再用。
    final after = await call('GET', '/debug/spider?session=$session');
    expect(after.status, 401);
  });

  test('关闭开关后已有会话立即失效', () async {
    debug.enabled = true;
    final created = await call('POST', '/debug/spider/session');
    final session = (jsonDecode(created.body) as Map)['session'] as String;

    debug.enabled = false;
    final blocked = await call('GET', '/debug/spider?session=$session');
    expect(blocked.status, 403);
  });
}

// 蜘蛛调试会话（纯逻辑状态机，可注入时钟与执行器，便于单测）。
//
// 用途：对某个源跑一次 home / search / detail / play，看到原始返回、耗时与
// 期间所有 `req()` 记录。现有排查手段只有翻日志，源站行为一变就得靠猜。
//
// 安全边界（很重要，这里能执行任意蜘蛛脚本）：
//   · 只在中继的 loopback 端口暴露，且必须由调用方显式开启（默认关闭）；
//   · HTTP 层强制同源（`relay_origin.dart` 把非媒体路由的跨站请求一律拒绝）；
//   · 会话有 TTL 与数量上限，进程退出即失效，不落盘任何脚本内容。
//
// 与 FongMi 的 SpiderTest 同构的关键设计：
//   · 每次 run 递增 generation，回调时比对，旧请求的回调直接丢弃；
//   · 超时用独立 deadline 终结会话，而不是裸等；
//   · 一次只允许一个进行中的请求（idle 检查），避免并发把运行时打爆。

import 'dart:async';
import 'dart:convert';
import 'dart:math';

/// 会话状态。
enum SpiderDebugState {
  idle,
  loading,
  running,
  done,
  error,
  cancelled,
  timedOut,
}

extension SpiderDebugStateLabel on SpiderDebugState {
  String get label => switch (this) {
    SpiderDebugState.idle => 'idle',
    SpiderDebugState.loading => 'loading',
    SpiderDebugState.running => 'running',
    SpiderDebugState.done => 'done',
    SpiderDebugState.error => 'error',
    SpiderDebugState.cancelled => 'cancelled',
    SpiderDebugState.timedOut => 'timedout',
  };

  /// 进行中的状态：此时不接受新的 run。
  bool get busy => this == SpiderDebugState.loading || this == SpiderDebugState.running;
}

/// 调试执行器：由 AppState 注入，实际调用 SourceService。
///
/// [onRequest] 用于记录蜘蛛在执行期间发出的每一次网络请求（`req()` / curl）。
typedef SpiderDebugRunner = Future<String> Function({
  required String method,
  required Map<String, dynamic> args,
  required void Function(String request) onRequest,
});

/// 一次会话的快照（回给调试端）。
class SpiderDebugSnapshot {
  const SpiderDebugSnapshot({
    required this.session,
    required this.state,
    required this.result,
    required this.elapsedMs,
    required this.requests,
    required this.method,
  });

  final String session;
  final String state;
  final String result;
  final int elapsedMs;

  /// 本次执行期间观察到的请求地址（有上限，避免撑爆响应体）。
  final List<String> requests;
  final String method;

  Map<String, dynamic> toJson() => {
    'session': session,
    'state': state,
    'result': result,
    'elapsed': elapsedMs,
    'requests': requests,
    'method': method,
  };
}

/// 单个调试会话。
class SpiderDebugSession {
  SpiderDebugSession({
    required this.id,
    this.ttl = const Duration(minutes: 15),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    // 构造函数体里用注入时钟初始化：字段初始化器不能引用 this。
    _lastAccess = _clock();
  }

  final String id;

  /// 会话空闲存活时间；每次访问都会续期。
  final Duration ttl;

  /// 注入的时钟：TTL 与耗时统计都走它，单测可以不真实等待。
  final DateTime Function() _clock;

  /// 单次请求最多记录多少条 `req()`，防止响应体过大。
  static const int maxRequests = 100;

  SpiderDebugState _state = SpiderDebugState.idle;
  int _generation = 0;
  String _result = '';
  String _method = '';
  int _elapsedMs = 0;
  final List<String> _requests = [];
  DateTime _lastAccess = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _deadline;
  bool _closed = false;

  /// 当前进行中那次 run 的等待者。
  ///
  /// 必须持有它：取消 / 关闭 / 超时都会让代际号失效，`finish()` 因此直接返回，
  /// 若不在这里主动完成，`run()` 返回的 Future 就永远不会结束，调用方（HTTP
  /// 请求）会一直挂着直到客户端超时。
  Completer<SpiderDebugSnapshot>? _pending;

  SpiderDebugState get state => _state;
  bool get closed => _closed;
  DateTime get lastAccess => _lastAccess;
  bool get busy => _state.busy;

  void touch() => _lastAccess = _clock();

  SpiderDebugSnapshot snapshot() => SpiderDebugSnapshot(
    session: id,
    state: _state.label,
    result: _result,
    elapsedMs: _elapsedMs,
    requests: List.unmodifiable(_requests),
    method: _method,
  );

  /// 执行一次蜘蛛方法。
  ///
  /// 允许执行时返回结果；会话已结束或正忙时抛 [SpiderDebugException]，
  /// 由 HTTP 层映射成 4xx / 409。
  Future<SpiderDebugSnapshot> run({
    required SpiderDebugRunner runner,
    required String method,
    required Map<String, dynamic> args,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_closed) throw const SpiderDebugException('调试会话已结束');
    if (busy) throw const SpiderDebugException('已有请求在执行，请先取消');
    touch();

    final generation = ++_generation;
    _state = SpiderDebugState.running;
    _method = method;
    _result = '';
    _elapsedMs = 0;
    _requests.clear();
    final startedAt = _clock();
    final completer = Completer<SpiderDebugSnapshot>();
    _pending = completer;

    void settle(SpiderDebugState state, String result, {Object? error}) {
      if (completer.isCompleted) return;
      _state = state;
      _result = error == null ? result : '$error';
      _elapsedMs = _clock().difference(startedAt).inMilliseconds;
      _pending = null;
      completer.complete(snapshot());
    }

    void finish(SpiderDebugState state, String result, {Object? error}) {
      // 代际已变（被取消 / 超时 / 关闭）：结果作废，但等待者已在对应分支完成。
      if (_closed || generation != _generation) return;
      _cancelDeadline();
      settle(state, result, error: error);
    }

    _deadline?.cancel();
    _deadline = Timer(timeout, () {
      if (_closed || generation != _generation) return;
      // 超时只是把会话标记为结束；执行器仍可能在后台跑完，但它的结果会因
      // generation 已变而被丢弃，不会再写进快照。
      _generation++;
      _cancelDeadline();
      settle(SpiderDebugState.timedOut, '蜘蛛执行超时（${timeout.inSeconds}s）');
    });

    unawaited(() async {
      try {
        final output = await runner(
          method: method,
          args: args,
          onRequest: (request) {
            if (_closed || generation != _generation) return;
            if (_requests.length >= maxRequests) return;
            _requests.add(request);
          },
        );
        finish(SpiderDebugState.done, output);
      } catch (e) {
        finish(SpiderDebugState.error, '', error: e);
      }
    }());

    return completer.future;
  }

  /// 取消进行中的请求（不影响后续 run）。
  SpiderDebugSnapshot cancel() {
    touch();
    if (busy) {
      _generation++;
      _cancelDeadline();
      _state = SpiderDebugState.cancelled;
      _result = '已取消';
      _completePending();
    }
    return snapshot();
  }

  void close() {
    _closed = true;
    _generation++;
    _cancelDeadline();
    _state = SpiderDebugState.cancelled;
    _completePending();
  }

  /// 让仍在等待的那次 run 立即结束，避免调用方挂死。
  void _completePending() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(snapshot());
    }
  }

  bool isExpired(DateTime now) =>
      !busy && now.difference(_lastAccess) > ttl;

  void _cancelDeadline() {
    _deadline?.cancel();
    _deadline = null;
  }
}

/// 调试层错误（HTTP 层映射成 4xx）。
class SpiderDebugException implements Exception {
  const SpiderDebugException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 会话管理器：数量上限 + TTL 清理。
class SpiderDebugService {
  SpiderDebugService({
    DateTime Function()? clock,
    this.maxSessions = 8,
    Duration? ttl,
  }) : _clock = clock ?? DateTime.now,
       ttl = ttl ?? const Duration(minutes: 15);

  /// 全局开关：默认关闭。关闭时不再接受任何调用，已有会话也会被清掉。
  bool enabled = false;

  final DateTime Function() _clock;
  final int maxSessions;
  final Duration ttl;

  final Map<String, SpiderDebugSession> _sessions = {};
  final Random _random = Random.secure();

  int get sessionCount => _sessions.length;

  /// 新建会话；达到上限时先清理过期会话，仍然满则拒绝。
  SpiderDebugSession create() {
    if (!enabled) throw const SpiderDebugException('蜘蛛调试未开启');
    prune();
    if (_sessions.length >= maxSessions) {
      throw const SpiderDebugException('调试会话过多，请关闭旧会话');
    }
    final id = _newId();
    final session = SpiderDebugSession(id: id, ttl: ttl, clock: _clock);
    _sessions[id] = session;
    return session;
  }

  SpiderDebugSession? find(String? id) {
    if (id == null || id.trim().isEmpty) return null;
    final session = _sessions[id.trim()];
    if (session == null) return null;
    if (session.isExpired(_clock())) {
      _sessions.remove(id.trim());
      session.close();
      return null;
    }
    session.touch();
    return session;
  }

  /// 关闭并移除会话。
  void remove(String id) {
    final session = _sessions.remove(id);
    session?.close();
  }

  /// 清理过期会话，返回被清掉的数量。
  int prune() {
    final now = _clock();
    final dead = [
      for (final entry in _sessions.entries)
        if (entry.value.isExpired(now)) entry.key,
    ];
    for (final id in dead) {
      remove(id);
    }
    return dead.length;
  }

  /// 关闭全部会话（关闭开关 / 退出时调用）。
  void closeAll() {
    for (final session in _sessions.values) {
      session.close();
    }
    _sessions.clear();
  }

  String _newId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// 把调试请求体解析成 `{method, args}`；非法输入抛 [SpiderDebugException]。
({String method, Map<String, dynamic> args, Duration timeout}) parseSpiderDebugRequest(
  Map<String, dynamic> body,
) {
  final method = (body['method'] ?? '').toString().trim();
  if (method.isEmpty) {
    throw const SpiderDebugException('缺少 method');
  }
  // 只允许这几个公开的蜘蛛入口，避免调试口变成任意反射入口。
  const allowed = {'home', 'category', 'detail', 'search', 'live', 'play'};
  if (!allowed.contains(method)) {
    throw SpiderDebugException('不支持的 method：$method');
  }
  final rawArgs = body['args'];
  final args = rawArgs is Map
      ? Map<String, dynamic>.from(rawArgs)
      : <String, dynamic>{};
  final seconds = (body['timeout'] as num?)?.toInt() ?? 60;
  if (seconds < 1 || seconds > 300) {
    throw const SpiderDebugException('timeout 必须在 1..300 秒之间');
  }
  return (method: method, args: args, timeout: Duration(seconds: seconds));
}

/// 把调试结果编码成响应体（固定 JSON，便于脚本消费）。
String encodeSpiderDebugResponse(SpiderDebugSnapshot snapshot) =>
    jsonEncode(snapshot.toJson());

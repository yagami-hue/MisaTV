// 源健康度阶梯熔断（纯 Dart，可注入时钟，便于单测）。
//
// 聚合搜索会对几十个源并发请求。失效源如果每次都参与，会把每轮搜索拖到
// 单源超时上限。这里按连续失败次数做阶梯冷却：
//   · 第 1 次失败：只记账，不阻断（偶发抖动）；
//   · 第 2 次失败：冷却 15 分钟；
//   · 第 3 次失败：冷却 2 小时；
//   · 第 4 次及以上：冷却 24 小时；
// 冷却结束自动放行一次探测；成功一次立即清零并恢复正常。
import 'dart:convert';
class SourceCircuitRecord {
  const SourceCircuitRecord({
    required this.failureCount,
    required this.lastFailureAt,
    required this.cooldownUntil,
    this.lastError = '',
  });

  final int failureCount;
  final DateTime lastFailureAt;
  final DateTime cooldownUntil;
  final String lastError;

  Map<String, dynamic> toJson() => {
    'failureCount': failureCount,
    'lastFailureAt': lastFailureAt.millisecondsSinceEpoch,
    'cooldownUntil': cooldownUntil.millisecondsSinceEpoch,
    'lastError': lastError,
  };

  factory SourceCircuitRecord.fromJson(Map<String, dynamic> json) {
    final failure = (json['failureCount'] as num?)?.toInt() ?? 0;
    final last = (json['lastFailureAt'] as num?)?.toInt() ?? 0;
    final until = (json['cooldownUntil'] as num?)?.toInt() ?? 0;
    return SourceCircuitRecord(
      failureCount: failure,
      lastFailureAt: DateTime.fromMillisecondsSinceEpoch(last),
      cooldownUntil: DateTime.fromMillisecondsSinceEpoch(until),
      lastError: (json['lastError'] ?? '').toString(),
    );
  }
}

class SourceCircuitBreaker {
  SourceCircuitBreaker({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const List<Duration> cooldownLevels = [
    Duration(minutes: 15),
    Duration(hours: 2),
    Duration(hours: 24),
  ];

  final DateTime Function() _clock;
  final Map<String, SourceCircuitRecord> _records = {};

  SourceCircuitRecord? recordOf(String key) => _records[key];

  int failureCount(String key) => _records[key]?.failureCount ?? 0;

  bool isAvailable(String key) {
    final record = _records[key];
    return record == null || !_clock().isBefore(record.cooldownUntil);
  }

  Duration cooldownRemaining(String key) {
    final record = _records[key];
    if (record == null) return Duration.zero;
    final remaining = record.cooldownUntil.difference(_clock());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// 记录一次失败，返回本次触发的冷却时长（0 = 不阻断）。
  Duration recordFailure(String key, Object error) {
    final now = _clock();
    final nextCount = failureCount(key) + 1;
    final cooldown = _cooldownFor(nextCount);
    _records[key] = SourceCircuitRecord(
      failureCount: nextCount,
      lastFailureAt: now,
      cooldownUntil: now.add(cooldown),
      lastError: _shortError(error),
    );
    return cooldown;
  }

  /// 成功一次即自愈：清空该源的失败计数与冷却。
  void recordSuccess(String key) {
    if (key.isNotEmpty) _records.remove(key);
  }

  /// 手动重置指定源；不传 key 时清空全部。
  void reset([String? key]) {
    if (key == null) {
      _records.clear();
    } else {
      _records.remove(key);
    }
  }

  /// 当前处于冷却中的源数量（设置页 / 日志展示用）。
  int get coolingCount {
    final now = _clock();
    var count = 0;
    for (final record in _records.values) {
      if (now.isBefore(record.cooldownUntil)) count++;
    }
    return count;
  }

  /// 当前全部记录（只读快照；设置页展示冷却中的源）。
  Map<String, SourceCircuitRecord> get records => Map.unmodifiable(_records);

  /// 序列化到本地偏好。冷却状态需要跨启动保留，否则每次重启都会重新
  /// 把已知失效的源打一遍，用户感受就是「启动后的第一次搜索特别慢」。
  String exportJsonString() => jsonEncode({
    for (final entry in _records.entries) entry.key: entry.value.toJson(),
  });

  void importJsonString(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final now = _clock();
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final record = SourceCircuitRecord.fromJson(
          Map<String, dynamic>.from(value),
        );
        // 冷却早已结束且超过 7 天的记录没有保留价值，避免偏好文件无限膨胀。
        if (record.cooldownUntil.isBefore(
          now.subtract(const Duration(days: 7)),
        )) {
          continue;
        }
        _records[entry.key.toString()] = record;
      }
    } catch (_) {
      // 损坏的健康档案按空处理，不能影响启动。
    }
  }

  static Duration _cooldownFor(int failureCount) {
    if (failureCount <= 1) return Duration.zero;
    if (failureCount == 2) return cooldownLevels[0];
    if (failureCount == 3) return cooldownLevels[1];
    return cooldownLevels[2];
  }

  static String _shortError(Object error) {
    final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 300 ? text : '${text.substring(0, 300)}…';
  }
}

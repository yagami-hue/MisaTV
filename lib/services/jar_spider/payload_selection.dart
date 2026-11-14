// 加固壳 payload 候选选择的纯逻辑（便于单测）。
//
// 从 `JarSpiderService._payloadCandidates` 抽出的判定部分。这里的规则错过两次，
// 每次都表现为「以前能用的壳突然加载不了」，所以单独抽出来测。
//
// 关键背景：一个 jar key（订阅里声明的 md5 或 jar URL 的 md5）下往往缓存了
// **多个聚合包**，每只壳只装在其中某一个里。例如实测数据：
//
//   payloads/c3bb107b/
//     index.json: { "*": "b66f….r2.jar",
//                   "…WexNewHuYaGuard": "80dbe….r2.jar", ... 30 个 Wex 壳 }
//     b66f….r2.jar  ← 589 个 class，**一个 Wex 都没有**
//     80dbe….r2.jar ← 1340 个 class，30 个 Wex 壳都在这里
//
// 所以 `*` 绝不能无条件当候选：它很可能不含目标类。

/// 一条 payload 候选。
class PayloadCandidate {
  const PayloadCandidate({
    required this.name,
    required this.containsWanted,
    required this.trusted,
  });

  /// 包文件名。
  final String name;

  /// 包内是否含目标类（目标类未知时视为 true）。
  final bool containsWanted;

  /// 是否为「本类验证成功过」的精确记录（index[className]）。
  final bool trusted;

  @override
  String toString() =>
      'PayloadCandidate($name, wanted=$containsWanted, trusted=$trusted)';
}

/// 判定某个 index 记录能否作为候选。
///
/// 规则：
///   · 精确记录（`index[className]`）：只要文件存在就收（它代表本类成功过）；
///   · 默认记录（`*`）：**必须**含目标类才收，否则跳过。
///
/// [wantedKnown] 为 false 表示调用方没有目标类信息（如只做预热），此时只能放行。
({bool accept, String reason}) judgePayloadEntry({
  required String entryKind, // 'exact' | 'star'
  required bool fileExists,
  required bool containsWanted,
  required bool wantedKnown,
}) {
  if (!fileExists) return (accept: false, reason: 'missing-file');
  if (entryKind == 'exact') return (accept: true, reason: 'exact-record');
  // `*` 兜底。
  if (!wantedKnown) return (accept: true, reason: 'star-no-target');
  if (!containsWanted) return (accept: false, reason: 'star-lacks-target');
  return (accept: true, reason: 'star-has-target');
}

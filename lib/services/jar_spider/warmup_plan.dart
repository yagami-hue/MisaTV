// JAR 源启动预热的调度决策（纯逻辑，便于单测）。
//
// 真正的预热要起 JVM，单测里跑不动；但「该不该预热、按什么顺序、最多几个」
// 这类决策是最容易写错的地方（例如把十几个 JAR 源全排上，开机后几分钟都在开
// JVM），所以单独抽出来测。

import '../../models/site_config.dart';

/// 预热计划里的一项。
class WarmUpPlanItem {
  const WarmUpPlanItem({required this.site, required this.weight});

  final SourceBean site;

  /// 排序权重（越小越先预热）；来自实测耗时档案。
  final int weight;
}

/// 一次预热最多拉起几个 JVM。
///
/// 每个 JAR 源一只常驻 JVM，内存与启动开销都不小；订阅里常有十几个 JAR 源，
/// 全排上去会让启动后几分钟都在开 JVM，反而不如让用户先用 CMS 源。
const int kWarmUpLimit = 3;

/// 决定本次启动要预热哪些 JAR 源。
///
/// 规则：
///   · 运行时未就绪（没装 JRE）→ 空计划，不静默下载运行时；
///   · 只考虑「参与搜索」（`searchable == 1`）且确实需要 JVM 的源；
///   · 按实测耗时升序：先预热快的，收益最直接；
///   · 最多 [kWarmUpLimit] 个。
List<WarmUpPlanItem> buildWarmUpPlan({
  required Iterable<SourceBean> sites,
  required bool runtimeReady,
  required int Function(SourceBean site) weightOf,
  int limit = kWarmUpLimit,
}) {
  if (!runtimeReady || limit <= 0) return const [];
  final candidates = <WarmUpPlanItem>[];
  var index = 0;
  for (final site in sites) {
    // JAR / DEX 才需要 JVM；.js / .py 走别的运行时，预热它们没有意义。
    if (!site.isJarSpider) continue;
    // 用户关掉的源不该占用启动开销。
    if (site.searchable != 1) continue;
    candidates.add(
      WarmUpPlanItem(site: site, weight: weightOf(site)),
    );
    index++;
    if (index > limit * 8) break; // 防御：订阅异常大时不无限遍历
  }
  candidates.sort((a, b) {
    final byWeight = a.weight.compareTo(b.weight);
    if (byWeight != 0) return byWeight;
    return 0; // 同权重保持原顺序（稳定）
  });
  return candidates.length > limit
      ? candidates.sublist(0, limit)
      : candidates;
}

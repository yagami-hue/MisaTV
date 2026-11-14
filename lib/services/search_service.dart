import 'dart:async';

import '../core/logging/app_log.dart';
import '../models/site_config.dart';
import '../models/vod.dart';
import 'jar_spider/spider_failure.dart';
import 'matching/search_query.dart';
import 'matching/title_matching.dart';
import 'source_circuit_breaker.dart';
import 'source_service.dart';

class SearchService {
  SearchService(this.sourceService, {SourceCircuitBreaker? breaker})
    : breaker = breaker ?? SourceCircuitBreaker();
  final SourceService sourceService;

  /// 源健康度：连续失败按阶梯冷却，成功一次自愈。
  final SourceCircuitBreaker breaker;

  /// 一轮搜索结束后回调。只在正常结束时触发一次。
  void Function()? onRoundFinished;

  /// 健康度变化（失败 / 成功）后回调，由 AppState 负责落盘。
  void Function()? onHealthChanged;

  /// 健康记录的身份：同一个 key 在不同订阅里可能指向不同 API，带上 api 避免串状态。
  static String healthKeyOf(SourceBean site) => '${site.key}\u0000${site.api}';

  /// 设置页手动体检的结果同步给熔断器：成功即自愈，失败计入连续失败。
  void markSiteHealthy(SourceBean site) {
    breaker.recordSuccess(healthKeyOf(site));
    onHealthChanged?.call();
  }

  void markSiteFailed(SourceBean site, Object error) {
    breaker.recordFailure(healthKeyOf(site), error);
    onHealthChanged?.call();
  }

  static const _emitInterval = Duration(milliseconds: 80);
  static const _cacheTtl = Duration(minutes: 5);
  static const _cacheMax = 300;

  /// 同源同关键词的短期结果缓存：搜索页来回切关键词时不必重复打源站。
  final Map<String, _SearchCacheEntry> _cache = {};

  /// 搜索代际号：`search()` 每调用一次自增，旧代际的结果一律丢弃。
  int _generation = 0;

  void clearCache() => _cache.clear();

  /// [sites] 应是已按当前运行时就绪情况筛过的可用站点（见 `AppState.usableSites`）。
  ///
  /// 这里不能再按 `SourceBean.supported` 过滤：JAR 蜘蛛的 `supported` 恒为 false，
  /// 只能由 `AppState.isSiteUsable` 结合 `jarReady` 判定；旧写法会把全部 JAR 源
  /// 排除在搜索之外，表现为「搜什么都是 0 条」。
  Stream<SearchProgress> search(String keyword, List<SourceBean> sites) {
    // 结构化语法：`year:2024 type:电影 -广告` 等在这里拆开。
    // 关键词之外的条件只能就地过滤（CMS 接口不接受附加字段），见 search_query.dart。
    // 单源收窄不在这里做 —— 搜索页的 `@源名` 已经收窄了 scope。
    final parsed = parseSearchQuery(keyword);
    final query = parsed.keyword;
    final usable = sites.where((s) => s.searchable == 1).toList();
    final siteByKey = <String, SourceBean>{
      for (final site in usable) site.key: site,
    };

    /// 结果排序：CMS 优先，其次 Kazumi，再 JS/PY，最后 JAR/加固壳。
    /// 慢源（尤其需要启动 JVM 的 JAR）不把 CMS 结果往后挤。
    int tierOf(VodItem item) {
      final site = siteByKey[item.sourceKey];
      if (site == null) return 4;
      if (site.isJarSpider) return 3;
      if (site.type == 3) return 2;
      if (site.isKazumi) return 1;
      return 0;
    }

    final controller = StreamController<SearchProgress>();
    // 每次 search() 领一个代际号：流的消费者可以「先取消订阅、再发起新搜索」，
    // 而 cancel 回调与在途的源请求不是同步的 —— 旧搜索的 emit 仍可能在
    // 新搜索已经开始之后才到达。用代际号让旧搜索彻底闭嘴，而不是只靠布尔位。
    final generation = ++_generation;
    var cancelled = false;
    bool stale() => cancelled || generation != _generation;
    var closed = false;
    Timer? emitTimer;
    controller.onCancel = () {
      cancelled = true;
      emitTimer?.cancel();
    };
    if (query.isEmpty || usable.isEmpty) {
      controller.add(
        SearchProgress(
          items: const [],
          perSource: const [],
          done: 0,
          total: usable.length,
          finished: true,
        ),
      );
      controller.close();
      return controller.stream;
    }

    // 增量合并：不再每来一个源就重新扫描全部结果。
    final merged = <String, VodItem>{};
    final counts = <String, int>{};
    final perSource = <SearchPerSource>[];
    final sourceItems = <String, List<VodItem>>{};
    var done = 0;

    void absorb(VodItem item) {
      // 结构化过滤（year / type / area / 排除词）在 `run()` 里对 rawItems 做过；
      // 这里只做合并去重。相关性不参与过滤，只参与排序（见 snapshot()）。
      final key = _dedupeKey(item);
      counts[key] = (counts[key] ?? 0) + 1;
      final existing = merged[key];
      if (existing == null) {
        merged[key] = item;
        return;
      }
      // 同片多源：保留响应更快的源类型（CMS），顺带补封面。
      final keep = tierOf(item) < tierOf(existing) ? item : existing;
      final other = identical(keep, item) ? existing : item;
      final pic = keep.pic.isEmpty && other.pic.isNotEmpty ? other.pic : null;
      merged[key] = (pic == null && identical(keep, existing))
          ? existing
          : _copyItem(keep, pic: pic);
    }

    List<VodItem> snapshot() {
      final out = <VodItem>[];
      for (final entry in merged.entries) {
        final others = (counts[entry.key] ?? 1) - 1;
        final same = others > 0 ? others : 0;
        final item = entry.value;
        out.add(
          same == item.sameFromOtherSources
              ? item
              : _copyItem(item, sameFromOtherSources: same),
        );
      }
      // 相关度优先：名称完全一致 > 前缀 > 包含 > 模糊相似；同级再按源类型。
      final ranked = [
        for (final item in out)
          (item: item, score: searchTitleScore(query, item.name)),
      ];
      ranked.sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        final byTier = tierOf(a.item).compareTo(tierOf(b.item));
        if (byTier != 0) return byTier;
        return a.item.name.compareTo(b.item.name);
      });
      return [for (final row in ranked) row.item];
    }

    void emit({required bool finished}) {
      if (stale() || closed) return;
      controller.add(
        SearchProgress(
          items: snapshot(),
          perSource: List.of(perSource),
          sourceItems: Map<String, List<VodItem>>.from(sourceItems),
          done: done,
          total: usable.length,
          finished: finished,
          filterSummary: parsed.filterSummary,
        ),
      );
      if (finished) {
        closed = true;
        // 本轮的全部耗时已经齐了，交给上层落盘，下次启动沿用学到的顺序。
        // 只在这一轮仍然有效时回调：被取消 / 换代的那轮不写盘。
        if (!stale()) onRoundFinished?.call();
        unawaited(controller.close());
      }
    }

    // 搜索页每个源完成都会 setState 重建结果网格；把高频事件压到 80ms
    // 一次，既保持流式上屏，又避免十几个源同时返回时连续掉帧。
    void scheduleEmit() {
      emitTimer?.cancel();
      if (done >= usable.length) {
        emit(finished: true);
      } else {
        emitTimer = Timer(_emitInterval, () => emit(finished: false));
      }
    }

    Future<void> run(SourceBean site) async {
      final started = DateTime.now().millisecondsSinceEpoch;
      final healthKey = healthKeyOf(site);
      try {
        // 同源同关键词 2 分钟内直接复用结果，不重复请求源站。
        final cacheKey = '${site.key}\u0000$query';
        final cached = _cache[cacheKey];
        final fresh =
            cached != null &&
            DateTime.now().difference(cached.at) < _cacheTtl;
        if (cached != null && !fresh) _cache.remove(cacheKey);
        List<VodItem>? cachedItems;
        if (cached != null && fresh) cachedItems = cached.items;
        List<VodItem> rawItems;
        if (cachedItems != null) {
          rawItems = cachedItems;
        } else {
          // 蜘蛛源（尤其常驻 JVM 首次 init）比 CMS 慢得多，给它更宽的窗口；
          // 但也别无限等：本机日志 364 次采样里最慢一次是 32.5 秒。以前是
          // timeout+35，默认 15 秒就变成 50 秒，一个卡死源能把整轮拖到 50 秒以上。
          final timeoutSeconds = site.type == 3
              ? (site.timeout + 15).clamp(20, 45)
              : site.timeout + 3;
          try {
            rawItems = await sourceService
                .search(site, query)
                .timeout(Duration(seconds: timeoutSeconds));
          } catch (e) {
            // 只有真正打到源站失败才计入健康度；本地处理异常不背这个锅。
            // 已过期 / 被取消的搜索也不能写健康度：它可能属于上一轮用户已放弃
            // 的关键词，污染熔断器会让该源在后续正常搜索里被误判为冷却中。
            if (!stale()) {
              breaker.recordFailure(healthKey, e);
              onHealthChanged?.call();
            }
            rethrow;
          }
          breaker.recordSuccess(healthKey);
          onHealthChanged?.call();
          _remember(cacheKey, rawItems);
        }
        if (stale()) return;
        // 「只看某个源」用的是 sourceItems，它同样要经过结构化过滤
        // （`year:` / `type:` / `area:` / 排除词——那些是用户显式写的条件）。
        //
        // **不做相关性过滤**：任何基于字符串的相关性判定都会误杀译名与别名
        // （「NARUTO」vs「火影忍者」在字符串层面毫无关系）。误杀的代价是
        // 「这个源搜不到东西」，比多显示几条噪音严重得多。相关度只用于排序，
        // 见下方 snapshot()。
        final items = <VodItem>[
          for (final e in rawItems)
            if (parsed.accepts(
              name: e.name,
              year: e.year,
              type: e.type,
              area: e.area,
            ))
              VodItem(
                id: e.id,
                name: e.name,
                pic: e.pic,
                remarks: e.remarks,
                year: e.year,
                area: e.area,
                type: e.type,
                sourceKey: e.sourceKey,
                tag: e.tag,
                sourceName: site.displayName,
              ),
        ];
        for (final item in items) {
          absorb(item);
        }
        sourceItems[site.key] = items;
        final ms = DateTime.now().millisecondsSinceEpoch - started;
        perSource.add(
          SearchPerSource(
            key: site.key,
            name: site.displayName,
            status: items.isEmpty ? 'empty' : 'ok',
            count: items.length,
            ms: ms,
          ),
        );
        AppLog.i(
          'search',
          '源 ${site.key} ${cachedItems != null ? '缓存 ' : ''}'
              '${items.isEmpty ? '空' : '${items.length} 条'} ${ms}ms',
        );
      } catch (e) {
        if (stale()) return;
        final ms = DateTime.now().millisecondsSinceEpoch - started;
        // 原始错误常常是英文堆栈或一句「常驻蜘蛛调用失败」，用户看不出该做什么。
        // 这里归因成「缺少运行时 / 源失效 / 网络异常…」并附上下一步动作；
        // 完整原文仍然写进日志，排查时不受影响。
        final failure = classifySpiderFailure(e);
        perSource.add(
          SearchPerSource(
            key: site.key,
            name: site.displayName,
            status: 'error',
            error: failure.message,
            ms: ms,
          ),
        );
        AppLog.e(
          'search',
          '源 ${site.key} 失败 ${ms}ms（${failure.kind.name}）',
          e,
        );
      } finally {
        if (!stale()) {
          done++;
          scheduleEmit();
        }
      }
    }

    // 源健康度：冷却中的源直接跳过，但仍以失败状态出现在 perSource 里，
    // 避免用户以为这个源根本没参与搜索。冷却结束会自动放行一次探测。
    final available = <SourceBean>[];
    for (final site in usable) {
      final key = healthKeyOf(site);
      if (breaker.isAvailable(key)) {
        available.add(site);
        continue;
      }
      final minutes = _cooldownMinutes(breaker.cooldownRemaining(key));
      perSource.add(
        SearchPerSource(
          key: site.key,
          name: site.displayName,
          status: 'error',
          error: '近期连续失败，冷却中（约 $minutes 分钟）；可在设置中体检后恢复',
          ms: 0,
        ),
      );
      sourceItems[site.key] = const <VodItem>[];
      done++;
    }
    if (available.isEmpty) {
      emit(finished: true);
      return controller.stream;
    }

    // CMS 与蜘蛛各自独立并发：以前只要订阅里有一个 type=3 源，所有源都退化为
    // 3 个 worker，几十个普通 CMS 要排队几十轮，整体搜索比原版慢一个量级。
    // CMS 16 个 worker：只是一次 HTTP GET，瓶颈在源站。
    //
    // 蜘蛛池以前限 3（后来 6），理由是「JAR 源常驻 host 有上限」。这是误判：
    //   · 蜘蛛源慢的主因是**等源站响应**（网络 I/O），不是本地 CPU；限并发只是
    //     让慢源排队，把总耗时按 ceil(N/并发) 成倍拉长；
    //   · 真正需要限流的是「每个 JAR 源能起几只 JVM」，那一层由
    //     `JarSpiderService._servePoolMax` 独立兜住，多出来的请求会自动排队；
    //   · JS / PY 源各有自己的执行器池，同样不吃这个 worker 数。
    // 所以这里按源数量放开：让所有源同时发出去，谁先回来谁先上屏。
    // 蜘蛛池并发 = 池内源数量（见上方说明），上限只用来防御异常大的订阅。

    // 启动顺序：健康度优先（近期失败的源排后），同类内保持订阅原顺序。
    final cmsSites = _orderByHealth(available.where((s) => s.type != 3));
    // 同类（type=3）里 JS / PY 先跑，需要冷启动 JVM 的 JAR / 加固壳排最后，
    // 让不依赖 JVM 的源先返回结果。
    final spiderSites = _orderByHealth(
      available.where((s) => s.type == 3),
      jarLast: true,
    );

    // CMS 与蜘蛛各自独立并发。
    // CMS 16 个 worker：只是一次 HTTP GET，瓶颈在源站。
    const cmsConcurrency = 16;
    //
    // 关键理由：蜘蛛源慢是**在等源站响应**（网络 I/O），不是吃本地 CPU。
    // 限并发只会让慢源排队，总耗时按 ceil(N/并发) 成倍拉长；而真正需要
    // 限流的是「每个 JAR 源起几只 JVM」，那由 JarSpiderService._servePoolMax
    // 独立兜住，多出的请求会自动排队。JS / PY 也各有自己的执行器池。
    const int spiderConcurrencyCap = 32;
    final spiderConcurrency = spiderSites.length < spiderConcurrencyCap
        ? spiderSites.length
        : spiderConcurrencyCap;

    Future<void> runPool(List<SourceBean> pool, int concurrency) async {
      var cursor = 0;
      Future<void> worker() async {
        while (!stale()) {
          final index = cursor++;
          if (index >= pool.length) return;
          await run(pool[index]);
        }
      }

      final count = pool.length < concurrency ? pool.length : concurrency;
      await Future.wait([for (var i = 0; i < count; i++) worker()]);
    }

    unawaited(() async {
      // CMS 与蜘蛛**同时**启动。
      //
      // 原来蜘蛛要等 1200ms 才开跑，理由是「JVM 冷启动抢 CPU 拖慢 CMS」。但那是
      // 早期只有 3 个 worker、CMS 也要排队时的权衡；现在 CMS 有 16 个 worker、
      // 蜘蛛并发也不受限，这 1.2 秒只是让整轮搜索无条件晚了 1.2 秒 —— 用户感受
      // 得到的就是「点搜索后什么都没发生」。JVM 冷启动的 CPU 争抢交给操作系统
      // 调度即可，不值得用固定延迟去换。
      final cmsRun = runPool(cmsSites, cmsConcurrency);
      final spiderRun = runPool(spiderSites, spiderConcurrency);
      await Future.wait([cmsRun, spiderRun]);
    }());
    return controller.stream;
  }

  /// 同档内按健康度排：健康 / 未知（0 次失败）→ 近期单次失败 → 原顺序兜底。
  ///
  /// [jarLast] 用于蜘蛛池：JAR / 加固壳需要冷启动 JVM，仍排在 JS / PY 之后。
  List<SourceBean> _orderByHealth(
    Iterable<SourceBean> sites, {
    bool jarLast = false,
  }) {
    final rows =
        <({SourceBean site, int index, int jar, int failures})>[];
    var index = 0;
    for (final site in sites) {
      rows.add((
        site: site,
        index: index++,
        jar: jarLast && site.isJarSpider ? 1 : 0,
        failures: breaker.failureCount(healthKeyOf(site)),
      ));
    }
    rows.sort((a, b) {
      final byJar = a.jar.compareTo(b.jar);
      if (byJar != 0) return byJar;
      final byFailures = a.failures.compareTo(b.failures);
      if (byFailures != 0) return byFailures;
      return a.index - b.index;
    });
    return [for (final row in rows) row.site];
  }

  static int _cooldownMinutes(Duration remaining) {
    final minutes = (remaining.inSeconds + 59) ~/ 60;
    return minutes < 1 ? 1 : minutes;
  }

  void _remember(String key, List<VodItem> items) {
    if (_cache.length >= _cacheMax && !_cache.containsKey(key)) {
      String? oldestKey;
      DateTime? oldestAt;
      for (final entry in _cache.entries) {
        if (oldestAt == null || entry.value.at.isBefore(oldestAt)) {
          oldestAt = entry.value.at;
          oldestKey = entry.key;
        }
      }
      if (oldestKey != null) _cache.remove(oldestKey);
    }
    _cache[key] = _SearchCacheEntry(DateTime.now(), items);
  }

  VodItem _copyItem(
    VodItem item, {
    String? pic,
    int? sameFromOtherSources,
  }) => VodItem(
        id: item.id,
        name: item.name,
        pic: pic ?? item.pic,
        remarks: item.remarks,
        year: item.year,
        area: item.area,
        type: item.type,
        sourceKey: item.sourceKey,
        tag: item.tag,
        sourceName: item.sourceName,
        sameFromOtherSources:
            sameFromOtherSources ?? item.sameFromOtherSources,
      );

  String _dedupeKey(VodItem item) =>
      searchDedupeKey(item.name, year: item.year);
}

class _SearchCacheEntry {
  const _SearchCacheEntry(this.at, this.items);

  final DateTime at;
  final List<VodItem> items;
}

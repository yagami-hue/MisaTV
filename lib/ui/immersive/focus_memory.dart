// 焦点记忆与恢复（纯逻辑，不依赖 Flutter 的 FocusNode，便于单测）。
//
// 沉浸观影 / TV 场景的两个实际问题，都出在「焦点」上：
//
//   1. 从详情页返回列表，焦点跳回第一个卡片 —— 用户刚翻到第 30 个，
//      返回后要重新找。需要记住「上次聚焦的是哪个卡片」并恢复；
//   2. 列表刷新（加载更多、筛选变化）后，旧卡片的焦点节点没有释放，
//      或者记住了已不存在的 key —— 恢复时找不到目标，焦点落到根节点，
//      方向键随之失灵。
//
// 这里只维护「key ↔ 焦点身份」的簿记，真正的 FocusNode 由 UI 层持有：
// 把可测的逻辑（去重、清理、恢复优先级）抽出来，UI 层只负责按 key 请求焦点。

/// 焦点记忆：记住最后聚焦的条目，并支持在列表变化后安全恢复。
class FocusMemory {
  FocusMemory({this.onChanged});

  /// 焦点变化回调（UI 用来刷新高亮样式）。
  final void Function(String? key)? onChanged;

  /// 当前存在的全部 key（与列表数据同步）。
  final Set<String> _validKeys = {};

  String? _lastFocused;

  /// 最后聚焦过的 key；已失效时为 null。
  String? get lastFocused => _lastFocused;

  /// 当前有效 key 的数量。
  int get length => _validKeys.length;

  bool has(String key) => _validKeys.contains(key);

  bool isFocused(String key) => _lastFocused == key;

  /// 同步当前列表的 key 集合。
  ///
  /// 返回「被移除的 key」，调用方据此释放对应的 FocusNode。
  /// 若最后聚焦的条目已被移除，焦点记忆会退回到 [fallback]（如果有效）。
  List<String> syncKeys(Iterable<String> keys, {String? fallback}) {
    final next = keys.toSet();
    final removed = _validKeys.difference(next).toList();
    _validKeys
      ..clear()
      ..addAll(next);

    if (_lastFocused != null && !_validKeys.contains(_lastFocused)) {
      final previous = _lastFocused;
      _lastFocused = null;
      // 优先回到调用方指定的 fallback（通常是列表首项），否则就空着等
      // 用户重新按方向键 —— 不要把焦点硬塞到某个随机条目上。
      if (fallback != null && _validKeys.contains(fallback)) {
        _lastFocused = fallback;
      }
      if (previous != _lastFocused) onChanged?.call(_lastFocused);
    }
    return removed;
  }

  /// 记录一次聚焦；key 不在有效集合里时忽略（防止脏 key 污染记忆）。
  void remember(String key) {
    if (key.isEmpty || !_validKeys.contains(key)) return;
    if (_lastFocused == key) return;
    _lastFocused = key;
    onChanged?.call(key);
  }

  /// 计算恢复目标：优先上次聚焦，其次 [fallback]，都没有则 null。
  ///
  /// 返回 null 表示「不要抢焦点」，让 Flutter 按默认规则处理，
  /// 这比强行 `requestFocus` 到一个可能已被移除的节点安全。
  String? restoreTarget({String? fallback}) {
    final last = _lastFocused;
    if (last != null && _validKeys.contains(last)) return last;
    if (fallback != null && _validKeys.contains(fallback)) return fallback;
    return null;
  }

  void clear() {
    final had = _lastFocused != null;
    _validKeys.clear();
    _lastFocused = null;
    if (had) onChanged?.call(null);
  }
}

/// 方向键在网格里的下一目标（纯逻辑，绕开 Flutter 焦点树的默认行为）。
///
/// 为什么自己算：Flutter 默认的 `FocusTraversalPolicy` 按 widget 树的几何
/// 顺序走，在「横向滚动 + 多行分架」的沉浸布局里经常跳到视口外，或者横向
/// 走到头后不换行。这里按「列数 + 索引」直接算，行为可预测。
class GridNavigator {
  const GridNavigator({required this.count, required this.columns});

  /// 条目总数。
  final int count;

  /// 每行几列（沉浸首页按列数排卡片）。
  final int columns;

  bool get isEmpty => count <= 0;

  /// 按方向移动；返回新的下标，无路可走时返回 null（调用方应忽略该按键）。
  ///
  /// - left / right：行内移动，到头**不换行**（换行会让遥控器手感变怪）；
  /// - up / down：按列数整行跳，越界则停在原地（返回 null）。
  int? move(int current, FocusDirection direction) {
    if (isEmpty) return null;
    final index = current < 0 || current >= count ? 0 : current;
    final cols = columns <= 0 ? 1 : columns;
    switch (direction) {
      case FocusDirection.left:
        if (index % cols == 0) return null; // 已在行首
        return index - 1;
      case FocusDirection.right:
        if (index % cols == cols - 1) return null; // 已在行尾
        if (index + 1 >= count) return null; // 最后一个条目
        return index + 1;
      case FocusDirection.up:
        if (index - cols < 0) return null;
        return index - cols;
      case FocusDirection.down:
        final next = index + cols;
        // 下一行该列没有条目时，落到最后一个条目，而不是原地不动：
        // 否则用户会觉得「按了没反应」。
        if (next >= count) {
          return index == count - 1 ? null : count - 1;
        }
        return next;
    }
  }
}

/// 焦点移动方向。
enum FocusDirection { left, right, up, down }

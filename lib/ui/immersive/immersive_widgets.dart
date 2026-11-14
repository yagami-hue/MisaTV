import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../core/theme/app_theme.dart';
import '../../models/vod.dart';
import '../pages/detail_page.dart';
import '../widgets/mouse_drag_scroll.dart';

/// 沉浸观影统一的大屏主题：强制深色 + 透明 Scaffold 背景。
ThemeData immersiveTheme(BuildContext context) {
  final app = AppScope.of(context);
  final base = AppTheme.build(app.accentColor, Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: Colors.black,
    canvasColor: Colors.black,
    dividerColor: Colors.white.withValues(alpha: 0.10),
    cardTheme: base.cardTheme.copyWith(
      color: Colors.white.withValues(alpha: 0.05),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: const Color(0xFF141A15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: base.snackBarTheme.copyWith(
      backgroundColor: const Color(0xFF20261F),
    ),
  );
}

/// 横图封面：先显示源里的竖版图，随后用豆瓣 / TMDB / IMDb 的横图替换。
class ImmersiveBackdrop extends StatefulWidget {
  const ImmersiveBackdrop({
    super.key,
    required this.title,
    this.year = '',
    this.fallback = '',
    this.fit = BoxFit.cover,
    this.scrim = false,
    this.placeholderTitle = '',
    this.artworkTitle = '',
  });

  final String title;
  final String year;

  /// 源里的海报地址（可能是竖图、也可能是豆瓣 418 图）。
  final String fallback;
  final BoxFit fit;

  /// 是否叠一层从下到上的暗角（卡片文字用）。
  final bool scrim;

  /// 没有任何横图时，在占位渐变上显示片名，避免卡片只剩一块黑。
  final String placeholderTitle;

  /// 封面匹配使用的剧名；为空时用 [title]。
  final String artworkTitle;

  @override
  State<ImmersiveBackdrop> createState() => _ImmersiveBackdropState();
}

class _ImmersiveBackdropState extends State<ImmersiveBackdrop> {
  Future<String?>? _future;
  String _key = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensure();
  }

  @override
  void didUpdateWidget(covariant ImmersiveBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensure();
  }

  void _ensure() {
    final artwork = widget.artworkTitle.trim().isNotEmpty
        ? widget.artworkTitle.trim()
        : widget.title;
    final key = '$artwork|${widget.year}';
    if (key == _key) return;
    _key = key;
    _future = AppScope.of(context).artworkService.backdrop(
      artwork,
      year: widget.year,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 沉浸模式只显示横图：源里的竖版海报（多半分辨率很低）不再铺底，
        // 避免被裁成 16:9 后糊成一片；横图没到之前用深色渐变占位。
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1A231B), Color(0xFF0B0F0B), Color(0xFF141A14)],
              stops: [0, 0.55, 1],
            ),
          ),
        ),
        if (widget.placeholderTitle.trim().isNotEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                widget.placeholderTitle,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.36),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                ),
              ),
            ),
          ),
        FutureBuilder<String?>(
          future: _future,
          builder: (context, snapshot) {
            final url = snapshot.data;
            if (url == null || url.isEmpty) return const SizedBox.shrink();
            return Image.network(
              url,
              fit: widget.fit,
              gaplessPlayback: true,
              frameBuilder: (context, child, frame, sync) {
                if (sync) return child;
                return AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 350),
                  child: child,
                );
              },
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            );
          },
        ),
        if (widget.scrim)
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xE6000000)],
                stops: [0.45, 1],
              ),
            ),
          ),
      ],
    );
  }
}

/// TV 风格的横版卡片（16:9 为主），悬停放大 + 描边。
class ImmersiveCard extends StatefulWidget {
  const ImmersiveCard({
    super.key,
    required this.title,
    this.year = '',
    this.subtitle = '',
    this.fallback = '',
    this.badge = '',
    required this.onTap,
    this.width = 300,
    this.showText = true,
    this.progress = 0,
    this.artworkTitle = '',
    this.focusNode,
    this.onFocus,
  });

  final String title;
  final String year;
  final String subtitle;
  final String fallback;
  final String badge;
  final VoidCallback onTap;
  final double width;
  final bool showText;

  /// 封面匹配使用的剧名；为空时由 [ImmersiveBackdrop] 用 [title] 归一。
  final String artworkTitle;

  /// 0~1 的观看进度；0 不绘制。
  final double progress;

  /// 遥控器 / 键盘焦点节点：不传时卡片不可键盘聚焦（纯鼠标场景）。
  final FocusNode? focusNode;

  /// 获得焦点时回调，供外层记录「上次聚焦的是哪个条目」。
  final VoidCallback? onFocus;

  @override
  State<ImmersiveCard> createState() => _ImmersiveCardState();
}

class _ImmersiveCardState extends State<ImmersiveCard> {
  bool _hover = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant ImmersiveCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_onFocusChange);
      widget.focusNode?.addListener(_onFocusChange);
    }
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() {
    final hasFocus = widget.focusNode?.hasFocus ?? false;
    if (hasFocus) widget.onFocus?.call();
    if (hasFocus != _focused && mounted) {
      setState(() => _focused = hasFocus);
    }
  }

  /// 鼠标悬停与键盘焦点共用同一套高亮，TV / 桌面手感一致。
  bool get _active => _hover || _focused;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _active ? 1.035 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: SizedBox(
            width: widget.width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _active
                          ? theme.colorScheme.primary.withValues(alpha: 0.75)
                          : Colors.white.withValues(alpha: 0.08),
                    ),
                    boxShadow: _active
                        ? [
                            BoxShadow(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.24,
                              ),
                              blurRadius: 22,
                              offset: const Offset(0, 8),
                            ),
                          ]
                        : const [],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ImmersiveBackdrop(
                            title: widget.title,
                            year: widget.year,
                            fallback: widget.fallback,
                            scrim: widget.showText,
                            placeholderTitle: widget.showText
                                ? ''
                                : widget.title,
                            artworkTitle: widget.artworkTitle,
                          ),
                          if (widget.badge.isNotEmpty)
                            Positioned(
                              left: 10,
                              top: 10,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.62),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 3,
                                  ),
                                  child: Text(
                                    widget.badge,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (widget.progress > 0)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                  bottom: Radius.circular(12),
                                ),
                                child: LinearProgressIndicator(
                                  value: widget.progress.clamp(0.0, 1.0),
                                  minHeight: 4,
                                  backgroundColor: Colors.black.withValues(
                                    alpha: 0.34,
                                  ),
                                ),
                              ),
                            ),
                          if (widget.showText)
                            Positioned(
                              left: 12,
                              right: 12,
                              bottom: 10,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      shadows: const [
                                        Shadow(blurRadius: 8, color: Colors.black),
                                      ],
                                    ),
                                  ),
                                  if (widget.subtitle.isNotEmpty)
                                    Text(
                                      widget.subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: Colors.white.withValues(alpha: 0.66),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (!widget.showText) ...[
                  const SizedBox(height: 8),
                  Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (widget.subtitle.isNotEmpty)
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.58),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    // 没有焦点节点时保持纯鼠标卡片：沉浸模式里的大部分卡片仍由鼠标操作，
    // 只有需要遥控器导航的列表才传入 focusNode。
    final node = widget.focusNode;
    if (node == null) return card;
    return Focus(
      focusNode: node,
      // 键盘焦点不应该画 Flutter 默认的焦点框：我们用 _active 自己画高亮。
      child: Builder(
        builder: (context) => Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            // 回车与遥控器 OK 键都归到 ActivateIntent。
            // 注意不要同时写 numpadEnter：它与 enter 是同一个 logical key，
            // 放进 const map 会被判重复键。
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onTap();
                  return null;
                },
              ),
            },
            child: card,
          ),
        ),
      ),
    );
  }
}

class ImmersiveSection extends StatelessWidget {
  const ImmersiveSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
            const Spacer(),
            ?trailing,
          ],
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

/// 可鼠标左键拖拽、带左右翻页按钮的横向货架。
class ImmersiveShelf extends StatefulWidget {
  const ImmersiveShelf({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.height = 224,
    this.trailing,
  });

  final String title;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final double height;
  final Widget? trailing;

  @override
  State<ImmersiveShelf> createState() => _ImmersiveShelfState();
}

class _ImmersiveShelfState extends State<ImmersiveShelf> {
  final ScrollController _controller = ScrollController();
  bool _canBack = false;
  bool _canForward = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    _controller.removeListener(_sync);
    _controller.dispose();
    super.dispose();
  }

  void _sync() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final back = position.pixels > 2;
    final forward = position.maxScrollExtent - position.pixels > 2;
    if (back == _canBack && forward == _canForward) return;
    setState(() {
      _canBack = back;
      _canForward = forward;
    });
  }

  void _page(double direction) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target = (position.pixels + direction * (position.viewportDimension * 0.82))
        .clamp(0.0, position.maxScrollExtent)
        .toDouble();
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              widget.title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(width: 12),
            if (widget.trailing != null) widget.trailing!,
            const Spacer(),
            _ShelfArrow(
              icon: Icons.chevron_left_rounded,
              enabled: _canBack,
              onTap: () => _page(-1),
            ),
            const SizedBox(width: 6),
            _ShelfArrow(
              icon: Icons.chevron_right_rounded,
              enabled: _canForward,
              onTap: () => _page(1),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: widget.height,
          child: ScrollConfiguration(
            behavior: const MouseDragScrollBehavior(),
            child: ListView.separated(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: widget.itemCount,
              separatorBuilder: (_, _) => const SizedBox(width: 18),
              itemBuilder: widget.itemBuilder,
            ),
          ),
        ),
      ],
    );
  }
}

class _ShelfArrow extends StatelessWidget {
  const _ShelfArrow({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: enabled ? onTap : null,
      style: IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: enabled ? 0.09 : 0.04),
        disabledBackgroundColor: Colors.white.withValues(alpha: 0.03),
        minimumSize: const Size(38, 38),
        shape: const CircleBorder(),
      ),
      icon: Icon(
        icon,
        size: 22,
        color: Colors.white.withValues(alpha: enabled ? 0.82 : 0.20),
      ),
    );
  }
}

/// 首页顶部海报轮播。
class ImmersiveHeroItem {
  const ImmersiveHeroItem({
    required this.title,
    required this.onTap,
    this.year = '',
    this.subtitle = '',
    this.description = '',
    this.fallback = '',
    this.actionLabel = '查看详情',
  });

  final String title;
  final String year;
  final String subtitle;
  final String description;
  final String fallback;
  final String actionLabel;
  final VoidCallback onTap;
}

class ImmersiveHero extends StatefulWidget {
  const ImmersiveHero({super.key, required this.items, this.height = 520});

  final List<ImmersiveHeroItem> items;
  final double height;

  @override
  State<ImmersiveHero> createState() => _ImmersiveHeroState();
}

class _ImmersiveHeroState extends State<ImmersiveHero> {
  final PageController _controller = PageController();
  Timer? _timer;
  int _index = 0;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(covariant ImmersiveHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items.length != oldWidget.items.length) {
      _index = 0;
      if (_controller.hasClients) _controller.jumpToPage(0);
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (widget.items.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 7), (_) {
      if (!mounted || _hover || !_controller.hasClients) return;
      final next = (_index + 1) % widget.items.length;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  void _step(int direction) {
    if (!_controller.hasClients) return;
    final target = (_index + direction)
        .clamp(0, widget.items.length - 1)
        .toInt();
    if (target == _index) return;
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = widget.items;
    if (items.isEmpty) return const SizedBox.shrink();
    return MouseRegion(
      onEnter: (_) => _hover = true,
      onExit: (_) => _hover = false,
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            ScrollConfiguration(
              behavior: const MouseDragScrollBehavior(),
              child: PageView.builder(
                controller: _controller,
                itemCount: items.length,
                onPageChanged: (value) => setState(() => _index = value),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ImmersiveBackdrop(
                        title: item.title,
                        year: item.year,
                        fallback: item.fallback,
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [Color(0xF20A0D0A), Color(0x000A0D0A)],
                            stops: [0.0, 0.74],
                          ),
                        ),
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0x66000000),
                              Colors.transparent,
                              Color(0xFF080B08),
                            ],
                            stops: [0, 0.32, 1],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 64,
                        right: 64,
                        bottom: 64,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.subtitle.toUpperCase(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                letterSpacing: 2.4,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.displayLarge?.copyWith(
                                fontSize: 58,
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                height: 1.04,
                                shadows: const [
                                  Shadow(blurRadius: 22, color: Colors.black54),
                                ],
                              ),
                            ),
                            if (item.year.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                item.year,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.66),
                                ),
                              ),
                            ],
                            if (item.description.isNotEmpty) ...[
                              const SizedBox(height: 14),
                              SizedBox(
                                width: 760,
                                child: Text(
                                  item.description,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.80),
                                    height: 1.6,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 26),
                            FilledButton.icon(
                              onPressed: item.onTap,
                              icon: const Icon(Icons.play_arrow_rounded, size: 24),
                              label: Text(item.actionLabel),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 30,
                                  vertical: 18,
                                ),
                                textStyle: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (items.length > 1)
              Positioned(
                right: 56,
                bottom: 58,
                child: Row(
                  children: [
                    for (var i = 0; i < items.length; i++)
                      GestureDetector(
                        onTap: () => _controller.animateToPage(
                          i,
                          duration: const Duration(milliseconds: 450),
                          curve: Curves.easeOutCubic,
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: i == _index ? 26 : 8,
                          height: 8,
                          margin: const EdgeInsets.only(left: 6),
                          decoration: BoxDecoration(
                            color: i == _index
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.32),
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                    const SizedBox(width: 18),
                    _HeroArrow(
                      icon: Icons.chevron_left_rounded,
                      onTap: () => _step(-1),
                    ),
                    const SizedBox(width: 8),
                    _HeroArrow(
                      icon: Icons.chevron_right_rounded,
                      onTap: () => _step(1),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 卡片点击：豆瓣推荐源没有可播线路，改为全源搜索。
void openImmersiveItem(BuildContext context, VodItem item) {
  final app = AppScope.of(context);
  final titleOnly = item.id.trim().isNotEmpty && item.id.trim() == item.name.trim();
  if (app.isDoubanSourceKey(item.sourceKey) || titleOnly) {
    app.requestSearch(item.name);
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => DetailPage(item: item)),
  );
}

class _HeroArrow extends StatelessWidget {
  const _HeroArrow({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.42),
        minimumSize: const Size(42, 42),
        shape: const CircleBorder(),
      ),
      icon: Icon(icon, size: 24, color: Colors.white.withValues(alpha: 0.86)),
    );
  }
}

class ImmersiveEmpty extends StatelessWidget {
  const ImmersiveEmpty({
    super.key,
    required this.title,
    this.message = '',
    this.action,
  });

  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.wb_twilight_rounded,
            size: 56,
            color: Colors.white.withValues(alpha: 0.20),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/vod.dart';
import '../../services/discover/cover_images.dart';
import 'hover_marquee_text.dart';
import 'secondary_long_press.dart';

class PosterCard extends StatefulWidget {
  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
    this.onSecondaryLongPress,
    this.onShowSources,
    this.showSource = false,
    this.heroTag,
    this.badge = '',
  });

  final VodItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 鼠标右键按住一段时间（默认 600ms）触发；用于全源聚合搜索。
  final VoidCallback? onSecondaryLongPress;

  /// 点「另有 N 个源」时展开同名跨源候选；null = 只显示文字。
  final VoidCallback? onShowSources;
  final bool showSource;
  final String? heroTag;

  /// 右上角提醒徽标（如收藏有更新）；空 = 不显示。
  final String badge;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hover = false;

  /// 源里缺图 / 坏图时，用豆瓣按片名补一张（结果按片名缓存，全屏共享）。
  String? _fallbackUrl;
  String _itemKey = '';
  bool _lookupStarted = false;

  /// 源封面加载失败 → 改用豆瓣兜底图。
  bool _originalFailed = false;

  String get _currentKey =>
      '${widget.item.name}|${widget.item.year}|${widget.item.cleanPic}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncItem();
  }

  @override
  void didUpdateWidget(covariant PosterCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncItem();
  }

  void _syncItem() {
    final key = _currentKey;
    if (key != _itemKey) {
      _itemKey = key;
      _fallbackUrl = null;
      _lookupStarted = false;
      _originalFailed = false;
    }
    // 源里本来就没有封面：进屏即去豆瓣找，不必等占位图先闪一下。
    if (widget.item.cleanPic.isEmpty) _startLookup();
  }

  void _startLookup() {
    if (_lookupStarted || widget.item.name.trim().isEmpty) return;
    _lookupStarted = true;
    unawaited(_lookup());
  }

  Future<void> _lookup() async {
    final key = _itemKey;
    final url = await CoverImages.instance.resolve(
      widget.item.name,
      year: widget.item.year,
    );
    if (!mounted || key != _itemKey) return;
    setState(() => _fallbackUrl = url);
  }

  /// 图片加载失败发生在 build 里：标脏与补图都推迟到这一帧之后。
  void _handleImageError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_originalFailed && widget.item.cleanPic.isNotEmpty) {
        setState(() => _originalFailed = true);
      }
      _startLookup();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.item;
    final usingOriginal = item.cleanPic.isNotEmpty && !_originalFailed;
    // 豆瓣图床不带 Referer 会 418：源里直接给的豆瓣封面改走本地中继。
    final originalUrl = doubanImageDisplayUrl(item.cleanPic);
    final posterUrl = usingOriginal ? originalUrl : (_fallbackUrl ?? '');
    final posterHeaders = usingOriginal && !isDoubanImageUrl(item.cleanPic)
        ? item.picHeaders
        : const <String, String>{};
    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _PosterImage(
            url: posterUrl,
            headers: posterHeaders,
            name: item.name,
            onError: _handleImageError,
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0x99000000)],
                stops: [0.55, 1],
              ),
            ),
          ),
          if (item.year.isNotEmpty)
            Positioned(left: 8, top: 8, child: _Badge(text: item.year)),
          if (item.remarks.isNotEmpty)
            Positioned(
              left: 9,
              right: 9,
              bottom: 9,
              child: Text(
                item.remarks,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                ),
              ),
            ),
          if (widget.badge.isNotEmpty)
            Positioned(
              right: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.badge,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.onPrimary,
                  ),
                ),
              ),
            )
          else if (widget.showSource && item.sourceName.isNotEmpty)
            Positioned(
              right: 8,
              top: 8,
              child: _Badge(text: item.sourceName, light: true),
            ),
          if (_hover)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.18),
                child: const Center(
                  child: CircleAvatar(
                    radius: 22,
                    backgroundColor: Colors.white24,
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    final card = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _hover ? 1.025 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: widget.heroTag == null
                    ? poster
                    : Hero(tag: widget.heroTag!, child: poster),
              ),
              const SizedBox(height: 8),
              HoverMarqueeText(
                item.name,
                maxLines: 2,
                externalHover: _hover,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
              if (item.sameFromOtherSources > 0)
                _SourceCountLabel(
                  count: item.sameFromOtherSources,
                  onTap: widget.onShowSources,
                ),
            ],
          ),
        ),
      ),
    );

    // 网格中不再逐卡片播放入场动画：一屏几十个隐式动画会同时驱动重绘。
    final withSecondary =
        (widget.onLongPress != null || widget.onSecondaryLongPress != null)
        ? SecondaryLongPressDetector(
            onLongPress: widget.onSecondaryLongPress,
            // 短按右键保持原有行为（收藏菜单等）；长按右键则改为聚合搜索。
            onTap: widget.onLongPress,
            child: card,
          )
        : card;
    return RepaintBoundary(child: withSecondary);
  }
}

class _PosterImage extends StatelessWidget {
  const _PosterImage({
    required this.url,
    required this.headers,
    required this.name,
    this.onError,
  });

  final String url;
  final Map<String, String> headers;
  final String name;

  /// 加载失败时通知卡片去豆瓣兜底。
  final VoidCallback? onError;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return _Placeholder(name: name);
    return Image.network(
      url,
      fit: BoxFit.cover,
      headers: headers.isEmpty ? null : headers,
      filterQuality: FilterQuality.low,
      // 卡片物理宽度约 170~380px（含高 DPI），按 320 解码即可，过大只是浪费内存
      cacheWidth: 320,
      errorBuilder: (_, _, _) {
        onError?.call();
        return _Placeholder(name: name);
      },
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return _Placeholder(name: name);
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.32),
            accent.withValues(alpha: 0.12),
            theme.colorScheme.secondary.withValues(alpha: 0.2),
          ],
        ),
      ),
      child: Center(
        child: Text(
          name.isEmpty ? '?' : name.characters.first,
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            color: Colors.white.withValues(alpha: 0.75),
          ),
        ),
      ),
    );
  }
}

class _SourceCountLabel extends StatelessWidget {
  const _SourceCountLabel({required this.count, this.onTap});

  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.layers_rounded,
          size: 12,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 4),
        Text(
          '另有 $count 个源',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ],
    );
    // 没有回调时不能包 GestureDetector：opaque 命中区域会吞掉整张卡片的点击。
    if (onTap == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: row),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.light = false});
  final String text;
  final bool light;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: light
            ? Colors.white.withValues(alpha: 0.86)
            : Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: light ? Colors.black87 : Colors.white,
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/theme/app_theme.dart';
import '../../services/runtime_extension.dart';
import '../pages/favorites_page.dart';
import '../pages/history_page.dart';
import '../pages/home_page.dart';
import '../pages/live_page.dart';
import '../pages/search_page.dart';
import '../pages/settings_page.dart';
import '../immersive/immersive_shell.dart';
import '../widgets/glass.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with TickerProviderStateMixin {
  int _index = 0;
  bool _eulaScheduled = false;
  int _handledSearchSeq = 0;
  final GlobalKey<SettingsPageState> _settingsKey =
      GlobalKey<SettingsPageState>();
  late final AnimationController _indicator = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    lowerBound: 0,
    upperBound: (_items.length - 1).toDouble(),
  );

  /// 自动隐藏模式下横条的滑入/滑出（1 = 完全展开，0 = 完全收起）。
  late final AnimationController _navSlide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );
  Timer? _navHideTimer;
  static const _navHideDelay = Duration(milliseconds: 380);

  /// 上一次的自动隐藏设置；null 表示还没同步过（首次构建）。
  bool? _lastNavAutoHide;

  static const _items = [
    _NavItem(
      icon: Icons.home_rounded,
      outline: Icons.home_outlined,
      label: '首页',
    ),
    _NavItem(
      icon: Icons.search_rounded,
      outline: Icons.search_rounded,
      label: '搜索',
    ),
    _NavItem(
      icon: Icons.live_tv_rounded,
      outline: Icons.live_tv_outlined,
      label: '直播',
    ),
    _NavItem(
      icon: Icons.history_rounded,
      outline: Icons.history_rounded,
      label: '历史',
    ),
    _NavItem(
      icon: Icons.favorite_rounded,
      outline: Icons.favorite_border_rounded,
      label: '收藏',
    ),
    _NavItem(
      icon: Icons.settings_rounded,
      outline: Icons.settings_outlined,
      label: '设置',
    ),
  ];

  @override
  void initState() {
    super.initState();
    RuntimeInstallPrompt.instance.onReveal = _revealRuntimeInstall;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    RuntimeInstallPrompt.instance.hostContext = context;
    _syncNavAutoHide(AppScope.of(context).navBarAutoHide);
  }

  @override
  void dispose() {
    RuntimeInstallPrompt.instance.onReveal = null;
    RuntimeInstallPrompt.instance.hostContext = null;
    _navHideTimer?.cancel();
    _navSlide.dispose();
    _indicator.dispose();
    super.dispose();
  }

  void _syncNavAutoHide(bool autoHide) {
    if (_lastNavAutoHide == autoHide) return;
    final first = _lastNavAutoHide == null;
    _lastNavAutoHide = autoHide;
    _navHideTimer?.cancel();
    if (!autoHide) {
      _navSlide.value = 1;
    } else if (first) {
      // 启动时就处于自动隐藏：直接保持收起，避免闪一下。
      _navSlide.value = 0;
    } else {
      // 刚切换到自动隐藏：先展示一会儿再收起，方便用户确认横条还在。
      _navSlide.value = 1;
      _scheduleNavHide(const Duration(milliseconds: 1600));
    }
  }

  void _showNav() {
    _navHideTimer?.cancel();
    if (_navSlide.value >= 1) return;
    _navSlide.animateTo(1, curve: Curves.easeOutCubic);
  }

  void _scheduleNavHide([Duration delay = _navHideDelay]) {
    if (_navSlide.value <= 0) return;
    // 鼠标持续移动时，已有默认回收计划就不必重建 Timer；
    // 但切换设置时留下的长延时计划要允许被更短的默认计划替换。
    if ((_navHideTimer?.isActive ?? false) && delay == _navHideDelay) {
      return;
    }
    _navHideTimer?.cancel();
    _navHideTimer = Timer(delay, () {
      if (!mounted || _navSlide.value <= 0) return;
      _navSlide.animateTo(0, curve: Curves.easeInCubic);
    });
  }

  /// 自动隐藏模式下：鼠标靠近窗口底部就滑出，离开后延时收回。
  void _handleNavHover(
    PointerHoverEvent event,
    double viewportHeight,
    double revealZone,
  ) {
    final fromBottom = viewportHeight - event.localPosition.dy;
    if (fromBottom <= revealZone) {
      _showNav();
    } else {
      _scheduleNavHide();
    }
  }

  /// 扩展下载确认后：回到主界面 → 切到设置 → 展开「播放」并滚动到对应卡片，
  /// 由设置页卡片自己开始安装。
  Future<void> _revealRuntimeInstall(RuntimeExtension kind) async {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    _select(5);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _settingsKey.currentState?.revealRuntime(kind);
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
    _indicator.animateTo(index.toDouble(), curve: Curves.easeOutCubic);
    // 进入「收藏」时静默检查一次更新（AppState 内部 30 分钟节流）。
    if (index == 4) unawaited(AppScope.of(context).checkFavoriteUpdates());
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    // 详情页点演员 / 推荐条目 → 切到搜索页并执行一次全源搜索。
    if (app.pendingSearchSeq != _handledSearchSeq) {
      _handledSearchSeq = app.pendingSearchSeq;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _select(1);
      });
    }
    if (!app.eulaAccepted && !_eulaScheduled) {
      _eulaScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => PopScope(
            canPop: false,
            child: _EulaDialog(
              onAccept: () async {
                await app.acceptEula();
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
            ),
          ),
        );
      });
    }

    final theme = Theme.of(context);
    // 沉浸观影模式：整套导航与页面换成大屏 TV 布局。
    if (app.playerSettings.immersiveMode) {
      return const ImmersiveShell();
    }
    // 外观设置里的底部横条尺寸：0 紧凑 / 1 标准 / 2 较大 / 3 超大。
    final navSize = app.navBarSize;
    final barHeight = switch (navSize) {
      0 => 50.0,
      2 => 66.0,
      3 => 78.0,
      _ => 58.0,
    };
    final iconSize = switch (navSize) {
      0 => 19.0,
      2 => 23.5,
      3 => 27.0,
      _ => 21.0,
    };
    // 中文小字号在 Windows 的分数缩放下极易糊成一团，最低也保持在 11 左右。
    final labelSize = switch (navSize) {
      0 => 11.0,
      2 => 13.0,
      3 => 14.0,
      _ => 12.0,
    };
    final barMaxWidth = switch (navSize) {
      0 => 560.0,
      2 => 720.0,
      3 => 820.0,
      _ => 640.0,
    };
    final navRadius = navSize >= 3 ? 26.0 : 22.0;
    final itemRadius = navSize >= 3 ? 20.0 : 17.0;

    final pages = IndexedStack(
      index: _index,
      children: [
        const HomePage(),
        const SearchPage(),
        const LivePage(),
        const HistoryPage(),
        const FavoritesPage(),
        SettingsPage(key: _settingsKey),
      ],
    );

    final navBar = Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: barMaxWidth),
          child: GlassPanel(
            padding: const EdgeInsets.all(5),
            borderRadius: navRadius,
            child: SizedBox(
              height: barHeight,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final slot = constraints.maxWidth / _items.length;
                  return Stack(
                    children: [
                      Positioned(
                        left: 0,
                        top: 2,
                        width: slot - 4,
                        height: barHeight - 4,
                        child: IgnorePointer(
                          child: AnimatedBuilder(
                            animation: _indicator,
                            builder: (context, child) {
                              return Transform.translate(
                                offset: Offset(slot * _indicator.value + 2, 0),
                                child: child,
                              );
                            },
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: 0.17,
                                ),
                                borderRadius: BorderRadius.circular(itemRadius),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          for (var i = 0; i < _items.length; i++)
                            Expanded(
                              child: _NavButton(
                                item: _items[i],
                                selected: _index == i,
                                iconSize: iconSize,
                                labelSize: labelSize,
                                borderRadius: itemRadius,
                                onTap: () => _select(i),
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    // 横条连同外边距的总高度（4 + 5 + barHeight + 5 + 10）。
    final navTotalHeight = barHeight + 24;
    // 鼠标进入窗口底部这个区域时把横条拉出。
    final revealZone = navTotalHeight + 20;
    final autoHide = app.navBarAutoHide;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: autoHide
            ? LayoutBuilder(
                builder: (context, constraints) {
                  return MouseRegion(
                    onHover: (event) => _handleNavHover(
                      event,
                      constraints.maxHeight,
                      revealZone,
                    ),
                    onExit: (_) => _scheduleNavHide(),
                    child: Stack(
                      children: [
                        Positioned.fill(child: pages),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: AnimatedBuilder(
                            animation: _navSlide,
                            builder: (context, child) => IgnorePointer(
                              ignoring: _navSlide.value <= 0.02,
                              child: Transform.translate(
                                offset: Offset(
                                  0,
                                  (1 - _navSlide.value) * (navTotalHeight + 12),
                                ),
                                child: child,
                              ),
                            ),
                            child: navBar,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              )
            : Column(
                children: [
                  Expanded(child: pages),
                  navBar,
                ],
              ),
      ),
    );
  }
}

class _NavItem {
  const _NavItem({
    required this.icon,
    required this.outline,
    required this.label,
  });
  final IconData icon;
  final IconData outline;
  final String label;
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
    this.iconSize = 21,
    this.labelSize = 10.5,
    this.borderRadius = 17,
  });
  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;
  final double iconSize;
  final double labelSize;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withValues(alpha: 0.72);
    return InkWell(
      borderRadius: BorderRadius.circular(borderRadius),
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedScale(
            scale: selected ? 1.08 : 1,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            child: Icon(
              selected ? item.icon : item.outline,
              size: iconSize,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 180),
            style: TextStyle(
              fontFamily: AppTheme.bodyFontFamily,
              fontFamilyFallback: AppTheme.bodyFontFamilyFallback,
              fontSize: labelSize,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: color,
            ),
            child: Text(item.label),
          ),
        ],
      ),
    );
  }
}

/// 首次启动的用户协议与免责声明。参考原版 Winbox 的免责口径：
/// 软件只是播放器与聚合客户端，内容与来源由使用者自行负责。
class _EulaDialog extends StatelessWidget {
  const _EulaDialog({required this.onAccept});

  final VoidCallback onAccept;

  static const _terms = [
    '本软件是本地播放器与信息聚合客户端，仅用于个人学习、研究与技术交流，不提供、不存储、不分发任何音视频内容。',
    '软件不内置任何影视源、解析接口或直播源。所有订阅源、直播源均由你自行提供，其内容与合法性由你自行负责。',
    '请遵守你所在地区的法律法规及内容服务条款，不得将本软件用于商业用途或任何违法用途。',
    '使用本软件产生的一切后果由你自行承担；开发者不对第三方内容的可用性、合法性或安全性负责。',
    '软件无账号、无遥测，数据只保存在本机。',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: Icon(Icons.gavel_rounded, color: theme.colorScheme.primary),
      title: const Text('用户协议与免责声明'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '欢迎使用 MisaTV。开始使用前，请阅读并同意以下条款：',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < _terms.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i + 1}.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _terms[i],
                          style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.65,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                '点击「同意并继续」即表示你已阅读并同意以上条款。',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [FilledButton(onPressed: onAccept, child: const Text('同意并继续'))],
    );
  }
}

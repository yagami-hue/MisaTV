import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../logging/app_log.dart';
import 'video_window_fit.dart';

/// 桌面自绘标题栏仅在 Windows 启用（其余桌面保留系统窗口装饰）。
final bool hasCustomWindowChrome = Platform.isWindows;


/// 关窗时（自绘按钮 / 系统 X / Alt+F4）先跑这里注册的清理，再结束进程。
Future<void> Function()? _shutdownHook;

/// 注册关窗清理：停掉常驻取流 JVM、结束子进程等。必须在 `setupDesktopWindow()` 之前调用。
void registerAppShutdown(Future<void> Function() hook) => _shutdownHook = hook;

class _WindowChromeObserver with WindowListener {
  _WindowChromeObserver() {
    windowManager.addListener(this);
    windowManager.isMaximized().then(
      (value) => maximized.value = value,
      onError: (_) {},
    );
  }

  final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);
  final ValueNotifier<bool> fullScreen = ValueNotifier<bool>(false);
  bool _closing = false;

  @override
  void onWindowMaximize() => maximized.value = true;

  @override
  void onWindowUnmaximize() => maximized.value = false;

  @override
  void onWindowEnterFullScreen() => fullScreen.value = true;

  @override
  void onWindowLeaveFullScreen() => fullScreen.value = false;

  /// 窗口拦截了关闭消息（`setPreventClose(true)`），在这里做收尾后真正退出。
  ///
  /// 收尾只做「停掉常驻取流 JVM」这类必须走 Dart 的事；进程怎么结束交给
  /// runner：`windowManager.destroy()` 发出 WM_QUIT，runner 退出消息循环后
  /// 先销毁窗口、再直接 TerminateProcess。以前在 Dart 里 `exit(0)` 会让退出
  /// 走进 flutter_windows / WebView2 的析构崩溃路径，Windows 错误报告每次都
  /// 生成一个快照克隆进程，任务管理器里就会堆一串关不掉的 kniephos.exe。
  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    try {
      await _shutdownHook?.call().timeout(const Duration(seconds: 3));
    } catch (_) {
      // 收尾失败也要退出
    }
    try {
      await windowManager.destroy().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}

_WindowChromeObserver? _chrome;

_WindowChromeObserver get _observer => _chrome ??= _WindowChromeObserver();

ValueListenable<bool> get windowMaximized => _observer.maximized;

ValueListenable<bool> get windowFullScreen => _observer.fullScreen;

/// 默认窗口大小按主屏**工作区**（逻辑像素，已扣除任务栏与系统缩放）等比推算。
///
/// 基准是 2K（2560×1440）下的 1280×820：取工作区宽度的 50%，这样 1080p 下
/// 约为 960×620、4K 下约为 1920×1230，相对占屏比例与 2K 保持一致，而不是
/// 固定像素导致小屏过大、大屏过小。
const double _minWindowWidth = 920.0;
const double _minWindowHeight = 620.0;

bool get _isDesktopWindow =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// 桌面端才有独立窗口可记忆（Web / 移动端返回 false）。
bool get supportsAppWindowSize => _isDesktopWindow;

/// 当前窗口大小（逻辑像素）；非桌面端返回 null。
Future<Size?> currentAppWindowSize() async {
  if (!_isDesktopWindow) return null;
  try {
    return await windowManager.getSize();
  } catch (_) {
    return null;
  }
}

Future<Size> _defaultWindowSize() async {
  const base = Size(1280, 820);
  try {
    final work = await _workAreaSize();
    if (work.width <= 0 || work.height <= 0) return base;
    final width = (work.width * 0.5).clamp(_minWindowWidth, 1920.0).toDouble();
    final maxHeight = work.height * 0.9;
    final height = (width * base.height / base.width)
        .clamp(math.min(_minWindowHeight, maxHeight), maxHeight)
        .toDouble();
    return Size(width, height);
  } catch (_) {
    // 拿不到显示器信息时退回 2K 基准，不影响启动。
    return base;
  }
}

/// 启动尺寸：记住过就用记忆值，并按当前显示器工作区收一收，
/// 避免换到小屏后窗口比屏幕还大。
Future<Size> _startupWindowSize(Size? remembered) async {
  if (remembered == null) return _defaultWindowSize();
  try {
    final work = await _workAreaSize();
    if (work.width > 0 && work.height > 0) {
      return Size(
        remembered.width
            .clamp(math.min(_minWindowWidth, work.width), work.width)
            .toDouble(),
        remembered.height
            .clamp(math.min(_minWindowHeight, work.height), work.height)
            .toDouble(),
      );
    }
  } catch (_) {
    // 拿不到显示器信息时按记忆值直接创建
  }
  return remembered;
}

Future<void> setupDesktopWindow({Size? size}) async {
  if (!_isDesktopWindow) return;
  await windowManager.ensureInitialized();
  _observer;
  // 关窗交给 onWindowClose 做收尾，避免残留进程。
  await windowManager.setPreventClose(true);
  final options = WindowOptions(
    size: await _startupWindowSize(size),
    minimumSize: const Size(_minWindowWidth, _minWindowHeight),
    center: true,
    title: 'MisaTV',
    titleBarStyle: hasCustomWindowChrome
        ? TitleBarStyle.hidden
        : TitleBarStyle.normal,
    backgroundColor: Colors.transparent,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    if (hasCustomWindowChrome) {
      // 去掉系统标题栏与边框，全部由 Flutter 自绘。
      await windowManager.setAsFrameless();
    }
    await windowManager.show();
    await windowManager.focus();
  });
}

/// 无边框窗口的边缘缩放层（Windows 由 Flutter 接管全部拖拽缩放）。
Widget windowFrame(Widget child) {
  if (!hasCustomWindowChrome) return child;
  return ValueListenableBuilder<bool>(
    valueListenable: windowFullScreen,
    builder: (context, fullScreen, _) {
      return ValueListenableBuilder<bool>(
        valueListenable: windowMaximized,
        builder: (context, maximized, _) {
          return DragToResizeArea(
            resizeEdgeSize: 6,
            enableResizeEdges: (maximized || fullScreen) ? const [] : null,
            child: child,
          );
        },
      );
    },
  );
}

Future<void> minimizeAppWindow() async {
  if (hasCustomWindowChrome) await windowManager.minimize();
}

bool _trayHidden = false;
bool _trayWasFullScreen = false;
Size? _immersiveRestoreSize;
Offset? _immersiveRestorePosition;
bool _immersiveRestoreMaximized = false;
bool _immersiveWasFullScreen = false;
bool _immersiveActive = false;

/// 进入沉浸观影：独占全屏，并记住原来的窗口状态，退出时还原。
Future<void> enterImmersiveFullscreen() async {
  if (!_isDesktopWindow || _immersiveActive) return;
  _immersiveActive = true;
  try {
    _immersiveWasFullScreen = await windowManager.isFullScreen();
    _immersiveRestoreMaximized = await windowManager.isMaximized();
    _immersiveRestoreSize = await windowManager.getSize();
    _immersiveRestorePosition = await windowManager.getPosition();
    if (!_immersiveWasFullScreen) await setWindowFullscreen(true);
  } catch (_) {
    _immersiveActive = false;
  }
}

/// 退出沉浸观影：还原进入前的窗口大小、位置与最大化状态。
Future<void> exitImmersiveFullscreen() async {
  if (!_isDesktopWindow || !_immersiveActive) return;
  _immersiveActive = false;
  try {
    if (!_immersiveWasFullScreen) {
      await setWindowFullscreen(false);
      final size = _immersiveRestoreSize;
      final position = _immersiveRestorePosition;
      if (size != null) await windowManager.setSize(size);
      if (position != null) await windowManager.setPosition(position);
      if (_immersiveRestoreMaximized) await windowManager.maximize();
    }
  } catch (_) {
    // 还原失败不阻断切回普通界面
  } finally {
    _immersiveRestoreSize = null;
    _immersiveRestorePosition = null;
    _immersiveRestoreMaximized = false;
    _immersiveWasFullScreen = false;
  }
}

/// 老板键隐藏：记下隐藏前的窗口形态（全屏 / 小窗 / 最大化或普通），
/// 隐藏到托盘并从任务栏移除。
Future<void> hideAppWindowToTray() async {
  if (!_isDesktopWindow || _trayHidden) return;
  _trayHidden = true;
  try {
    _trayWasFullScreen = await windowManager.isFullScreen();
    await windowManager.setSkipTaskbar(true);
    await windowManager.hide();
  } catch (_) {
    _trayHidden = false;
  }
}

/// 老板键恢复：按隐藏前的形态还原（全屏回全屏，小窗尺寸与置顶保持不变）。
Future<void> restoreAppWindowFromTray() async {
  if (!_isDesktopWindow) return;
  try {
    await windowManager.setSkipTaskbar(false);
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    if (_trayWasFullScreen && !await windowManager.isFullScreen()) {
      await setWindowFullscreen(true);
    }
    _trayWasFullScreen = false;
    await windowManager.focus();
  } catch (_) {
    // 恢复失败不影响后续操作
  } finally {
    _trayHidden = false;
  }
}

/// 播放器窗口置顶开关。只在本次播放会话内生效，离开播放器时由播放器页复位。
Future<void> setAppWindowAlwaysOnTop(bool value) async {
  if (!hasCustomWindowChrome) return;
  await windowManager.setAlwaysOnTop(value);
}

Future<void> toggleMaximizeAppWindow() async {
  if (!hasCustomWindowChrome) return;
  if (await windowManager.isMaximized()) {
    await windowManager.unmaximize();
  } else {
    await windowManager.maximize();
  }
}

Future<void> closeAppWindow() async {
  if (hasCustomWindowChrome) await windowManager.close();
}

Future<void> startWindowDrag() async {
  if (hasCustomWindowChrome) await windowManager.startDragging();
}

/// 二级页面（详情 / 播放器 / 直播）隐藏了自绘标题栏，让页面自己的顶栏承担
/// 窗口拖拽，否则这些页面上窗口完全没法用鼠标移动。
///
/// 只挂拖拽、不挂双击最大化：双击识别器会把子按钮（返回 / 收藏等）的点击
/// 拖到双击超时之后才判定，按钮会明显变迟钝。
Widget windowDragArea(Widget child, {bool enabled = true}) {
  if (!hasCustomWindowChrome || !enabled) return child;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => startWindowDrag(),
    child: child,
  );
}

/// 本窗口的常规最小尺寸：主窗口 920×620，独立播放器窗口更小（见调用方）。
Size _windowMinimumSize = const Size(_minWindowWidth, _minWindowHeight);

/// 登记本窗口的常规最小尺寸；迷你小窗退出后按它还原。
void setAppWindowMinimumSize(Size size) => _windowMinimumSize = size;

Size? _miniRestoreSize;
Offset? _miniRestorePosition;
bool _miniRestoreMaximized = false;
bool _miniActive = false;

/// 小窗播放：缩成小窗、始终置顶；退出时恢复原来的大小、位置与最大化状态。
Future<void> enterMiniPlayerWindow() async {
  if (!hasCustomWindowChrome || _miniActive) return;
  _miniActive = true;
  try {
    _miniRestoreMaximized = await windowManager.isMaximized();
    _miniRestoreSize = await windowManager.getSize();
    _miniRestorePosition = await windowManager.getPosition();

    if (_miniRestoreMaximized) await windowManager.unmaximize();
    await windowManager.setMinimumSize(const Size(280, 160));
    await windowManager.setAlwaysOnTop(true);
    // 竖版视频的小窗也竖着放，否则小窗里全是黑边。
    await windowManager.setSize(
      _videoAspect > 0 && _videoAspect < 1
          ? const Size(292, 480)
          : const Size(480, 292),
    );
    await windowManager.center();
  } catch (_) {
    _miniActive = false;
  }
}

Future<void> exitMiniPlayerWindow() async {
  if (!hasCustomWindowChrome || !_miniActive) return;
  _miniActive = false;
  try {
    await windowManager.setAlwaysOnTop(false);
    if (_miniRestoreSize != null) {
      await windowManager.setSize(_miniRestoreSize!);
    }
    if (_miniRestorePosition != null) {
      await windowManager.setPosition(_miniRestorePosition!);
    }
    await windowManager.setMinimumSize(_windowMinimumSize);
    if (_miniRestoreMaximized) await windowManager.maximize();
  } catch (_) {
    // 恢复失败也不阻断播放
  } finally {
    _miniRestoreSize = null;
    _miniRestorePosition = null;
    _miniRestoreMaximized = false;
  }
}

/// window_manager 的 Windows 实现在「已无边框」（`setAsFrameless`）状态下会跳过
/// 真正的全屏处理，只把内部标志置位：第一次点全屏毫无反应，要再点两次才生效。
/// 进全屏前先把标题栏样式声明为 `hidden`（外观仍是自绘无边框，这也正是启动时的
/// 选项），插件才会走真正的全屏分支；退出后再恢复 frameless，避免残留系统边框。
///
/// 窗口本身保持瞬时切换；播放器页会在切换前后用 Flutter 内容缩放动画
/// 把这次尺寸跳变遮掉（逐帧 Resize 整个引擎表面会明显卡顿）。
Future<void> setWindowFullscreen(bool fullscreen) async {
  if (!Platform.isWindows) {
    await windowManager.setFullScreen(fullscreen);
    _observer.fullScreen.value = fullscreen;
    return;
  }
  _observer.fullScreen.value = fullscreen;
  if (fullscreen) {
    // 两条消息同批下发：中间不做等待，少一帧 hidden 样式自带的缩放边内缩。
    final style = windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    final enter = windowManager.setFullScreen(true);
    await style;
    await enter;
  } else {
    final exit = windowManager.setFullScreen(false);
    final restore = windowManager.setAsFrameless();
    await exit;
    await restore;
  }
}

double _videoAspect = 0;
Size? _videoRestoreSize;
Offset? _videoRestorePosition;
Size? _videoRestoreMinimum;

/// 主屏工作区（与 window_manager 的尺寸接口同一套单位，Windows 上是物理像素）。
Future<Size> _workAreaSize() async {
  try {
    final display = await screenRetriever.getPrimaryDisplay();
    final work = display.visibleSize ?? display.size;
    if (work.width > 0 && work.height > 0) return work;
  } catch (_) {
    // 拿不到显示器信息时退回 2K 基准
  }
  return const Size(1280, 720);
}

/// 独立播放器窗口按视频分辨率切横 / 竖版。
///
/// 只在分辨率真的变了才动手：同一段视频里用户自己拖过的尺寸不会被反复覆盖。
/// 竖版视频把窗口压成视频比例并居中，同时记住切换前的几何；回到横版视频时还原，
/// 用户手动摆的位置也不会丢。
Future<void> fitAppWindowToVideo(double videoWidth, double videoHeight) async {
  if (!_isDesktopWindow) return;
  final aspect = videoAspectOf(videoWidth, videoHeight);
  if (aspect <= 0 || (aspect - _videoAspect).abs() < 0.02) return;
  _videoAspect = aspect;
  try {
    if (await windowManager.isFullScreen()) return;
    if (aspect < 1) {
      if (_videoRestoreSize == null) {
        _videoRestoreSize = await windowManager.getSize();
        _videoRestorePosition = await windowManager.getPosition();
        _videoRestoreMinimum = _windowMinimumSize;
      }
      final size = windowSizeForVideo(
        videoWidth,
        videoHeight,
        await _workAreaSize(),
      );
      _windowMinimumSize = portraitWindowMinimum(videoWidth, videoHeight);
      await windowManager.setMinimumSize(_windowMinimumSize);
      await windowManager.setSize(size);
      await windowManager.center();
      AppLog.i(
        'window',
        '竖版视频 ${videoWidth.round()}x${videoHeight.round()} → '
            '窗口 ${size.width.round()}x${size.height.round()}',
      );
      return;
    }
    // 横版：只还原被我们改成竖版的窗口，用户自己拖出来的尺寸不动。
    final restore = _videoRestoreSize;
    if (restore == null) return;
    final position = _videoRestorePosition;
    final minimum = _videoRestoreMinimum;
    _videoRestoreSize = null;
    _videoRestorePosition = null;
    _videoRestoreMinimum = null;
    if (minimum != null) {
      _windowMinimumSize = minimum;
      await windowManager.setMinimumSize(minimum);
    }
    await windowManager.setSize(restore);
    if (position != null) await windowManager.setPosition(position);
    AppLog.i('window', '横版视频 → 窗口还原 ${restore.width.round()}x${restore.height.round()}');
  } catch (e, s) {
    AppLog.w('window', '按视频比例调整窗口失败', e, s);
  }
}

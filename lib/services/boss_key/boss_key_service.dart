import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../core/logging/app_log.dart';
import '../../core/platform/window_service.dart';
import '../../models/user_data.dart';
import '../../state/app_state.dart';

/// 老板键：暂停正在播放的视频并把窗口收进托盘；再按一次老板键或点托盘图标
/// 恢复原来的形态（全屏回全屏、小窗回小窗、普通窗口回普通窗口）。
///
/// 沉浸观影模式下整个功能不生效（热键仍然注册，但按下不做任何事）。
class BossKeyService {
  BossKeyService._();

  static final BossKeyService instance = BossKeyService._();

  AppState? _app;
  TrayIcon? _tray;
  Menu? _menu;
  final List<MenuItem> _menuItems = [];
  HotKey? _hotKey;
  String _activeBossKey = '';
  bool _hidden = false;
  bool _busy = false;
  bool _pausedByBoss = false;
  int _lastPressMs = 0;
  String lastHotKeyError = '';

  /// 最近一次注册使用的老板键（用于设置页显示状态）。
  String get activeBossKey => _activeBossKey;

  static bool get _desktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// 启动时接好托盘与全局热键；失败只记日志，不影响正常使用。
  ///
  /// 调用方必须保证此时窗口与消息循环已就绪（见 main.dart 的首帧回调）。
  Future<void> init(AppState app) async {
    if (!_desktop) return;
    _app = app;
    // 托盘与热键互不影响：任一失败都不该拖垮启动。
    try {
      _initTray();
    } catch (e) {
      AppLog.w('boss', '托盘初始化异常（忽略）：$e');
    }
    try {
      await applyBossKey(app.playerSettings.bossKey);
    } catch (e) {
      AppLog.w('boss', '老板键初始化异常（忽略）：$e');
    }
  }

  /// 更换老板键（设置页保存后调用）。返回是否注册成功。
  ///
  /// **只有用户显式选择的组合才会被注册**。未设置（空串）时直接释放旧热键，
  /// 不占用任何全局组合——不替用户做决定，也避免与常用软件抢键。
  Future<bool> applyBossKey(String raw) async {
    if (!_desktop) return false;
    final value = normalizeBossKey(raw);
    _activeBossKey = value;
    lastHotKeyError = '';
    final previous = _hotKey;
    _hotKey = null;
    if (previous != null) {
      try {
        await hotKeyManager.unregister(previous);
      } catch (_) {
        // 旧键可能已经失效，继续注册新键。
      }
    }
    _tray?.setTooltip(_tooltipText());
    // 未设置：什么都不注册，这是正常状态而不是失败。
    if (!isBossKeySet(value)) {
      AppLog.i('boss', '老板键未设置（不占用全局热键）');
      return true;
    }
    final hotKey = _hotKeyFor(value);
    if (hotKey == null) {
      lastHotKeyError = '不支持的组合：${bossKeyLabel(value)}';
      AppLog.w('boss', lastHotKeyError);
      return false;
    }
    try {
      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) => _onPressed(),
      );
      _hotKey = hotKey;
      AppLog.i('boss', '老板键已注册：${bossKeyLabel(value)}');
      return true;
    } catch (e) {
      // 冲突是最常见的失败原因（组合已被其它软件占用）。把原因留给设置页显示，
      // 不要让用户以为「设置成功但按了没反应」。
      lastHotKeyError = _describeRegisterFailure(e, value);
      AppLog.w('boss', '老板键注册失败（${bossKeyLabel(value)}）：$e');
      return false;
    }
  }

  /// 把注册异常翻译成用户能看懂的说明。
  String _describeRegisterFailure(Object error, String value) {
    final text = '$error';
    final label = bossKeyLabel(value);
    if (text.contains('register_failed') || text.contains('RegisterHotKey')) {
      return '$label 已被其它程序占用，请换一个组合';
    }
    return '$label 注册失败：$text';
  }

  /// 托盘提示：未设置时也要说清楚，而不是显示一个假的组合。
  String _tooltipText() {
    final value = _activeBossKey;
    if (!isBossKeySet(value)) return 'MisaTV';
    if (lastHotKeyError.isNotEmpty) {
      return 'MisaTV · ${bossKeyLabel(value)}（不可用）';
    }
    return 'MisaTV · 老板键 ${bossKeyLabel(value)}';
  }

  /// 热键回调：沉浸观影模式直接忽略，按住不放产生的重复事件只认第一次。
  void _onPressed() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPressMs < 600) return;
    _lastPressMs = now;
    final app = _app;
    if (app == null) return;
    if (app.playerSettings.immersiveMode) return;
    unawaited(toggle());
  }

  Future<void> toggle() async {
    if (_busy) return;
    if (_hidden) {
      await restore();
    } else {
      await hide();
    }
  }

  /// 暂停视频并隐藏到托盘。
  Future<void> hide() async {
    if (_busy || _hidden) return;
    _busy = true;
    try {
      final paused = _pauseHook?.call() ?? false;
      _pausedByBoss = paused;
      await hideAppWindowToTray();
      _hidden = true;
      AppLog.i('boss', '老板键：已隐藏到托盘${paused ? '，播放已暂停' : ''}');
    } finally {
      _busy = false;
    }
  }

  /// 从托盘恢复窗口，并只在老板键按下前正在播放时才继续播放。
  Future<void> restore() async {
    if (_busy) return;
    _busy = true;
    try {
      await restoreAppWindowFromTray();
      _hidden = false;
      if (_pausedByBoss) {
        _pausedByBoss = false;
        _resumeHook?.call();
      }
      AppLog.i('boss', '老板键：已恢复窗口');
    } finally {
      _busy = false;
    }
  }

  // ---------------------------------------------------------------- 播放器钩子

  Object? _playerOwner;
  bool Function()? _pauseHook;
  VoidCallback? _resumeHook;

  /// 播放器页注册：返回是否真的暂停了（原本暂停时不恢复）。
  void bindPlayer(
    Object owner, {
    required bool Function() pause,
    required VoidCallback resume,
  }) {
    _playerOwner = owner;
    _pauseHook = pause;
    _resumeHook = resume;
  }

  void unbindPlayer(Object owner) {
    if (_playerOwner != owner) return;
    _playerOwner = null;
    _pauseHook = null;
    _resumeHook = null;
  }

  // -------------------------------------------------------------------- 托盘

  void _initTray() {
    try {
      final icon = TrayIcon.create();
      if (icon == null) return;
      _tray = icon;
      icon.icon = ImageAsset.fromAsset('assets/images/app_icon.png');
      icon.setTooltip(_tooltipText());

      final menu = Menu.create();
      if (menu != null) {
        final showItem = MenuItem.createWithLabelAndType(
          '显示 MisaTV',
          MenuItemType.normal,
        );
        if (showItem != null) {
          showItem.addListener((event) {
            if (event is MenuItemClickedEvent) unawaited(restore());
          });
          menu.addItem(showItem);
          _menuItems.add(showItem);
        }
        menu.addSeparator();
        final exitItem = MenuItem.createWithLabelAndType(
          '退出 MisaTV',
          MenuItemType.normal,
        );
        if (exitItem != null) {
          exitItem.addListener((event) {
            if (event is MenuItemClickedEvent) {
              // 等菜单收起后再关窗，避免在菜单回调里直接销毁窗口。
              Timer.run(() => unawaited(closeAppWindow()));
            }
          });
          menu.addItem(exitItem);
          _menuItems.add(exitItem);
        }
        icon.setContextMenu(menu);
        icon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
        _menu = menu;
      }
      if (_menu != null) {
        AppLog.i('boss', '托盘菜单已创建（${_menuItems.length} 项）');
      }

      icon.addListener((event) {
        if (event is TrayIconClickedEvent ||
            event is TrayIconDoubleClickedEvent) {
          unawaited(restore());
        }
      });
      // 原生托盘可能在窗口 / 消息循环未就绪时失败，而 setVisible 只返回 bool、
      // 不抛异常。以前直接丢弃返回值，日志永远写「托盘图标已创建」，
      // 崩溃现场就变成「看起来成功然后进程消失」。现在按真实结果记日志。
      final visible = icon.setVisible(true);
      if (visible) {
        AppLog.i('boss', '托盘图标已创建');
      } else {
        AppLog.w('boss', '托盘图标创建失败：setVisible 返回 false（窗口或消息循环未就绪）');
      }
    } catch (e) {
      AppLog.w('boss', '托盘图标创建失败：$e');
    }
  }

  HotKey? _hotKeyFor(String value) {
    final key = switch (value) {
      'ctrl+shift+b' => LogicalKeyboardKey.keyB,
      'ctrl+alt+b' => LogicalKeyboardKey.keyB,
      'ctrl+shift+f' => LogicalKeyboardKey.keyF,
      'alt+q' => LogicalKeyboardKey.keyQ,
      'alt+x' => LogicalKeyboardKey.keyX,
      'alt+z' => LogicalKeyboardKey.keyZ,
      'f12' => LogicalKeyboardKey.f12,
      _ => null,
    };
    if (key == null) return null;
    final modifiers = switch (value) {
      'ctrl+shift+b' || 'ctrl+shift+f' => [
        HotKeyModifier.control,
        HotKeyModifier.shift,
      ],
      'ctrl+alt+b' => [HotKeyModifier.control, HotKeyModifier.alt],
      'alt+q' || 'alt+x' || 'alt+z' => [HotKeyModifier.alt],
      _ => const <HotKeyModifier>[],
    };
    return HotKey(
      identifier: 'misa-boss-key',
      key: key,
      modifiers: modifiers,
      scope: HotKeyScope.system,
    );
  }
}

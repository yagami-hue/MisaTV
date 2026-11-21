import 'package:flutter/material.dart';

import '../../models/drive_account.dart';
import '../../models/site_config.dart';
import '../../models/vod.dart';
import '../../services/drive/drive_login_types.dart';
import '../../state/app_state.dart';
import 'drive_cookie_dialog.dart';
import 'drive_web_login_dialog.dart';
import 'uc_tv_login_dialog.dart';

/// 订阅里的「云盘配置 / 配置中心」源：返回的是操作项，不是影片详情。
///
/// 名称不一定连续：`Wexconfig`、`AAConfig`、`MDrive`（名称「我的云盘┃配置」）
/// 都会返回登入 / 清除 / 排序这类操作项。正常「我的网盘」浏览源没有「配置」字样，
/// 不会命中。
bool isDriveConfigSource(SourceBean site) {
  if (site.api.toLowerCase().contains('config')) return true;
  final label = '${site.key} ${site.name}'.toLowerCase();
  if (label.contains('config') ||
      label.contains('配置中心') ||
      label.contains('云盘配置') ||
      label.contains('网盘配置')) {
    return true;
  }
  final driveLabel = label.contains('云盘') || label.contains('网盘');
  return driveLabel && label.contains('配置');
}

/// 打开网盘配置项面板。
///
/// 订阅里的配置项（登入网盘 / 清除 Cookie / 排序 / 推送授权）多数依赖
/// Android 弹窗，桌面端点进详情只会拿到一段说明。这里直接换成宿主自己的
/// 网盘登录 / 清除面板，凭据保存后照常由 `SpiderEnv.sync` 同步给蜘蛛。
Future<void> showDriveConfigActionSheet(
  BuildContext context,
  AppState app,
  VodItem item,
  SourceBean site,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        DriveConfigPanel(app: app, site: site, item: item, showDone: true),
  );
}

/// 网盘登录 / 清除面板。
///
/// [item] 为空时作为配置源的首页使用（例如 `csp_WexconfigGuard` 在桌面端
/// 起不来时，直接用本面板替代它的空首页）。
class DriveConfigPanel extends StatefulWidget {
  const DriveConfigPanel({
    super.key,
    required this.app,
    required this.site,
    this.item,
    this.showDone = false,
  });

  final AppState app;
  final SourceBean site;
  final VodItem? item;

  /// 底部弹层里显示「完成」；作为首页嵌入时不需要。
  final bool showDone;

  @override
  State<DriveConfigPanel> createState() => _DriveConfigPanelState();
}

class _DriveConfigPanelState extends State<DriveConfigPanel> {
  /// 面板里列出的凭据：能扫码的三家 + 只能手动粘贴的 115 / 哔哩。
  static const _providers = ['quark', 'uc', 'baidu', '115', 'bili', 'thunder', 'guangya'];

  String get _actionText {
    final item = widget.item;
    if (item == null) return '';
    return '${item.name} ${item.id}'.toLowerCase();
  }

  bool get _isClear =>
      _actionText.contains('清除') || _actionText.contains('clear');

  bool get _isTokenAction =>
      _actionText.contains('token') ||
      _actionText.contains('阿里') ||
      _actionText.contains('授权') ||
      _actionText.contains('推送');

  String? get _targetProvider {
    if (_actionText.contains('夸克') ||
        _actionText.contains('夸父') ||
        _actionText.contains('quark')) {
      return 'quark';
    }
    if (_actionText.contains('优汐') ||
        _actionText.contains('优视') ||
        _actionText.contains('uc')) {
      return 'uc';
    }
    if (_actionText.contains('百度') || _actionText.contains('baidu')) {
      return 'baidu';
    }
    if (_isTokenAction) return 'uc';
    return null;
  }

  List<String> get _orderedProviders {
    final target = _targetProvider;
    if (target == null || !_providers.contains(target)) return _providers;
    return [target, ..._providers.where((p) => p != target)];
  }

  String get _hint {
    if (widget.item == null) {
      return '这是一个网盘配置源，桌面端可以直接在本机登录网盘；'
          '排序等 Android 专属配置暂不支持。'
          '扫码完成后 Cookie 会保存到本机，播放时自动同步给蜘蛛源。';
    }
    if (_isClear) {
      return '这是清除项。可以直接用对应网盘的「清除」按钮；清除后重新登录即可恢复。';
    }
    if (_actionText.contains('排序')) {
      return '排序类配置由订阅源维护，桌面端暂不支持修改；网盘账号仍可在本面板管理。';
    }
    if (_isTokenAction) {
      return 'UC TV 授权用于非会员 UC 原画；扫码后会把 Token 保存在本机。';
    }
    return '该配置项由订阅源提供。桌面端可直接在本机登录网盘，播放时会自动同步给蜘蛛源。';
  }

  Future<void> _login(String provider) async {
    if (!driveSupportsWebLogin(provider)) {
      await _manualCookie(provider);
      return;
    }
    final ok = await showDriveLoginDialog(context, provider);
    if (!mounted) return;
    setState(() {});
    if (ok == true) {
      _toast('${driveProviderNames[provider] ?? provider} 登录已更新');
    }
  }

  Future<void> _manualCookie(String provider) async {
    final ok = await showDriveCookieDialog(context, provider);
    if (!mounted) return;
    setState(() {});
    if (ok == true) {
      _toast('${driveProviderNames[provider] ?? provider} Cookie 已保存');
    }
  }

  Future<void> _clear(String provider) async {
    final name = driveProviderNames[provider] ?? provider;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清除 $name 登录？'),
        content: Text('将删除本机保存的 $name Cookie，之后需要重新扫码登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.app.removeDriveAccount(provider);
    if (!mounted) return;
    setState(() {});
    _toast('已清除 $name 登录');
  }

  Future<void> _ucTvLogin() async {
    final ok = await showUcTvLoginDialog(context);
    if (!mounted) return;
    setState(() {});
    if (ok == true) _toast('UC TV 授权已更新');
  }

  Future<void> _clearUcTv() async {
    final uc = widget.app.driveAccounts['uc'];
    if (uc == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除 UC TV 授权？'),
        content: const Text('只会删除 TV 端 Token，不会影响 UC 网盘 Cookie。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final extra = Map<String, String>.from(uc.extra)
      ..remove('uctvToken')
      ..remove('uctvDeviceId');
    if (uc.cookie.trim().isEmpty && extra.isEmpty) {
      await widget.app.removeDriveAccount('uc');
    } else {
      await widget.app.saveDriveAccount(
        'uc',
        uc.cookie,
        username: uc.username,
        extra: extra,
      );
    }
    if (!mounted) return;
    setState(() {});
    _toast('已清除 UC TV 授权');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final site = widget.site;
    final item = widget.item;
    final target = _targetProvider;
    final providers = _orderedProviders;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        // 作为首页嵌入时外层已经是 CustomScrollView，内层不再抢滚动手势。
        physics: widget.showDone ? null : const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          20,
          widget.showDone ? 0 : 8,
          20,
          widget.showDone ? 20 + MediaQuery.paddingOf(context).bottom : 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primary.withValues(
                    alpha: 0.14,
                  ),
                  child: Icon(
                    Icons.cloud_sync_rounded,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item?.name ?? '网盘登录与授权',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${site.displayName} · 网盘配置',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
                height: 1.5,
              ),
            ),
            if (_isClear && target != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () => target == 'uc' && _isTokenAction
                      ? _clearUcTv()
                      : _clear(target),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: Text(
                    target == 'uc' && _isTokenAction
                        ? '清除 UC TV 授权'
                        : '清除 ${driveProviderNames[target] ?? target} 登录',
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            for (final provider in providers) ...[
              _DriveAccountRow(
                provider: provider,
                name: driveProviderNames[provider] ?? provider,
                account: widget.app.driveAccounts[provider],
                onLogin: () => _login(provider),
                onCookie: () => _manualCookie(provider),
                onClear: () => _clear(provider),
              ),
              const SizedBox(height: 10),
            ],
            _UcTvRow(
              account: widget.app.driveAccounts['uc'],
              onLogin: _ucTvLogin,
              onClear: _clearUcTv,
            ),
            if (widget.showDone) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DriveAccountRow extends StatelessWidget {
  const _DriveAccountRow({
    required this.provider,
    required this.name,
    required this.account,
    required this.onLogin,
    required this.onCookie,
    required this.onClear,
  });

  final String provider;
  final String name;
  final DriveAccount? account;
  final VoidCallback onLogin;
  final VoidCallback onCookie;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cookie = (account?.cookie ?? '').trim();
    final guest = account?.extra['guest'] == 'true';
    final loggedIn = cookie.isNotEmpty;
    final optional = provider == 'bili';
    final status = guest
        ? (optional ? 'Cookie 已失效，可重新粘贴' : '访客态，需要重新登录')
        : loggedIn
        ? '已登录'
        : optional
        ? '未配置（仅能播 360P / 480P）'
        : '未登录';
    final statusColor = guest
        ? (optional
              ? theme.colorScheme.onSurface.withValues(alpha: 0.55)
              : theme.colorScheme.error)
        : loggedIn
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface.withValues(alpha: 0.55);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            loggedIn ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
            color: statusColor,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  status,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: statusColor,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '手动输入 Cookie',
            onPressed: onCookie,
            icon: const Icon(Icons.content_paste_rounded, size: 19),
          ),
          OutlinedButton(
            onPressed: onLogin,
            child: Text(
              driveSupportsWebLogin(provider)
                  ? (loggedIn ? '更新' : '登录')
                  : (loggedIn ? '更新 Cookie' : '粘贴 Cookie'),
            ),
          ),
          if (loggedIn)
            IconButton(
              tooltip: '清除 $name 登录',
              onPressed: onClear,
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
            ),
        ],
      ),
    );
  }
}

class _UcTvRow extends StatelessWidget {
  const _UcTvRow({
    required this.account,
    required this.onLogin,
    required this.onClear,
  });

  final DriveAccount? account;
  final VoidCallback onLogin;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final token = (account?.extra['uctvToken'] ?? '').trim();
    final hasToken = token.isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            Icons.tv_rounded,
            color: hasToken
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface.withValues(alpha: 0.5),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'UC TV 授权',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  hasToken ? '已授权' : '未授权',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: hasToken
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
          OutlinedButton(
            onPressed: onLogin,
            child: Text(hasToken ? '重新授权' : '扫码授权'),
          ),
          if (hasToken)
            IconButton(
              tooltip: '清除 UC TV 授权',
              onPressed: onClear,
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
            ),
        ],
      ),
    );
  }
}

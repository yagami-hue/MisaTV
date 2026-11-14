part of '../settings_page.dart';

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: onTap != null,
      leading: Icon(icon, size: 20),
      title: Text(title, style: theme.textTheme.bodyMedium),
      subtitle: Text(subtitle, style: theme.textTheme.labelSmall),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: onTap,
    );
  }
}

class _DriveAccountRow extends StatelessWidget {
  const _DriveAccountRow({required this.provider, required this.app});
  final String provider;
  final AppState app;

  IconData get _icon => switch (provider) {
    'quark' => Icons.cloud_circle_outlined,
    'uc' => Icons.cloud_queue_rounded,
    'baidu' => Icons.cloud_done_outlined,
    '115' => Icons.folder_special_outlined,
    'bili' => Icons.smart_display_outlined,
    _ => Icons.cloud_outlined,
  };

  bool get _webLogin => driveSupportsWebLogin(provider);

  Future<void> _login(BuildContext context) async {
    if (!_webLogin) {
      await _manualCookie(context);
      return;
    }
    final ok = await showDriveLoginDialog(context, provider);
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已绑定${driveProviderNames[provider] ?? provider}'),
        ),
      );
    }
  }

  Future<void> _ucTvLogin(BuildContext context) async {
    final ok = await showUcTvLoginDialog(context);
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('UC TV 授权已保存到本机')));
    }
  }

  Future<void> _manualCookie(BuildContext context) async {
    final ok = await showDriveCookieDialog(context, provider);
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已保存${driveProviderNames[provider] ?? provider} Cookie',
          ),
        ),
      );
    }
  }

  Future<void> _logout(BuildContext context) async {
    final name = driveProviderNames[provider] ?? provider;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('退出 $name？'),
        content: const Text('只会删除本机保存的登录凭据，可随时重新扫码。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true) await app.removeDriveAccount(provider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final account = app.driveAccounts[provider];
    final hasCookie = (account?.cookie ?? '').trim().isNotEmpty;
    final guest = account?.extra['guest'] == 'true';
    final signedIn = hasCookie && !guest;
    final tvBound = (account?.extra['uctvToken'] ?? '').trim().isNotEmpty;
    final name = driveProviderNames[provider] ?? provider;
    final optional = provider == 'bili';
    final statusLabel = guest
        ? '已失效'
        : signedIn
        ? '已登录'
        : (optional ? '未配置' : '未登录');
    final subtitleText = guest
        ? (optional
              ? 'Cookie 已失效，可重新粘贴（未配置也能播 360P / 480P）'
              : '会话已失效（游客态），请重新扫码登录')
        : (signedIn
              ? (account!.username.isNotEmpty
                    ? account.username
                    : 'Cookie 已保存到本机')
              : optional
              ? '可选：粘贴浏览器 Cookie 后可用高清 / 大会员画质，不配置也能播 360P / 480P'
              : (_webLogin
                    ? '在官方网页中扫码登录，登录后蜘蛛源可读取网盘内的资源'
                    : '粘贴浏览器 Cookie 后，蜘蛛源才能读取该网盘内的资源'));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_icon, size: 20),
      title: Row(
        children: [
          Text(name, style: theme.textTheme.bodyMedium),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: signedIn
                  ? theme.colorScheme.primary.withValues(alpha: 0.12)
                  : theme.colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.6,
                    ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: signedIn
                    ? theme.colorScheme.primary
                    : (guest && !optional
                          ? theme.colorScheme.error
                          : theme.disabledColor),
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(subtitleText, style: theme.textTheme.labelSmall),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (provider == 'uc')
            TextButton(
              onPressed: () => _ucTvLogin(context),
              child: Text(tvBound ? 'TV 已授权' : 'TV 扫码'),
            ),
          if (_webLogin)
            TextButton(
              onPressed: () => _manualCookie(context),
              child: const Text('手动 Cookie'),
            ),
          if (guest && !optional)
            FilledButton.tonal(
              onPressed: () => _login(context),
              child: const Text('重新登录'),
            )
          else if (hasCookie)
            TextButton(
              onPressed: () => _logout(context),
              child: const Text('退出'),
            )
          else
            FilledButton.tonal(
              onPressed: () => _login(context),
              child: Text(_webLogin ? '网页扫码登录' : '粘贴 Cookie'),
            ),
        ],
      ),
    );
  }
}

class _ThemeModeTabs extends StatelessWidget {
  const _ThemeModeTabs({required this.value, required this.onChanged});
  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const items = [
      (ThemeMode.system, Icons.brightness_auto_rounded, '跟随系统'),
      (ThemeMode.light, Icons.light_mode_rounded, '浅色'),
      (ThemeMode.dark, Icons.dark_mode_rounded, '深色'),
    ];
    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (final item in items)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(item.$1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value == item.$1
                        ? theme.colorScheme.primary.withValues(alpha: 0.2)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        item.$2,
                        size: 15,
                        color: value == item.$1
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          item.$3,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: value == item.$1
                                ? FontWeight.w800
                                : FontWeight.w500,
                            color: value == item.$1
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface.withValues(
                                    alpha: 0.6,
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AccentDot extends StatelessWidget {
  const _AccentDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.transparent,
            width: 3,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.45),
                    blurRadius: 14,
                  ),
                ]
              : null,
        ),
        child: selected
            ? const Icon(Icons.check_rounded, color: Colors.white, size: 18)
            : null,
      ),
    );
  }
}


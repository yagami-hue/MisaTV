import 'package:flutter/material.dart';

import '../../app.dart';
import '../../services/drive/drive_line_hint.dart';
import 'drive_cookie_dialog.dart';
import 'drive_web_login_dialog.dart';
import 'uc_tv_login_dialog.dart';

/// 线路要用的网盘没登录时，直接把扫码窗口摆出来
/// （winbox 的经验：缺凭据不要只丢一句「请去配置中心」，用户找不到入口）。
///
/// 返回 true 表示此刻已具备该线路需要的凭据，可以继续播放。
Future<bool> promptDriveLogin(
  BuildContext context,
  DriveLineHint hint, {
  String message = '',
}) async {
  // 可选增强（哔哩）：没登录也能播低画质，绝不能弹窗拦住播放。
  if (hint.optional) return true;
  if (!hint.supported) {
    if (context.mounted) {
      await _showUnsupported(context, hint, message);
    }
    return false;
  }

  final app = AppScope.of(context);
  if (!app.hasDriveAccount(hint.provider)) {
    if (!hint.webLogin) {
      // 115 这类没有网页扫码的网盘：直接给手动 Cookie 输入框。
      if (context.mounted) await _showManualCookieHint(context, hint, message);
      return false;
    }
    final ok = await showDriveLoginDialog(context, hint.provider);
    if (ok != true || !context.mounted) return false;
  }

  if (hint.needsToken) {
    final token = (app.driveAccounts[hint.provider]?.extra['uctvToken'] ?? '').trim();
    if (token.isEmpty) {
      final ok = await showUcTvLoginDialog(context);
      return ok == true;
    }
  }
  return true;
}

/// 只能手动粘贴 Cookie 的网盘：给出入口，而不是一句「请去配置中心」。
Future<void> _showManualCookieHint(
  BuildContext context,
  DriveLineHint hint,
  String message,
) async {
  final open = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('${hint.name}还没有登录'),
      content: Text(
        [
          if (message.isNotEmpty) message,
          '本机不内置 ${hint.name} 的网页扫码登录。'
              '请在浏览器登录后复制 Cookie，粘贴到这里保存。',
        ].join('\n\n'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('粘贴 Cookie'),
        ),
      ],
    ),
  );
  if (open != true || !context.mounted) return;
  await showDriveCookieDialog(context, hint.provider);
}

Future<void> _showUnsupported(
  BuildContext context,
  DriveLineHint hint,
  String message,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('${hint.name}线路暂不支持扫码'),
      content: Text(
        [
          if (message.isNotEmpty) message,
          '本机已内置夸克 / UC / 百度 / 115 / 哔哩 / 迅雷 / 光鸭的登录与凭据配置；这条线路暂不支持，请换其他可用线路再试。',
        ].join('\n\n'),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

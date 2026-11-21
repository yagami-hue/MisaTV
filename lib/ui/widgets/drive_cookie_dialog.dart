import 'package:flutter/material.dart';

import '../../app.dart';
import '../../core/logging/app_log.dart';
import '../../services/drive/baidu_session.dart';
import '../../services/drive/bili_session.dart';
import '../../services/drive/drive_cookie_input.dart';
import '../../services/drive/drive_login_types.dart';
import '../../services/drive/pan115_session.dart';
import '../../services/drive/quark_session.dart';
import '../../services/drive/uc_session.dart';

/// 手动粘贴网盘 Cookie 的输入框；保存成功后返回 true。
Future<bool?> showDriveCookieDialog(
  BuildContext context,
  String provider,
) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _DriveCookieDialog(provider: provider),
  );
}

class _DriveCookieDialog extends StatefulWidget {
  const _DriveCookieDialog({required this.provider});
  final String provider;

  @override
  State<_DriveCookieDialog> createState() => _DriveCookieDialogState();
}

class _DriveCookieDialogState extends State<_DriveCookieDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _saving = false;
  String _error = '';

  String get _provider => widget.provider;
  String get _name => driveProviderNames[_provider] ?? _provider;
  String get _domain => driveCookieDomains[_provider] ?? '网盘官网';
  String get _authFields =>
      (driveAuthCookieNames[_provider] ?? const []).join(' / ');

  /// 这个 Cookie 是不是「可选增强」（哔哩）：没登录也能播低画质。
  bool get _optional => _provider == 'bili';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final app = AppScope.of(context);
    if (isTokenDriveProvider(_provider)) {
      final normalized = normalizeDriveTokenInput(_controller.text);
      if (normalized.isEmpty) {
        setState(() => _error = '请输入 Token');
        return;
      }
      setState(() {
        _saving = true;
        _error = '';
      });
      try {
        await app.saveDriveAccount(_provider, normalized);
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = '保存失败: $e';
        });
      }
      return;
    }
    final cookie = normalizeDriveCookieInput(_controller.text);
    if (cookie.isEmpty) {
      setState(() => _error = '请粘贴 Cookie，格式形如 a=b; c=d');
      return;
    }
    if (!driveCookieIsComplete(_provider, cookie)) {
      setState(() => _error = driveCookieMissingHint(_provider));
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      final result = switch (_provider) {
        'quark' => await refreshQuarkSession(cookie),
        'uc' => await refreshUcSession(cookie),
        'baidu' => await refreshBaiduSession(cookie),
        '115' => await refreshPan115Session(cookie),
        'bili' => await refreshBiliSession(cookie),
        _ => await refreshBaiduSession(cookie),
      };
      if (!mounted) return;
      if (result.valid == false) {
        // 哔哩的 Cookie 只是画质增强：登录态过期也值得保存，让用户自己决定。
        if (_provider != 'bili') {
          setState(() {
            _saving = false;
            _error = 'Cookie 未通过登录校验（可能是访客态或已过期），请重新复制';
          });
          return;
        }
        AppLog.w('drive', '哔哩 Cookie 未通过登录校验，按用户输入原样保存');
      }
      if (result.valid == null) {
        AppLog.w('drive', '手动 Cookie 无法联网校验 provider=$_provider，按原样保存');
      }
      // 校验响应可能补发了新的 __puus，优先保存刷新后的 Cookie。
      final finalCookie = result.cookie.trim().isEmpty
          ? cookie
          : result.cookie.trim();
      await app.saveDriveAccount(_provider, finalCookie);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.60),
      height: 1.6,
    );
    return AlertDialog(
      title: Text(isTokenDriveProvider(_provider) ? '手动输入 Token · $_name' : '手动输入 Cookie · $_name'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '在浏览器登录 $_domain 后，打开开发者工具（F12）→ 应用 / 存储 → '
                'Cookies，复制该域名下的全部 Cookie；也可以从「网络」请求头里'
                '复制 Cookie 一段。粘贴时支持 a=b; c=d、每行一个 a=b 或带 Cookie: 前缀。',
                style: hint,
              ),
              const SizedBox(height: 8),
              Text(
                _optional
                    ? '建议包含登录态字段：$_authFields（没有也能播 360P / 480P，'
                        '配上后才能拿高清与大会员画质）；'
                        'Cookie 等同于账号密码，只会保存在本机。'
                    : _authFields.isEmpty
                    ? 'Cookie 等同于账号密码，只会保存在本机。'
                    : '必须包含登录态字段：$_authFields；'
                        'Cookie 等同于账号密码，只会保存在本机。',
                style: hint,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 5,
                maxLines: 10,
                enabled: !_saving,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.5,
                ),
                decoration: InputDecoration(
                  hintText: _provider == '115'
                      ? '例如：UID=xxxx; CID=yyyy; SEID=zzzz; ...'
                      : _provider == 'bili'
                      ? '例如：SESSDATA=xxxx; bili_jct=yyyy; ...'
                      : '例如：__puus=xxxx; __pus=yyyy; ...',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  errorText: _error.isEmpty ? null : _error,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _optional
                          ? '保存前会联网校验登录态；校验失败仍会保存（画质增强不阻断播放）。'
                          : '保存前会联网校验登录态；校验通过后 Cookie 会同步给订阅里的蜘蛛源。',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.50,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('校验并保存'),
        ),
      ],
    );
  }
}

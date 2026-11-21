import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../app.dart';
import '../../core/logging/app_log.dart';
import '../../services/drive/baidu_session.dart';
import '../../services/drive/quark_session.dart';
import '../../services/drive/bili_session.dart';
import '../../services/drive/pan115_session.dart';
import '../../services/drive/uc_session.dart';
import 'drive_cookie_dialog.dart';
import 'uc_tv_login_dialog.dart';

/// 网盘网页扫码登录：直接加载官方登录页，由网盘页面自己展示二维码
/// （UC 页面内可切换 UC 扫码 / TV 扫码），登录成功后从 WebView2 读取
/// HttpOnly Cookie 并保存到本机。
Future<bool?> showDriveLoginDialog(
  BuildContext context,
  String provider,
) async {
  final config = _webLoginConfigs[provider];
  if (config == null) {
    throw StateError('暂不支持该网盘的网页登录：$provider');
  }
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _DriveWebLoginDialog(config: config),
  );
}

class _WebLoginConfig {
  const _WebLoginConfig({
    required this.provider,
    required this.name,
    required this.loginUrl,
    required this.scope,
    required this.authCookies,
    this.cookieScopes = const [],
    this.readyCookies = const [],
    this.hint = '在下方官方网页中扫码登录，成功后自动读取 Cookie',
    this.width = 700,
    this.isolate = false,
    this.loginSelectors = const [],
    this.hideSelectors = const [],
    this.extraCss = '',
    this.useLocalStorageToken = false,
  });

  final String provider;
  final String name;
  final String loginUrl;
  final String scope;
  final String hint;

  /// 除登录页域名外，还需要一并读取 Cookie 的接口域名（同名以首个为准）。
  final List<String> cookieScopes;

  /// 命中任一（子串）且值足够长即判定已登录。
  final List<String> authCookies;

  /// 会话齐全所需的 Cookie（如百度 STOKEN 晚于 BDUSS 下发）。
  final List<String> readyCookies;

  /// 弹窗首选宽度（逻辑像素），最终会按窗口尺寸收敛。
  final double width;

  /// 官方登录页是营销版式：加载后隐藏营销区并把登录卡片摆到可视区。
  final bool isolate;

  /// 登录卡片的选择器候选（按顺序取第一个命中的）。
  final List<String> loginSelectors;

  /// 明确要隐藏的营销区块选择器。
  final List<String> hideSelectors;

  /// 额外的兜底样式。
  final String extraCss;
  final bool useLocalStorageToken;
}

const _webLoginConfigs = <String, _WebLoginConfig>{
  'quark': _WebLoginConfig(
    provider: 'quark',
    name: '夸克网盘',
    loginUrl: 'https://pan.quark.cn/login',
    scope: 'https://pan.quark.cn',
    authCookies: ['__puus', '__pus', '__puuk', '__pusd'],
    width: 660,
    isolate: true,
    // 首页左侧是营销文案、右侧才是登录盒；下面还有长长的功能介绍。
    loginSelectors: ['.first-screen .right', '.login-component', '#登录账号'],
    hideSelectors: ['.feature-screen'],
  ),
  'uc': _WebLoginConfig(
    provider: 'uc',
    name: 'UC 网盘',
    loginUrl: 'https://drive.uc.cn/',
    scope: 'https://drive.uc.cn',
    cookieScopes: ['https://pc-api.uc.cn', 'https://fast.uc.cn'],
    authCookies: ['PUVID', '__puus', '__pus', 'drive_uc'],
    hint: '页面顶部可切换「微信扫码 / UC扫码」两个二维码；TV 授权见右下角',
    width: 620,
    isolate: true,
    // 登录卡片里自带「微信扫码 / UC扫码 / 短信验证 / 密码登录」四个标签。
    loginSelectors: ['.login-component-modal'],
    hideSelectors: ['.rights-list', '.modal-left', '.header-wrap'],
    extraCss:
        'html,body{overflow-x:hidden!important;background:#fff!important}'
        '.flex-wrap{margin:0!important;padding:14px 0 20px!important;min-height:100vh!important}'
        '.modal-wrap{width:100%!important;justify-content:center!important;align-items:flex-start!important}'
        '.login-component-modal{box-shadow:0 8px 28px rgba(5,12,26,.12)!important}',
  ),
  'baidu': _WebLoginConfig(
    provider: 'baidu',
    name: '百度网盘',
    // 直接进通行证扫码页，省掉在网盘首页手动点「登录」再找二维码。
    loginUrl:
        'https://passport.baidu.com/v2/?login&tpl=netdisk'
        '&u=https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fhome',
    scope: 'https://pan.baidu.com',
    authCookies: ['BDUSS'],
    readyCookies: ['STOKEN'],
    hint: '使用百度 APP 扫码登录；页面会跳转到网盘并自动保存会话',
    width: 600,
    isolate: true,
    loginSelectors: [
      '#TANGRAM__PSP_3__contentWrapper',
      '.login-wrapper',
      '.login-form',
    ],
    hideSelectors: [
      '#TANGRAM__PSP_3__footerWrapper',
      '.pass-footer',
      '.app-download',
    ],
  ),
  '115': _WebLoginConfig(
  provider: '115',
  name: '115网盘',
  loginUrl: 'https://115.com/',
    scope: 'https:/115.com',
    cookieScopes: [
      'https:/115.com',
      'https:/webapi.115.com',
      'https:/proapi.115.com',
    ],
    authCookies: ['UID', 'CID', 'SEID', 'KID'],
    readyCookies: ['UID', 'CID', 'SEID'],
  ),
  'bili': _WebLoginConfig(
    provider: 'bili',
    name: '哔哩哔哩',
    loginUrl: 'https:/passport.bilibili.com/login',
    scope: 'https:/www.bilibili.com',
    cookieScopes: [
      'https:/www.bilibili.com',
      'https:/passport.bilibili.com',
      'https:/api.bilibili.com',
    ],
    authCookies: ['SESSDATA', 'bili_jct', 'DedeUserID'],
    readyCookies: ['SESSDATA', 'DedeUserID'],
  ),
  'thunder': _WebLoginConfig(
    provider: 'thunder',
    name: '迅雷云盘',
    loginUrl: 'https://pan.xunlei.com/',
    scope: 'https://pan.xunlei.com',
    cookieScopes: [
      'https://pan.xunlei.com',
      'https://xunlei.com',
      'https://xluser-ssl.xunlei.com',
    ],
    authCookies: ['sessionid', 'userid', 'loginday'],
    readyCookies: [],
    useLocalStorageToken: true,
  ),
  'guangya': _WebLoginConfig(
    provider: 'guangya',
    name: '光鸭云盘',
    loginUrl: 'https://www.guangyapan.com/home/',
    scope: 'https://www.guangyapan.com',
    cookieScopes: [
      'https://www.guangyapan.com',
      'https://app.guangyapan.com',
      'https://api.guangyapan.com',
    ],
    authCookies: ['token', 'access_token', 'refresh_token'],
    readyCookies: [],
    useLocalStorageToken: true,
  ),
};

const _desktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// 官方登录页都是「营销 + 登录卡片」的版式，卡片常被挤到可视区外。
/// 这里在页面加载后隐藏营销区块，并把登录卡片单独留在视口中央。
String _buildLoginScript(_WebLoginConfig config) {
  final payload = jsonEncode({
    'login': config.loginSelectors,
    'hide': config.hideSelectors,
    'css': config.extraCss,
  });
  return '''
(function () {
  var cfg = $payload;
  var style = document.getElementById('__kniephos_login_style');
  if (!style) {
    style = document.createElement('style');
    style.id = '__kniephos_login_style';
    (document.head || document.documentElement).appendChild(style);
  }
  style.textContent = cfg.css || '';

  (cfg.hide || []).forEach(function (sel) {
    Array.prototype.forEach.call(document.querySelectorAll(sel), function (el) {
      el.style.setProperty('display', 'none', 'important');
    });
  });

  // 与登录/二维码相关或可交互的节点不隐藏，避免误伤验证码与切换 tab。
  function keep(el) {
    var tag = (el.tagName || '').toLowerCase();
    if (tag === 'iframe' || tag === 'canvas' || tag === 'img' || tag === 'input' || tag === 'form') return true;
    var hint = ((el.className || '') + ' ' + (el.id || '')).toString();
    return /login|qrcode|qr|code|account|passport|tab|sms|phone/i.test(hint);
  }

  var target = null;
  var selectors = cfg.login || [];
  for (var i = 0; i < selectors.length && !target; i++) {
    target = document.querySelector(selectors[i]);
  }
  if (!target) return;

  // 自下而上，把每个祖先容器里「通往登录卡片」以外的兄弟节点隐藏掉。
  var chain = [];
  var node = target;
  while (node && node.parentElement && node.parentElement !== document.documentElement) {
    var parent = node.parentElement;
    Array.prototype.forEach.call(parent.children, function (sib) {
      if (sib === node || sib.contains(target) || keep(sib)) return;
      sib.style.setProperty('display', 'none', 'important');
    });
    chain.push(parent);
    node = parent;
  }
  // body 下与登录卡片无关的顶层节点（页脚、装饰层等）一并隐藏。
  if (node && node.parentElement === document.documentElement) {
    Array.prototype.forEach.call(node.parentElement.children, function (sib) {
      if (sib === node || sib.contains(target) || keep(sib)) return;
      sib.style.setProperty('display', 'none', 'important');
    });
  }

  // 此时每一层祖先只剩「登录卡片」这一条可见分支，把它们逐层规整成
  // 整屏居中的弹性容器，卡片就会稳定落在视口正中，不受各家版式影响。
  chain.forEach(function (el, index) {
    el.style.setProperty('display', 'flex', 'important');
    el.style.setProperty('align-items', 'center', 'important');
    el.style.setProperty('justify-content', 'center', 'important');
    el.style.setProperty('width', '100%', 'important');
    el.style.setProperty('max-width', 'none', 'important');
    el.style.setProperty('min-width', '0', 'important');
    el.style.setProperty('margin', '0', 'important');
    el.style.setProperty('padding', '0', 'important');
    el.style.setProperty('transform', 'none', 'important');
    el.style.setProperty('overflow', 'visible', 'important');
    el.style.setProperty('float', 'none', 'important');
    if (index === chain.length - 1) {
      el.style.setProperty('height', 'auto', 'important');
      el.style.setProperty('min-height', '100vh', 'important');
    }
  });
  document.documentElement.style.setProperty('overflow', 'hidden', 'important');
  if (document.body) {
    document.body.style.setProperty('overflow', 'hidden', 'important');
    document.body.style.setProperty('background', '#fff', 'important');
  }

  window.scrollTo(0, 0);
  try {
    target.scrollIntoView({ block: 'center', inline: 'center' });
  } catch (e) {}
})();
''';
}

class _DriveWebLoginDialog extends StatefulWidget {
  const _DriveWebLoginDialog({required this.config});
  final _WebLoginConfig config;

  @override
  State<_DriveWebLoginDialog> createState() => _DriveWebLoginDialogState();
}

class _DriveWebLoginDialogState extends State<_DriveWebLoginDialog> {
  InAppWebViewController? _controller;
  Timer? _timer;
  Timer? _timeoutTimer;
  bool _polling = false;
  bool _finished = false;
  bool _expired = false;
  bool _storageCleared = false;
  int _loginSeenAt = 0;
  int _lastValidateAt = 0;
  String _lastValidatedCookie = '';
  bool? _lastValidatedOk;
  String _status = '正在打开网页…';
  String? _guangyaDeviceCode;
  String? _guangyaAuthUrl;
  String? _guangyaUserCode;
  bool _guangyaAuthLoading = false;
  String? _guangyaError;
    String? _error;

  _WebLoginConfig get _config => widget.config;

  @override
  void initState() {
    super.initState();
    if (_config.provider == 'guangya') {
      _startGuangyaDeviceAuth();
    }
    _bootstrap();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timeoutTimer?.cancel();
    super.dispose();
  }
  Future<void> _startGuangyaDeviceAuth() async {
    if (_guangyaAuthLoading) return;
    if (mounted) { setState(() { _guangyaAuthLoading = true; _guangyaError = null; }); }
    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.https('account.guangyapan.com', '/v1/auth/device/code'),
      );
      req.headers.set('content-type', 'application/json');
      req.headers.set('referer', _config.scope);
      req.headers.set('user-agent', _desktopUserAgent);
      req.write(
        jsonEncode({'scope': 'user', 'client_id': 'aMe-8VSlkrbQXpUR'}),
      );
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (!mounted || _finished) return;
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final decoded = jsonDecode(body);
        if (decoded is Map) {
          final deviceCode = (decoded['device_code'] ?? '').toString().trim();
          final userCode = (decoded['user_code'] ?? '').toString().trim();
          final verifyComplete =
              (decoded['verification_uri_complete'] ?? '').toString().trim();
          final verifyUri =
              (decoded['verification_uri'] ?? '').toString().trim();
          final authUrl =
              verifyComplete.isNotEmpty ? verifyComplete : verifyUri;
          if (deviceCode.isNotEmpty && authUrl.isNotEmpty) {
            setState(() {
              _guangyaDeviceCode = deviceCode;
              _guangyaUserCode = userCode.isNotEmpty ? userCode : null;
              _guangyaAuthUrl = authUrl;
            _guangyaAuthLoading = false;
            if (userCode.isNotEmpty) {
              _status = '请完成光鸭官方授权（授权码：$userCode）';
            }
          });
          _timer ??= Timer.periodic(
            const Duration(seconds: 2),
            (_) => _poll(),
          );
        } else if (mounted) {
          setState(() {
            _guangyaError = '光鸭授权响应缺少必要字段（device_code 或 verification_uri）';
            _guangyaAuthLoading = false;
          });
        }
      } else if (mounted) {
        setState(() {
          _guangyaError = '获取光鸭授权码失败：响应格式异常';
          _guangyaAuthLoading = false;
        });
      }
    } else if (mounted) {
      setState(() {
        _guangyaError = '获取光鸭授权码失败（HTTP ${resp.statusCode}）';
        _guangyaAuthLoading = false;
      });
    }
  } catch (e) {
    if (mounted) {
      setState(() {
        _guangyaError = '获取光鸭授权码失败：$e';
        _guangyaAuthLoading = false;
      });
    }
  } finally {
    client.close();
    if (mounted && _guangyaAuthLoading) {
      setState(() => _guangyaAuthLoading = false);
    }
    }
  }


  Future<void> _bootstrap() async {
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _poll());
    _timeoutTimer = Timer(const Duration(minutes: 5), () {
      if (!mounted || _finished) return;
      _timer?.cancel();
      setState(() {
        _expired = true;
        _status = '登录超时，请关闭后重试';
      });
    });
  }

  /// 首屏若带着上次会话，页面会显示「快捷登录」卡片而不是扫码二维码。
  /// 这里清掉本机 WebView2 里的会话再重载一次，确保每次都是扫码登录。
  /// 必须等页面加载完成后再清：CookieManager 需要 WebView 环境就绪。
  Future<void> _resetSession(InAppWebViewController controller) async {
    try {
      await CookieManager.instance().deleteAllCookies().timeout(
        const Duration(seconds: 8),
      );
    } catch (_) {
      // 清不掉时仍继续重载，页面可能自己落到扫码态。
    }
    try {
      await controller.evaluateJavascript(
        source: 'try{localStorage.clear();sessionStorage.clear();}catch(e){}',
      );
      await controller.reload();
    } catch (_) {}
  }

  bool _isLoggedIn(List<Cookie> cookies) {
    if (cookies.isEmpty) return false;
    return cookies.any((cookie) {
      final value = cookie.value?.toString() ?? '';
      if (value.length < 6) return false;
      return _config.authCookies.any(cookie.name.contains);
    });
  }

  bool _isReady(List<Cookie> cookies) {
    if (_config.readyCookies.isEmpty) return true;
    return _config.readyCookies.every(
      (name) => cookies.any(
        (cookie) =>
            cookie.name == name && (cookie.value?.toString() ?? '').length >= 6,
      ),
    );
  }

  String _buildCookie(List<Cookie> cookies) {
    final jar = <String, String>{};
    for (final cookie in cookies) {
      final value = cookie.value?.toString() ?? '';
      if (cookie.name.trim().isEmpty || value.isEmpty) continue;
      jar[cookie.name] = value;
    }
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 登录页域名 + 接口域名一起读；同名 Cookie 以登录页域名的值为准。
  /// UC 的会话 Cookie 可能由 `pc-api.uc.cn` / `fast.uc.cn` 下发，只读
  /// `drive.uc.cn` 会漏掉 `__puus`。
  Future<List<Cookie>> _readCookies() async {
    final jar = <String, Cookie>{};
    for (final url in [_config.scope, ..._config.cookieScopes]) {
      try {
        final cookies = await CookieManager.instance().getCookies(
          url: WebUri(url),
        );
        for (final cookie in cookies) {
          if (cookie.name.trim().isEmpty) continue;
          jar.putIfAbsent(cookie.name, () => cookie);
        }
      } catch (_) {
        // 单个域名读取失败不影响其它域名
      }
    }
    return jar.values.toList();
  }

  Future<void> _poll() async {
    if (_polling || _finished || _expired) return;
    _polling = true;
    try {
      if (_config.provider == 'guangya' &&
          (_guangyaDeviceCode ?? '').isNotEmpty) {
        final client = HttpClient();
        try {
          final req = await client.postUrl(
            Uri.https('account.guangyapan.com', '/v1/auth/token'),
          );
          req.headers.set('content-type', 'application/json');
          req.headers.set('referer', _config.scope);
          req.headers.set('user-agent', _desktopUserAgent);
          req.write(
            jsonEncode({
              'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
              'device_code': _guangyaDeviceCode,
              'client_id': 'aMe-8VSlkrbQXpUR',
            }),
          );
          final resp = await req.close();
          final body = await resp.transform(utf8.decoder).join();
          if (!mounted || _finished) return;
          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            final m = jsonDecode(body);
            if (m is Map) {
              final accessToken = m['access_token'];
              if (accessToken is String && accessToken.isNotEmpty) {
                final tokenJson = jsonEncode({
                  'token_type': (m['token_type'] ?? 'Bearer').toString(),
                  'access_token': accessToken,
                  'refresh_token': (m['refresh_token'] ?? '').toString(),
                  'sub': (m['sub'] ?? '').toString(),
                });
                _finished = true;
                _timer?.cancel();
                _timeoutTimer?.cancel();
                if (!mounted) return;
                final app = AppScope.of(context);
                await app.saveDriveAccount('guangya', tokenJson);
                if (!mounted) return;
                Navigator.of(context).pop(true);
                return;
              }
            }
          }
        } catch (_) {
          // Ignore transient errors and fall through to localStorage scan.
        } finally {
          client.close();
        }
      }
      if (_config.useLocalStorageToken && _controller != null) {
        final lsRaw = await _controller!.evaluateJavascript(
          source: '''
            (function() {
              try {
                var fallback = '';
                for (var i = 0; i < localStorage.length; i++) {
                  var k = localStorage.key(i);
                  if (!k) continue;
                  if (k.indexOf('credentials_') === 0 || k === 'token' || k === 'auth_token') {
                    var raw = localStorage.getItem(k);
                    if (!raw) continue; try { var o = JSON.parse(raw); if (o && typeof o === 'object') { var at = o.access_token || o.accessToken || ''; var rt = o.refresh_token || o.refreshToken || ''; if ((typeof at === 'string' && at.length >= 10) || (typeof rt === 'string' && rt.length >= 10)) { return JSON.stringify({token_type: o.token_type || o.tokenType || 'Bearer', access_token: o.access_token || o.accessToken || '', refresh_token: o.refresh_token || o.refreshToken || ''}); } } } catch (e) { if (!fallback && raw.length >= 20) fallback = raw; }
                  }
                }
                return fallback || null;
              } catch (e) {
                return null;
              }
            })();
          ''',
        );
        if (lsRaw is String && lsRaw.isNotEmpty) {
          final String? token = lsRaw.trim().isEmpty ? null : lsRaw.trim();
          if (token != null && token.isNotEmpty) {
            _finished = true;
            _timer?.cancel();
            _timeoutTimer?.cancel();
            if (!mounted) return;
            final app = AppScope.of(context);
            await app.saveDriveAccount(_config.provider, token);
            if (!mounted) return;
            Navigator.of(context).pop(true);
            return;
          }
        }
      }
      final cookies = await _readCookies();
      if (!_isLoggedIn(cookies)) {
        _loginSeenAt = 0;
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!_isReady(cookies)) {
        if (_loginSeenAt == 0) {
          _loginSeenAt = now;
          if (mounted) setState(() => _status = '已检测到登录，正在等待会话 Cookie 齐全…');
        } else if (now - _loginSeenAt < 20000) {
          return;
        }
      }
      var cookie = _buildCookie(cookies);
      if (cookie.isEmpty) return;
      // 夸克 / UC / 百度登录页一打开就会下发访客 Cookie，只看「有 Cookie」会把
      // 访客态当成登录成功（蜘蛛随后 download 只回 404 / 空数据）。
      // 用 `/member`（百度 `/api/gettemplatevariable`）探测真实登录态。
      if ((_config.provider == 'quark' ||
              _config.provider == 'uc' ||
              _config.provider == 'baidu' ||
            _config.provider == '115' ||
            _config.provider == 'bili') &&
          cookie != _lastValidatedCookie &&
          now - _lastValidateAt >= 3000) {
        _lastValidatedCookie = cookie;
        _lastValidateAt = now;
        final session = switch (_config.provider) {
          'quark' => await refreshQuarkSession(cookie),
          'uc' => await refreshUcSession(cookie),
          '115' => await refreshPan115Session(cookie),
          'bili' => await refreshBiliSession(cookie),
            _ => await refreshBaiduSession(cookie),
        };
        if (!mounted) return;
        _lastValidatedOk = session.valid;
        if (session.valid == true && session.changed) {
          cookie = session.cookie;
          _lastValidatedCookie = cookie;
        }
        AppLog.i(
          'drive',
          '网页登录校验 provider=${_config.provider} '
              'valid=${session.valid} changed=${session.changed}',
        );
        if (session.valid != true) {
          final names = cookies
              .map((c) => c.name)
              .where((name) => name.trim().isNotEmpty)
              .take(40)
              .join(',');
          AppLog.w(
            'drive',
            '登录校验未通过 provider=${_config.provider} cookies=[$names]',
          );
        }
      }
      if (_config.provider == 'quark' ||
          _config.provider == 'uc' ||
          _config.provider == 'baidu' ||
         _config.provider == '115' ||
        _config.provider == 'bili') {
        // Cookie 刚变化但还没到下一次校验时间：继续等，绝不能先保存访客 Cookie。
        if (cookie != _lastValidatedCookie) return;
        if (_lastValidatedOk == false) {
          _loginSeenAt = 0;
          setState(() => _status = '尚未检测到真实登录（当前为访客会话），请继续扫码…');
          return;
        }
        if (_lastValidatedOk != true) {
          _lastValidateAt = 0;
          setState(() => _status = '正在确认登录状态…');
          return;
        }
      }
      _finished = true;
      _timer?.cancel();
      _timeoutTimer?.cancel();
      if (!mounted) return;
      final app = AppScope.of(context);
      await app.saveDriveAccount(_config.provider, cookie);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted && !_finished) {
        setState(() => _status = '读取登录状态失败，重试中…');
      }
    } finally {
      _polling = false;
    }
  }

  void _setStatus(String text) {
    if (mounted) setState(() => _status = text);
  }

  /// 登录卡片多为 JS 异步渲染，加载完成后补几次注入，避免首次注入时节点还不存在。
  void _scheduleIsolation() {
    if (!_config.isolate) return;
    for (final delay in const [0, 900, 2200, 4200]) {
      Timer(Duration(milliseconds: delay), () {
        if (!mounted || _finished) return;
        _controller?.evaluateJavascript(source: _buildLoginScript(_config));
      });
    }
  }

  Future<void> _reload() async {
    setState(() {
      _error = null;
      _expired = false;
      _loginSeenAt = 0;
      _status = '正在刷新网页…';
    });
    try {
      await _controller?.reload();
    } catch (_) {}
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(minutes: 5), () {
      if (!mounted || _finished) return;
      _timer?.cancel();
      setState(() {
        _expired = true;
        _status = '登录超时，请关闭后重试';
      });
    });
  }

  /// 手动粘贴 Cookie：校验通过后直接结束网页登录流程。
  Future<void> _manualCookie() async {
    final ok = await showDriveCookieDialog(context, _config.provider);
    if (!mounted || ok != true) return;
    _finished = true;
    _timer?.cancel();
    _timeoutTimer?.cancel();
    Navigator.of(context).pop(true);
  }

  Widget _buildGuangyaQrBody(BuildContext context) {
    final theme = Theme.of(context);
    if (_guangyaAuthLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              '正在获取光鸭登录二维码...',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }
    if (_guangyaError != null || (_guangyaAuthUrl ?? '').isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 40,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                _guangyaError ?? '未能获取光鸭登录二维码',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _startGuangyaDeviceAuth,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重新获取二维码'),
              ),
            ],
          ),
        ),
      );
    }

    final qrUrl = Uri.https(
      'api.qrserver.com',
      '/v1/create-qr-code/',
      {
        'size': '280x280',
        'margin': '12',
        'data': _guangyaAuthUrl!,
      },
    ).toString();

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Image.network(
                qrUrl,
                width: 220,
                height: 220,
                fit: BoxFit.contain,
              ),
            ),
            if ((_guangyaUserCode ?? '').isNotEmpty) ...[
              const SizedBox(height: 16),
              SelectableText(
                '授权码：$_guangyaUserCode',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              '请使用「光鸭云盘 App」扫码确认登录\n（同一台手机可先截屏，再在光鸭 App 扫一扫 → 相册选择截屏）',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _guangyaAuthUrl!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制光鸭授权链接')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('复制授权链接'),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: _startGuangyaDeviceAuth,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('刷新二维码'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    // 登录卡片本身不宽，弹窗跟着卡片走即可；注入脚本会把营销区裁掉。
    // ★ 手机竖屏时可用宽度常常不到 480（如 393dp 的屏只有 ~361dp），
    //   num.clamp 要求 lower <= upper，写死 clamp(480, size.width*0.94)
    //   会抛 `Invalid argument(s): 480.0`，表现为「未捕获的 Flutter 异常」
    //   且网盘扫码登录弹窗打不开。先把上下限收敛到屏幕可用范围。
    final availableWidth = size.width - 32; // Dialog 的 insetPadding 16 * 2
    final maxWidth = availableWidth > 0 ? availableWidth : 320.0;
    final minWidth = maxWidth < 480.0 ? maxWidth : 480.0;
    final width = _config.width.clamp(minWidth, maxWidth);
    final availableHeight = size.height - 32;
    final maxHeight = availableHeight > 820.0
        ? 820.0
        : (availableHeight > 0 ? availableHeight : 520.0);
    final minHeight = maxHeight < 520.0 ? maxHeight : 520.0;
    final height = (size.height * 0.9).clamp(minHeight, maxHeight);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '登录 ${_config.name}',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                        (_guangyaUserCode ?? '').isNotEmpty
                            ? '请完成光鸭官方授权（授权码：$_guangyaUserCode）'
                            :                           _config.hint,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _config.provider == 'guangya'
                  ? _buildGuangyaQrBody(context)
                  : Stack(
                children: [
                  Positioned.fill(
                    child: InAppWebView(
                      initialUrlRequest: URLRequest(
                        url: WebUri(_guangyaAuthUrl ?? _config.loginUrl),
                      ),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        supportMultipleWindows: false,
                        userAgent: _desktopUserAgent,
                        useWideViewPort: true,
                        loadWithOverviewMode: true,
                        supportZoom: true,
                        builtInZoomControls: true,
                        displayZoomControls: false,
                      ),
                      onWebViewCreated: (controller) =>
                          _controller = controller,
                      // Windows 插件 0.6.0 的权限回调不判空，Dart 返回 null 会闪退。
                      onPermissionRequest: (controller, request) async =>
                          PermissionResponse(action: PermissionResponseAction.DENY),
                      onLoadStart: (controller, url) {
                        _setStatus('正在加载网页…');
                      },
                      onLoadStop: (controller, url) async {
                        // 首次加载完成后清一次旧会话并重载，保证看到扫码页。
                        if (!_storageCleared &&
                            (url?.scheme ?? '').startsWith('http')) {
                          _storageCleared = true;
                          await _resetSession(controller);
                          return;
                        }
                        // 页面可能重定向（如百度跳网盘），每次加载完成都重放裁剪脚本。
                        _scheduleIsolation();
                        if (!_finished) _setStatus('等待扫码…');
                      },
                      onReceivedError: (controller, request, error) {
                        if (request.isForMainFrame ?? false) {
                          setState(() {
                            _error = error.description;
                            _status = '网页加载失败';
                          });
                        }
                      },
                    ),
                  ),
                  if (_error != null)
                    Positioned.fill(
                      child: ColoredBox(
                        color: theme.colorScheme.surface,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.cloud_off_rounded,
                                  size: 40,
                                  color: theme.colorScheme.error,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '网页加载失败',
                                  style: theme.textTheme.titleSmall,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _error!,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodySmall,
                                ),
                                const SizedBox(height: 16),
                                FilledButton.tonal(
                                  onPressed: _reload,
                                  child: const Text('重试'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
              child: Row(
                children: [
                  Icon(
                    _expired
                        ? Icons.error_outline_rounded
                        : Icons.qr_code_2_rounded,
                    size: 18,
                    color: _expired
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _status,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: _expired ? theme.colorScheme.error : null,
                      ),
                    ),
                  ),
                  if (_config.provider == 'uc')
                    TextButton(
                      onPressed: () => showUcTvLoginDialog(context),
                      child: const Text('TV 授权二维码'),
                    ),
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: _manualCookie,
                    child: const Text('手动 Cookie'),
                  ),
                  TextButton(onPressed: _reload, child: const Text('刷新')),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
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

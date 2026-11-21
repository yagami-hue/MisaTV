import 'drive_login_types.dart';

/// 一条线路（flag）或一条错误文案指向的网盘。
///
/// 用来回答三个问题：这条线路要登录哪个网盘？本机能不能直接扫码登录？
/// 没登录时能不能照常播？
class DriveLineHint {
  const DriveLineHint({
    required this.provider,
    required this.name,
    required this.supported,
    this.webLogin = false,
    this.optional = false,
    this.needsToken = false,
  });

  /// 与 `driveAccounts` / `driveProviderNames` 一致的键（quark / uc / baidu / 115 / bili）。
  final String provider;
  final String name;

  /// 本机能保存这条凭据（扫码或手动粘贴 Cookie）。
  final bool supported;

  /// 本机内置了网页扫码登录（夸克 / UC / 百度）；其余只能手动粘贴 Cookie。
  final bool webLogin;

  /// 凭据是可选增强：没有也能播，只是画质 / 可用性受限（哔哩哔哩）。
  ///
  /// 这类线路**不能**弹登录窗、不能阻断播放，否则会把「没登录只能看 480P」
  /// 变成「点了没反应」。
  final bool optional;

  /// 除了 Cookie 还需要额外授权（目前只有 UC 电视端令牌）。
  final bool needsToken;
}

class _HintRule {
  const _HintRule(
    this.provider,
    this.name,
    this.patterns, {
    this.supported = false,
    this.webLogin = false,
    this.optional = false,
  });

  final String provider;
  final String name;
  final List<Pattern> patterns;
  final bool supported;
  final bool webLogin;
  final bool optional;
}

/// 顺序即优先级：先认能扫码的三家，再认只能贴 Cookie 的站点。
final _rules = <_HintRule>[
  _HintRule('quark', driveProviderNames['quark']!, [
    '夸克',
    RegExp('quark', caseSensitive: false),
  ], supported: true, webLogin: true),
  _HintRule('baidu', driveProviderNames['baidu']!, [
    '百度',
    RegExp('baidu', caseSensitive: false),
  ], supported: true, webLogin: true),
  _HintRule('uc', driveProviderNames['uc']!, [
    // 避免把 quark / uhd 之类误判成 UC。
    RegExp(r'(^|[^a-z])uc([^a-z]|$)', caseSensitive: false),
    '优视',
  ], supported: true, webLogin: true),
  // 哔哩要排在「115」之类数字规则之前，避免 B站 线路被别的规则抢走。
  _HintRule('bili', driveProviderNames['bili']!, [
    RegExp(r'^b\s*站', caseSensitive: false),
    RegExp('bilibili', caseSensitive: false),
    RegExp(r'(^|[^a-z])bili([^a-z]|$)', caseSensitive: false),
    '哔哩',
  ], supported: true, optional: true),
  _HintRule('115', driveProviderNames['115']!, [
    RegExp(r'(^|[^0-9])115([^0-9]|$)'),
  ], supported: true),
  _HintRule('aliyun', '阿里云盘', [
    '阿里',
    RegExp('aliyun', caseSensitive: false),
    RegExp(r'(^|[^a-z])ali([^a-z]|$)', caseSensitive: false),
  ]),
  _HintRule('pan123', '123 云盘', [
    RegExp(r'(^|[^0-9])123([^0-9]|$)'),
    '123盘',
  ]),
  _HintRule('pan139', '移动云盘', [
    RegExp(r'(^|[^0-9])139([^0-9]|$)'),
    '移动云',
  ]),
  _HintRule('pan189', '天翼云盘', [
    RegExp(r'(^|[^0-9])189([^0-9]|$)'),
    '天翼',
  ]),
  _HintRule('guangya', '光鸭云盘', [
    '光雅',
    '光鸭',
    RegExp('guangya', caseSensitive: false),
  ], supported: true, webLogin: true),
  _HintRule('thunder', '迅雷云盘', [
    '迅雷',
    RegExp('thunder', caseSensitive: false),
    RegExp('xunlei', caseSensitive: false),
  ], supported: true, webLogin: true),
  _HintRule('pikpak', 'PikPak', [
    RegExp('pikpak', caseSensitive: false),
  ]),
  _HintRule('magnet', '磁力链接', [
    '磁力',
    RegExp('magnet', caseSensitive: false),
  ]),
];

final _ucTokenPattern = RegExp(
  r'token|高会|电视端|TV\s*授权',
  caseSensitive: false,
);

DriveLineHint? _matchRule(String text) {
  final value = text.trim();
  if (value.isEmpty) return null;
  for (final rule in _rules) {
    for (final pattern in rule.patterns) {
      if (pattern.allMatches(value).isNotEmpty) {
        return DriveLineHint(
          provider: rule.provider,
          name: rule.name,
          supported: rule.supported,
          webLogin: rule.webLogin,
          optional: rule.optional,
        );
      }
    }
  }
  return null;
}

/// 线路名（如「夸克原画」「百度」「UC」）→ 需要的网盘。
DriveLineHint? driveHintFromFlag(String flag) => _matchRule(flag);

/// 蜘蛛的失败文案（如「还没有配置百度网盘 Cookie」）→ 需要补登录的网盘。
DriveLineHint? driveHintFromMessage(String message) {
  final hint = _matchRule(message);
  if (hint == null) return null;
  if (!hint.supported || hint.provider != 'uc') return hint;
  if (!_ucTokenPattern.hasMatch(message)) return hint;
  return DriveLineHint(
    provider: hint.provider,
    name: hint.name,
    supported: true,
    webLogin: hint.webLogin,
    needsToken: true,
  );
}

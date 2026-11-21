/// 网盘登录的公共常量（不依赖 dart:io，Web 版也可引用）。
///
/// 键名同时是蜘蛛 `ext` 里的注入键（对齐 TVBox 生态：provider 名即 ext 键名）。
const driveProviderNames = <String, String>{
  'quark': '夸克网盘',
  'uc': 'UC 网盘',
  'baidu': '百度网盘',
  '115': '115 网盘',
  'bili': '哔哩哔哩',
  'thunder': '迅雷云盘',
  'guangya': '光鸭云盘',
};

/// 内置了网页扫码登录的网盘（其余只能手动粘贴 Cookie）。
///
/// 哔哩哔哩与 115 的登录页要么需要短信验证、要么与站点风控强绑定，桌面端只提供
/// 「手动粘贴 Cookie」；哔哩的 Cookie 是**可选增强**：没有它也能播 360P / 480P，
/// 配上之后才能拿到更高画质。
const driveWebLoginProviders = <String>{'quark', 'uc', 'baidu', '115', 'bili', 'thunder', 'guangya'};

/// 该网盘是否能在应用内扫码登录。
bool driveSupportsWebLogin(String provider) =>
    driveWebLoginProviders.contains(provider);

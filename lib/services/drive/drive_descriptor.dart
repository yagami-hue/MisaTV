// 网盘分享描述符解析（盘搜 / 免转存家族）。
//
// 集地址常见两种形态：
//   · `<provider>@<base64(JSON)>` —— 例如 `baidu@eyJzaGFyZUlkIjo…`；
//   · 嵌套信封 `base64(JSON{a:<商>, b:<内层 JSON 字符串>, c, d})`。
// 本文件只负责解码、短键归一与字段取值，不含任何网络请求。
import 'dart:convert';

/// 解析后的描述符。
class DriveDescriptor {
  const DriveDescriptor({required this.provider, required this.data});

  /// 归一后的网盘商（quark / uc / baidu / 115 / ali / alipan / thunder）。
  final String provider;

  /// 描述对象；嵌套信封已把内层短键补成既有长键。
  final Map<String, dynamic> data;
}

/// 原生解链结果（百度 / UC 共用）。
class NativeDriveLink {
  const NativeDriveLink({
    required this.ok,
    this.url = '',
    this.headers = const <String, String>{},
    this.reason = '',
  });

  /// 是否取到可播放直链。
  final bool ok;

  /// 直链地址（ok=false 时为空串）。
  final String url;

  /// 播放时必须携带的请求头（UA / Referer / Cookie）。
  final Map<String, String> headers;

  /// ok=false 时的简短中文原因。
  final String reason;

  factory NativeDriveLink.failed(String reason) =>
      NativeDriveLink(ok: false, reason: reason);
}

/// 描述符前缀允许的网盘商；base64 允许 `+ / - _ =` 四种字符。
final _descriptorKeyRe =
    RegExp(r'^(quark|uc|baidu|115|ali|alipan)@([A-Za-z0-9_+/=-]+)$');

/// 嵌套信封外层 `a` 允许的网盘商（含暂不支持的 thunder，供上层给出明确提示）。
const _nestedProviders = <String>{
  'quark',
  'uc',
  'baidu',
  '115',
  'ali',
  'alipan',
  'thunder',
};

/// 嵌套信封内层短键 → 既有长键（仅对已实证的商做映射，其余保留原样）。
const _nestedShortKeyMap = <String, Map<String, String>>{
  'quark': <String, String>{
    'a': 'fileId',
    'b': 'fileToken',
    'c': 'shareId',
    'd': 'stoken',
    'e': 'name',
  },
  'uc': <String, String>{
    'a': 'fileId',
    'b': 'fileToken',
    'c': 'shareId',
    'd': 'stoken',
    'e': 'name',
  },
  // wex 系壳（9280 那套）的百度分享用的是另一套短键，实测样本：
  //   {"a":"271762599896626"(uk),"b":"01 4K.mkv"(name),"c":"3576627086"(shareId),
  //    "d":"10420030909"(fs_id),"e":"vlOn10c2…"(seKey),"f":"wogg"(壳名),
  //    "g":"STOKEN=…; BDUSS=…; BDCLND=…"(预授权 Cookie)}
  // 补齐映射后 `extractBaiduSharedFile` 能直接命中 → 走 `_directFile` 免转存签名取链，
  // 跳过 init→verify→分享页 那三次 HTTPS 往返（实测这段占了取链耗时的绝大部分）。
  'baidu': <String, String>{
    'a': 'uk',
    'b': 'name',
    'c': 'shareId',
    'd': 'fs_id',
    'e': 'seKey',
    'g': 'cookie',
  },
};

/// 纯 base64（兼容标准 `+/` 与 URL-safe `-_`，允许 `=` 填充）。
final _bareBase64Re = RegExp(r'^[A-Za-z0-9_+/=-]+$');

/// 解码 `base64(JSON)`；失败返回 null（绝不抛）。
Map<String, dynamic>? _decodeBase64Json(String source) {
  var b64 = source.replaceAll('-', '+').replaceAll('_', '/');
  final mod = b64.length % 4;
  if (mod == 2) {
    b64 += '==';
  } else if (mod == 3) {
    b64 += '=';
  }
  final bytes = base64.decode(b64);
  return _asStringMap(jsonDecode(utf8.decode(bytes, allowMalformed: true)));
}

Map<String, dynamic>? _asStringMap(Object? value) {
  if (value is! Map) return null;
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) out[key] = entry.value;
  }
  return out;
}

/// 解码嵌套信封 `base64(JSON{a:<商>, b:<内层 JSON 字符串>})`；非该形态返回 null。
DriveDescriptor? _decodeNestedEnvelope(String raw) {
  final s = raw.trim();
  if (s.isEmpty || s.contains('@') || !_bareBase64Re.hasMatch(s)) {
    return null;
  }
  try {
    final outer = _decodeBase64Json(s);
    if (outer == null) return null;
    final providerRaw = outer['a'];
    if (providerRaw is! String) return null;
    final provider = providerRaw.trim().toLowerCase();
    if (provider.isEmpty || !_nestedProviders.contains(provider)) {
      return null;
    }
    final innerRaw = outer['b'];
    if (innerRaw is! String || innerRaw.trim().isEmpty) return null;
    final decoded = jsonDecode(innerRaw);
    final inner = _asStringMap(decoded);
    if (inner == null) return null;

    final key = provider == 'alipan' ? 'ali' : provider;
    // 保留短键（不影响长键检索，便于排障）。
    final data = <String, dynamic>{...inner};
    final map = _nestedShortKeyMap[key];
    if (map != null) {
      for (final entry in map.entries) {
        if (!data.containsKey(entry.value) && inner.containsKey(entry.key)) {
          data[entry.value] = inner[entry.key];
        }
      }
    }
    final displayName = outer['d'];
    if (!data.containsKey('name') &&
        displayName is String &&
        displayName.trim().isNotEmpty) {
      data['name'] = displayName.trim();
    }
    return DriveDescriptor(provider: key, data: data);
  } catch (_) {
    return null;
  }
}

/// 解析集地址里的网盘描述符；非描述符返回 null（解码 / JSON 失败一律不抛）。
DriveDescriptor? parseDriveDescriptor(String id) {
  final s = id.trim();
  final m = _descriptorKeyRe.firstMatch(s);
  if (m != null) {
    try {
      final decoded = _decodeBase64Json(m.group(2)!);
      if (decoded == null) return null;
      final rawKey = m.group(1)!;
      return DriveDescriptor(
        provider: rawKey == 'alipan' ? 'ali' : rawKey,
        data: decoded,
      );
    } catch (_) {
      return null;
    }
  }
  return _decodeNestedEnvelope(s);
}

/// 该 id 是否为嵌套信封且桌面端暂不支持（返回 provider 键，无则空串）。
String unsupportedNestedProvider(String id) {
  final d = _decodeNestedEnvelope(id.trim());
  if (d == null) return '';
  return RegExp(r'^(quark|uc|baidu)$').hasMatch(d.provider) ? '' : d.provider;
}

/// 从描述对象里取第一个非空字段（多字段名兼容：fileId / fid / fs_id …）。
String descriptorField(Map<String, dynamic> data, List<String> names) {
  for (final name in names) {
    final value = data[name];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is num) return value.toString();
  }
  return '';
}

/// 文本的「匹配候选」= 原文 + 逐层 percent-decode（≤2 轮）。
///
/// jar 常把分享链接塞进 `do=pan` 代理地址的 query 参数值并 percent-encode，
/// 裸正则匹配不到；非法百分号序列时停止解链，原文仍作为唯一候选。
List<String> shareTextCandidates(String text) {
  final out = <String>[];
  var current = text;
  for (var i = 0; i < 3 && current.isNotEmpty; i++) {
    out.add(current);
    String next;
    try {
      next = Uri.decodeComponent(current);
    } catch (_) {
      break;
    }
    if (next == current) break;
    current = next;
  }
  return out;
}

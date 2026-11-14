// 百度网盘「免转存」直链解析（纯 Dart，供桌面端原生通道使用）。
//
// 只做直链：绝不转存到用户网盘、不建目录、不删除、不轮询任务。
//
// 取链契约（复刻 winbox 的真机结论）：
//   GET  /share/init?surl=<短 id 去掉首位 1>                 → HTML（含 t）
//   POST /share/verify?surl=&t=&…                           → errno 0 + Set-Cookie: BDCLND
//   GET  /s/<短 id>（带 BDCLND）                             → HTML：shareid / share_uk / 根条目
//   GET  /userx/v1/info/get                                 → 当前账号 uid（只读签名上下文）
//   GET  /share/list?shareid&uk&fid&sekey&time&rand          → 分享文件 dlink
//
// 两个协议坑（勿回退）：
//   ① `share/verify` 的 `surl` 必须去掉分享 id 首位那个 `1`；
//   ② `t` 必须从 `/share/init` 页面取，自造值恒定 errno 105。
//
// 直链防盗链按 UA 判定：浏览器 UA 拉流恒定 403，播放必须带网盘客户端 UA。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'drive_descriptor.dart';
import 'quark_session_io.dart' show mergeSetCookies, sanitizeCookie;

const _ref = 'https://pan.baidu.com/';
const _refDisk = 'https://pan.baidu.com/disk/main';

/// 调 API 用浏览器 UA（网页登录抓到的就是这套会话）。
const _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.6478.61 Safari/537.36';

/// 拉 dlink 只能用网盘客户端 UA：浏览器 UA 恒定 403 31326。
const _dlUa = 'netdisk;P2SP;3.0.0;windows;;;';

/// 分享签名接口使用的客户端 UA / 设备常量。
const _shareUa =
    'netdisk;12.24.6;WinBox;android-android;12;JSbridge4.4.0;jointBridge;1.1.0';
const _shareDevice = '73CED981D0F186D12BC18CAE1684FFD5|VSRCQTF6W';
const _shareUserApi =
    'https://mbd.baidu.com/userx/v1/info/get'
    '?appname=baiduboxapp&fields=%5B%22bg_image%22,%22member%22,%22uid%22,'
    '%22avatar%22,%22avatar_member%22%5D&lang=zh-cn';

final _digitsRe = RegExp(r'^\d+$');
final _digits6Re = RegExp(r'^\d{6,}$');
final _httpUrlRe = RegExp(r'^https?://', caseSensitive: false);
final _videoRe = RegExp(
  r'\.(mkv|mp4|ts|avi|rmvb|flv|mov|wmv|m4v|webm)$',
  caseSensitive: false,
);
final _panQueryRe = RegExp(r'(?:do=pan|site=baidu)', caseSensitive: false);
final _ownFsidQueryRe = RegExp(
  r'''[?&](?:fileId|file_id|fs_id|fids)=([^&#"'\s]+)''',
  caseSensitive: false,
);
final _ownFsidJsonRe = RegExp(r'''"fs_id"\s*:\s*"?(\d+)"?''');
final _ownFsidFileIdRe = RegExp(r'''"fileId"\s*:\s*"?(\d+)"?''');
final _shareItemNameRe = RegExp(r'"server_filename"\s*:\s*"((?:[^"\\]|\\.)*)"');
final _shareItemFsidRe = RegExp(r'"fs_id"\s*:\s*(\d+)');
final _shareItemIsdirRe = RegExp(r'"isdir"\s*:\s*(\d+)');
final _shareItemPathRe = RegExp(r'"path"\s*:\s*"((?:[^"\\]|\\.)*)"');
final _shareIdUrlRe = RegExp(
  r'(?:pan|yun)\.baidu\.com/s/([0-9a-zA-Z_-]+)',
  caseSensitive: false,
);
final _shareInitRe = RegExp(
  r'''/share/init\?[^"'\s]*?surl=([0-9a-zA-Z_-]+)''',
  caseSensitive: false,
);
final _shareJsonSurlRe = RegExp(
  r'"surl"\s*:\s*"([0-9a-zA-Z_-]{8,})"',
  caseSensitive: false,
);
final _pwdRe = RegExp(
  r'[?&](?:pwd|password|passcode)=([0-9a-zA-Z]{4})',
  caseSensitive: false,
);
final _shareTRe = RegExp(r'"t"\s*:\s*(\d{13})');
final _shareTAltRe = RegExp(r'\bt\s*[:=]\s*"?(\d{13})');
final _shareIdRe = RegExp(r'"shareid"\s*:\s*(\d+)');
final _shareUkRe = RegExp(r'"share_uk"\s*:\s*"?(\d+)');
final _shareUkAltRe = RegExp(r'"uk"\s*:\s*"?(\d+)');

/// 分享内的一个条目（来自分享页 HTML）。
class BaiduShareItem {
  const BaiduShareItem({
    required this.name,
    required this.fsid,
    required this.isdir,
    required this.path,
  });

  final String name;
  final String fsid;
  final bool isdir;
  final String path;
}

/// 分享者的文件 ID 与已验证的分享会话；fsid 不能当作本人盘 ID 使用。
class BaiduSharedFile {
  const BaiduSharedFile({
    required this.shareId,
    required this.uk,
    required this.sekey,
    required this.fsid,
    this.name = '',
  });

  final String shareId;
  final String uk;
  final String sekey;
  final String fsid;
  final String name;
}

/// 分享链接解析结果。
class BaiduShareRef {
  const BaiduShareRef({required this.short, this.pwd = ''});

  final String short;
  final String pwd;
}

class _BaiduSession {
  _BaiduSession(this.cookie);

  String cookie;
}

class _HttpResult {
  const _HttpResult({
    required this.status,
    required this.text,
    required this.json,
    required this.setCookies,
  });

  final int status;
  final String text;
  final Map<String, dynamic> json;
  final List<String> setCookies;
}

class _RootPick {
  const _RootPick(this.item, this.reason);

  final BaiduShareItem? item;
  final String reason;
}

class _NamePick {
  const _NamePick(this.item, this.ambiguous);

  final BaiduShareItem? item;
  final bool ambiguous;
}

/// 全局串行锁：与 winbox 的 transferChain 同义，避免并发解链污染会话。
Future<void> _baiduChain = Future<void>.value();

Future<NativeDriveLink> _enqueueBaidu(Future<NativeDriveLink> Function() task) {
  final run = _baiduChain.then((_) async {
    try {
      return await task();
    } catch (e) {
      return NativeDriveLink.failed('百度请求失败（${_briefError(e)}）');
    }
  });
  _baiduChain = run.then<void>((_) {}, onError: (Object e, StackTrace s) {});
  return run;
}

/// 该文本是否是百度分享（分享链接 / 描述符 / `do=pan` 代理地址）。
bool looksLikeBaiduShare(String text) {
  final desc = parseDriveDescriptor(text);
  if (desc != null && desc.provider == 'baidu') return true;
  if (extractBaiduSharedFile(text) != null) return true;
  // 播放描述 JSON 的提取码 / BDCLND 在 jar 详情阶段的内存状态里，这里拿不到：
  // 只有 `"surl"` 而没有完整凭据时，原生解链必定失败并白等数秒，交回蜘蛛自己解。
  final trimmed = text.trimLeft();
  if (trimmed.startsWith('{') && _shareJsonSurlRe.hasMatch(text)) return false;
  if (extractBaiduShare(text) != null) return true;
  if (!_isBaiduPanQuery(text)) return false;
  return _ownFsidOf(text).isNotEmpty;
}

/// 解析 `baidu@<base64(JSON)>` 描述符或播放描述 JSON 里的分享凭据。
BaiduSharedFile? extractBaiduSharedFile(String text) {
  final desc = parseDriveDescriptor(text);
  if (desc != null) {
    if (desc.provider != 'baidu') return null;
    final shareId = descriptorField(desc.data, <String>['shareId', 'share_id']);
    final uk = descriptorField(desc.data, <String>['uk']);
    final fsid = descriptorField(desc.data, <String>[
      'fileId',
      'fs_id',
      'fsid',
    ]);
    final sekey = descriptorField(desc.data, <String>[
      'randsk',
      'seKey',
      'sekey',
      'bdclnd',
    ]);
    if (_digitsRe.hasMatch(shareId) &&
        _digitsRe.hasMatch(uk) &&
        _digitsRe.hasMatch(fsid) &&
        sekey.isNotEmpty) {
      var name = extractBaiduInnerName(text);
      if (name.isEmpty) {
        name = descriptorField(desc.data, <String>[
          'name',
          'fileName',
          'file_name',
        ]);
      }
      return BaiduSharedFile(
        shareId: shareId,
        uk: uk,
        fsid: fsid,
        sekey: sekey,
        name: name,
      );
    }
    return null;
  }

  try {
    final decoded = jsonDecode(text);
    final d = _asMap(decoded);
    if (d == null) return null;
    final shareId = _str(d['share_id']);
    final uk = _str(d['uk']);
    final fsid = _str(d['fs_id']);
    final sekey = _str(d['seKey']).isNotEmpty
        ? _str(d['seKey'])
        : _str(d['sekey']);
    if (sekey.isEmpty ||
        !_digitsRe.hasMatch(shareId) ||
        !_digitsRe.hasMatch(uk) ||
        !_digitsRe.hasMatch(fsid)) {
      return null;
    }
    final isdir = d['isdir'];
    final isFile =
        isdir == null ||
        isdir == false ||
        isdir == 0 ||
        (isdir is String && isdir.trim() == '0');
    if (!isFile) return null;
    return BaiduSharedFile(
      shareId: shareId,
      uk: uk,
      fsid: fsid,
      sekey: sekey,
      name: extractBaiduInnerName(text),
    );
  } catch (_) {
    return null;
  }
}

/// 从文本（分享链接 / `do=pan` 代理地址 / episode id）解析分享 id 与提取码。
BaiduShareRef? extractBaiduShare(String text) {
  for (final candidate in shareTextCandidates(text)) {
    final short = _baiduShareIdOf(candidate);
    if (short.isEmpty) continue;
    final pwd = _pwdRe.firstMatch(candidate)?.group(1) ?? '';
    return BaiduShareRef(short: short, pwd: pwd);
  }
  return null;
}

/// 从播放描述 JSON 里取内层文件线索（`path` 末段优先，其次 `name`）。
String extractBaiduInnerName(String text) {
  final pathMatch = RegExp(r'"path"\s*:\s*"((?:[^"\\]|\\.)*)"')
      .firstMatch(text);
  if (pathMatch != null) {
    var path = pathMatch.group(1)!;
    try {
      path = Uri.decodeComponent(path);
    } catch (_) {
      // 非法百分号序列：原样使用。
    }
    final parts = path.split('/').where((x) => x.isNotEmpty).toList();
    if (parts.isNotEmpty) return _unescapeJson(parts.last);
  }
  final nameMatch = RegExp(
    r'"(?:name|server_filename)"\s*:\s*"((?:[^"\\]|\\.)*)"',
  ).firstMatch(text);
  return nameMatch != null ? _unescapeJson(nameMatch.group(1)!) : '';
}

/// 百度接口 errno → 人话。
String baiduErrnoText(int errno) {
  if (errno == -6) return '百度登录态失效，请到「配置→网盘绑定」重新扫码绑定百度';
  if (errno == -9) return '分享需要提取码（该线路未携带提取码）';
  if (errno == -12 || errno == 200025) return '提取码错误';
  if (errno == 105) return '分享链接不正确';
  if (errno == 116) return '分享不存在或已失效';
  if (errno == 113) return '分享已过期';
  if (errno == 118) return '没有下载权限';
  if (errno == -20) return '需要验证码（账号被风控，请在浏览器完成验证后重试）';
  if (errno == -65) return '触发频率限制，稍后重试';
  if (errno == -1 || errno == -4) return '内容违规，无法获取';
  return '未知错误';
}

/// 分享短链 id → `share/verify` 要用的 `surl`（百度分享 id 固定以 `1` 开头）。
String verifySurl(String short) =>
    short.startsWith('1') ? short.substring(1) : short;

/// fty 的只读分享签名；设备 / 版本常量必须与请求参数一致，不是 MD5。
String baiduShareRand(String bduss, String uid, String time) {
  String sha1Hex(String value) => sha1.convert(utf8.encode(value)).toString();
  return sha1Hex(
    '${sha1Hex(bduss)}'
    '$uid'
    'ebrcUYiuxaZv2XGu7KIYKxUrqfnOfpDF'
    '$time'
    '$_shareDevice'
    '11.30.2ae5821440fab5e1a61a025f014bd8972',
  );
}

/// 从分享页 HTML 解析文件项（每个 `server_filename` 向前找最近的元数据）。
List<BaiduShareItem> parseBaiduShareItems(String html) {
  final out = <BaiduShareItem>[];
  for (final match in _shareItemNameRe.allMatches(html)) {
    final start = match.start - 800;
    final segment = html.substring(start < 0 ? 0 : start, match.start);
    final fsid = _lastGroup(segment, _shareItemFsidRe);
    if (fsid.isEmpty) continue;
    final isdir = _lastGroup(segment, _shareItemIsdirRe);
    out.add(
      BaiduShareItem(
        name: _unescapeJson(match.group(1)!),
        fsid: fsid,
        isdir: isdir == '1',
        path: _unescapeJson(_lastGroup(segment, _shareItemPathRe)),
      ),
    );
  }
  return out;
}

/// 把文本解析为可播直链（全局串行）。
///
/// 支持：`baidu@<base64>` 描述符、播放描述 JSON、`pan|yun.baidu.com/s/<id>` 分享链接，
/// 以及 `do=pan&site=baidu&fileId=<fs_id>`（本人盘文件直链）。
Future<NativeDriveLink> resolveBaiduDirect(
  String text, {
  required String cookie,
  String episodeName = '',
}) {
  return _enqueueBaidu(
    () => _resolveBaiduDirectInner(
      text,
      cookie: cookie,
      episodeName: episodeName,
    ),
  );
}

/// 已解析出的分享凭据 → 直链（不做转存兜底）。
Future<NativeDriveLink> resolveBaiduSharedFile(
  String descriptor, {
  required String cookie,
}) {
  return _enqueueBaidu(
    () => _resolveBaiduSharedFileInner(descriptor, cookie: cookie),
  );
}

Future<NativeDriveLink> _resolveBaiduDirectInner(
  String text, {
  required String cookie,
  required String episodeName,
}) async {
  if (cookie.trim().isEmpty) {
    return NativeDriveLink.failed('未绑定百度账号（Cookie 缺失）');
  }
  final trimmed = text.trim();
  if (trimmed.isEmpty) return NativeDriveLink.failed('播放地址为空');

  final desc = parseDriveDescriptor(trimmed);
  if (desc != null) {
    if (desc.provider != 'baidu') {
      return NativeDriveLink.failed('不是百度网盘分享（provider=${desc.provider}）');
    }
    final file = extractBaiduSharedFile(trimmed);
    if (file == null) {
      return NativeDriveLink.failed('百度分享描述符不完整（缺少 shareId/uk/fileId/randsk）');
    }
    return _directFile(file, cookie);
  }

  final sharedFile = extractBaiduSharedFile(trimmed);
  if (sharedFile != null) return _directFile(sharedFile, cookie);

  final share = extractBaiduShare(trimmed);
  if (share != null) {
    return _resolveShareLink(share.short, share.pwd, cookie, episodeName);
  }

  final fsid = _ownFsidOf(trimmed);
  if (fsid.isNotEmpty && _isBaiduPanQuery(trimmed)) {
    return _resolveOwnFsid(fsid, cookie);
  }
  return NativeDriveLink.failed('未识别百度分享链接');
}

Future<NativeDriveLink> _resolveBaiduSharedFileInner(
  String descriptor, {
  required String cookie,
}) async {
  if (cookie.trim().isEmpty) {
    return NativeDriveLink.failed('未绑定百度账号（Cookie 缺失）');
  }
  final file = extractBaiduSharedFile(descriptor);
  if (file == null) {
    return NativeDriveLink.failed('不是可用的百度分享描述符（需要 shareId/uk/fileId/randsk）');
  }
  return _directFile(file, cookie);
}

Future<NativeDriveLink> _directFile(BaiduSharedFile file, String cookie) {
  return _trySharedDirectLink(file, cookie);
}

/// 只读分享取链：不创建目录、不转存、不登记清理；分享者 fs_id 必须精确命中。
Future<NativeDriveLink> _trySharedDirectLink(
  BaiduSharedFile file,
  String cookie,
) async {
  if (!_digitsRe.hasMatch(file.shareId) ||
      !_digitsRe.hasMatch(file.uk) ||
      !_digitsRe.hasMatch(file.fsid) ||
      file.sekey.isEmpty) {
    return NativeDriveLink.failed('分享文件会话不完整');
  }
  final bduss = _cookieValueOf(cookie, 'BDUSS');
  if (bduss.isEmpty) {
    return NativeDriveLink.failed('Cookie 缺少 BDUSS（百度登录态无效）');
  }
  final sharedCookie = mergeSetCookies(sanitizeCookie(cookie), <String>[
    'BDCLND=${_encodedSekey(file.sekey)}',
  ]);

  final user = await _shareGet(_shareUserApi, sharedCookie);
  if (user == null) {
    return NativeDriveLink.failed('未能取到百度账号 uid（登录态可能失效）');
  }
  final uid = _str(_dig(user.json, <Object>['data', 'fields', 'uid']));
  final userErrno = _intOrNull(user.json['errno']);
  if (userErrno != 0 || !_digitsRe.hasMatch(uid)) {
    return NativeDriveLink.failed('百度账号 uid 获取失败');
  }

  final time = DateTime.now().millisecondsSinceEpoch.toString();
  final uri = Uri.parse('https://pan.baidu.com/share/list').replace(
    queryParameters: <String, String>{
      'shareid': file.shareId,
      'uk': file.uk,
      'fid': file.fsid,
      'sekey': _rawSekey(file.sekey),
      'origin': 'dlna',
      'devuid': _shareDevice,
      'clienttype': '1',
      'channel': 'android_12_zhao_bd-netdisk_1024266h',
      'version': '11.30.2',
      'time': time,
      'rand': baiduShareRand(bduss, uid, time),
    },
  );
  final result = await _shareGet(uri.toString(), sharedCookie);
  if (result == null) {
    return NativeDriveLink.failed('签名分享接口不可用（HTTP 异常）');
  }
  final errno = _intOrNull(result.json['errno']);
  if (errno != null && errno != 0) {
    return NativeDriveLink.failed('${baiduErrnoText(errno)}（errno=$errno）');
  }
  final exact = <Map<Object?, Object?>>[];
  for (final raw in _listOf(result.json['list'])) {
    final item = _asMap(raw);
    if (item == null) continue;
    if (_str(item['fs_id']) == file.fsid && _intOrNull(item['isdir']) == 0) {
      exact.add(item);
    }
  }
  if (errno == null || exact.length != 1) {
    return NativeDriveLink.failed('分享接口未定位到所选文件');
  }
  final dlink = _str(exact.first['dlink']);
  if (!_httpUrlRe.hasMatch(dlink)) {
    return NativeDriveLink.failed('分享接口未返回有效下载地址');
  }
  final headers = <String, String>{
    'Cookie': sharedCookie,
    'User-Agent': _dlUa,
    'Referer': _ref,
  };
  // 与 winbox 一致：签名接口可能回「过期 / 被拒」的地址，Range 预探测不过不算成功，
  // 否则播放器只会黑屏，也丢掉回退 jar 的机会。
  final invalid = await _probeSharedDirect(dlink, headers);
  if (invalid != null) {
    return NativeDriveLink.failed('免转存直链不可用（$invalid）');
  }
  return NativeDriveLink(ok: true, url: dlink, headers: headers);
}

/// Range 预探测（`bytes=0-0`）：必须 206 + `bytes 0-0/<总长>` + 非 text/json/xml。
/// 只看响应头，随后强制断开连接，不会把整个文件拉下来。
///
/// ★ 必须**手动**跟随重定向（`followRedirects = false` + 自己取 Location）：
///   百度的 `dlink` 会先 302 到 `*.baidupcs.com` 的真实流地址，而 Dart 的自动
///   跟随会新建请求，新请求已带默认 `User-Agent: Dart/x.y`，调用方设置的 UA
///   不再被复制；百度 CDN 正是按 UA 判防盗链。同一 URL、同一套头，
///   「自动跟随 → 403 + text/plain」「手动跟随 → 206 + bytes 0-0/…」。
Future<String?> _probeSharedDirect(
  String url,
  Map<String, String> headers,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  // 整条重定向链共用一份预算，避免 5 跳 × 8s 把探测拖到半分钟。
  final deadline = DateTime.now().add(const Duration(seconds: 12));
  try {
    var current = Uri.parse(url);
    final origin = current;
    HttpClientResponse? response;
    for (var hop = 0; hop <= 5; hop++) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        return 'Range 探测超时（重定向链过长）';
      }
      final timeout = remaining < const Duration(seconds: 8)
          ? remaining
          : const Duration(seconds: 8);
      final request = await client.getUrl(current).timeout(timeout);
      final crossOrigin =
          !origin.isScheme(current.scheme) ||
          origin.host != current.host ||
          origin.port != current.port;
      for (final entry in headers.entries) {
        // 跨源不带本机网盘 Cookie / Authorization（CDN 域不需要，也不该外泄）
        final sensitive =
            _probeSensitiveHeaders.contains(entry.key.toLowerCase());
        if (crossOrigin && sensitive) continue;
        request.headers.set(entry.key, entry.value);
      }
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      request.followRedirects = false;
      final res = await request.close().timeout(timeout);
      final code = res.statusCode;
      final location = res.headers.value(HttpHeaders.locationHeader);
      if (code < 300 || code >= 400 || location == null || location.isEmpty) {
        response = res;
        break;
      }
      await res.drain<void>().catchError((Object _) {});
      current = current.resolve(location);
      if (!current.isScheme('http') && !current.isScheme('https')) {
        return '重定向到不支持的协议（${current.scheme}）';
      }
    }
    if (response == null) return '重定向次数过多';
    final contentRange = response.headers.value('content-range') ?? '';
    final contentType =
        response.headers.value(HttpHeaders.contentTypeHeader) ?? '';
    final valid =
        response.statusCode == 206 &&
        RegExp(
          r'^bytes 0-0/[1-9]\d*$',
          caseSensitive: false,
        ).hasMatch(contentRange) &&
        !RegExp(r'text/|json|xml', caseSensitive: false).hasMatch(contentType);
    // 只看响应头；成功分支也主动 drain，避免 finally 的强制关闭留下连接异常。
    await response.drain<void>().catchError((Object _) {});
    if (valid) return null;
    return 'HTTP ${response.statusCode}'
        '${contentRange.isNotEmpty ? '（$contentRange）' : ''}';
  } catch (e) {
    return 'Range 探测异常（${_briefError(e)}）';
  } finally {
    client.close(force: true);
  }
}

/// 跨源重定向时不能继续携带的敏感头。
const _probeSensitiveHeaders = {
  'cookie',
  'cookie2',
  'authorization',
  'proxy-authorization',
  'www-authenticate',
  'proxy-authenticate',
};

/// 分享链接：init 取 t → verify 取 BDCLND → 分享页 HTML → 按集名定位 → 签名取链。
Future<NativeDriveLink> _resolveShareLink(
  String short,
  String pwd,
  String cookie,
  String episodeName,
) async {
  final session = _BaiduSession(sanitizeCookie(cookie));
  final surl = verifySurl(short);

  // 1) 分享页取 t（自造值恒定 errno 105）。
  final init = await _sessionRequest(
    session,
    'https://pan.baidu.com/share/init?surl=$surl',
  );
  final t =
      _shareTRe.firstMatch(init.text)?.group(1) ??
      _shareTAltRe.firstMatch(init.text)?.group(1);
  if (t == null) {
    return NativeDriveLink.failed('分享页打不开（取不到 t，分享可能已失效）');
  }

  // 2) 提交提取码 → BDCLND（= sekey，后续取链必带）。
  final verify = await _sessionRequest(
    session,
    'https://pan.baidu.com/share/verify?surl=$surl&t=$t'
    '&channel=chunlei&web=1&app_id=250528&bdstoken=null&logid=&clienttype=0',
    method: 'POST',
    body: 'pwd=${Uri.encodeComponent(pwd)}&vcode=&vcode_str=',
    referer: 'https://pan.baidu.com/share/init?surl=$surl',
  );
  final verifyErrno = _intOrNull(verify.json['errno']);
  if (verifyErrno != 0) {
    if (verifyErrno == null) {
      return NativeDriveLink.failed('提取码验证响应异常');
    }
    return NativeDriveLink.failed(
      '${baiduErrnoText(verifyErrno)}（errno=$verifyErrno）',
    );
  }
  final sekey = _encodedSekey(_cookieValueOf(session.cookie, 'BDCLND'));
  if (sekey.isEmpty) {
    return NativeDriveLink.failed('提取码已通过但未拿到分享会话（BDCLND 缺失）');
  }

  // 3) 分享页 HTML（权威来源：shareid / share_uk / 根文件项）。
  final page = await _sessionRequest(
    session,
    'https://pan.baidu.com/s/$short',
    accept: 'text/html,application/xhtml+xml,*/*',
  );
  final shareid = _shareIdRe.firstMatch(page.text)?.group(1) ?? '';
  final shareUk =
      _shareUkRe.firstMatch(page.text)?.group(1) ??
      _shareUkAltRe.firstMatch(page.text)?.group(1) ??
      '';
  if (shareid.isEmpty || shareUk.isEmpty) {
    return NativeDriveLink.failed('分享页未解析出 shareid/uk（分享可能已失效）');
  }
  final rootItems = parseBaiduShareItems(page.text);
  if (rootItems.isEmpty) {
    return NativeDriveLink.failed('分享内没有可播文件');
  }

  // 4) 按集名精确 / 唯一命中；拿不准就拒绝，绝不默认播首集。
  final pick = _pickRootItem(rootItems, episodeName);
  final target = pick.item;
  if (target == null) {
    return NativeDriveLink.failed(pick.reason);
  }
  if (target.isdir) {
    return NativeDriveLink.failed('分享目标是文件夹，免转存无法直接取链');
  }

  // 5) 只读签名取链（无转存兜底）。
  return _trySharedDirectLink(
    BaiduSharedFile(
      shareId: shareid,
      uk: shareUk,
      sekey: sekey,
      fsid: target.fsid,
      name: target.name,
    ),
    session.cookie,
  );
}

/// `do=pan&site=baidu&fileId=<fs_id>` 的本人盘文件直链（只读）。
Future<NativeDriveLink> _resolveOwnFsid(String fsid, String cookie) async {
  if (!_digits6Re.hasMatch(fsid)) {
    return NativeDriveLink.failed('文件 ID 非纯数字（非自有文件形态）');
  }
  final session = _BaiduSession(sanitizeCookie(cookie));
  final bdstoken = await _fetchBdstoken(session);
  if (bdstoken.isEmpty) {
    return NativeDriveLink.failed('未取到 bdstoken（百度登录态可能已失效）');
  }
  final result = await _sessionRequest(
    session,
    'https://pan.baidu.com/api/filemetas?dlink=1&fsids=%5B$fsid%5D&thumb=0'
    '&web=1&app_id=250528&channel=chunlei&clienttype=0'
    '&bdstoken=${Uri.encodeQueryComponent(bdstoken)}',
    referer: _refDisk,
  );
  final errno = _intOrNull(result.json['errno']);
  final url = errno == 0
      ? _str(_dig(result.json, <Object>['info', 0, 'dlink']))
      : '';
  if (!_httpUrlRe.hasMatch(url)) {
    final code = errno ?? result.status;
    return NativeDriveLink.failed('未取到下载地址（errno=$code）');
  }
  return NativeDriveLink(
    ok: true,
    url: url,
    headers: <String, String>{
      'User-Agent': _dlUa,
      'Referer': _ref,
      'Cookie': session.cookie,
    },
  );
}

Future<String> _fetchBdstoken(_BaiduSession session) async {
  final result = await _sessionRequest(
    session,
    'https://pan.baidu.com/api/gettemplatevariable'
    '?clienttype=0&app_id=250528&web=1&fields=%5B%22bdstoken%22%5D',
  );
  return baiduBdstokenFromTemplate(result.json);
}

/// 从 `gettemplatevariable` 响应里取 bdstoken。
///
/// 百度返回的键是 `bdstoken`；旧版本误读了 `bstoken`，导致始终取不到令牌。
String baiduBdstokenFromTemplate(Map<String, dynamic> json) {
  final result = json['result'];
  if (result is! Map) return '';
  final value = result['bdstoken'] ?? result['bstoken'];
  final text = value?.toString().trim() ?? '';
  return text;
}

Future<_HttpResult> _sessionRequest(
  _BaiduSession session,
  String url, {
  String method = 'GET',
  String? body,
  String referer = _ref,
  String accept = 'application/json, text/plain, */*',
}) async {
  final headers = <String, String>{
    'User-Agent': _ua,
    'Cookie': session.cookie,
    'Referer': referer,
    'Accept': accept,
  };
  if (body != null) {
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
  }
  final result = await _http(
    Uri.parse(url),
    method: method,
    body: body,
    headers: headers,
  );
  session.cookie = mergeSetCookies(session.cookie, result.setCookies);
  return result;
}

Future<_HttpResult> _http(
  Uri uri, {
  String method = 'GET',
  String? body,
  Map<String, String> headers = const <String, String>{},
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final request = await client
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 12));
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (body != null) request.write(body);
    final response = await request.close().timeout(const Duration(seconds: 20));
    final text = await response
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(const Duration(seconds: 20));
    final setCookies = <String>[];
    response.headers.forEach((name, values) {
      if (name.toLowerCase() == HttpHeaders.setCookieHeader) {
        setCookies.addAll(values);
      }
    });
    var json = <String, dynamic>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // HTML / 空响应：调用方读 text。
    }
    return _HttpResult(
      status: response.statusCode,
      text: text,
      json: json,
      setCookies: setCookies,
    );
  } finally {
    client.close(force: true);
  }
}

Future<_HttpResult?> _shareGet(String url, String cookie) async {
  try {
    final result = await _http(
      Uri.parse(url),
      headers: <String, String>{
        'Cookie': cookie,
        'User-Agent': _shareUa,
        'Referer': _ref,
      },
    );
    if (result.status < 200 || result.status >= 300) return null;
    return result;
  } catch (_) {
    return null;
  }
}

String _baiduShareIdOf(String text) {
  final direct = _shareIdUrlRe.firstMatch(text);
  if (direct != null) return direct.group(1)!;
  final init = _shareInitRe.firstMatch(text);
  if (init != null) return '1${init.group(1)!}';
  final json = _shareJsonSurlRe.firstMatch(text);
  return json != null ? json.group(1)! : '';
}

bool _isBaiduPanQuery(String text) {
  for (final candidate in shareTextCandidates(text)) {
    if (_panQueryRe.hasMatch(candidate)) return true;
  }
  return false;
}

String _ownFsidOf(String text) {
  for (final candidate in shareTextCandidates(text)) {
    final query = _ownFsidQueryRe.firstMatch(candidate);
    if (query != null) {
      var value = query.group(1)!;
      try {
        value = Uri.decodeComponent(value);
      } catch (_) {
        // 非法百分号序列：原样判断。
      }
      if (_digits6Re.hasMatch(value)) return value;
    }
    for (final re in <RegExp>[_ownFsidJsonRe, _ownFsidFileIdRe]) {
      final match = re.firstMatch(candidate);
      if (match != null && _digits6Re.hasMatch(match.group(1)!)) {
        return match.group(1)!;
      }
    }
  }
  return '';
}

_RootPick _pickRootItem(List<BaiduShareItem> items, String innerName) {
  final want = innerName.trim();
  if (want.isNotEmpty) {
    final hit = _pickByName(items, want);
    if (hit.ambiguous) {
      return _RootPick(null, '分享内有多个「${_stem(want)}」同名文件，无法确定集数');
    }
    if (hit.item != null) return _RootPick(hit.item, '');
    // 文件可能在唯一目录内；没有目录时不能静默改播首个文件。
    if (!items.any((x) => x.isdir)) {
      return _RootPick(null, '分享内未找到所选文件「$want」');
    }
  }
  if (items.length == 1) return _RootPick(items.first, '');
  final dirs = items.where((x) => x.isdir).toList();
  if (dirs.length == 1) return _RootPick(dirs.first, '');
  final videos = _sortByNaturalName(
    items.where((x) => !x.isdir && _videoRe.hasMatch(x.name)).toList(),
  );
  if (videos.length == 1) return _RootPick(videos.first, '');
  if (videos.length > 1) {
    return _RootPick(null, '分享包含多集但缺少所选文件标识，拒绝默认播放首集');
  }
  return _RootPick(null, '分享内没有可播的视频文件');
}

_NamePick _pickByName(List<BaiduShareItem> items, String innerName) {
  final want = _stem(innerName);
  if (want.isEmpty) return const _NamePick(null, false);
  final hits = items
      .where((x) => x.name == innerName || _stem(x.name) == want)
      .toList();
  if (hits.length == 1) return _NamePick(hits.first, false);
  return _NamePick(null, hits.length > 1);
}

List<BaiduShareItem> _sortByNaturalName(List<BaiduShareItem> items) {
  return items..sort((a, b) => _naturalCompare(a.name, b.name));
}

int _naturalCompare(String a, String b) {
  final chunksA = RegExp(r'(\d+|\D+)')
      .allMatches(a)
      .map((m) => m.group(0)!)
      .toList();
  final chunksB = RegExp(r'(\d+|\D+)')
      .allMatches(b)
      .map((m) => m.group(0)!)
      .toList();
  final length = chunksA.length < chunksB.length
      ? chunksA.length
      : chunksB.length;
  for (var i = 0; i < length; i++) {
    final left = chunksA[i];
    final right = chunksB[i];
    final leftNumber = int.tryParse(left);
    final rightNumber = int.tryParse(right);
    if (leftNumber != null && rightNumber != null) {
      if (leftNumber != rightNumber) return leftNumber.compareTo(rightNumber);
    } else {
      final diff = left.toLowerCase().compareTo(right.toLowerCase());
      if (diff != 0) return diff;
    }
  }
  return chunksA.length.compareTo(chunksB.length);
}

String _stem(String name) =>
    name.replaceFirst(RegExp(r'\.[0-9a-zA-Z]{2,4}$'), '').trim();

String _unescapeJson(String source) {
  var out = source.replaceAllMapped(
    RegExp(r'\\u([0-9a-fA-F]{4})'),
    (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
  );
  out = out.replaceAllMapped(RegExp(r'\\(["\\/])'), (m) => m.group(1)!);
  return out;
}

String _lastGroup(String source, RegExp re) {
  var last = '';
  for (final match in re.allMatches(source)) {
    last = match.group(1) ?? '';
  }
  return last;
}

String _cookieValueOf(String cookie, String name) {
  final match = RegExp(
    '(?:^|;\\s*)${RegExp.escape(name)}=([^;]*)',
    caseSensitive: false,
  ).firstMatch(cookie);
  return match?.group(1) ?? '';
}

String _rawSekey(String sekey) {
  try {
    return Uri.decodeComponent(sekey);
  } catch (_) {
    return sekey;
  }
}

String _encodedSekey(String sekey) => Uri.encodeComponent(_rawSekey(sekey));

Map<Object?, Object?>? _asMap(Object? value) => value is Map ? value : null;

List<dynamic> _listOf(Object? value) =>
    value is List ? value : const <dynamic>[];

Object? _dig(Object? node, List<Object> path) {
  var current = node;
  for (final key in path) {
    if (current is Map) {
      current = current[key];
    } else if (current is List && key is int) {
      if (key < 0 || key >= current.length) return null;
      current = current[key];
    } else {
      return null;
    }
  }
  return current;
}

String _str(Object? value) {
  if (value is String) return value.trim();
  if (value is num) return value.toString();
  if (value is bool) return value ? '1' : '0';
  return '';
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is bool) return value ? 1 : 0;
  if (value is String) return int.tryParse(value.trim());
  return null;
}

String _briefError(Object error) {
  final text = error.toString().replaceAll('\n', ' ');
  return text.length > 80 ? text.substring(0, 80) : text;
}

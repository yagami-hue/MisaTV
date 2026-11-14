// 夸克网盘「免转存」直链解析（纯 Dart，供桌面端原生通道使用）。
//
// 只做直链：绝不转存到用户网盘、不轮询任务、不删除。
//
// 取链契约（与 UC 同构，但主机名与 UA 完全不同 —— 这点踩过坑）：
//   POST /share/sharepage/token   { pwd_id, passcode }              → data.stoken
//   GET  /share/sharepage/detail  ?pwd_id&stoken&pdir_fid&_page&_size → data.list[]
//   POST /file/download           { fids, fid_token_list, pwd_id, stoken } → data[0].download_url
//
// ★ 主机名必须是 `drive-pc.quark.cn`，UA 必须是夸克桌面客户端（quark-cloud-drive/…）。
//   实测：用浏览器 UA 打 `drive.quark.cn` 时 token 能通、detail 能通，但
//   `/file/download` 一律 400 code=23018「download file size limit」；
//   `/member`、`/file/sort` 则直接 401。换成 drive-pc + 客户端 UA 后，
//   同一个 cookie、同一个分享立刻返回 200 + 真实 download_url，且该直链
//   （带 Range 请求）返回 200 / video/mp4 / ftypisom 头 —— 即真的能播。
//   所以「23018」不是账号权限问题，是**请求身份不对**。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'drive_descriptor.dart';
import 'quark_session_io.dart' show mergeSetCookies, sanitizeCookie;

/// 桌面客户端身份（与 quark_session_io 的会话探测保持一致）。
const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 '
    'Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';
const _ref = 'https://pan.quark.cn/';
const _origin = 'https://pan.quark.cn';

/// 取链 API 主机（见文件头：必须是 drive-pc）。
const _api = 'https://drive-pc.quark.cn/1/clouddrive';
const _query = 'pr=ucpro&fr=pc';

const _pageSize = 50;
const _maxPages = 10;

/// 整个分享最多列多少页（含所有子目录）。
///
/// 单目录 10 页的上限挡不住「根目录下几十个文件夹、每个再 10 页」的分享，
/// 极端样本会几十秒才失败；这里给整体预算，超了就用手上已列到的文件匹配。
const _maxTotalPages = 60;

final _quarkFlagRe = RegExp(r'夸父|夸克|quark', caseSensitive: false);
final _digitsRe = RegExp(r'^\d+$');
final _fidBadRe = RegExp(r'[/:?]');

/// 夸克分享的定位信息。
class QuarkShareRef {
  const QuarkShareRef({
    required this.pwdId,
    this.passcode = '',
    this.fileId = '',
    this.fileToken = '',
    this.dirFid = '',
    this.name = '',
    this.stoken = '',
  });

  /// 分享 ID（`sId` / `pwd_id`）。
  final String pwdId;

  /// 提取码（无密码分享为空）。
  final String passcode;

  /// 目标文件 fid。
  final String fileId;

  /// 目标文件的分享令牌（`share_fid_token`）。
  final String fileToken;

  /// 目标文件所在目录 fid（`pdir_fid`）。
  final String dirFid;

  /// 文件名（定位兜底 / 提示用）。
  final String name;

  /// 集参数里自带的分享令牌（`sToken`）；为空时再向 token 接口申请。
  ///
  /// fty 系壳每次播放都会下发新的 `sToken`，直接复用能省一次 POST；
  /// 有提取码的分享也可能只认这份与 `sId` 一起生成的会话。
  final String stoken;
}

/// 该文本是否是夸克分享（描述符 / 线路名明确是夸克 / 集参数 JSON 带 sId+fid）。
bool looksLikeQuarkShare(String text, {String flag = ''}) {
  final desc = parseDriveDescriptor(text);
  if (desc != null) return desc.provider == 'quark';
  return extractQuarkShare(text, flag: flag) != null;
}

/// 从文本解析夸克分享定位信息。
///
/// 认三种来源（按可信度）：
///   · 网盘描述符（`quark@base64` / 嵌套信封）；
///   · 加固壳集参数 JSON（`sId` + `fid` + `share_fid_token` + `pdir_fid`）——
///     这是 fty 系（玩偶哥哥等）最常见的形态；
///   · 分享链接 `pan.quark.cn/s/<id>`（无内层 fid，需要列目录）。
QuarkShareRef? extractQuarkShare(String text, {String flag = ''}) {
  final desc = parseDriveDescriptor(text);
  if (desc != null) {
    if (desc.provider != 'quark') return null;
    final pwdId = descriptorField(desc.data, <String>['shareId', 'pwdId', 'sId']);
    if (pwdId.isEmpty) return null;
    return QuarkShareRef(
      pwdId: pwdId,
      passcode: _str(desc.data['passcode']).isNotEmpty
          ? _str(desc.data['passcode'])
          : _str(desc.data['pwd']),
      fileId: descriptorField(desc.data, <String>['fileId', 'fid', 'fs_id']),
      fileToken: descriptorField(desc.data, <String>[
        'fileToken',
        'share_fid_token',
        'fid_token',
      ]),
      dirFid: descriptorField(desc.data, <String>['pdir_fid', 'pdirFid']),
      name: descriptorField(desc.data, <String>[
        'name',
        'fileName',
        'file_name',
        'vodName',
      ]),
      stoken: descriptorField(desc.data, <String>['stoken']),
    );
  }

  // 集参数 JSON（fty 系壳）：只有明确是夸克线路时才解释，
  // 否则会把同一批 id 里的百度 / UC 分享误当夸克。
  if (_quarkFlagRe.hasMatch(flag) || flag.isEmpty) {
    try {
      final d = _asMap(jsonDecode(text.trim()));
      if (d != null) {
        final sid = _str(d['sId']).isNotEmpty ? _str(d['sId']) : _str(d['pwd_id']);
        final fid = _str(d['fid']);
        if (sid.isNotEmpty &&
            _digitsRe.hasMatch(sid) == false &&
            !_fidBadRe.hasMatch(sid)) {
          final passcode = _str(d['passcode']).isNotEmpty
              ? _str(d['passcode'])
              : _str(d['pwd']);
          final name = _str(d['file_name']).isNotEmpty
              ? _str(d['file_name'])
              : _str(d['vodName']);
          return QuarkShareRef(
            pwdId: sid,
            passcode: passcode,
            fileId: fid,
            fileToken: _str(d['share_fid_token']).isNotEmpty
                ? _str(d['share_fid_token'])
                : _str(d['shareFidToken']),
            dirFid: _str(d['pdir_fid']),
            name: name,
            stoken: _str(d['sToken']).isNotEmpty
                ? _str(d['sToken'])
                : _str(d['stoken']),
          );
        }
      }
    } catch (_) {
      // 不是 JSON：继续走链接解析
    }
  }

  // 分享链接
  final link = RegExp(
    r'pan\.quark\.cn/s/([0-9a-zA-Z_-]+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (link != null) {
    final pwd = RegExp(
      r'[?&](?:pwd|password|passcode)=([0-9a-zA-Z]{4})',
      caseSensitive: false,
    ).firstMatch(text);
    return QuarkShareRef(
      pwdId: link.group(1)!,
      passcode: pwd?.group(1) ?? '',
    );
  }
  return null;
}

/// 全局串行锁：分享会话与 download 下发 Cookie 属共享状态机，并发会互相污染。
Future<void> _chain = Future<void>.value();

/// 把文本解析为可播直链（全局串行；不转存）。
Future<NativeDriveLink> resolveQuarkDirect(
  String text, {
  required String cookie,
  String flag = '',
  String episodeName = '',
}) {
  final run = _chain.then((_) async {
    try {
      return await _resolveInner(
        text,
        cookie: cookie,
        flag: flag,
        episodeName: episodeName,
      );
    } catch (e) {
      return NativeDriveLink.failed('夸克请求失败（${_briefError(e)}）');
    }
  });
  _chain = run.then<void>((_) {}, onError: (Object e, StackTrace s) {});
  return run;
}

Future<NativeDriveLink> _resolveInner(
  String text, {
  required String cookie,
  required String flag,
  required String episodeName,
}) async {
  if (cookie.trim().isEmpty) {
    return NativeDriveLink.failed('未绑定夸克账号（Cookie 缺失）');
  }
  final trimmed = text.trim();
  if (trimmed.isEmpty) return NativeDriveLink.failed('播放地址为空');

  final ref = extractQuarkShare(trimmed, flag: flag);
  if (ref == null) return NativeDriveLink.failed('未识别夸克分享');
  if (ref.pwdId.trim().isEmpty) return NativeDriveLink.failed('分享 ID 为空');
  final accountCookie = sanitizeCookie(cookie);

  // 1) 分享 stoken：集参数自带就复用（fty 每次播放下发新值），否则申请。
  //    token 接口不需要账号 Cookie（匿名也能拿），带上是为了让服务端把
  //    会话与我们账号关联，下载时才认。
  var stoken = ref.stoken;
  if (stoken.isEmpty) {
    final tokenResult = await _post(
      '/share/sharepage/token',
      accountCookie,
      <String, Object?>{'pwd_id': ref.pwdId, 'passcode': ref.passcode},
    );
    stoken = _str(_dig(tokenResult.json, <Object>['data', 'stoken']));
    if (stoken.isEmpty) {
      final detail = _errDetail(tokenResult);
      return NativeDriveLink.failed('分享不可用（${_clip(detail, 120)}）');
    }
  }

  // 2) 定位目标文件：优先用集参数自带的 fid + share_fid_token（无需列目录）；
  //    否则按 pdir_fid 列目录，再按 fid / 集名匹配。
  var fid = ref.fileId;
  var fileToken = ref.fileToken;
  var size = 0;
  var fileName = ref.name;

  if (fid.isEmpty || fileToken.isEmpty) {
    final located = await _locateFile(
      ref: ref,
      stoken: stoken,
      cookie: accountCookie,
      preferName: episodeName.trim().isNotEmpty
          ? episodeName.trim()
          : ref.name,
    );
    if (located == null) {
      return NativeDriveLink.failed('分享内未定位到目标文件（可能已失效或集数不匹配）');
    }
    fid = located.fid;
    fileToken = located.token;
    size = located.size;
    if (located.name.isNotEmpty) fileName = located.name;
  }
  if (fid.isEmpty) return NativeDriveLink.failed('目标文件 fid 为空');
  if (fileToken.isEmpty) {
    final label = fileName.isNotEmpty ? fileName : fid;
    return NativeDriveLink.failed('目标文件「${_clip(label, 30)}」缺少分享令牌');
  }

  // 3) 免转存直链：带分享 token 直接 download，不写本人盘。
  final direct = await _post(
    '/file/download',
    accountCookie,
    <String, Object?>{
      'fids': <String>[fid],
      'fid_token_list': <String>[fileToken],
      'pwd_id': ref.pwdId,
      'stoken': stoken,
    },
  );
  final directUrl = _str(_dig(direct.json, <Object>['data', 0, 'download_url']));
  if (directUrl.isEmpty) {
    final detail = _errDetail(direct);
    return NativeDriveLink.failed('未取到下载直链（${_clip(detail, 100)}）');
  }

  // 部分 CDN 节点会在 download 响应里下发新会话 Cookie，必须并入播放 Cookie。
  final playCookie = mergeSetCookies(accountCookie, direct.setCookies);
  final playHeaders = <String, String>{
    'User-Agent': _ua,
    'Referer': _ref,
    'Cookie': playCookie,
  };
  final invalid = await _validate(directUrl, size, playHeaders);
  if (invalid != null) {
    return NativeDriveLink.failed('免转存直链不可用（$invalid）');
  }
  return NativeDriveLink(ok: true, url: directUrl, headers: playHeaders);
}

class _Located {
  const _Located({
    required this.fid,
    required this.token,
    required this.name,
    required this.size,
  });
  final String fid;
  final String token;
  final String name;
  final int size;
}

/// 列分享目录树并定位目标文件。
Future<_Located?> _locateFile({
  required QuarkShareRef ref,
  required String stoken,
  required String cookie,
  required String preferName,
}) async {
  final queue = <String>[ref.dirFid.isEmpty ? '0' : ref.dirFid];
  final visited = <String>{};
  final all = <_Located>[];
  var pages = 0;
  outer:
  while (queue.isNotEmpty) {
    final dir = queue.removeAt(0);
    if (!visited.add(dir)) continue;
    for (var page = 1; page <= _maxPages; page++) {
      if (pages >= _maxTotalPages) break outer;
      pages++;
      final result = await _get(
        '/share/sharepage/detail'
        '?pwd_id=${Uri.encodeQueryComponent(ref.pwdId)}'
        '&stoken=${Uri.encodeQueryComponent(stoken)}'
        '&pdir_fid=${Uri.encodeQueryComponent(dir)}'
        '&force=0&_page=$page&_size=$_pageSize'
        '&_fetch_banner=0&_fetch_share=0&_fetch_total=1',
        cookie,
      );
      final code = _intOrNull(result.json['code']);
      if (result.status != 200 || code != 0) {
        throw StateError(
          '夸克分享列表失败 HTTP ${result.status}, code=${result.json['code'] ?? '-'}',
        );
      }
      final list = _dig(result.json, <Object>['data', 'list']);
      if (list is! List || list.isEmpty) break;
      for (final raw in list) {
        final e = _asMap(raw);
        if (e == null) continue;
        final fid = _str(e['fid']);
        if (fid.isEmpty) continue;
        final type = _intOrNull(e['file_type']) ?? 0;
        final isDir = type == 0 || e['dir'] == true;
        if (isDir) {
          queue.add(fid);
          continue;
        }
        all.add(
          _Located(
            fid: fid,
            token: _str(e['share_fid_token']),
            name: _str(e['file_name']),
            size: _intOrNull(e['size']) ?? 0,
          ),
        );
      }
      if (list.length < _pageSize) break;
    }
  }
  if (all.isEmpty) return null;

  // 精确 fid 优先
  if (ref.fileId.isNotEmpty) {
    for (final f in all) {
      if (f.fid == ref.fileId) return f;
    }
  }
  // 集名唯一匹配
  if (preferName.isNotEmpty) {
    final exact = all.where((f) => f.name == preferName).toList();
    if (exact.length == 1) return exact.first;
    final loose = all
        .where((f) => f.name.contains(preferName) || preferName.contains(f.name))
        .toList();
    if (loose.length == 1) return loose.first;
  }
  // 只有一个文件时直接用它
  if (all.length == 1) return all.first;
  return null;
}

/// 用 Range 探针确认直链真的能下（壳与网盘都会给"看起来正常"的死链）。
Future<String?> _validate(
  String url,
  int expectedSize,
  Map<String, String> headers,
) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.isScheme('http') && !uri.isScheme('https')) {
    return '地址无效';
  }
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..autoUncompress = false;
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 12));
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    final response = await request.close().timeout(const Duration(seconds: 20));
    final status = response.statusCode;
    final type = response.headers.contentType?.mimeType ?? '';
    final length = response.contentLength;
    // 只读第一个数据块就断开：CDN 忽略 Range 回 200 时，
    // drain 会把整个大文件拖完（几个 GB），探针本身反而成了下载。
    await response.take(1).drain<void>().catchError((Object _) {});
    if (status != 200 && status != 206) {
      return 'HTTP $status';
    }
    if (type.contains('json') || type.contains('text/html')) {
      return '返回了 $type 而不是媒体流';
    }
    if (expectedSize > 0) {
      // Range 请求下 contentLength 是被截断的长度，只在非 206 时比较
      if (status == 200 && length > 0 && length != expectedSize) {
        return '大小不符（$length ≠ $expectedSize）';
      }
    }
    return null;
  } catch (e) {
    return _briefError(e);
  } finally {
    client.close(force: true);
  }
}

Future<_HttpResult> _post(String path, String cookie, Object body) {
  final headers = <String, String>{
    'User-Agent': _ua,
    'Referer': _ref,
    'Origin': _origin,
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/plain, */*',
  };
  if (cookie.isNotEmpty) headers['Cookie'] = cookie;
  return _http(
    Uri.parse('$_api$path?$_query'),
    method: 'POST',
    body: jsonEncode(body),
    headers: headers,
  );
}

Future<_HttpResult> _get(String path, String cookie) {
  final sep = path.contains('?') ? '&' : '?';
  return _http(
    Uri.parse('$_api$path$sep$_query'),
    headers: <String, String>{
      'User-Agent': _ua,
      'Referer': _ref,
      'Origin': _origin,
      'Accept': 'application/json, text/plain, */*',
      'Cookie': cookie,
    },
  );
}

Future<_HttpResult> _http(
  Uri uri, {
  String method = 'GET',
  String? body,
  Map<String, String> headers = const <String, String>{},
}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12);
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
      // 非 JSON：调用方看 text / status。
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

/// 把接口错误压成一句可读的话（优先 message，其次 code）。
String _errDetail(_HttpResult result) {
  final message = _str(result.json['message']);
  if (message.isNotEmpty) return message;
  final code = _intOrNull(result.json['code']);
  return code == null ? 'HTTP ${result.status}' : 'code=$code';
}

Map<String, dynamic>? _asMap(Object? value) {
  if (value is! Map) return null;
  final out = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) out[key] = entry.value;
  }
  return out;
}

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
  if (value == null) return '';
  if (value is String) return value.trim();
  return value.toString().trim();
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';

String _briefError(Object error) {
  final text = error is StateError ? error.message : error.toString();
  return _clip(text.replaceAll('\n', ' ').trim(), 120);
}

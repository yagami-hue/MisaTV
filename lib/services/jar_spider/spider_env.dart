import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 把已绑定的网盘凭据同步成 jar 系蜘蛛**期望的落盘格式**。
///
/// 为什么必须有这一层：加固壳 / jar 系蜘蛛（wex、AiNew* 等家族）**不读** ext 里的
/// cookie，而是各自去固定位置取。桌面端不替它们写文件就会：
///   · 详情里拿不到网盘资源（播放列表为空）；
///   · `playerContent` 直接回「还没有配置夸克 Cookie，请先去配置中心登录夸克」。
/// （2026-10-27 实测：写齐后同一次调用立刻返回可播的取流地址。）
///
/// 四条通道（对齐旧版 Electron 项目对同名 jar 的反编译实证）：
///  1. **wex 文件通道**：`<spiderCache>/files/TV/.quarkcookie`（裸 cookie 串）、`.ucpancookie`；
///  2. **wex SharedPreferences 种子**：`<spiderCache>/shared_prefs/seed.txt`，
///     行格式 `表名 \t 键 \t 值`（内置 prefs-shim 读取；表 `NewWexFnw_preferences`）；
///  3. **Pizazz/太太太硬了 通道**：`<java.io.tmpdir>/tvbox-ext/TVBox/{quark_cookie,uc_cookie,baidu}.txt`，
///     JSON `{"cookie":…}`（quark / uc 另补 `nickname` / `member_type` 占位，否则该族判「未登录」）；
///  4. **fty Cloud-drive 通道**：`<数据目录>/tvfan/Cloud-drive.txt`（或源 ext 里
///     `Cloud-drive` 指向的 JSON 文件），键 `quarkCookie` / `ucCookie`——fty 系在 init 时读它。
///  5. **TVBox 站点 Cookie 通道**：`<数据目录>/TVBox/{bili_cookie,115}.txt`（裸 cookie 串）。
///     哔哩系蜘蛛的 ext 写的是 `cookie: http://127.0.0.1:9978/file/TVBox/bili_cookie.txt`，
///     即由本地中继把该文件当 Cookie 读走；不写这个文件时蜘蛛拿到空 Cookie，
///     只能取到 360P / 480P，部分稿件直接判未登录。
///
/// 每次调用都重写（不再按签名跳过）：jar 可能自行清掉/改写这些文件，跳过写盘会让
/// 「已登录」在常驻进程里变成「未配置」。
class SpiderEnv {
  SpiderEnv._();

  /// wex 文件通道：provider → 文件名（裸 cookie）。
  static const _wexFiles = <String, List<String>>{
    'quark': ['.quarkcookie', 'quark_cookie.txt'],
    'uc': ['.ucpancookie', 'uc_cookie.txt'],
    'baidu': ['.baiducookie', 'baidu_cookie.txt', 'baidu.txt'],
    // 115 属于同一族的「网盘直连」，文件名为约定俗成的 `.115cookie`；
    // 不认识它的 jar 只会忽略这个文件，不会因此报错。
    '115': ['.115cookie', '115_cookie.txt'],
    'thunder': ['.xunleitoken', '.xunleicookie', '.thundertoken', 'xunlei_token.txt', 'xunlei_cookie.txt', 'thunder_token.txt', 'xunlei.txt'],
    'guangya': ['.guangyatoken', '.guangyacookie', 'guangya_token.txt', 'guangya_cookie.txt', 'guangya.txt'],
    };

  /// wex SharedPreferences 键：provider → `Wex_*` 键名。
  static const _wexPrefKeys = <String, List<String>>{
    'quark': ['Wex_quark_cookie'],
    'uc': ['Wex_ucpan_cookie'],
    'baidu': ['Wex_baidu_cookie'],
    '115': ['Wex_pan115_cookie', 'Wex_115_cookie'],
    'thunder': ['thunderCfg', 'Wex_thunder_token'],
    'guangya': ['Wex_GuangYa_Cache', 'Wex_guangya_token'],
    };

  static const _wexPrefsName = 'NewWexFnw_preferences';

  /// TVBox 站点 Cookie 通道：provider → `<数据目录>/TVBox/<文件名>`。
  ///
  /// 哔哩这一条是实测口径：订阅里的 `csp_Bili` / `csp_BiliYS` 把 ext 的
  /// `cookie` 直接写成这个中继地址，蜘蛛把响应体当 Cookie 用。
  static const _siteCookieFiles = <String, String>{
    'bili': 'bili_cookie.txt',
    '115': '115.txt',
    'thunder': 'xunlei_token.txt',
    'guangya': 'guangya_token.txt',
  };


  /// Pizazz 通道：provider → 文件名。
  static const _pizazzFiles = <String, String>{
    'quark': 'quark_cookie.txt',
    'uc': 'uc_cookie.txt',
    'baidu': 'baidu.txt',
    'aliyun': 'aliyun.txt',
  };

  /// 同步一次（文件都很小，每次调用都重写；内容未变时写入是幂等的）。
  ///
  /// [spiderCacheDir] = 传给 JVM 的 `-Dtvbox.spiderCacheDir`；
  /// [cookies] = provider → cookie（小写键，通常来自设置里的网盘账户）；
  /// [seed] = 额外 prefs 键（如 UC TV Token 的 `Wex_ucpan_token` / `Wex_ucpan_device_id`）；
  /// [dataDir] = 应用数据目录（Cloud-drive 默认落点 `<dataDir>/tvfan/Cloud-drive.txt`）；
  /// [ext] = 当前站点 ext（用于定位它声明的 `Cloud-drive` 文件）。
  static Future<void> sync({
    required String spiderCacheDir,
    required Map<String, String> cookies,
    Map<String, String> seed = const {},
    String? tmpDir,
    String? dataDir,
    String ext = '',
  }) async {
    final normalized = <String, String>{};
    cookies.forEach((key, value) {
      final k = key.trim().toLowerCase();
      final v = value.trim();
      if (k.isNotEmpty && v.isNotEmpty) normalized[k] = v;
    });
    final extra = <String, String>{};
    seed.forEach((key, value) {
      final k = key.trim();
      final v = value.trim();
      if (k.isNotEmpty && v.isNotEmpty) extra[k] = v;
    });

    // 各通道互相隔离：某一个文件被 JVM 占用时，不能让其余通道也不写。
    await _guard(() => _syncWexFiles(spiderCacheDir, normalized));
    await _guard(() => _syncWexSeed(spiderCacheDir, normalized, extra));
    await _guard(() => _syncPizazzFiles(tmpDir ?? Directory.systemTemp.path, normalized, extra));
    if (dataDir != null && dataDir.trim().isNotEmpty) {
      await _guard(() => _syncSiteCookieFiles(dataDir, normalized));
      await _guard(() => _syncCloudDrive(dataDir, normalized, ext));
    }
  }

  static Future<void> _guard(Future<void> Function() task) async {
    try {
      await task();
    } catch (_) {
      // 单个通道失败不阻断其它通道：下次调用会再试
    }
  }

  /// 通道 1：`<spiderCache>/files/TV/.quarkcookie`（裸 cookie，jar 里直接 trim 当 Cookie 用）。
  static Future<void> _syncWexFiles(String spiderCacheDir, Map<String, String> cookies) async {
    final dir = Directory(p.join(spiderCacheDir, 'files', 'TV'));
    _wexFiles.forEach((provider, names) {
      final value = cookies[provider] ?? '';
      if (value.isEmpty) {
        for (final name in names) {
          _delete(File(p.join(dir.path, name)));
        }
        return;
      }
      dir.createSync(recursive: true);
      for (final name in names) {
        File(p.join(dir.path, name)).writeAsStringSync(value, flush: true);
      }
    });
  }

  /// 通道 2：SharedPreferences 种子（内置 prefs-shim 读 `<base>/shared_prefs/seed.txt`）。
  static Future<void> _syncWexSeed(
    String spiderCacheDir,
    Map<String, String> cookies,
    Map<String, String> seed,
  ) async {
    final file = File(p.join(spiderCacheDir, 'shared_prefs', 'seed.txt'));
    final lines = <String>[
      for (final entry in _wexPrefKeys.entries)
        if ((cookies[entry.key] ?? '').isNotEmpty) for (final prefKey in entry.value)
          '$_wexPrefsName\t$prefKey\t${_clean(_formatWexPrefValue(prefKey, cookies[entry.key]!))}',
      for (final entry in seed.entries) '$_wexPrefsName\t${entry.key}\t${_clean(entry.value)}',
      // 桌面端没有 Go 代理（ARM32 + Android root 场景），强制 Java 多线程取流；
      // 否则原画线路必报「Go多线程启动失败」。
      '$_wexPrefsName\tpan.thread_proxy_mode\tjava',
    ];
    if (lines.isEmpty) {
      _delete(file);
      return;
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${lines.join('\n')}\n', flush: true);
  }
  static String _formatWexPrefValue(String prefKey, String raw) {
    if (prefKey != 'Wex_GuangYa_Cache' && prefKey != 'thunderCfg') return raw;
final trimmed = raw.trim();
Map<String, dynamic>? m;
if (trimmed.startsWith('{')) {
try {
final decoded = jsonDecode(trimmed);
if (decoded is Map) m = decoded.map((k, v) => MapEntry('$k', v));
} catch (_) {}
}
String pick(String a, String b, [String fallback = '']) {
final v = '${m?[a] ?? m?[b] ?? ''}'.trim();
return v.isNotEmpty ? v : fallback;
}
if (prefKey == 'Wex_GuangYa_Cache') {
return jsonEncode({
'token_type': pick('token_type', 'tokenType', 'Bearer'),
'access_token': m == null ? '' : pick('access_token', 'accessToken'),
'refresh_token': m == null ? trimmed : pick('refresh_token', 'refreshToken'),
});
}
    final deviceId = pick('deviceId', 'device_id');
    final deviceSign = pick('deviceSign', 'device_sign');
    final peerId = pick('peerId', 'peer_id');
   final resp = (m?['token_resp'] is Map) ? (m!['token_resp'] as Map).map((k, v) => MapEntry('$k', v)) : m;
   String pickResp(String a, String b, [String fallback = '']) { final v = '${resp?[a] ?? resp?[b] ?? ''}'.trim(); return v.isNotEmpty ? v : fallback; }
   final accessToken = resp == null ? '' : pickResp('accessToken', 'access_token'); final rawUserId = pickResp('userId', 'user_id'); final userId = rawUserId.isNotEmpty ? rawUserId : pickResp('sub', 'sub'); int expireTime = 0; final rawExpire = num.tryParse('${resp?['expireTime'] ?? resp?['expires_end'] ?? 0}')?.toInt() ?? 0; if (rawExpire > 0) { expireTime = rawExpire < 1000000000000 ? rawExpire * 1000 : rawExpire; } else { final expiresIn = num.tryParse('${resp?['expires_in'] ?? 0}')?.toInt() ?? 0; if (expiresIn > 0) expireTime = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000; }
    return jsonEncode({
      'accessToken': accessToken,
      'refreshToken': resp == null ? trimmed : pickResp('refreshToken', 'refresh_token'),
      'tokenType': pickResp('tokenType', 'token_type', 'Bearer'),
      'userId': userId,
      'expireTime': expireTime,
      'authVersion': 'downloadprovider-25.0.6.30',
      'authPackage': 'com.xunlei.downloadprovider',
      'authClientId': 'Xp6vsxz_7IYVw2BB',
      if (deviceId.isNotEmpty) 'deviceId': deviceId,
      if (deviceSign.isNotEmpty) 'deviceSign': deviceSign,
      if (peerId.isNotEmpty) 'peerId': peerId,
    });
  }
  
  /// 通道 5：`<数据目录>/TVBox/{bili_cookie,115}.txt`（裸 cookie 串）。
  ///
  /// 哔哩系蜘蛛的 ext 直接写 `http://127.0.0.1:9978/file/TVBox/bili_cookie.txt`，
  /// 由本地中继 `/file` 读走这段文本当 Cookie。
  ///
  /// **未配置时也要写成空文件**：文件缺失时中继回的是 404 + 正文「文件不存在」，
  /// 蜘蛛不校验状态码，会把那段中文当成 Cookie 拼进请求头，反而连
  /// 360P / 480P 都取不到。空文件才是「没有登录态」的正确表示。
  static Future<void> _syncSiteCookieFiles(
    String dataDir,
    Map<String, String> cookies,
  ) async {
    final dir = Directory(p.join(dataDir, 'TVBox'));
    dir.createSync(recursive: true);
    _siteCookieFiles.forEach((provider, name) {
      final file = File(p.join(dir.path, name));
      // 解绑时必须原地清空：删文件会让中继回 404 + 中文正文，蜘蛛把那段正文
      // 当 Cookie 拼进请求头，比「空 Cookie」更糟；换成旧 Cookie 更不行。
      file.writeAsStringSync(cookies[provider] ?? '', flush: true);
    });
  }

  /// 通道 3：`<java.io.tmpdir>/tvbox-ext/TVBox/*.txt`（JSON 对象，键 `cookie`）。
  static Future<void> _syncPizazzFiles(String tmpDir, Map<String, String> cookies, Map<String, String> seed) async {
    final dir = Directory(p.join(tmpDir, 'tvbox-ext', 'TVBox'));
    for (final entry in _pizazzFiles.entries) {
      final file = File(p.join(dir.path, entry.value));
      final value = (cookies[entry.key] ?? (entry.key == 'aliyun' ? cookies['ali'] : null) ?? '');
      if (value.isEmpty) {
        _delete(file);
        continue;
      }
      // quark / uc 的登录判定是「三字段均非空」→ 保留旧文件里的真实昵称/会员态，缺省占位。
      var nickname = 'MisaTV';
      var memberType = '1';
      var userId = '';
      var username = '';
      try {
          final old = jsonDecode(file.readAsStringSync());
          if (old is Map) {
            final n = '${old['nickname'] ?? ''}'.trim();
            final t = '${old['member_type'] ?? ''}'.trim();
            if (n.isNotEmpty) nickname = n;
            if (t.isNotEmpty) memberType = t;
            final u = '${old['userId'] ?? ''}'.trim();
            final un = '${old['username'] ?? ''}'.trim();
            if (u.isNotEmpty) userId = u;
            if (un.isNotEmpty) username = un;
          }
        } catch (_) {
          // 无旧文件 / 内容损坏 → 用占位
      }
      final body = <String, dynamic>{'cookie': value};
      if (entry.key == 'quark' || entry.key == 'uc') {
        body['nickname'] = nickname;
        body['member_type'] = memberType;
      }
    if (entry.key == 'baidu' && (seed['baidu_user_id'] ?? '').isNotEmpty) userId = seed['baidu_user_id']!;
      if (userId.isNotEmpty) body['userId'] = userId;
      if (username.isNotEmpty) body['username'] = username;
      dir.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(body), flush: true);
    }
  const tokenFiles = {'thunder': 'xunlei.txt', 'guangya': 'guangya.txt'};
for (final entry in tokenFiles.entries) {
  final file = File(p.join(dir.path, entry.value));
  final raw = (cookies[entry.key] ?? '').trim();
  if (raw.isEmpty) {
    _delete(file);
    continue;
  }
  var tokenType = 'Bearer';
  var accessToken = raw;
  var refreshToken = '';
  var sub = '';
  var expiresIn = 7200;
  var deviceId = '';
  if (raw.startsWith('{')) {
    try {
      final src = jsonDecode(raw);
      if (src is Map) {
        final resp = src['token_resp'] is Map ? src['token_resp'] as Map : src;
        final at = '${resp['access_token'] ?? resp['accessToken'] ?? ''}'.trim();
        if (at.isNotEmpty) accessToken = at;
        refreshToken = '${resp['refresh_token'] ?? resp['refreshToken'] ?? ''}'.trim();
        final tt = '${resp['token_type'] ?? resp['tokenType'] ?? ''}'.trim();
        if (tt.isNotEmpty) tokenType = tt;
        sub = '${resp['sub'] ?? resp['userId'] ?? ''}'.trim();
        final expRaw = resp['expires_in'] ?? resp['expireTime'];
        final exp = expRaw is num ? expRaw.toInt() : int.tryParse('${expRaw ?? ''}') ?? 7200;
        if (exp > 0) expiresIn = exp;
        deviceId = '${src['deviceid'] ?? src['deviceId'] ?? ''}'.trim();
      }
    } catch (_) {}
  }
  if (deviceId.isEmpty) {
    final seed = utf8.encode('MisaTV:${entry.key}:$accessToken');
    final bytes = List<int>.filled(16, 0);
    for (var i = 0; i < seed.length; i++) {
      bytes[i % 16] = (bytes[i % 16] * 31 + seed[i] + i) & 0xff;
    }
    deviceId = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
  final expiresEnd = DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
  final payload = {
    'token_resp': {
      'token_type': tokenType,
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'sub': sub,
      'expires_in': expiresIn,
      'expires_end': expiresEnd,
    },
    'deviceid': deviceId,
    'username': 'MisaTV',
  };
  dir.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode(payload), flush: true);
}
  }

  /// 通道 4：fty 系 `Cloud-drive` 配置（源在 init 时读取 quarkCookie / ucCookie）。
  ///
  /// 默认落点 `<数据目录>/tvfan/Cloud-drive.txt`；源 ext 里声明了相对路径时一并写入
  /// 该文件（绝对 http 地址属于远端配置，不碰）。
  static Future<void> _syncCloudDrive(
    String dataDir,
    Map<String, String> cookies,
    String ext,
  ) async {
    final targets = <String>{p.join(dataDir, 'tvfan', 'Cloud-drive.txt')};
    final rel = _cloudDriveRelPath(ext);
    if (rel.isNotEmpty) targets.add(p.join(dataDir, rel));
    for (final path in targets) {
      final file = File(path);
      var obj = <String, dynamic>{};
      try {
        if (file.existsSync()) {
          final old = jsonDecode(file.readAsStringSync());
          if (old is Map) obj = Map<String, dynamic>.from(old);
        }
      } catch (_) {
        // 首次/损坏 → 重建
      }
      // 凭据键必须完全由当前绑定状态决定：解绑后不能留着旧 Cookie。
      obj.remove('quarkCookie');
      obj.remove('ucCookie');
      obj.remove('baiduCookie');
      obj.remove('115Cookie');
      obj.remove('biliCookie');
      obj.remove('xunleiToken');
      obj.remove('xunleiCookie');
      obj.remove('thunderCookie');
      obj.remove('guangyaToken');
      obj.remove('guangyaCookie');
      final quark = cookies['quark'] ?? '';
      final uc = cookies['uc'] ?? '';
      final baidu = cookies['baidu'] ?? '';
      final pan115 = cookies['115'] ?? '';
      final bili = cookies['bili'] ?? '';
      final thunder = cookies['thunder'] ?? '';
      final guangya = cookies['guangya'] ?? '';
      if (quark.isNotEmpty) obj['quarkCookie'] = quark;
      if (uc.isNotEmpty) obj['ucCookie']       = uc;
      if (baidu.isNotEmpty) obj['baiduCookie'] = baidu;
      if (pan115.isNotEmpty) obj['115Cookie'] = pan115;
      if (bili.isNotEmpty) obj['biliCookie'] = bili;
      if (thunder.isNotEmpty) obj['xunleiToken'] = thunder;
      if (thunder.isNotEmpty) obj['xunleiCookie'] = thunder;
      if (thunder.isNotEmpty) obj['thunderCookie'] = thunder;
      if (guangya.isNotEmpty) obj['guangyaToken'] = guangya;
      if (guangya.isNotEmpty) obj['guangyaCookie'] = guangya;
      try {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(jsonEncode(obj), flush: true);
      } catch (_) {
        // 写入失败不阻断调用
      }
    }
  }

  /// 源 ext 的 `Cloud-drive` 若是本地相对路径 → 相对数据目录的规范路径。
  static String _cloudDriveRelPath(String ext) {
    final trimmed = ext.trim();
    if (trimmed.isEmpty) return '';
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return '';
      final value = '${decoded['Cloud-drive'] ?? ''}'.trim();
      if (value.isEmpty || RegExp(r'^https?://', caseSensitive: false).hasMatch(value)) {
        return '';
      }
      return value.replaceFirst(RegExp(r'^\.{0,2}/+'), '');
    } catch (_) {
      return '';
    }
  }

  /// 种子是「按行/按制表符切分」的纯文本，值里不能出现换行或制表符。
  static String _clean(String value) => value.replaceAll(RegExp(r'[\r\n\t]'), '').trim();

  static void _delete(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 文件被占用时忽略：下次同步会再试
    }
  }
}

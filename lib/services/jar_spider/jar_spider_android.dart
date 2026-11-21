import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/site_config.dart';
import '../../models/vod.dart';
import '../drive/drive_ext.dart';
import '../jvm/jvm_runtime.dart';
import '../movie_parser.dart';
import '../play_result_parser.dart';
import 'jar_spider.dart';
import 'spider_env.dart';
import '../../core/logging/app_log.dart';
import '../../core/net/app_http.dart';

/// 安卓版「jar / DEX 蜘蛛」服务：用 ART 的 `DexClassLoader` 直接加载蜘蛛 DEX，
/// 通过 MethodChannel(`com.kniephos.kniephos/spider`) 调用 CatVod 蜘蛛接口。
///
/// 这是桌面端「JRE17 + dex2jar + 外部 JVM 进程」的安卓等价实现，也是把
/// [dex2jar] 与 [unidbg] 两个能力落到安卓上的方式：
///   · dex2jar 的作用是把 `dex` 变成可运行的 class —— 安卓 ART 原生就能跑 `dex`，
///     所以不再需要 dex2jar，直接用 DexClassLoader 加载即可（见 SpiderHostPlugin）。
///   · unidbg 在桌面用「ARM 模拟器」解加固壳的 `.so` —— 安卓设备本身就是 ARM，
///     直接用 `System.load` 跑壳里的 `.so` 即可（见 SpiderHostPlugin.loadNative）。
///
/// 加固壳（Guard / DexNative）若已拿到解密后的「真实实现 payload jar」，同样用
/// DexClassLoader 加载；壳自带的 127.0.0.1 取流地址由插件内的进程内代理承接。
class JarSpiderAndroidService extends JarSpiderService {
  JarSpiderAndroidService({
    required super.driveTokens,
    required super.driveSeed,
    super.http,
  });

  static const _channel = MethodChannel('com.kniephos.kniephos/spider');

  /// 已加载到插件侧的蜘蛛（按 jar 指纹 + 类名 复用，避免重复加载）。
  final Map<String, _LoadedSpider> _loaded = {};
  final Map<String, Future<File>> _downloading = {};

  /// 上次同步给安卓宿主的网盘凭据签名。加固壳在 init() 时把 Cookie 读进内存，
  /// 登录 / 刷新后必须重新实例化，否则 playerContent 仍回「还没有配置夸克 Cookie」。
  String _credentialStamp = '';

  // ---------------------------------------------------------------------------
  // jar 取件（精简版：下载并缓存，校验结构）
  // ---------------------------------------------------------------------------

  String _jarUrlOf(SourceBean site) {
    final raw = site.jar.trim().isNotEmpty ? site.jar.trim() : globalJar.trim();
    if (raw.isEmpty) return '';
    return raw.split(';').first.trim();
  }

  String _className(SourceBean site) {
    var api = site.api.trim();
    final q = api.indexOf('?');
    if (q >= 0) api = api.substring(0, q);
    if (api.startsWith('csp_')) return 'com.github.catvod.spider.${api.substring(4)}';
    if (api.contains('.')) return api;
    return 'com.github.catvod.spider.$api';
  }

  Future<Directory> _cacheDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'jvm_cache', 'jars'));
    dir.createSync(recursive: true);
    return dir;
  }

  Future<File> _acquireJar(SourceBean site) async {
    final url = _jarUrlOf(site);
    if (url.isEmpty) {
      throw SourceException('该源没有配置 JAR 地址（站点 jar 与订阅 spider 都为空）');
    }
    final key = crypto.md5.convert(utf8.encode(url)).toString();
    final dir = await _cacheDir();
    final file = File(p.join(dir.path, '$key.jar'));
    if (file.existsSync() && file.lengthSync() > 1024) return file;

    final pending = _downloading[key];
    if (pending != null) {
      await pending;
      return file;
    }
    final task = _download(url, file);
    _downloading[key] = task;
    try {
      return await task;
    } finally {
      _downloading.remove(key);
    }
  }

  Future<File> _download(String url, File dest) async {
    final targets = <String>[
      url,
      url.replaceFirst(
        RegExp(r'https?://github\.com/'),
        'https://ghfast.top/https://github.com/',
      ),
      url.replaceFirst(
        RegExp(r'https?://github\.com/'),
        'https://gh-proxy.com/https://github.com/',
      ),
    ];
    for (final target in targets.toSet()) {
      try {
        final client = HttpClient();
        final req = await client.getUrl(Uri.parse(target));
        req.headers.set('User-Agent', 'okhttp/4.12.0');
        req.headers.set('Accept', '*/*');
        req.headers.set('Accept-Encoding', 'identity');
        final res = await req.close().timeout(const Duration(seconds: 30));
        if (res.statusCode != 200) {
          await res.drain<void>();
          client.close(force: true);
          continue;
        }
        final tmp = File('${dest.path}.part');
        final sink = tmp.openWrite();
        await for (final chunk in res) {
          sink.add(chunk);
        }
        await sink.close();
        client.close(force: true);
        if (tmp.lengthSync() < 1024) {
          tmp.deleteSync();
          continue;
        }
        if (!isSpiderJarBytes(tmp.readAsBytesSync())) {
          tmp.deleteSync();
          continue;
        }
        if (dest.existsSync()) dest.deleteSync();
        tmp.renameSync(dest.path);
        return dest;
      } catch (_) {
        // 试下一个镜像
      }
    }
    throw SourceException('JAR 下载失败：${Uri.parse(url).host}');
  }

  // ---------------------------------------------------------------------------
  // 加载到 ART（DexClassLoader）
  // ---------------------------------------------------------------------------

  Future<String> _spiderCacheDir() async {
    final support = await getApplicationSupportDirectory();
    return p.join(support.path, 'jvm_cache', 'spider');
  }

  /// 凭据签名：Cookie 或种子预置变了就得重新 init 壳（它只在启动时读一次）。
  String _currentStamp() {
    final buf = StringBuffer();
    final tokens = driveTokens?.call() ?? const <String, String>{};
    final keys = tokens.keys.toList()..sort();
    for (final key in keys) {
      buf.write('$key=${(tokens[key] ?? '').trim()};');
    }
    final seed = driveSeed?.call() ?? const <String, String>{};
    final seedKeys = seed.keys.toList()..sort();
    for (final key in seedKeys) {
      buf.write('seed:$key=${(seed[key] ?? '').trim()};');
    }
    return crypto.md5.convert(utf8.encode(buf.toString())).toString();
  }

  /// 双通道写凭据：Dart 侧落盘（桌面 JVM 口径的文件），Java 侧再按安卓口径
  /// 写 SharedPreferences / getFilesDir()/getDir("TV") —— 真实壳用
  /// `Init.context().getSharedPreferences()` 和 `getFilesDir()` 读登录态。
  Future<void> _syncCreds(SourceBean site) async {
    final support = await getApplicationSupportDirectory();
    final spiderDir = p.join(support.path, 'jvm_cache', 'spider');
    final cookies = Map<String, String>.from(
      driveTokens?.call() ?? const <String, String>{},
    );
    final seed = Map<String, String>.from(
      driveSeed?.call() ?? const <String, String>{},
    );
    try {
      await SpiderEnv.sync(
        spiderCacheDir: spiderDir,
        cookies: cookies,
        seed: seed,
        dataDir: support.path,
        ext: site.ext,
      );
    } catch (_) {
      // 单个通道失败不阻断其它通道
    }
    try {
      await _channel.invokeMethod<dynamic>('syncDrive', {
        'cookies': cookies,
        'seed': seed,
        'cacheDir': spiderDir,
      });
    } catch (_) {
      // 老版本宿主没有 syncDrive 时仍可用文件通道
    }
  }

  /// 只重建蜘蛛实例，保留宿主侧已解包的 ClassLoader / native 库 / 代理端口。
  Future<void> _resetSpiders() async {
    _loaded.clear();
    try {
      await _channel.invokeMethod<dynamic>('resetSpiders');
    } catch (_) {}
  }

  /// 网盘凭据变更（登录 / 刷新 / 判定访客）后让安卓蜘蛛重新 init。
  /// 基类只回收桌面 JVM 进程，对 DexClassLoader 里的常驻实例无效。
  @override
  Future<void> resetDriveState() async {
    _credentialStamp = '';
    await _resetSpiders();
    AppLog.i('jar', '网盘凭据变更：释放安卓蜘蛛实例，下次调用重新初始化');
  }

  @override
  Future<void> resetForNetworkChange() async {
    await resetDriveState();
  }

  Future<_LoadedSpider> _ensureLoaded(SourceBean site) async {
    final raw = await _acquireJar(site);
    final className = _className(site);
    final cacheKey = '${p.basenameWithoutExtension(raw.path)}|${site.key}|$className';
    final spiderDir = await _spiderCacheDir();

    final stamp = _currentStamp();
    if (stamp != _credentialStamp) {
      _credentialStamp = stamp;
      await _syncCreds(site);
      if (_loaded.isNotEmpty) {
        AppLog.i('jar', '网盘凭据已变化，重新初始化已加载的安卓蜘蛛');
        await _resetSpiders();
      }
    }

    final existing = _loaded[cacheKey];
    if (existing != null) return existing;

    final hasDex = await _jarHasDex(raw);
    if (!hasDex) {
      throw SourceException(
        '该蜘蛛是 class 格式，安卓需 dex/APK 格式（请用 TVBox 的 dex 版蜘蛛）',
      );
    }

    final ext = enrichSpiderExt(site.ext, driveTokens?.call() ?? const {});
    final reply = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'loadSpider',
      {
        'paths': [raw.path],
        'className': className,
        'ext': ext,
        'cacheDir': spiderDir,
        'instanceKey': cacheKey,
      },
    );
    final ok = reply?['ok'] == true;
    if (!ok) {
      throw SourceException('蜘蛛加载失败：${reply?['error'] ?? '未知错误'}');
    }
    final loaded = _LoadedSpider(
      key: cacheKey,
      proxyPort: (reply?['proxyPort'] as num?)?.toInt() ?? 0,
    );
    _loaded[cacheKey] = loaded;
    return loaded;
  }

  Future<bool> _jarHasDex(File jar) async {
    try {
      final bytes = jar.readAsBytesSync();
      final text = String.fromCharCodes(bytes);
      return text.contains('classes.dex');
    } catch (_) {
      return false;
    }
  }

  Future<String> _invoke(SourceBean site, String method, List<String> args) async {
    final loaded = await _ensureLoaded(site);
    final reply = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'invoke',
      {
        'method': method,
        'args': args,
        // 插件侧按类名保存多个蜘蛛实例，避免同时加载多个源时互相覆盖。
        'className': _className(site),
        'instanceKey': loaded.key,
      },
    );
    final ok = reply?['ok'] == true;
    if (!ok) {
      throw SourceException(reply?['error'] ?? '蜘蛛调用失败：$method');
    }
    final data = (reply?['data'] as String?) ?? '';
    return data;
  }

  String _rewriteLocalProxy(String url, int proxyPort) {
    if (proxyPort <= 0 || url.isEmpty) return url;
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final host = uri.host.toLowerCase();
    if (host != '127.0.0.1' && host != 'localhost') return url;
    // 只接管 /proxy 路由（对齐桌面端 spider_host.rewriteLocalProxy）：加固壳自己会
    // 起本地 HTTP 取流服务处理 /chunk 多线程分片下载，必须保持原样由壳本地服务器响应；
    // 若改写到进程内代理端口（只认 /proxy），播放器会拿到错误响应而 Source error。
    if (uri.path == '/proxy') {
      return uri.replace(host: '127.0.0.1', port: proxyPort).toString();
    }
    return url;
  }

  // ---------------------------------------------------------------------------
  // 公开接口（与桌面端 JarSpiderService 同签名，覆盖原 JVM 进程调用）
  // ---------------------------------------------------------------------------

  @override
  Future<CmsResult> home(SourceBean site) async {
    final text = await _homeText(site);
    final body = MovieParser.parseJson(text);
    var items = MovieParser.toItems(body.movie, site.key);
    final classes = body.classes;
    if (items.isEmpty) {
      final extra = await _invoke(site, 'homeVideoContent', const []);
      if (extra.trim().isNotEmpty) {
        final more = MovieParser.parseJson(extra);
        final extraItems = MovieParser.toItems(more.movie, site.key);
        if (extraItems.isNotEmpty) items = extraItems;
      }
    }
    if (items.isEmpty && classes.isNotEmpty) {
      try {
        return await category(site, classes.first.id, '1', const {});
      } catch (_) {
        // 回退失败不影响分类浏览
      }
    }
    return CmsResult(
      classes: classes,
      items: items,
      page: body.movie?.page ?? 0,
      pagecount: body.movie?.pagecount ?? 0,
      total: body.movie?.recordcount ?? 0,
    );
  }

  @override
  Future<CmsResult> category(
    SourceBean site,
    String tid,
    String pg,
    Map<String, String> filters,
  ) async {
    final extend = filters.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final text = await _invoke(site, 'categoryContent', [tid, pg, extend]);
    if (text.trim().isEmpty) return const CmsResult();
    final body = MovieParser.parseJson(text);
    return CmsResult(
      items: MovieParser.toItems(body.movie, site.key),
      page: body.movie?.page ?? 0,
      pagecount: body.movie?.pagecount ?? 0,
      total: body.movie?.recordcount ?? 0,
    );
  }

  @override
  Future<VodDetail?> detail(SourceBean site, String id) async {
    final text = await _invoke(site, 'detailContent', [id]);
    if (text.trim().isEmpty) return null;
    final body = MovieParser.parseJson(text);
    final detail = MovieParser.toDetail(body.movie, site.key);
    if (detail == null || detail.episodes.isEmpty) {
      final preview = text.length > 1200 ? text.substring(0, 1200) : text;
      AppLog.i('jar', 'detailContent 空剧集 site=${site.key} len=${text.length} raw=$preview');
    }
    return detail;
  }

  @override
  Future<List<VodItem>> search(SourceBean site, String keyword) async {
    final text = await _invoke(site, 'searchContent', [keyword, '1']);
    if (text.trim().isEmpty) return const [];
    final body = MovieParser.parseJson(text);
    return MovieParser.toItems(body.movie, site.key);
  }

  @override
  Future<String> live(SourceBean site, String url) async {
    return _invoke(site, 'liveContent', [url]);
  }

  @override
  Future<PlayResult?> play(
    SourceBean site,
    String flag,
    String id, {
    List<String> vipFlags = const [],
    bool retryAuth = true,
  }) async {
    var loaded = await _ensureLoaded(site);
    // 部分壳在 playerContent 时才去读 Cookie 文件，调用前再写一次。
    await _syncCreds(site);
    final text = await _invoke(site, 'playerContent', [
      flag,
      id,
      vipFlags.join(','),
    ]);
    if (text.trim().isEmpty) return null;
    var result = normalizeSpiderPlay(text, flag);

    // 已登录却仍回「还没有配置夸克 Cookie」：壳持有的是登录前 init 的空值。
    // 刷新会话 + 重新实例化蜘蛛后只重试一次（分享失效时也不至于卡死）。
    if (retryAuth && _needsDriveLogin(result)) {
      final provider = _driveProvider(flag);
      if (provider != null) {
        await refreshDriveSession?.call(provider);
        await resetDriveState();
        await _syncCreds(site);
        loaded = await _ensureLoaded(site);
        final retried = await _invoke(site, 'playerContent', [
          flag,
          id,
          vipFlags.join(','),
        ]);
        if (retried.trim().isNotEmpty) {
          result = normalizeSpiderPlay(retried, flag);
        }
        AppLog.i('jar', '网盘登录态刷新后重试播放 provider=$provider');
      }
    }

    if (result.url.isNotEmpty && result.url.contains('127.0.0.1')) {
      final url = _rewriteLocalProxy(result.url, loaded.proxyPort); if (url.contains(':5266')) { final target = Uri.tryParse(url)?.queryParameters['url'] ?? ''; final targetUri = Uri.tryParse(target); AppLog.i('jar', '5266 proxy target empty=${target.isEmpty} len=${target.length} scheme=${targetUri?.scheme ?? ''} host=${targetUri?.host ?? ''} path=${targetUri?.path ?? ''}'); }
      result = PlayResult(
        url: url,
        parse: result.parse,
        playUrl: result.playUrl,
        flag: result.flag,
        headers: result.headers,
        message: result.message,
      );
    }
    return result;
  }

  /// 豆瓣一类源偶发返回空 body（源站 15s 超时 / 限流），加固壳会直接
  /// `new JSONObject("")` 抛 `End of input at character 0`。短暂退避后重试一次，
  /// 仍失败就翻成人话，别把 Java 栈丢给用户。
  Future<String> _homeText(SourceBean site) async {
    try {
      return await _invoke(site, 'homeContent', const []);
    } on SourceException catch (e) {
      if (!_isEmptyPayloadError(e.message)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        return await _invoke(site, 'homeContent', const []);
      } on SourceException catch (_) {
        throw SourceException(
          '首页接口返回空内容（源站超时或被限流），请稍后重试或切换站点',
        );
      }
    }
  }

  bool _isEmptyPayloadError(String message) =>
      message.contains('End of input at character 0') ||
      (message.contains('End of input') && message.contains('JSONException'));

  bool _needsDriveLogin(PlayResult result) {
    if (result.url.trim().isNotEmpty) return false;
    final message = result.message.toLowerCase();
    return message.contains('cookie') ||
        message.contains('配置中心') ||
        message.contains('登录') ||
        message.contains('(auth)');
  }

  String? _driveProvider(String flag) {
    final lower = flag.toLowerCase();
    if (flag.contains('夸克') || lower.contains('quark')) return 'quark';
    if (flag.contains('UC') || lower.contains('ucpan')) return 'uc';
    if (flag.contains('百度') || lower.contains('baidu')) return 'baidu';
    if (lower.contains('115')) return '115';
    if (flag.contains('哔哩') || lower.contains('bili')) return 'bili';
    if (flag.contains('迅雷') || lower.contains('xunlei') || lower.contains('thunder')) return 'thunder';
    if (flag.contains('光鸭') || flag.contains('光雅') || lower.contains('guangya')) return 'guangya';
    return null;
  }

  /// 应用退出：先走基类的桌面进程清理（安卓侧是安全空操作），再释放插件侧已加载的
  /// 蜘蛛与进程内代理（等价于桌面端 kill spider-host / serve 进程）。
  @override
  Future<void> shutdown() async {
    await super.shutdown();
    await disposeAndroid();
  }

  /// 释放进程内加载的蜘蛛与代理（应用退出 / 源切换时调用）。
  Future<void> disposeAndroid() async {
    _loaded.clear();
    try {
      await _channel.invokeMethod<dynamic>('unload');
    } catch (_) {}
  }
}

class _LoadedSpider {
  _LoadedSpider({required this.key, required this.proxyPort});
  final String key;
  final int proxyPort;
}

/// 按平台创建 jar/DEX 蜘蛛服务：安卓走 ART(DexClassLoader)，其它平台走桌面/网页实现。
JarSpiderService createJarSpiderService({
  JvmRuntime? runtime,
  required Map<String, String> Function() driveTokens,
  required Map<String, String> Function() driveSeed,
  AppHttp? http,
}) {
  if (Platform.isAndroid) {
    return JarSpiderAndroidService(
      driveTokens: driveTokens,
      driveSeed: driveSeed,
      http: http,
    );
  }
  return JarSpiderService(
    runtime: runtime,
    driveTokens: driveTokens,
    driveSeed: driveSeed,
    http: http,
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/logging/app_log.dart';
import '../../core/logging/log_redact.dart';
import '../../core/net/app_http.dart';
import '../../core/net/doh_client_io.dart';
import '../../core/net/proxy_runtime.dart';
import '../../core/net/url_utils.dart';
import '../../core/utils/file_url.dart';
import '../../models/site_config.dart';
import '../../models/vod.dart';
import '../drive/baidu_native.dart';
import '../drive/drive_ext.dart';
import '../drive/quark_native.dart';
import '../drive/uc_native.dart';
import '../runtime_extension.dart';
import '../jvm/arm_bridge_runtime.dart';
import '../relay/local_relay.dart';
import '../jvm/jvm_runtime.dart';
import '../movie_parser.dart';
import '../play_result_parser.dart';
import 'bili_dash_fallback.dart';
import 'hyms_native.dart';
import 'spider_env.dart';
import 'spider_host.dart';

/// 下载到的内容 md5 与订阅声明不一致（通常是 CDN 回了错误页），可重连重试。
class _JarChecksumException implements Exception {
  const _JarChecksumException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 是否是「看起来能用」的蜘蛛 JAR：必须是 zip，且含 class / dex / 原生库 / assets。
///
/// 订阅里的 md5 经常是作者打包时的旧值，CDN 每次重打包都会变；用它区分
/// 「源站重新打包的正常 JAR」和「下到了错误页 / 空包」。
bool isSpiderJarBytes(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = entry.name.toLowerCase();
      if (name.endsWith('.class') ||
          name.endsWith('.dex') ||
          name.endsWith('.so') ||
          name.endsWith('.guard') ||
          name.startsWith('assets/')) {
        return true;
      }
    }
  } catch (_) {
    // 不是 zip / 文件损坏
  }
  return false;
}

/// 壳类是否属于嗷呜系（`*Amns` 或类名含 `Aowu`）。
///
/// 不能按整包判断：wex 聚合 jar 里同时有 `WoggGuard`（wex）和 `WoggAmns`
/// （嗷呜），按包扫会把 wex 源也挂上嗷呜影子类。
bool isAowuShellClass(String className) {
  final simple = className.replaceAll('/', '.').split('.').last.toLowerCase();
  return simple.endsWith('amns') || simple.contains('aowu');
}

/// 线路名 / 失败文案是否指向哔哩哔哩（`B站` / `哔哩` / `bilibili`）。
///
/// 单独抽成顶层函数：`_driveProviderFromFlag` 里 UC 用的是 `contains('uc')`，
/// 而 `bilibili` 不含 `uc`，B 站线路会一路落到 null，导致「Cookie 过期后刷新
/// 会话再重试」永远触发不到。抽出来也便于单测覆盖。
bool looksLikeBiliFlag(String flag) {
  if (flag.contains('哔哩') || RegExp(r'[Bb]\s*站').hasMatch(flag)) return true;
  final lower = flag.toLowerCase();
  return lower.contains('bilibili') ||
      RegExp(r'(^|[^a-z])bili([^a-z]|$)').hasMatch(lower);
}

/// 随包「真实实现」与订阅壳版本不匹配时的典型错误。
///
/// 这些错误继续跑只会得到空内容 / 难懂 NPE；命中后应改用解包 payload。
bool isJarShimMissMessage(String message) {
  return message.contains('ClassNotFoundException') ||
      message.contains('NoClassDefFoundError') ||
      message.contains('UnsatisfiedLinkError') ||
      message.contains('NoSuchMethodError') ||
      message.contains('ExceptionInInitializerError') ||
      message.contains('VerifyError') ||
      message.contains('ShellShim') ||
      message.contains('加固壳解包失败') ||
      message.contains('app-api-verify-sign') ||
      message.contains('Empty key') ||
      message.contains('JSONObject text must begin') ||
      message.contains('无真实实现可加载') ||
      (message.contains('getSharedPreferences') &&
          message.contains('is null')) ||
      (message.contains('Spider.init') && message.contains('is null'));
}

/// TVBox JAR / DEX 蜘蛛（type=3，api 为 `csp_*` 或类名）。
///
/// 流程：下载 jar → 保留 assets 资源 → 若含 classes.dex 则用 dex2jar 转换 →
/// 反射调用运行器（随 stubs.jar 内置的 `SpiderRunner`）。
///
/// 加固壳（Guard / DexNative，jar 内含 ARM `.so`）：
///   · 首次：用可选下载的 unidbg ARM 桥**解包一次**，把壳里加密的 payload
///     转成普通 jar 并缓存到 `<cache>/payloads/<jarKey>/`；
///   · 之后：用 shell-shim（纯 Java 影子 DexNative）直接加载缓存里的真实实现，
///     不再启动模拟器，单次调用约 2–3 秒。
class JarSpiderService {
  JarSpiderService({
    JvmRuntime? runtime,
    this.driveTokens,
    this.driveSeed,
    this.http,
  }) : _runtimeOverride = runtime,
       _hymsNative = http == null ? null : HymsNative(http);

  /// 供壳外回退（如 B 站 DASH → durl）直接发请求用。
  final AppHttp? http;

  final JvmRuntime? _runtimeOverride;
  JvmRuntime get runtime => _runtimeOverride ?? JvmRuntime.instance;

  /// 海绵（HmysGuard）旧壳只跑一段 collection；这里补上 result → collection
  /// 两段换链，避免壳返回空的 `url/ck`。
  final HymsNative? _hymsNative;

  final Map<String, String> Function()? driveTokens;

  /// 网盘登录附带的其他种子键（如 UC TV Token 的 `Wex_ucpan_token` / `Wex_ucpan_device_id`）。
  final Map<String, String> Function()? driveSeed;

  /// 播放失败且怀疑网盘凭据过期时按需刷新会话（夸克 `/member` 会补发新的
  /// `__puus`，对齐 winbox：蜘蛛 init 只读一次 cookie，旧值会让 download 404）。
  Future<void> Function(String provider)? refreshDriveSession;

  /// 正在为播放而常驻的取流进程（壳内自解链 / 多线程取流服务就在它内存里）。
  JarSpiderHost? _playHost;
  Timer? _playReaper;

  /// 播放回退专用的 serve host（唯一 pool key，播放结束后直接关闭）。
  JarServeHost? _playServeHost;
  String? _playServeKey;

  /// 当前常驻取流 JVM 的宿主代理端口（0 = 没有可用进程）。
  ///
  /// 加固壳返回的 `do=hmys` 等地址依赖该 JVM 内存里的状态；本地中继把
  /// `/proxy?do=…` 原样转发到这里，壳生成的清单内部分片地址才不会失效。
  int get activeHostProxyPort {
    final play = _playHost;
    if (play != null && play.alive && play.proxyPort > 0) return play.proxyPort;
    final serve = _playServeHost;
    if (serve != null && serve.alive && serve.proxyPort > 0) {
      return serve.proxyPort;
    }
    return 0;
  }

  /// 本次会话里确认过「`playerContent` 不会自己解 CDN 挑战」的源。
  /// 之后播同一源直接走专用 serve host，不再先陪跑一次必然失败的 `--hold`。
  final Set<String> _servePlaySites = {};

  /// 浏览 / 搜索用常驻进程池：同一份 jar 最多 3 个 host。
  ///
  /// serve 在主线程顺序执行（加固壳在池化线程上解析不出站点基址），所以并发度
  /// 只能靠多开少量 JVM；3 个 host 足够让首屏结果持续流入，又把内存压在
  /// 单次搜索同时 6 个一次性 JVM 的一半左右。
  final Map<String, List<JarServeHost>> _servePools = {};
  final Map<String, int> _serveStarting = {};
  final Map<String, int> _serveHostSeq = {};
  final Map<String, Timer> _serveIdleTimers = {};
  static const _servePoolMax = 3;
  static const _serveIdleDefault = Duration(seconds: 45);
  static const _serveIdleKeepWarm = Duration(minutes: 2);
  Duration _serveIdleTimeout = _serveIdleDefault;

  /// 性能设置：搜索 / 浏览结束后让常驻 JVM 多保留一段时间，减少再次冷启动。
  void setKeepHostsWarm(bool value) {
    _serveIdleTimeout = value ? _serveIdleKeepWarm : _serveIdleDefault;
  }

  /// 已经预热过（或正在预热）的源：同一个源只预热一次，避免反复拉起 JVM。
  final Set<String> _warmed = {};

  /// 后台预热一个 JAR 源的常驻 host。
  ///
  /// 为什么需要它：JAR 源的**首次**调用要下载 JRE、做 jar→dex 转换、起 JVM、
  /// 蜘蛛 `init()` 解挑战，几十秒起步。等用户点搜索才开始，第一批结果注定慢。
  /// 应用启动后在后台把这件事先做掉，用户真正搜索时只剩一次普通请求。
  ///
  /// 约束：
  ///   · 绝不抛错 —— 预热失败不应影响启动，失败就让真正搜索时重试；
  ///   · 不写健康度 —— 它不代表用户可见的一次失败；
  ///   · 由调用方用 [runtimeReady] 把关：JVM 运行时没装时直接跳过，
  ///     否则预热会静默下载几十 MB 运行时，用户会以为软件卡住了。
  Future<bool> warmUpSite(
    SourceBean site, {
    required bool runtimeReady,
    Duration? timeout,
  }) async {
    if (!site.isJarSpider) return false;
    if (!runtimeReady) return false;
    final key = '${site.key}\u0000${site.jar}\u0000${site.api}';
    if (!_warmed.add(key)) return true; // 已经预热过 / 正在预热

    try {
      // 用 home 而不是直接起 host：home 走的是和真实搜索完全相同的链路
      // （加载脚本 → 起 serve host → spider.init → 首次请求），预热才有意义。
      await home(site).timeout(timeout ?? const Duration(seconds: 90));
      _touchServe(site.key);
      AppLog.i('jar', '预热完成 ${site.key}');
      return true;
    } catch (e) {
      // 允许下次重试：预热失败不该被永久记住（可能只是当时网络抖了）。
      _warmed.remove(key);
      AppLog.i('jar', '预热跳过 ${site.key}：${redactUrl('$e')}');
      return false;
    }
  }

  /// 该源是否已经预热过（诊断 / 测试用）。
  bool isWarmed(SourceBean site) =>
      _warmed.contains('${site.key}\u0000${site.jar}\u0000${site.api}');

  /// 配置级的全局 spider jar（`SiteConfig.spider`），站点自带 `jar` 时优先站点。
  String globalJar = '';

  final Map<String, String> _converted = {};
  final Map<String, Future<String>> _converting = {};
  final Map<String, List<String>> _zipNamesCache = {};
  final Map<String, int> _zipSizeCache = {};

  /// 无 `.so/.guard` 的新壳（aowu 等）：dex 里是否带壳入口（按 jar 指纹缓存）。
  final Map<String, bool> _shellEntryCache = {};

  /// 转换产物格式版本：修复规则（super 自递归 / NEW 抽象类误译）变化时 +1。
  ///
  /// 产物文件名带版本号，旧产物不会再被复用；被占用的旧文件留到下次清理。
  static const _convertedRev = 1;

  /// 解包后仍需 ARM native 的类（`jarKey|className`），本次会话内不再试 shell-shim。
  final Set<String> _nativeOnly = {};

  /// 实测会让 JVM 直接崩掉（hs_err / 进程退出）的 payload：本次会话内不再尝试。
  ///
  /// 缓存里同一份加固壳可能有多个 payload，热更新拉到的新包常与本机兼容层不匹配，
  /// 表现为加载到一半 `EXCEPTION_ACCESS_VIOLATION`；继续拿它试只会反复拖崩进程。
  final Set<String> _brokenPayloads = {};

  /// 每次调用最多试几个 payload 包（坏包会白起一只 JVM，别无限试）。
  static const _payloadMaxCandidates = 4;

  /// `payloads/<jar>/index.json` 的内存镜像（className → 已验证可用的包文件名）。
  final Map<String, Map<String, String>> _payloadIndexCache = {};

  /// 同一 jar 的周更只跑一次，避免并发请求同时下载/替换。
  final Map<String, Future<void>> _jarRefreshLocks = {};

  /// 原生解包串行闸门：多个搜索 worker 同时首次命中加固壳时，只允许一只 unidbg
  /// 进程在跑；排队者拿到锁后若 payload 已生成就直接走快路径（避免 3×768m 同时驻留）。
  Future<void> _nativeGate = Future<void>.value();

  /// 系统代理只解析一次（环境变量优先，其次 Windows IE 代理设置）。
  String? _proxyAddress;
  bool _proxyLoaded = false;

  // ---------------------------------------------------------------------------
  // 调用接口（与 JS / PY 蜘蛛同构）
  // ---------------------------------------------------------------------------
  Future<CmsResult> home(SourceBean site) async {
    final text = await _invokeWithAowuFallback(site, 'homeContent', const []);
    _throwIfError(text);
    final body = MovieParser.parseJson(text);
    var items = MovieParser.toItems(body.movie, site.key);
    final classes = body.classes;
    if (items.isEmpty) {
      final extra = await _invokeWithAowuFallback(
        site,
        'homeVideoContent',
        const [],
      );
      if (extra.trim().isNotEmpty) {
        final more = MovieParser.parseJson(extra);
        final extraItems = MovieParser.toItems(more.movie, site.key);
        if (extraItems.isNotEmpty) items = extraItems;
      }
    }
    if (items.isEmpty && classes.isNotEmpty) {
      try {
        final fallback = await category(site, classes.first.id, '1', const {});
        if (fallback.items.isNotEmpty) {
          return CmsResult(
            classes: classes,
            items: fallback.items,
            page: fallback.page,
            pagecount: fallback.pagecount == 0 ? 1 : fallback.pagecount,
            total: fallback.total == 0 ? fallback.items.length : fallback.total,
            homeFallback: true,
          );
        }
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
    final text = await _invokeWithAowuFallback(site, 'categoryContent', [
      tid,
      pg,
      extend,
    ]);
    _throwIfError(text);
    if (text.trim().isEmpty) return const CmsResult();
    final body = MovieParser.parseJson(text);
    return CmsResult(
      items: MovieParser.toItems(body.movie, site.key),
      page: body.movie?.page ?? 0,
      pagecount: body.movie?.pagecount ?? 0,
      total: body.movie?.recordcount ?? 0,
    );
  }

  Future<VodDetail?> detail(SourceBean site, String id) async {
    final text = await _invokeWithAowuFallback(site, 'detailContent', [id]);
    _throwIfError(text);
    if (text.trim().isEmpty) return null;
    final body = MovieParser.parseJson(text);
    return MovieParser.toDetail(body.movie, site.key);
  }

  Future<List<VodItem>> search(SourceBean site, String keyword) async {
    final text = await _invokeWithAowuFallback(site, 'searchContent', [
      keyword,
      '1',
    ]);
    _throwIfError(text);
    if (text.trim().isEmpty) return const [];
    final body = MovieParser.parseJson(text);
    return MovieParser.toItems(body.movie, site.key);
  }

  /// 百度 / UC / 夸克 分享型播放的原生「免转存」解链（只读分享，不写用户网盘）。
  ///
  /// 返回 null 表示：不是网盘分享、未绑定账号或解链失败 —— 交回 jar 兜底。
  Future<PlayResult?> _resolveNativeDrivePlay(String flag, String id) async {
    final tokens = driveTokens?.call() ?? const <String, String>{};
    final baiduCookie = (tokens['baidu'] ?? '').trim();
    if (looksLikeBaiduShare(id)) {
      if (baiduCookie.isEmpty) {
        AppLog.w('drive', '百度分享播放但未绑定账号，回退 jar：${shorten(id, 80)}');
      } else {
        final link = await resolveBaiduDirect(
          id,
          cookie: baiduCookie,
          episodeName: extractBaiduInnerName(id),
        );
        if (link.ok) {
          AppLog.i('drive', '百度免转存直链 ${shorten(link.url, 120)}');
          return PlayResult(url: link.url, flag: flag, headers: link.headers);
        }
        AppLog.w('drive', '百度免转存解链失败：${link.reason}');
      }
    }
    final ucCookie = (tokens['uc'] ?? '').trim();
    if (looksLikeUcShare(id, flag: flag)) {
      if (ucCookie.isEmpty) {
        AppLog.w('drive', 'UC 分享播放但未绑定账号，回退 jar：${shorten(id, 80)}');
      } else {
        final link = await resolveUcDirect(
          id,
          cookie: ucCookie,
          flag: flag,
          episodeName: extractUcShare(id, flag: flag)?.name ?? '',
        );
        if (link.ok) {
          AppLog.i('drive', 'UC 免转存直链 ${shorten(link.url, 120)}');
          return PlayResult(url: link.url, flag: flag, headers: link.headers);
        }
        AppLog.w('drive', 'UC 免转存解链失败：${link.reason}');
      }
    }
    // 夸克排在自己的分支：fty 系壳会把夸克分享塞进 `{sId,fid,share_fid_token,…}`
    // 这类集参数里，只有线路名明确是夸克时才解释，避免和 UC 抢同一批 id。
    final quarkCookie = (tokens['quark'] ?? '').trim();
    if (looksLikeQuarkShare(id, flag: flag)) {
      if (quarkCookie.isEmpty) {
        AppLog.w('drive', '夸克分享播放但未绑定账号，回退 jar：${shorten(id, 80)}');
      } else {
        final ref = extractQuarkShare(id, flag: flag);
        final link = await resolveQuarkDirect(
          id,
          cookie: quarkCookie,
          flag: flag,
          episodeName: ref?.name ?? '',
        );
        if (link.ok) {
          AppLog.i('drive', '夸克免转存直链 ${shorten(link.url, 120)}');
          return PlayResult(url: link.url, flag: flag, headers: link.headers);
        }
        AppLog.w('drive', '夸克免转存解链失败：${link.reason}');
      }
    }
    return null;
  }

  Future<PlayResult?> play(
    SourceBean site,
    String flag,
    String id, {
    List<String> vipFlags = const [],
    bool retryAuth = true,
  }) async {
    await _releasePlayHost();
    if (site.api.toLowerCase().contains('hmys')) {
      final hymsUrl = await _hymsNative?.resolve(id);
      if (hymsUrl != null) {
        AppLog.i('jar', '海绵原生两段取链成功 url=${shorten(hymsUrl, 140)}');
        return PlayResult(
          url: hymsUrl,
          flag: flag,
          headers: const {'Accept': '*/*', 'User-Agent': 'Mozi'},
        );
      }
    }
    // 播放地址本身就是百度 / UC 分享（含 FTY 描述符）：先走原生「免转存」取链，
    // 绕开 jar 侧依赖 App「do=pan」路由的地址（桌面端没有该路由）。
    final native = await _resolveNativeDrivePlay(flag, id);
    if (native != null) return native;
    // 已知这只蜘蛛的 playerContent 不处理 CDN 挑战：直接走专用 serve host，
    // 不再先起一只必然失败的 --hold 进程。
    if (_servePlaySites.contains(site.key)) {
      final preferred = await _playViaServe(site, flag, id, vipFlags);
      if (preferred != null) return preferred;
    }
    // 加固壳的取流地址指向**这个 JVM 自己**（壳内多线程取流服务 / 宿主代理），
    // 所以播放必须在「打完结果后不退出」的常驻进程里跑。
    var text = await _invokePlay(
      site,
      flag,
      id,
      vipFlags,
      retryAuth: retryAuth,
    );
    var result = normalizeSpiderPlay(text, flag);
    // ★ 已绑定却仍收到「还没有配置 XX Cookie / 请先去配置中心」或夸克 download 404：
    // 常驻 JVM 只在 init 读一次 cookie，且 `__puus` 会过期；先按 winbox 的方式刷新会话
    // （夸克 `/member` 补发新的 `__puus`，判定访客时直接清空凭据），再重写 cookie 文件、
    // 重置蜘蛛进程后重试一次。
    final authProvider = _authProviderOf(result, flag: flag);
    if (retryAuth && authProvider != null) {
      var bound = (driveTokens?.call()[authProvider] ?? '').trim();
      if (bound.isNotEmpty) {
        await refreshDriveSession?.call(authProvider);
        bound = (driveTokens?.call()[authProvider] ?? '').trim();
      }
      if (bound.isNotEmpty) {
        await _resetForDriveChange();
        text = await _invokeWithAowuFallback(site, 'playerContent', [
          flag,
          id,
          vipFlags.join(','),
        ], hold: true);
        result = normalizeSpiderPlay(text, flag);
      }
    }
    // ★ 壳只下发 DASH 时的回退（「高中课堂 / 少儿教育」这类 wex 源的常见形态）。
    // 壳的 playerContent 给的是 127.0.0.1:<jvm>/proxy?do=bili&...&type=mpd +
    // application/dash+xml，而内置内核（libmdk + 随包 ffmpeg）只有 dash muxer、
    // 没有 dashdec，MPD 一定播不了。改走官方 playurl?fnval=1 的 durl 单文件 mp4
    // （音轨已在内），这是内核对 mov/mp4 能解的形态。
    //
    // 必须在 _keepPlayHost 之前做：回退成功后壳的常驻进程就没必要再留。
    if (result.url.isNotEmpty &&
        BiliDashFallback.looksLikeShellDash(result.url)) {
      final client = http;
      final fallback = client == null
          ? null
          : await BiliDashFallback.resolve(
              client,
              result.url,
              cookie: (driveTokens?.call()['bili'] ?? '').trim(),
              flag: result.flag.isEmpty ? flag : result.flag,
            );
      if (fallback != null) {
        await _releasePlayHost();
        return fallback;
      }
      AppLog.w(
        'jar',
        'DASH 回退未成功，保留原地址（播放器将报不支持） ${site.key} '
        'flag=$flag url=${redactUrl(result.url)}',
      );
    }
    final host = _playHost;
    if (text.trim().isEmpty) {
      await _releasePlayHost();
      return null;
    }
    if (result.url.isEmpty && result.message.trim().isNotEmpty) {
      // 源侧业务失败（如「LIBVIO 播放参数获取失败」）：记下集数 id 与原始提示，
      // 方便判断是壳内解析不到播放参数，还是订阅里的 domain/payload 已过期。
      AppLog.w(
        'jar',
        'playerContent 未取到地址 ${site.key} flag=$flag id=${shorten(id, 100)} '
            'msg=${shorten(result.message, 160)}',
      );
    }
    // ★ 部分加固壳源（如 LIBVIO）只在浏览路径里处理 CDN 的 js-pow 挑战：
    // `f()` 会解挑战并把 `__cdn_verified` 写进蜘蛛实例内存里的 Cookie，而
    // `playerContent` 直接 GET 播放页 —— 全新的 `--hold` 进程没有这份 Cookie，
    // 拿到的是 403 挑战页，于是报「播放参数获取失败」。回退到已经服务过
    // home/detail 的 serve host（同一 SpiderPool 实例、Cookie 还在）再取一次。
    if (result.url.isEmpty &&
        result.message.trim().isNotEmpty &&
        _looksLikeCdnChallengeFailure(result.message)) {
      AppLog.w('jar', '播放参数为空，回退专用 serve host 重试 ${site.key} flag=$flag');
      await _releasePlayHost();
      final fallback = await _playViaServe(site, flag, id, vipFlags);
      if (fallback != null) {
        _servePlaySites.add(site.key);
        return fallback;
      }
      return result;
    }
    if (host != null) {
      if (result.url.isNotEmpty && result.url.contains('127.0.0.1')) {
        // 宿主网盘路由优先交给本地中继（桌面端 JVM 不提供 do=pan）。
        final relayUrl = _relayHostProxyUrl(result.url);
        if (relayUrl != null) {
          _keepPlayHost(host);
          return PlayResult(
            url: relayUrl,
            parse: result.parse,
            playUrl: result.playUrl,
            flag: result.flag,
            headers: result.headers,
            message: result.message,
          );
        }
        // 宿主代理形态（9978 / -1）按本 JVM 的实际端口对齐；壳内端口原样保留。
        // 壳的 thread/chunk 会被服务端夹到 1..10，壳却常发 16/32，白丢并发。
        final url = tuneChunkUrl(rewriteLocalProxy(result.url, host.proxyPort));
        _keepPlayHost(host);
        return PlayResult(
          url: url,
          parse: result.parse,
          playUrl: result.playUrl,
          flag: result.flag,
          headers: result.headers,
          message: result.message,
        );
      }
      await _releasePlayHost();
    }
    // 一次性进程（没有常驻 host）返回 /chunk、/proxy 这类本机取流地址时，进程退出后
    // 地址必然失效（播放器只会报 invalid or unsupported media）；不要把它交给播放器。
    if (result.url.isNotEmpty && _isDeadLocalPlayUrl(result.url)) {
      // 宿主网盘路由（`/proxy?do=pan…`）在桌面端由本地中继实现：改指中继而不是丢弃。
      final relayUrl = _relayHostProxyUrl(result.url);
      if (relayUrl != null) {
        AppLog.i('jar', '宿主网盘路由改走中继 ${shorten(relayUrl, 120)}');
        return PlayResult(
          url: relayUrl,
          parse: result.parse,
          playUrl: result.playUrl,
          flag: result.flag,
          headers: result.headers,
          message: result.message,
        );
      }
      return PlayResult(
        url: '',
        flag: result.flag,
        message: '取流进程未能常驻，播放地址已失效，请重试一次',
      );
    }
    return result;
  }

  /// `127.0.0.1:<JVM 端口>/proxy?do=…` → 本地中继的同路由地址。
  ///
  /// 桌面端没有原 App 的宿主取流进程，但中继已经实现了 `do=pan/do=proxy`，
  /// 只要把端口换成中继端口即可继续播放。
  ///
  /// 中继不认识的宿主路由（`do=bili` / `do=biliys` / `do=ali` / `do=czspp` …）
  /// 不能在这里放行：中继只会回 400，播放器拿到 400 仍然是「打不开」。
  /// 这类地址只有**产出它的那个 JVM**能解，必须走常驻 host 的 `_jvmProxyPort`。
  String? _relayHostProxyUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.path != '/proxy') return null;
    final doValue = (uri.queryParameters['do'] ?? '').toLowerCase();
    if (doValue != 'pan' &&
        doValue != 'proxy' &&
        doValue != 'url' &&
        doValue != 'img') {
      return null;
    }
    final relay = LocalRelay.instance;
    if (!relay.running) return null;
    return Uri.parse('${relay.baseUrl}/proxy')
        .replace(queryParameters: uri.queryParameters)
        .toString();
  }

  /// 播放回退：起一只**专用** serve host 来取链。
  ///
  /// 浏览池里的实例可能已经跑了几十分钟，`__cdn_verified` 会过期；而且
  /// `homeContent` 有时会命中实例内缓存，不再下发新的 set-cookie。新实例的
  /// `init` 会重新解挑战，`homeContent` 再把 `__cdn_verified` 吸收进实例 Cookie，
  /// 这样 `playerContent` 才能拿到真正的播放页而不是 403 挑战页。
  Future<PlayResult?> _playViaServe(
    SourceBean site,
    String flag,
    String id,
    List<String> vipFlags,
  ) async {
    JarServeHost? host;
    String? hostKey;
    void capture(JarServeHost h, String k) {
      if (!h.alive) return;
      host = h;
      hostKey = k;
    }

    final suffix = '|play-${DateTime.now().microsecondsSinceEpoch}';
    try {
      await _invokeWithAowuFallback(
        site,
        'homeContent',
        const [],
        hold: false,
        servePoolSuffix: suffix,
        serveHostListener: capture,
      );
      final current = host;
      if (current == null || !current.alive) return null;
      AppLog.i('jar', '播放回退专用 host pid=${current.pid} key=$hostKey');
      final text = await _callServeHost(current, site, 'playerContent', [
        flag,
        id,
        vipFlags.join(','),
      ]);
      final result = normalizeSpiderPlay(text, flag);
      if (result.url.isNotEmpty) {
        return _pinServePlayResult(result, host, hostKey);
      }
      AppLog.w(
        'jar',
        '播放回退专用 host 仍失败 ${site.key} flag=$flag '
            'msg=${shorten(result.message, 160)}',
      );
      return null;
    } on SourceException catch (e) {
      AppLog.w(
        'jar',
        '播放回退专用 host 失败 ${site.key} flag=$flag: ${shorten(e.message, 160)}',
      );
      return null;
    }
  }

  /// 回退结果若是本机取流地址，把 serve host pin 到播放结束；远端直链则不用留进程。
  PlayResult? _pinServePlayResult(
    PlayResult result,
    JarServeHost? host,
    String? hostKey,
  ) {
    final local =
        result.url.contains('127.0.0.1') || result.url.contains('localhost');
    if (!local) return result;
    // 没有常驻 host 的本机地址（一次性进程返回的 /chunk、/proxy）必然已失效。
    if (host == null || hostKey == null || !host.alive) return null;
    final url = tuneChunkUrl(rewriteLocalProxy(result.url, host.proxyPort));
    _keepPlayServeHost(host, hostKey);
    AppLog.i(
      'jar',
      '播放回退 serve host 成功 pid=${host.pid} proxy=${host.proxyPort} '
          'url=${redactUrl(url)}',
    );
    return PlayResult(
      url: url,
      parse: result.parse,
      playUrl: result.playUrl,
      flag: result.flag,
      headers: result.headers,
      message: result.message,
    );
  }

  /// 在指定 serve host 上直接调一次蜘蛛方法（复用它的 SpiderPool 实例与 Cookie）。
  Future<String> _callServeHost(
    JarServeHost host,
    SourceBean site,
    String method,
    List<String> args,
  ) async {
    final ext = enrichSpiderExt(site.ext, driveTokens?.call() ?? const {});
    ServeReply reply;
    try {
      reply = await host.call(
        className: _className(site),
        method: method,
        args: [ext, ...args],
        timeout: Duration(seconds: site.timeout + 120),
      );
    } on ServeHostException catch (e) {
      throw SourceException('常驻蜘蛛调用失败：${e.message}');
    }
    if (!reply.ok) {
      throw SourceException(await _errorText(reply.data, host.errorTail));
    }
    return reply.data.trim();
  }

  /// 消息是否像「播放页被 CDN 挑战拦下」：这类失败可以换有会话的 serve host 重试。
  bool _looksLikeCdnChallengeFailure(String message) {
    return message.contains('播放参数获取失败') ||
        message.contains('解析参数获取失败') ||
        message.contains('验证跳转') ||
        message.contains('__cdn') ||
        message.contains('人机验证') ||
        message.contains('请先完成验证');
  }

  /// 播放取链：失败若是「网盘接口没返回数据」这类登录态问题，刷新会话后重试一次。
  ///
  /// 加固壳的 playerContent 抛 `JSONException: JSONObject["data"] not found`
  /// 时通常不是壳不兼容，而是夸克/UC 的分享接口返回了错误（分享失效 / `__puus` 过期）。
  /// 不能把它当成 payload 崩溃丢掉，否则整个会话都会退化到一次性进程（地址随即失效）。
  Future<String> _invokePlay(
    SourceBean site,
    String flag,
    String id,
    List<String> vipFlags, {
    required bool retryAuth,
  }) async {
    try {
      return await _invokeWithAowuFallback(site, 'playerContent', [
        flag,
        id,
        vipFlags.join(','),
      ], hold: true);
    } on SourceException catch (e) {
      final provider = _driveProviderFromFlag(flag);
      if (!retryAuth ||
          provider == null ||
          !_looksLikeDriveApiError(e.message)) {
        rethrow;
      }
      final bound = (driveTokens?.call()[provider] ?? '').trim();
      if (bound.isEmpty) rethrow;
      AppLog.w(
        'jar',
        'playerContent 失败，刷新 $provider 登录态后重试: ${shorten(e.message, 200)}',
      );
      await refreshDriveSession?.call(provider);
      await _resetForDriveChange();
      try {
        return await _invokeWithAowuFallback(site, 'playerContent', [
          flag,
          id,
          vipFlags.join(','),
        ], hold: true);
      } catch (retryError, stack) {
        AppLog.e('jar', '刷新 $provider 登录态后重试仍失败', retryError, stack);
        rethrow;
      }
    }
  }

  bool _looksLikeDriveApiError(String message) {
    return message.contains('JSONObject["data"] not found') ||
        message.contains('JSONException') ||
        message.contains('shareInfo') ||
        message.contains('转存失败');
  }

  String? _driveProviderFromFlag(String flag) {
    final lower = flag.toLowerCase();
    if (flag.contains('夸克') || lower.contains('quark')) return 'quark';
    if (flag.contains('UC') || lower.contains('uc')) return 'uc';
    if (flag.contains('百度') || lower.contains('baidu')) return 'baidu';
    if (_looksLikeBiliFlag(flag)) return 'bili';
    if (RegExp(r'(^|[^0-9])115([^0-9]|$)').hasMatch(flag)) return '115';
    return null;
  }

  static bool _looksLikeBiliFlag(String flag) => looksLikeBiliFlag(flag);

  bool _isDeadLocalPlayUrl(String url) {
    final lower = url.toLowerCase();
    if (!lower.contains('127.0.0.1') && !lower.contains('localhost')) {
      return false;
    }
    return lower.contains('/chunk') || lower.contains('/proxy');
  }

  /// 调用蜘蛛的 liveContent(url)，返回直播订阅原文。
  Future<String> live(SourceBean site, String url) async {
    final text = await _invokeWithAowuFallback(site, 'liveContent', [url]);
    _throwIfError(text);
    return text;
  }

  /// 播放结束/切集时释放常驻取流进程（应用退出时 stdin 关闭，子进程也会自行退出）。
  Future<void> stopPlayback() => _releasePlayHost();

  /// 正在预热的 `/chunk` 地址：同一地址并发点击外部播放器时只发一次探针。
  final Map<String, Future<bool>> _chunkWarmups = {};

  /// 已提示过「声明 md5 与本地内容不一致」的 jar key（同一会话只记一次）。
  final Set<String> _staleMd5Logged = {};

  /// 是否是壳内自带取流服务的本机 `/chunk` 地址。
  static bool isLocalChunkPlayUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'http') return false;
    final host = uri.host.toLowerCase();
    if (host != '127.0.0.1' && host != 'localhost') return false;
    return uri.path == '/chunk';
  }

  /// 把壳给的 `/chunk` 地址按实测最优的 `thread` / `chunk` 重写。
  ///
  /// 加固壳自己决定并发与分片大小，写死在 `MyPan$*MineProvider`：
  /// 会员 `thread=32 / chunk=64(KB)`，非会员 `thread=16 / chunk=512`。
  /// 而服务端（`merge.j.c`）把 thread 夹到 [1,10]、chunk 当 KB 用 ——
  /// 壳发 16/32 都被砍成 10，白白浪费并发；chunk=64KB 更是过小。
  ///
  /// 实测同一夸克直链（thread 固定 10，chunk 按 KB）：
  ///   256 -> 6.8 MB/s · 512 -> 13.0 · 1024 -> 19.1 · 2048 -> 25.9 · 4096 -> 17.0
  ///
  /// 只改 `thread` / `chunk` 两个参数，其余（id、签名等）**按原始字节保留**。
  /// 不能用 `Uri.replace(queryParameters:)` 重建：它会重新编码其它参数
  /// （实测 `sign=a/b+c=` 会变成 `a%2Fb+c%3D`），壳若对原始 query 验签会直接播不了。
  /// 不是本机 `/chunk` 或缺少 `chunk` 参数时原样返回。
  static String tuneChunkUrl(String url) {
    if (!isLocalChunkPlayUrl(url)) return url;
    final trimmed = url.trim();
    final qIndex = trimmed.indexOf('?');
    if (qIndex < 0) return url;
    final hashIndex = trimmed.indexOf('#', qIndex + 1);
    final query = hashIndex < 0
        ? trimmed.substring(qIndex + 1)
        : trimmed.substring(qIndex + 1, hashIndex);
    if (query.isEmpty) return url;
    final parts = query.split('&');
    var hasChunk = false;
    var hasThread = false;
    for (var i = 0; i < parts.length; i++) {
      final pair = parts[i];
      final eq = pair.indexOf('=');
      final key = eq < 0 ? pair : pair.substring(0, eq);
      if (key == 'chunk') {
        hasChunk = true;
        parts[i] = 'chunk=$_chunkKb';
      } else if (key == 'thread') {
        hasThread = true;
        parts[i] = 'thread=$_chunkThreads';
      }
    }
    // 没有 chunk 参数说明不是这套壳的 /chunk 形态，不动。
    if (!hasChunk) return url;
    if (!hasThread) parts.add('thread=$_chunkThreads');
    final suffix = hashIndex < 0 ? '' : trimmed.substring(hashIndex);
    return '${trimmed.substring(0, qIndex + 1)}${parts.join('&')}$suffix';
  }

  /// 服务端把 thread 夹到 1..10，直接给上限。
  static const int _chunkThreads = 10;

  /// 分片大小（KB）：实测 2MB 最快（见 tuneChunkUrl 注释里的对照表）。
  static const int _chunkKb = 2048;

  /// 把 `/chunk` 地址先打一次 Range 探针再交给外部播放器。
  ///
  /// 壳内的 Java 取流服务对**每个首次访问**都会同步完成一次上游取链
  /// （`j.f.k()` 0-1023 字节请求），完成后才把会话登记到 `ConcurrentHashMap`；
  /// 没有登记期间来的并发请求会各自新建会话，而登记时又 `put` + `shutdownNow`
  /// 掉前一个。PotPlayer 打开 URL 时会连开 5~6 条探针连接，正好踩中这个竞态：
  /// 前几条被后一条杀掉，播放器只看到断流，表现就是「一直加载中」。
  /// 先在这里做完一次，会话已登记，之后播放器的探针都会直接复用。
  Future<bool> warmUpLocalPlayUrl(
    String url, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    final target = url.trim();
    if (!isLocalChunkPlayUrl(target)) return Future.value(true);
    final existing = _chunkWarmups[target];
    if (existing != null) return existing;
    final future = _warmUpLocalPlayUrl(target, timeout);
    _chunkWarmups[target] = future;
    return future.whenComplete(() => _chunkWarmups.remove(target));
  }

  Future<bool> _warmUpLocalPlayUrl(String url, Duration timeout) async {
    final uri = Uri.parse(url);
    final port = uri.hasPort ? uri.port : 80;
    final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    final sw = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        uri.host,
        port,
        timeout: const Duration(seconds: 8),
      );
      // 不用 HttpClient：壳的响应会带两条相同的 Content-Length，
      // dart:io 的解析器会直接抛 HttpException，探针本身也会失败。
      socket.write(
        'GET $path HTTP/1.1\r\n'
        'Host: ${uri.host}:$port\r\n'
        'User-Agent: MisaTV\r\n'
        'Accept: */*\r\n'
        'Accept-Encoding: identity\r\n'
        'Range: bytes=0-1023\r\n'
        'Connection: close\r\n\r\n',
      );
      await socket.flush();

      final completer = Completer<bool>();
      final head = <int>[];
      var status = 0;
      var headersDone = false;
      void finish(bool ok) {
        if (!completer.isCompleted) completer.complete(ok);
      }

      socket.listen(
        (data) {
          if (headersDone) return;
          head.addAll(data);
          final end = _headerEndIndex(head);
          if (end < 0) return;
          headersDone = true;
          final text = String.fromCharCodes(head.sublist(0, end));
          final match = RegExp(r'HTTP/1\.[01]\s+(\d{3})').firstMatch(text);
          status = int.tryParse(match?.group(1) ?? '') ?? 0;
          finish(status > 0 && status < 400);
        },
        onError: (Object _) => finish(false),
        onDone: () => finish(status > 0 && status < 400),
        cancelOnError: true,
      );
      final ok = await completer.future.timeout(
        timeout,
        onTimeout: () => false,
      );
      AppLog.i(
        'jar',
        '/chunk 预热${ok ? '成功' : '失败'} status=$status '
            '${sw.elapsedMilliseconds}ms ${redactUrl(url)}',
      );
      return ok;
    } catch (e) {
      AppLog.w('jar', '/chunk 预热失败 ${sw.elapsedMilliseconds}ms', e);
      return false;
    } finally {
      try {
        await socket?.close();
      } catch (_) {
        // 探针连接关闭失败不影响播放
      }
    }
  }

  static int _headerEndIndex(List<int> bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  /// 把播放交给外部播放器（Yaozhi MPV / PotPlayer 等）后继续保活取流 JVM。
  ///
  /// 本机 `/chunk` 地址由这只 JVM 的内存服务提供：内置播放器页一 dispose 就
  /// `stopPlayback`，外部播放器随后取流只能拿到 404。这里把回收时间延长到
  /// 6 小时（足够覆盖长片），由下一次 `play()` 或应用退出时释放。
  void holdPlaybackForExternal() {
    if (_playHost == null && _playServeHost == null) return;
    _playReaper?.cancel();
    _playReaper = Timer(const Duration(hours: 6), () {
      unawaited(_releasePlayHost());
    });
    AppLog.i('jar', '播放已交给外部播放器，取流 JVM 保持运行');
  }

  /// 网盘凭据变更（登录 / 刷新 / 判定访客）后让常驻进程重新 init，
  /// 否则旧 JVM 会一直用启动时读到的旧 Cookie。
  Future<void> resetDriveState() => _resetForDriveChange();

  /// 代理配置变更：常驻 JVM 只在启动时读 `-Dhttp.proxyHost`，必须重开进程池。
  Future<void> resetForNetworkChange() async {
    AppLog.i('jar', '代理配置变更：释放常驻取流/浏览进程');
    await _resetForDriveChange();
  }

  /// 应用退出：直接结束常驻取流 / 浏览进程，不等 JVM 自己退。
  Future<void> shutdown() async {
    _playReaper?.cancel();
    _playReaper = null;
    final host = _playHost;
    _playHost = null;
    final playServe = _playServeHost;
    _playServeHost = null;
    _playServeKey = null;
    for (final timer in _serveIdleTimers.values) {
      timer.cancel();
    }
    _serveIdleTimers.clear();
    final hosts = [for (final pool in _servePools.values) ...pool];
    _servePools.clear();
    _serveStarting.clear();
    _serveHostSeq.clear();
    if (playServe != null && !hosts.contains(playServe)) {
      hosts.add(playServe);
    }
    await Future.wait([
      if (host != null) host.killNow(),
      for (final item in hosts) item.killNow(),
    ]);
  }

  void _keepPlayHost(JarSpiderHost host) {
    _playReaper?.cancel();
    // 兜底：播放器异常未回调时，最多留 2 小时
    _playReaper = Timer(const Duration(hours: 2), () {
      unawaited(_releasePlayHost());
    });
    _playHost = host;
  }

  /// 回退到 serve host 取流成功后 pin 住它：壳内取流服务就在这只 JVM 里，
  /// 提前回收会让 `/chunk` 地址立刻失效。
  void _keepPlayServeHost(JarServeHost host, String key) {
    _playServeHost = host;
    _playServeKey = key;
    _playReaper?.cancel();
    _playReaper = Timer(const Duration(hours: 2), () {
      unawaited(_releasePlayHost());
    });
  }

  /// 播放结束：这只专用 host 不会再被复用（pool key 带时间戳），直接关掉，
  /// 避免连续切集时留下多只 JVM。
  Future<void> _releasePlayServeHost() async {
    final host = _playServeHost;
    final key = _playServeKey;
    _playServeHost = null;
    _playServeKey = null;
    if (host == null || key == null) return;
    final pool = _servePools[key];
    if (pool != null) {
      pool.remove(host);
      if (pool.isEmpty) {
        _servePools.remove(key);
        _serveIdleTimers.remove(key)?.cancel();
      } else {
        _touchServe(key);
      }
    }
    await host.close();
  }

  Future<void> _releasePlayHost() async {
    _playReaper?.cancel();
    _playReaper = null;
    final host = _playHost;
    _playHost = null;
    await host?.close();
    await _releasePlayServeHost();
  }

  /// 播放结果里的「缺少网盘凭据 / 网盘接口失效」提示 → provider（已绑定才重试）。
  String? _authProviderOf(PlayResult result, {String flag = ''}) {
    if (result.url.trim().isNotEmpty) return null;
    final message = result.message.trim();
    if (message.isEmpty) return null;
    final lower = message.toLowerCase();
    // 夸克 download 接口 404：常驻 JVM 的 flush 可能把好 cookie 降级成访客态，
    // 换一只 JVM 重读种子 cookie 后重解析往往能恢复（分享真的失效时也就多试一次）。
    final quarkDownload404 =
        (message.contains('夸克') || lower.contains('quark')) &&
        (message.contains('HTTP 404') || lower.contains('http 404')) &&
        (message.contains('download') || message.contains('下载'));
    if (quarkDownload404) return 'quark';
    // JSONObject["data"] not found 这类「网盘接口返回缺字段」：优先按播放线路名
    // 判断网盘商（蜘蛛的报错本身往往不带「夸克」二字），刷新会话后重试一次。
    if (_looksLikeDriveApiError(message)) {
      return _driveProviderFromFlag(flag) ?? _driveProviderFromMessage(message);
    }
    final authLike =
        message.contains('登录') ||
        message.contains('配置中心') ||
        message.contains('Cookie') ||
        lower.contains('cookie') ||
        lower.contains('(auth)');
    if (!authLike) return null;
    // 蜘蛛的报错往往不带网盘名（如「获取失败：账号未登录或 Cookie 已失效」），
    // 这时按线路名兜底，否则哔哩 / 115 的「刷新会话后重试」永远触发不到。
    return _driveProviderFromMessage(message) ?? _driveProviderFromFlag(flag);
  }

  String? _driveProviderFromMessage(String message) {
    final lower = message.toLowerCase();
    if (message.contains('夸克') || lower.contains('quark')) return 'quark';
    if (message.contains('百度') || lower.contains('baidu')) return 'baidu';
    if (message.contains('115')) return '115';
    if (_looksLikeBiliFlag(message)) return 'bili';
    if (message.contains('UC') ||
        lower.contains('ucpan') ||
        lower.contains('[uc]')) {
      return 'uc';
    }
    return null;
  }

  /// 网盘凭据变更后重置蜘蛛进程：常驻 JVM 的 prefs 种子只在启动时读一次，
  /// 不换进程就会一直用「绑定前」的空值（表现：已登录仍提示去配置中心）。
  Future<void> _resetForDriveChange() async {
    AppLog.i('jar', '网盘凭据变更：释放常驻取流/浏览进程');
    await _releasePlayHost();
    for (final key in _servePools.keys.toList()) {
      await _closeServePool(key);
    }
  }

  // ---------------------------------------------------------------------------
  // jar 取件 / dex 转换
  // ---------------------------------------------------------------------------

  /// `jar` 字段形如 `https://…jar;md5;abc123`，也允许只给 URL。
  String _jarUrlOf(SourceBean site) {
    final raw = site.jar.trim().isNotEmpty ? site.jar.trim() : globalJar.trim();
    if (raw.isEmpty) return '';
    return raw.split(';').first.trim();
  }

  String _jarMd5Of(SourceBean site) {
    final raw = site.jar.trim().isNotEmpty ? site.jar.trim() : globalJar.trim();
    final parts = raw.split(';');
    for (var i = 1; i < parts.length - 1; i++) {
      if (parts[i].trim().toLowerCase() == 'md5') {
        return parts[i + 1].trim().toLowerCase();
      }
    }
    return '';
  }

  /// TVBox 约定：`csp_Xxx` → `com.github.catvod.spider.Xxx`，其余按全类名/补包名。
  String _className(SourceBean site) {
    var api = site.api.trim();
    final q = api.indexOf('?');
    if (q >= 0) api = api.substring(0, q);
    if (api.startsWith('csp_')) {
      return 'com.github.catvod.spider.${api.substring(4)}';
    }
    if (api.contains('.')) return api;
    return 'com.github.catvod.spider.$api';
  }

  Future<Directory> _cacheDir() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'jvm_cache'));
    dir.createSync(recursive: true);
    return dir;
  }

  /// 加固壳的后台线程偶发把 JVM 拖崩：`hs_err` 落到缓存目录，别散落在安装目录。
  Future<String> _jvmErrorFile() async {
    final dir = Directory(p.join((await _cacheDir()).path, 'crash'));
    dir.createSync(recursive: true);
    return '-XX:ErrorFile=${p.join(dir.path, 'hs_err_%p.log')}';
  }

  /// 配置里引用到的所有 JAR 缓存键：优先订阅声明的 md5，否则用 URL 的 md5。
  Set<String> jarKeysOf(SiteConfig config) {
    final keys = <String>{};
    final global = config.spider.trim();
    void add(String raw) {
      final key = _jarKeyOf(raw);
      if (key.isNotEmpty) keys.add(key);
    }

    if (global.isNotEmpty) add(global);
    for (final site in config.sites) {
      add(site.jar.trim().isNotEmpty ? site.jar : global);
    }
    for (final live in config.lives) {
      add(live.jar.trim().isNotEmpty ? live.jar : global);
    }
    return keys;
  }

  String _jarKeyOf(String raw) {
    final spec = raw.trim();
    if (spec.isEmpty) return '';
    final parts = spec.split(';');
    final url = parts.first.trim();
    for (var i = 1; i < parts.length - 1; i++) {
      if (parts[i].trim().toLowerCase() == 'md5') {
        final md5 = parts[i + 1].trim().toLowerCase();
        if (md5.isNotEmpty) return md5;
      }
    }
    return url.isEmpty ? '' : crypto.md5.convert(utf8.encode(url)).toString();
  }

  /// 删除不再被任何配置引用的 JAR 缓存（原始包、转换产物、解包 payload）。
  ///
  /// 播放中的 JAR 会被 Windows 锁住，删不掉就留到下次启动再清；这里只删
  /// 形如 32 位 md5 的缓存项，不会碰其他文件。
  Future<void> purgeJarCaches(Set<String> keepKeys) async {
    final root = (await _cacheDir()).path;
    for (final poolKey in _servePools.keys.toList()) {
      if (keepKeys.contains(poolKey.split('|').first)) continue;
      await _closeServePool(poolKey);
    }
    _converted.removeWhere((key, _) => !keepKeys.contains(key));
    _payloadIndexCache.removeWhere((key, _) => !keepKeys.contains(key));
    _nativeOnly.removeWhere(
      (entry) => !keepKeys.contains(entry.split('|').first),
    );

    for (final name in const ['jars', 'converted']) {
      final dir = Directory(p.join(root, name));
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final base = p.basenameWithoutExtension(entity.path);
        final key = name == 'converted'
            ? _convertedKeyOf(base)
            : (_isJarKey(base) ? base : '');
        if (key.isEmpty || keepKeys.contains(key)) continue;
        try {
          entity.deleteSync();
        } catch (_) {
          // 被占用：下次启动再清
        }
      }
    }
    final payloads = Directory(p.join(root, 'payloads'));
    if (!payloads.existsSync()) return;
    for (final entity in payloads.listSync()) {
      if (entity is! Directory) continue;
      final key = p.basename(entity.path);
      if (keepKeys.contains(key) || !_isJarKey(key)) continue;
      try {
        entity.deleteSync(recursive: true);
      } catch (_) {
        // 被占用：下次启动再清
      }
    }
  }

  bool _isJarKey(String key) => RegExp(r'^[0-9a-f]{32}$').hasMatch(key);

  /// `converted/` 里可能是带版本号的产物（`<key>.v1`），取出原始 key。
  String _convertedKeyOf(String base) {
    final m = RegExp(r'^([0-9a-f]{32})(?:\.v\d+)?$').firstMatch(base);
    return m?.group(1) ?? '';
  }

  Future<File> _rawJar(SourceBean site) async {
    final url = normalizeHostUrl(_jarUrlOf(site));
    if (url.isEmpty) {
      throw SourceException('该源没有配置 JAR 地址（站点 jar 与订阅 spider 都为空）');
    }
    final expectMd5 = _jarMd5Of(site);
    final key = expectMd5.isNotEmpty
        ? expectMd5
        : crypto.md5.convert(utf8.encode(url)).toString();
    final dir = Directory(p.join((await _cacheDir()).path, 'jars'));
    dir.createSync(recursive: true);
    final file = File(p.join(dir.path, '$key.jar'));

    if (file.existsSync() && file.lengthSync() > 1024) {
      final actual = await _fileMd5(file);
      final md5Matches = expectMd5.isEmpty || actual == expectMd5;
      // md5 只作为缓存键和可比对信息：CDN 会在不改内容语义的情况下重新打包，
      // 实测同一 URL 每次下载长度相同但 md5 不同。声明 md5 对不上时，
      // 只要本地文件是有效 JAR 就继续用，避免每次启动重复下载。
      final valid = md5Matches || await _looksLikeSpiderJar(file);
      if (valid) {
        if (!md5Matches && _staleMd5Logged.add(key)) {
          AppLog.i(
            'jar',
            '声明 md5 与本地 JAR 不一致，文件结构有效，沿用缓存 '
                '${redactUrl(url)}',
          );
        }
        // 声明了 md5 的 jar 内容固定；本地 jar 也不做周更。
        if (expectMd5.isNotEmpty || url.startsWith('file://')) return file;
        // 无 md5 的远程 jar：最多每 7 天检查一次更新；失败保留旧 jar。
        final stamp = File('${file.path}.checked');
        if (_jarCheckFresh(stamp)) return file;
        final pending = _jarRefreshLocks[key];
        if (pending != null) {
          await pending;
          return file;
        }
        final lock = Completer<void>();
        _jarRefreshLocks[key] = lock.future;
        try {
          final oldDigest = await _fileMd5(file);
          final fresh = File('${file.path}.refresh');
          try {
            await _downloadJarWithFallbacks(url, fresh, expectMd5);
            final newDigest = await _fileMd5(fresh);
            if (file.existsSync()) {
              try {
                file.deleteSync();
              } catch (_) {
                if (fresh.existsSync()) fresh.deleteSync();
                _touchJarStamp(stamp);
                return file;
              }
            }
            fresh.renameSync(file.path);
            _touchJarStamp(stamp);
            if (oldDigest != newDigest) await _invalidateJarArtifacts(key);
            return file;
          } catch (_) {
            if (fresh.existsSync()) {
              try {
                fresh.deleteSync();
              } catch (_) {
                // 忽略临时文件清理失败
              }
            }
            _touchJarStamp(stamp);
            return file;
          }
        } finally {
          _jarRefreshLocks.remove(key);
          if (!lock.isCompleted) lock.complete();
        }
      }
      // 缓存是坏包：删掉重下，否则每次都会拿它去校验。
      try {
        file.deleteSync();
      } catch (_) {
        // 被占用时保留，后面写新文件会失败并给出提示
      }
    }

    if (url.startsWith('file://')) {
      final local = File(filePathOf(url));
      if (!local.existsSync()) {
        throw SourceException('本地 JAR 不存在：${local.path}');
      }
      local.copySync(file.path);
      return file;
    }

    // 同一 jar 可能被多个站点同时触发（首页 / 搜索并发）：只允许一个下载任务，
    // 其余等待后直接复用，避免多个请求同时写同一个 `.part` 临时文件。
    final pendingDownload = _jarRefreshLocks[key];
    if (pendingDownload != null) {
      await pendingDownload;
      return _rawJar(site);
    }
    final downloadLock = Completer<void>();
    _jarRefreshLocks[key] = downloadLock.future;
    try {
      // 等锁期间另一个调用可能已经下载完成。
      if (file.existsSync() && file.lengthSync() > 1024) {
        final actual = await _fileMd5(file);
        if (expectMd5.isEmpty ||
            actual == expectMd5 ||
            await _looksLikeSpiderJar(file)) {
          return file;
        }
      }
      await _downloadJarWithFallbacks(
        url,
        file,
        expectMd5,
        acceptValidOnMd5Mismatch: true,
      );
      return file;
    } finally {
      _jarRefreshLocks.remove(key);
      if (!downloadLock.isCompleted) downloadLock.complete();
    }
  }

  static const _jarRefreshInterval = Duration(days: 7);

  bool _jarCheckFresh(File stamp) {
    if (!stamp.existsSync()) return false;
    return DateTime.now().difference(stamp.lastModifiedSync()) <
        _jarRefreshInterval;
  }

  void _touchJarStamp(File stamp) {
    try {
      stamp.writeAsStringSync(DateTime.now().toIso8601String());
    } catch (_) {
      // 时间戳写不进去不影响播放；下次会重新检查
    }
  }

  /// jar 内容变了：作废转换产物、加固壳 payload 与内存索引，下次调用重新生成。
  Future<void> _invalidateJarArtifacts(String key) async {
    _converted.remove(key);
    _payloadIndexCache.remove(key);
    _brokenPayloads.removeWhere(
      (path) => path.contains(
        '${p.separator}payloads${p.separator}$key${p.separator}',
      ),
    );
    try {
      final root = await _cacheDir();
      final converted = Directory(p.join(root.path, 'converted'));
      if (converted.existsSync()) {
        for (final entity in converted.listSync()) {
          if (entity is! File) continue;
          if (_convertedKeyOf(p.basenameWithoutExtension(entity.path)) == key ||
              p.basename(entity.path).startsWith('$key.')) {
            try {
              entity.deleteSync();
            } catch (_) {
              // 被占用时忽略
            }
          }
        }
      }
      final payloads = Directory(p.join(root.path, 'payloads', key));
      if (payloads.existsSync()) payloads.deleteSync(recursive: true);
    } catch (_) {
      // 缓存清理失败不影响重新下载后的运行
    }
  }

  Future<void> _downloadJarWithFallbacks(
    String url,
    File dest,
    String expectMd5, {
    /// 声明的 md5 与源站实际内容不一致时，若文件本身是有效 JAR 仍然采用。
    /// 很多订阅的 md5 是作者打包时的旧值，CDN 每次重打包都会变
    /// （实测同一 URL 多次下载长度相同但 md5 不同），严格校验会导致
    /// 每次启动都重新下载、最后还加载失败。
    bool acceptValidOnMd5Mismatch = false,
  }) async {
    // GitHub raw 被墙时优先走 jsDelivr；注意有的 spider 是 jar 改名成 .txt 的。
    final targets = <String>[...githubMirrorUrls(url), url];
    // http 源额外试一次 https：部分网络会拦截明文 HTTP。
    final parsed = Uri.tryParse(url);
    if (parsed != null && parsed.scheme == 'http') {
      targets.add(parsed.replace(scheme: 'https').toString());
    }
    final proxy = await _systemProxy();
    // 直连 → 系统代理 → DoH（DNS 被污染时拿真实 IP）。DoH 放最后，避免
    // 正常网络每次下载都多一轮 DNS 查询。
    final modes = <({bool useProxy, bool useDoh})>[
      (useProxy: false, useDoh: false),
      if (proxy.isNotEmpty) (useProxy: true, useDoh: false),
      (useProxy: false, useDoh: true),
    ];
    final errors = <String>[];
    for (final target in targets) {
      for (final mode in modes) {
        final tag = mode.useDoh ? 'DoH ' : '';
        for (var round = 0; round < 2; round++) {
          try {
            await _downloadJar(
              target,
              dest,
              expectMd5,
              mode.useProxy ? proxy : '',
              useDoh: mode.useDoh,
              acceptValidOnMd5Mismatch: acceptValidOnMd5Mismatch,
            );
            return;
          } on _JarChecksumException catch (e) {
            errors.add(e.message);
            // 校验失败多半是下到了错误页，重连再试一次
          } on SourceException catch (e) {
            errors.add('$tag${e.message}');
            break;
          } on TimeoutException {
            errors.add('$tag连接超时');
            break;
          } on SocketException catch (e) {
            errors.add('$tag无法连接（${e.osError?.message ?? e.message}）');
            break;
          } on HandshakeException catch (e) {
            errors.add('${tag}TLS 握手失败（${e.message}）');
            // 部分源站使用系统根证书链不全的证书，正常校验会直接失败；
            // 只对 JAR 下载改用宽松 TLS 再试一次，别让整份订阅的站点全挂。
            if (!mode.useDoh) {
              try {
                AppLog.w(
                  'jar',
                  'JAR 下载 TLS 校验失败，改用宽松校验重试 ${redactUrl(target)}',
                );
                await _downloadJar(
                  target,
                  dest,
                  expectMd5,
                  mode.useProxy ? proxy : '',
                  allowBadCert: true,
                  acceptValidOnMd5Mismatch: acceptValidOnMd5Mismatch,
                );
                return;
              } on _JarChecksumException catch (retry) {
                errors.add('证书宽松重试：${retry.message}');
                break;
              } on SourceException catch (retry) {
                errors.add('证书宽松重试：${retry.message}');
                break;
              } on HandshakeException catch (retry) {
                errors.add('$tag证书宽松重试仍握手失败（${retry.message}）');
                break;
              } on TimeoutException {
                errors.add('$tag证书宽松重试连接超时');
                break;
              } on SocketException catch (retry) {
                errors.add(
                  '$tag证书宽松重试无法连接（${retry.osError?.message ?? retry.message}）',
                );
                break;
              } catch (retry) {
                errors.add('$tag证书宽松重试：$retry');
                break;
              }
            }
            break;
          } catch (e) {
            errors.add('$tag$e');
            break;
          }
        }
      }
    }
    final host = parsed?.host ?? '';
    final detail = errors.isEmpty ? '未知错误' : errors.toSet().take(3).join('；');
    throw SourceException('JAR 下载失败${host.isEmpty ? '' : '（$host）'}：$detail');
  }

  Future<void> _downloadJar(
    String url,
    File file,
    String expectMd5,
    String proxy, {
    bool useDoh = false,
    bool allowBadCert = false,
    bool acceptValidOnMd5Mismatch = false,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    client.idleTimeout = const Duration(seconds: 20);
    if (allowBadCert) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    // 内置代理优先：HttpClient 的全局 findProxy 会指向本机代理桥；
    // 未启用内置代理时才复用系统代理 / DoH 的旧逻辑。
    if (!ProxyRuntime.instance.enabled) {
      if (proxy.isNotEmpty) {
        client.findProxy = (_) => 'PROXY $proxy';
      } else if (useDoh) {
        client.connectionFactory = createDohConnectionFactory();
      }
    }
    final tmp = File('${file.path}.part');
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'okhttp/4.12.0');
      req.headers.set('Accept', '*/*');
      // 关掉压缩，才能用 content-length 判断是否下完整。
      req.headers.set('Accept-Encoding', 'identity');
      req.headers.set('Cache-Control', 'no-cache');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw SourceException('HTTP ${res.statusCode}');
      }
      if (tmp.existsSync()) tmp.deleteSync();
      final sink = tmp.openWrite();
      var received = 0;
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          received += chunk.length;
        }
      } finally {
        await sink.close();
      }
      final expected = res.contentLength;
      if (expected > 0 && received != expected) {
        throw SourceException('下载不完整（$received/$expected 字节）');
      }
      if (received < 1024) throw SourceException('内容过小，源可能已失效');
      if (expectMd5.isNotEmpty && await _fileMd5(tmp) != expectMd5) {
        if (!acceptValidOnMd5Mismatch || !await _looksLikeSpiderJar(tmp)) {
          throw const _JarChecksumException('md5 校验不通过');
        }
        AppLog.w(
          'jar',
          'JAR 声明 md5 与源站内容不一致，文件结构有效，按实际内容使用 '
              '${redactUrl(url)}',
        );
      }
      if (file.existsSync()) file.deleteSync();
      tmp.renameSync(file.path);
    } on SourceException {
      rethrow;
    } on _JarChecksumException {
      rethrow;
    } finally {
      client.close(force: true);
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {
          // 临时文件清理失败忽略
        }
      }
    }
  }

  /// 系统代理地址（`host:port`）：Dart 的 HttpClient 默认直连，不会读 Windows 代理设置。
  Future<String> _systemProxy() async {
    if (_proxyLoaded) return _proxyAddress ?? '';
    _proxyLoaded = true;
    final env = Platform.environment;
    for (final key in const [
      'HTTPS_PROXY',
      'https_proxy',
      'HTTP_PROXY',
      'http_proxy',
      'ALL_PROXY',
      'all_proxy',
    ]) {
      final address = _normalizeProxy((env[key] ?? '').trim());
      if (address.isNotEmpty) {
        _proxyAddress = address;
        return address;
      }
    }
    if (Platform.isWindows) {
      try {
        const regKey =
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
        final enabled = await Process.run('reg', [
          'query',
          regKey,
          '/v',
          'ProxyEnable',
        ]);
        final enabledText = '${enabled.stdout}';
        if (RegExp(
          r'ProxyEnable\s+REG_DWORD\s+0x1\b',
          caseSensitive: false,
        ).hasMatch(enabledText)) {
          final server = await Process.run('reg', [
            'query',
            regKey,
            '/v',
            'ProxyServer',
          ]);
          final match = RegExp(r'ProxyServer\s+REG_SZ\s+(.+)')
              .firstMatch('${server.stdout}');
          final address = _normalizeProxy(match?.group(1)?.trim() ?? '');
          if (address.isNotEmpty) _proxyAddress = address;
        }
      } catch (_) {
        // 注册表读不到就按直连处理
      }
    }
    return _proxyAddress ?? '';
  }

  /// 支持 `host:port`、`http://host:port`、`http=host:port;https=host:port`。
  String _normalizeProxy(String raw) {
    var value = raw.trim();
    if (value.isEmpty || value.toLowerCase() == 'direct') return '';
    if (value.contains('=')) {
      var http = '';
      var https = '';
      var socks = '';
      for (final part in value.split(';')) {
        final idx = part.indexOf('=');
        if (idx <= 0) continue;
        final scheme = part.substring(0, idx).trim().toLowerCase();
        final addr = part.substring(idx + 1).trim();
        if (addr.isEmpty) continue;
        if (scheme == 'https') {
          https = addr;
        } else if (scheme == 'http') {
          http = addr;
        } else if (scheme == 'socks') {
          socks = addr;
        }
      }
      value = https.isNotEmpty ? https : (http.isNotEmpty ? http : socks);
    }
    if (value.isEmpty) return '';
    if (!value.contains('://')) value = 'http://$value';
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return '';
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    return '${uri.host}:$port';
  }

  /// 含 classes*.dex 的包必须转换；已是 class 的 jar 直接可用。
  Future<bool> _hasDex(File jar) async {
    final raf = await jar.open();
    try {
      final length = await jar.length();
      const chunk = 512 * 1024;
      var offset = 0;
      while (offset < length) {
        await raf.setPosition(offset);
        final bytes = await raf.read(chunk);
        if (bytes.isEmpty) break;
        final text = latin1.decode(bytes, allowInvalid: true);
        if (text.contains('classes.dex')) return true;
        offset += bytes.length - 8;
      }
      return false;
    } finally {
      await raf.close();
    }
  }

  /// payload 版本指纹：同名 class 集合的多次 dex2jar 产物内容一致，用「文件数 + 解压总字节」
  /// 就能认出同一份 payload 的不同副本，避免为每个副本白试一次 JVM。
  Future<String> _zipSignature(File file) async {
    final names = await _zipNames(file);
    final key = _zipKey(file);
    return '${names.length}/${_zipSizeCache[key] ?? 0}';
  }

  String _zipKey(File file) =>
      '${file.path}:${file.lengthSync()}:${file.lastModifiedSync().millisecondsSinceEpoch}';

  /// 是否是「看起来能用」的蜘蛛 JAR：必须是 zip，且含 class / dex / 原生库 / assets。
  /// 用来在声明 md5 与源站不一致时区分「源站重新打包」和「下到了错误页」。
  Future<bool> _looksLikeSpiderJar(File file) async {
    try {
      return isSpiderJarBytes(file.readAsBytesSync());
    } catch (_) {
      return false;
    }
  }

  Future<List<String>> _zipNames(File file) async {
    final key = _zipKey(file);
    final cached = _zipNamesCache[key];
    if (cached != null) return cached;
    try {
      final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
      final names = <String>[];
      var total = 0;
      for (final f in archive.files) {
        if (!f.isFile) continue;
        names.add(f.name);
        total += f.size;
      }
      _zipNamesCache[key] = names;
      _zipSizeCache[key] = total;
      return names;
    } catch (_) {
      return const [];
    }
  }

  Future<bool> _jarHasSo(File jar) async {
    final names = await _zipNames(jar);
    if (names.any(
      (n) =>
          n.toLowerCase().endsWith('.so') || n.toLowerCase().endsWith('.guard'),
    )) {
      return true;
    }
    // 新壳（嗷呜 = aowu）：没有 .so/.guard，只有 assets/*.bin + DexNative 入口。
    // 不识别就会被当成普通 jar 直接跑 → System.load 失败 →「加固壳解包失败」。
    if (names.any((n) {
      final lower = n.toLowerCase();
      return lower.startsWith('assets/') && lower.endsWith('.bin');
    })) {
      return _jarHasShellEntry(jar);
    }
    // 还有一类壳连 assets/*.bin 都没有，只有 classes.dex；DexNative 在
    // classes.dex 里。这类 jar 当普通源跑会在 DexNative native 方法上报
    // 「载荷桥未就绪或未登记方法」，必须同样按加固壳挂原生桥。
    if (names.any((n) => n.toLowerCase().endsWith('.dex'))) {
      return _jarHasShellEntry(jar);
    }
    return false;
  }

  /// dex 里是否出现加固壳入口类（无 .so 的壳只能靠这个识别）。
  Future<bool> _jarHasShellEntry(File jar) async {
    final key = _zipKey(jar);
    final cached = _shellEntryCache[key];
    if (cached != null) return cached;
    var found = false;
    try {
      final archive = ZipDecoder().decodeBytes(jar.readAsBytesSync());
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final name = f.name.toLowerCase();
        if (!name.endsWith('.dex')) continue;
        final bytes = f.readBytes();
        if (bytes == null) continue;
        final text = String.fromCharCodes(bytes);
        if (text.contains('DexNative') ||
            text.contains('BaseSpiderGuard') ||
            text.contains('Shinidie')) {
          found = true;
          break;
        }
      }
    } catch (_) {
      // 非 zip / 读取失败 → 按普通源处理
    }
    _shellEntryCache[key] = found;
    return found;
  }

  /// 是否走嗷呜系壳的专用路径。
  ///
  /// 必须按**本次调用的壳类**判断，不能扫整包：wex 的聚合 jar 里同时带
  /// `WoggGuard`（wex）和 `WoggAmns`（嗷呜），按 jar 扫会把 wex 源也挂上
  /// `aowu-shim.jar`，导致 wex 的 MyCrypto 被嗷呜影子类覆盖、整源报
  /// 「需要加固壳原生库」。
  ///
  /// 嗷呜系壳类统一是 `*Amns` / 含 `Aowu`；其它 `*Guard` / `*DexNative` 走
  /// 各自的原生解包路径。只有这条接口本身失败后，才由
  /// [_invokeWithAowuFallback] 按嗷呜思路重试一次。
  bool _jarHasAowu(String className) => isAowuShellClass(className);

  /// 包里是否带嗷呜的 `awenc` / `awdm` 原生库（只用于失败后的兜底判断）。
  Future<bool> _jarHasAowuLibs(File jar) async {
    final names = await _zipNames(jar);
    return names.any((name) {
      final lower = name.toLowerCase();
      return lower.contains('awenc') || lower.contains('awdm');
    });
  }

  /// 错误是否属于嗷呜原生加密 / MyCrypto 这一类。
  bool _looksLikeAowuError(String message) {
    final lower = message.toLowerCase();
    return message.contains('需要加固壳原生库') ||
        lower.contains('mycrypto') ||
        lower.contains('awenc') ||
        lower.contains('awdm');
  }

  /// 内置「真实实现」jar（对齐 winbox 的 `shell-shim/real/<壳名>.jar`）。
  ///
  /// 壳 jar 里的 `assets/<X>.guard`（或 `<X>.bin`）就是壳名；随包内置了对应真实实现时，
  /// 直接走 shell-shim 纯 Java，不再依赖 unidbg 模拟器。
  Future<String?> _realShellShim(File raw, String className) async {
    final names = await _zipNames(raw);
    String guard = '';
    for (final name in names) {
      final m = RegExp(
        r'^assets/([^/]+)\.(guard|bin)$',
        caseSensitive: false,
      ).firstMatch(name);
      if (m != null) {
        guard = m.group(1)!;
        break;
      }
    }
    if (guard.isEmpty) return null;
    final dir = p.join((await runtime.directory()).path, 'shell-shim', 'real');
    final real = File(p.join(dir, '$guard.jar'));
    if (!real.existsSync()) return null;
    final foni = File(p.join(dir, 'foni-spider.jar'));
    // 饭太硬完整构建（foni）只给 blob ext 源（AppSx/AppTT/AppSK）前置：
    // 两套构建的混淆类同名不同结构，全局混载会让大量源退化（winbox 实证）。
    var preferFoni = RegExp(r'AppSx|AppTT|AppSK').hasMatch(className);
    if (!preferFoni && foni.existsSync()) {
      // 主实现里缺这个类、foni 里有 → 单源改用 foni 前置（避免大面积混载）。
      final simple = className.split('.').last;
      final base = simple.replaceFirst(RegExp(r'(Guard|Amns)$'), '');
      final pkgPath = className
          .substring(0, className.length - simple.length)
          .replaceAll('.', '/');
      final wanted = '$pkgPath$base.class';
      final hasInFoni = (await _zipNames(foni)).contains(wanted);
      final hasInReal = (await _zipNames(real)).contains(wanted);
      if (hasInFoni && !hasInReal) preferFoni = true;
    }
    if (preferFoni && foni.existsSync()) {
      return '${foni.path};${real.path}';
    }
    return real.path;
  }

  Future<String> _jarFor(SourceBean site) async {
    final raw = await _rawJar(site);
    final key = p.basenameWithoutExtension(raw.path);
    final cached = _converted[key];
    if (cached != null && File(cached).existsSync()) return cached;

    final running = _converting[key];
    if (running != null) return running;

    final task = _prepare(raw, key);
    _converting[key] = task;
    try {
      return await task;
    } finally {
      _converting.remove(key);
    }
  }

  Future<String> _prepare(File raw, String key) async {
    final dir = Directory(p.join((await _cacheDir()).path, 'converted'));
    dir.createSync(recursive: true);
    // 旧版（无版本号）产物可能带 dex2jar 误译，不再复用。
    final legacy = File(p.join(dir.path, '$key.jar'));
    try {
      if (legacy.existsSync()) legacy.deleteSync();
    } catch (_) {}
    final target = File(p.join(dir.path, '$key.v$_convertedRev.jar'));
    final needsAssets = await _jarHasSo(raw);

    // 上次转换在「合并资源 → 重命名成品」前被关闭时，`.part.fixed.jar` 已经是完整
    // 产物（修复阶段完成）。直接补做资源合并并启用，避免每次启动重跑几分钟的 dex2jar。
    if (!target.existsSync()) {
      final part = File('${target.path}.part');
      final repaired = File('${target.path}.part.fixed.jar');
      if (repaired.existsSync() &&
          repaired.lengthSync() > 1024 &&
          (!part.existsSync() ||
              repaired.lengthSync() >= part.lengthSync() * 0.9)) {
        final names = await _zipNames(repaired);
        if (names.any((n) => n.endsWith('.class'))) {
          await _mergeAssets(raw, repaired);
          try {
            repaired.renameSync(target.path);
            try {
              if (part.existsSync()) part.deleteSync();
            } catch (_) {}
            _converted[key] = target.path;
            return target.path;
          } catch (_) {
            // 文件仍被占用：继续走完整转换
          }
        }
      }
    }

    if (target.existsSync() && target.lengthSync() > 1024) {
      if (!needsAssets ||
          (await _zipNames(target)).any((n) => n.startsWith('assets/'))) {
        _converted[key] = target.path;
        return target.path;
      }
      // 旧产物是纯 class（没保留 assets），加固壳读不到 .so → 重转
      try {
        target.deleteSync();
      } catch (_) {}
    }
    if (!await _hasDex(raw)) {
      _converted[key] = raw.path;
      return raw.path;
    }
    final java = await runtime.javaExecutable();
    if (java.isEmpty) throw SourceException('缺少 JVM 运行时，请先在设置里下载');
    final jvmDir = (await runtime.directory()).path;
    final d2jJars = Directory(p.join(jvmDir, 'd2j'))
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.jar'))
        .map((f) => f.path)
        .join(';');
    if (d2jJars.isEmpty) throw SourceException('dex2jar 工具缺失，请重新安装 JVM 运行时');

    final part = File('${target.path}.part');
    final result = await _runProcess(java, [
      '-Xmx384m',
      '-XX:+UseSerialGC',
      '-XX:TieredStopAtLevel=1',
      '-Dfile.encoding=UTF-8',
      '-cp',
      d2jJars,
      'com.googlecode.dex2jar.tools.Dex2jarCmd',
      raw.path,
      '-o',
      part.path,
      '--force',
    ], timeout: const Duration(minutes: 4));
    if (result.exitCode != 0 || !part.existsSync() || part.lengthSync() < 512) {
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
      final tail = result.stderr
          .trim()
          .split('\n')
          .lastWhere((l) => l.trim().isNotEmpty, orElse: () => 'dex2jar 转换失败');
      throw SourceException('JAR 转换失败：$tail');
    }

    var product = part;
    final repaired = await _repairClasses(raw, part, java, d2jJars);
    if (repaired != null) product = repaired;

    await _mergeAssets(raw, product);

    if (target.existsSync()) target.deleteSync();
    product.renameSync(target.path);
    if (repaired != null && part.existsSync()) {
      try {
        part.deleteSync();
      } catch (_) {}
    }
    _converted[key] = target.path;
    return target.path;
  }

  /// 修复 dex2jar 的「super 调用被转成自递归 invokespecial」与 NEW 抽象类误译。
  Future<File?> _repairClasses(
    File raw,
    File part,
    String java,
    String d2jJars,
  ) async {
    final jvmDir = (await runtime.directory()).path;
    final bridge = File(p.join(jvmDir, 'shims', 'native-bridge.jar'));
    if (!bridge.existsSync()) return null;
    final work = File('${part.path}.fixed.jar');
    try {
      part.copySync(work.path);
      final res = await _runProcess(java, [
        '-Xmx384m',
        '-XX:+UseSerialGC',
        '-XX:TieredStopAtLevel=1',
        '-Dfile.encoding=UTF-8',
        '-cp',
        '${bridge.path};$d2jJars',
        'com.winbox.nativebridge.DexJarRepair',
        raw.path,
        work.path,
        java,
        d2jJars,
      ], timeout: const Duration(minutes: 2));
      if (res.exitCode == 0 &&
          work.existsSync() &&
          (await _zipNames(work)).any((n) => n.endsWith('.class'))) {
        return work;
      }
    } catch (_) {
      // 修复失败保留 dex2jar 原产物
    }
    try {
      if (work.existsSync()) work.deleteSync();
    } catch (_) {}
    return null;
  }

  /// dex2jar 只产出 class；加固壳/普通源都可能依赖原 jar 的 assets 资源。
  Future<void> _mergeAssets(File raw, File jar) async {
    try {
      final rawArchive = ZipDecoder().decodeBytes(raw.readAsBytesSync());
      final jarArchive = ZipDecoder().decodeBytes(jar.readAsBytesSync());
      final out = Archive();
      final existing = <String>{};
      for (final f in jarArchive.files) {
        if (!f.isFile) continue;
        final data = f.readBytes();
        if (data == null) continue;
        out.addFile(ArchiveFile.bytes(f.name, data));
        existing.add(f.name);
      }
      var added = 0;
      for (final f in rawArchive.files) {
        if (!f.isFile) continue;
        final name = f.name;
        final lower = name.toLowerCase();
        final keep =
            name.startsWith('assets/') ||
            lower.endsWith('.so') ||
            lower.endsWith('.guard');
        if (!keep || existing.contains(name)) continue;
        final data = f.readBytes();
        if (data == null) continue;
        out.addFile(ArchiveFile.bytes(name, data));
        existing.add(name);
        added++;
      }
      if (added == 0) return;
      final bytes = ZipEncoder().encode(out);
      final tmp = File('${jar.path}.merge');
      tmp.writeAsBytesSync(bytes, flush: true);
      tmp.renameSync(jar.path);
    } catch (_) {
      // 资源合并失败时保留原产物（普通源不受影响，加固壳会给出明确报错）
    }
  }

  // ---------------------------------------------------------------------------
  // 进程调用
  // ---------------------------------------------------------------------------

  Future<List<String>> _baseShims(String jvmDir) async {
    final shims = p.join(jvmDir, 'shims');
    final libs = Directory(p.join(jvmDir, 'libs'))
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.jar'))
        .map((f) => f.path)
        .toList();
    return [
      // 纯 Java GoProxy 影子类：让壳的 Go 代理 /health 通过（ARM Go .so 桌面不加载）。
      p.join(shims, 'go-proxy-shim.jar'),
      p.join(shims, 'spider-host.jar'),
      p.join(shims, 'prefs-shim.jar'),
      p.join(shims, 'stubs.jar'),
      p.join(shims, 'okhttp4-compat.jar'),
      ...libs,
    ];
  }

  Future<void> _ensureNativeDirs() async {
    final root = p.join((await _cacheDir()).path, 'native');
    for (final sub in ['work', 'patch', 'runtime_dex']) {
      Directory(p.join(root, sub)).createSync(recursive: true);
    }
    Directory(p.join((await _cacheDir()).path, 'spider'))
        .createSync(recursive: true);
  }

  /// 交给 shell-shim 的 payload 候选（**每个都单独挂**，按可信度排序）。
  ///
  /// 同一份 jar 下的加固壳共用一套 payload 包，但缓存里可能同时存在多个版本：
  /// 一部分是能配当前兼容层的旧包，另一部分可能是壳从远端热更新拉到的新包（新包
  /// 常与本机 stubs 不兼容，实测会拖崩 JVM）。所以先给「本类验过可用」「全局验过
  /// 可用」的包，再按**旧到新**补候选：旧包更容易配当前兼容层，坏包则记入
  /// [_brokenPayloads] 后不再重试。
  ///
  /// [preferAssets]：加固壳的载荷类（LoadNiMa / MyCrypto）要读 `assets/libwex_*.so`，
  /// 曾经「首页成功为空」的包会被索引记住（见 [_rememberPayload]），但缺 assets 的包
  /// 后续调 native 必失败。带库的包优先，避免被旧索引带偏。
  Future<List<String>> _payloadCandidates(
    String key, {
    String? className,
    bool preferAssets = false,
  }) async {
    if (className != null && _nativeOnly.contains('$key|$className')) {
      return const [];
    }
    await _adoptRuntimePayloads(key, className: className);
    final dir = Directory(p.join((await _cacheDir()).path, 'payloads', key));
    if (!dir.existsSync()) return const [];
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.toLowerCase().endsWith('.r2.jar') &&
                  f.lengthSync() > 1024,
            )
            .where((f) => !_brokenPayloads.contains(f.path))
            .toList()
          ..sort(
            (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
          );
    if (files.isEmpty) return const [];

    final index = await _payloadIndex(key);
    final wanted = _payloadClassEntries(className);
    final aowuClass = className != null && isAowuShellClass(className);
    final withAssets = <String>{};
    final withAowuLibs = <String>{};
    final withoutAowuLibs = <String>{};
    for (final f in files) {
      final names = await _zipNames(f);
      if (preferAssets) {
        final lower = names.map((e) => e.toLowerCase());
        if (lower.any(
          (n) =>
              n.startsWith('assets/') &&
              (n.endsWith('.so') || n.endsWith('.guard')),
        )) {
          withAssets.add(f.path);
        }
      }
      final hasAowuLib = names.any((n) {
        final lower = n.toLowerCase();
        return lower.contains('awenc') || lower.contains('awdm');
      });
      (hasAowuLib ? withAowuLibs : withoutAowuLibs).add(f.path);
    }
    // 有目标类时按厂商载荷过滤：
    //   · Wex 壳（WoggGuard / Wex*Guard）只能用不含 awenc/awdm 的载荷；
    //     旧聚合缓存里同时有嗷呜载荷（b66f/3f567），先试它们必然报原生加密。
    //   · 嗷呜壳（*Amns / Aowu）优先用带 awenc/awdm 的载荷。
    // 无目标类时仍按 assets 过滤（保持原行为）。
    bool usable(String path) {
      if (wanted.isEmpty) {
        return withAssets.isEmpty || withAssets.contains(path);
      }
      if (aowuClass) {
        return withAowuLibs.isEmpty || withAowuLibs.contains(path);
      }
      return withoutAowuLibs.isEmpty || withoutAowuLibs.contains(path);
    }

    bool containsWanted(List<String> names) =>
        wanted.isEmpty || wanted.any(names.contains);

    final out = <String>[];
    void add(String? name, List<String>? names, {bool trusted = false}) {
      if (name == null || name.isEmpty) return;
      final path = p.join(dir.path, name);
      if (_brokenPayloads.contains(path)) return;
      // index[className] 是本类验证成功后才写入的记录，不能再被厂商/ assets
      // 启发式否掉（例如 DoubanGuard 历史上就落在嗷呜载荷上）。
      if (!trusted && !usable(path)) return;
      if (out.contains(path)) return;
      if (!File(path).existsSync()) return;
      if (names != null && !containsWanted(names)) return;
      out.add(path);
    }

    // index 里的记录也必须验证是否真含目标类：旧的 `*` 可能指向上一个壳版本的
    // 载荷（类名对不上），强行加载只会报原生加密 / ClassNotFound 并挡住后面的正确包。
    if (className != null && index[className] != null) {
      final path = p.join(dir.path, index[className]!);
      if (File(path).existsSync()) {
        add(
          index[className],
          wanted.isEmpty ? null : await _zipNames(File(path)),
          trusted: true,
        );
      }
    }
    // `*` 只是「历史上某个壳用过的包」，**不是**本类的记录。
    //
    // 踩坑记录：一个 jar key 下常有多只壳共享同一批聚合包（c3bb107b 就是 30 个
    // Wex 壳），`*` 往往指向另一个聚合包（b66f…，里面一个 Wex 类都没有）。
    // 若把 `*` 无条件塞进候选，它会占掉一个候选位，还可能被优先试跑 —— 表现为
    // 「以前能用的壳突然 ClassNotFound / 原生解密失败」。
    //
    // 因此这里要求：`*` 必须真的含目标类才收；不含就直接跳过，让后面的全量扫描
    // 去找正确的包。
    if (index['*'] != null) {
      final path = p.join(dir.path, index['*']!);
      if (File(path).existsSync()) {
        final starNames = wanted.isEmpty ? null : await _zipNames(File(path));
        final hit = wanted.isEmpty || (starNames != null && containsWanted(starNames));
        if (hit) {
          add(index['*'], starNames);
        } else {
          AppLog.i(
            'jar',
            '跳过默认载荷 ${index['*']}：不含 ${className ?? '目标类'}',
          );
        }
      }
    }
    final seenSignatures = <String>{
      for (final path in out) await _zipSignature(File(path)),
    };
    for (final file in files) {
      if (out.length >= _payloadMaxCandidates) break;
      if (out.contains(file.path)) continue;
      if (!usable(file.path)) continue;
      final names = await _zipNames(file);
      if (!containsWanted(names)) continue;
      final signature = await _zipSignature(file);
      if (!seenSignatures.add(signature)) continue;
      out.add(file.path);
    }
    if (out.isEmpty) {
      // 一个候选都匹配不上时不要「拿第一个硬试」：壳类与 payload 类名对不上，
      // 类加载必失败，还会白起一只 JVM（aowu 系壳就是这种情况，应走原生）。
      return wanted.isEmpty ? [files.first.path] : const [];
    }
    if (className != null && out.length > 1) {
      AppLog.i(
        'jar',
        'payload 候选 class=$className -> '
            '${out.map((e) => p.basename(e)).join(', ')}',
      );
    }
    return out;
  }

  /// 站点自己的 payload 都跑不起来时，去其它壳缓存里找包含同一个真实实现的包。
  ///
  /// 壳类本身只是纯委托，`WexAiGuaZi` 这类真实实现在不同壳版本间 API 一致；
  /// 某些新壳的 payload 在桌面解包后缺少匿名类（TypeToken 直接实例化、
  /// InstantiationError 等），换用其它壳缓存里已验证可用的实现即可。
  Future<List<String>> _fallbackPayloads(String key, String? className) async {
    final wanted = _payloadClassEntries(className);
    if (wanted.isEmpty) return const [];
    final aowuClass = isAowuShellClass(className ?? '');
    final root = p.join((await _cacheDir()).path, 'payloads');
    if (!Directory(root).existsSync()) return const [];
    final dirs = Directory(root).listSync().whereType<Directory>().toList()
      ..sort((a, b) {
        int modified(Directory dir) {
          try {
            return dir.statSync().modified.millisecondsSinceEpoch;
          } catch (_) {
            return 0;
          }
        }

        return modified(b).compareTo(modified(a));
      });
    final out = <String>[];
    final signatures = <String>{};
    for (final dir in dirs) {
      if (out.length >= _payloadMaxCandidates) break;
      final dirKey = p.basename(dir.path);
      if (dirKey == key) continue;
      if (!dir.existsSync()) continue;
      final index = await _payloadIndex(dirKey);
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where(
                (f) =>
                    f.path.toLowerCase().endsWith('.r2.jar') &&
                    f.lengthSync() > 1024,
              )
              .toList()
            ..sort(
              (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
            );
      final ordered = <File>[];
      final indexed = index[className];
      if (indexed != null) {
        final f = File(p.join(dir.path, indexed));
        if (f.existsSync()) ordered.add(f);
      }
      for (final f in files) {
        if (!ordered.any((e) => e.path == f.path)) ordered.add(f);
      }
      for (final f in ordered) {
        final names = await _zipNames(f);
        if (!wanted.any(names.contains)) continue;
        // 跨壳借包也必须同厂商：Wex 壳不能借嗷呜载荷（awenc/awdm），反之亦然。
        final hasAowuLib = names.any((n) {
          final lower = n.toLowerCase();
          return lower.contains('awenc') || lower.contains('awdm');
        });
        if (hasAowuLib != aowuClass) continue;
        final signature = await _zipSignature(f);
        if (!signatures.add(signature)) break;
        out.add(f.path);
        break;
      }
    }
    return out;
  }

  /// 把其它壳缓存里验证可用的 payload 复制进本站点目录并写索引：后续调用
  /// （包括播放取流）都从这里取同一个包，不用每次回退搜索。
  Future<String> _adoptForeignPayload(
    String key,
    String className,
    String sourcePath,
  ) async {
    final source = File(sourcePath);
    if (!source.existsSync()) return sourcePath;
    final dir = Directory(p.join((await _cacheDir()).path, 'payloads', key));
    dir.createSync(recursive: true);
    final dest = File(p.join(dir.path, p.basename(sourcePath)));
    if (!dest.existsSync() || dest.lengthSync() != source.lengthSync()) {
      final tmp = File('${dest.path}.tmp');
      source.copySync(tmp.path);
      try {
        tmp.renameSync(dest.path);
      } catch (_) {
        tmp.deleteSync();
      }
    }
    final sourceShim = File('$sourcePath.shim.jar');
    if (sourceShim.existsSync()) {
      final shim = File('${dest.path}.shim.jar');
      if (!shim.existsSync() || shim.lengthSync() != sourceShim.lengthSync()) {
        try {
          sourceShim.copySync('${shim.path}.tmp');
          File('${shim.path}.tmp').renameSync(shim.path);
        } catch (_) {
          // 复制失败时下次 _payloadShim 会按 patched 目录重建
        }
      }
    }
    await _rememberPayload(key, className, dest.path);
    return dest.path;
  }

  /// 给快路径用的合成载荷 jar：补丁类 + `AwInit.show` 垫片 + 原 payload 其余条目。
  ///
  /// 为什么必须合成一个 jar（不能直接把补丁目录塞进 `tvbox.shellShimClasses`）：
  /// 壳的 `DexClassLoader` 影子只接受**文件**（dex/jar/zip），目录条目会被记成
  /// unsupported；合成 jar 后类加载顺序天然是「补丁类覆盖原类」。
  ///
  /// 补丁类来自首次 unidbg 解包时 `NativeBridgeMain.patchRuntimeJar` 写在
  /// `<cache>/native/runtime_dex/<payload>.patched` 的产物（native → 载荷桥、
  /// System.load → bridgeLoad）。没有它（或尚未下载加固壳支持）→ 返回 null，调用方
  /// 按原 payload 运行（普通源不受影响）。
  Future<File?> _payloadShim(
    String payloadPath, {
    bool excludeAowuCrypto = false,
  }) async {
    try {
      final payload = File(payloadPath);
      if (!payload.existsSync()) return null;
      final dir = Directory(
        p.join(
          (await _cacheDir()).path,
          'native',
          'runtime_dex',
          '${p.basename(payloadPath)}.patched',
        ),
      );
      if (!dir.existsSync()) return null;
      final patched = <String, File>{};
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.toLowerCase().endsWith('.class')) continue;
        final rel = p.relative(f.path, from: dir.path).replaceAll('\\', '/');
        patched[rel] = f;
      }
      if (patched.isEmpty) return null;
      // 合成规则变更（保留真实 AwInit / 排除嗷呜 MyCrypto）后必须换文件名，
      // 否则旧缓存会被复用。
      final out = File(
        '${payload.path}.shim${excludeAowuCrypto ? '3' : '2'}.jar',
      );
      if (out.existsSync() &&
          out.lastModifiedSync().isAfter(payload.lastModifiedSync()) &&
          out.lastModifiedSync().isAfter(dir.statSync().modified)) {
        return out;
      }
      final bytes = buildPayloadShim(
        payload: payload,
        patched: patched,
        excludeAowuCrypto: excludeAowuCrypto,
      );
      if (bytes == null || bytes.isEmpty) return null;
      final tmp = File('${out.path}.tmp');
      tmp.writeAsBytesSync(bytes, flush: true);
      tmp.renameSync(out.path);
      return out;
    } catch (_) {
      return null;
    }
  }

  /// 嗷呜载荷即使没有 native 补丁目录，也要生成一份排除自带 `MyCrypto` 的 jar。
  ///
  /// 载荷里的 `MyCrypto` 是 native 声明，桌面 x64 没有 `awenc` 库；它如果在
  /// 子优先类加载器里命中，会盖住 classpath 上的 Java 影子类，静态初始化就报
  /// 「载荷桥未就绪」。排掉它，类加载器回退到 `aowu-shim.jar`，MD5/SHA/AES
  /// 等标准算法即可在桌面执行。
  Future<File?> _aowuPayloadShim(String payloadPath) async {
    try {
      final payload = File(payloadPath);
      if (!payload.existsSync()) return null;
      final out = File('${payload.path}.aowu.jar');
      if (out.existsSync() &&
          out.lastModifiedSync().isAfter(payload.lastModifiedSync())) {
        return out;
      }
      final bytes = buildPayloadShim(
        payload: payload,
        patched: const {},
        excludeAowuCrypto: true,
      );
      if (bytes == null || bytes.isEmpty) return null;
      final tmp = File('${out.path}.tmp');
      tmp.writeAsBytesSync(bytes, flush: true);
      tmp.renameSync(out.path);
      return out;
    } catch (_) {
      return null;
    }
  }

  /// 载荷只有 `ProxyOrigin`、没有 `spider.Proxy` 时，把内置 `proxy-bridge.jar` 前置到
  /// `tvbox.shellShimClasses`：宿主 `com.github.catvod.Proxy` 只会反射 `spider.Proxy.proxy`，
  /// 没有它时 /proxy 播放地址一律 500（播放器只报 invalid or unsupported media）。
  /// 载荷自带 Proxy（普通 jar）或没有 ProxyOrigin 时原样返回。
  Future<String> _shimSpecWithProxyBridge(String spec) async {
    final parts = spec
        .split(';')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return spec;
    var hasOrigin = false;
    for (final part in parts) {
      final names = await _zipNames(File(part));
      if (names.contains('com/github/catvod/spider/Proxy.class')) return spec;
      if (names.contains('com/github/catvod/spider/ProxyOrigin.class')) {
        hasOrigin = true;
      }
    }
    if (!hasOrigin) return spec;
    final bridge = File(
      p.join((await runtime.directory()).path, 'shims', 'proxy-bridge.jar'),
    );
    if (!bridge.existsSync()) return spec;
    return '${bridge.path};$spec';
  }

  /// 载荷快路径要挂的原生桥组件（未安装加固壳支持时 ready=false，保持原行为）。
  Future<({bool ready, List<String> classpath, List<String> props})>
  _payloadBridge({required String java, required String jvmDir}) async {
    try {
      if (!await ArmBridgeRuntime.instance.installed()) {
        return (
          ready: false,
          classpath: const <String>[],
          props: const <String>[],
        );
      }
      final bridge = await runtime.ensureBridgeJar();
      final cache = (await _cacheDir()).path;
      return (
        ready: true,
        classpath: [bridge.path, ...await ArmBridgeRuntime.instance.jarPaths()],
        props: [
          '-Dtvbox.native.backend=dynarmic',
          '-Dtvbox.native.work=${p.join(cache, 'native', 'work')}',
          '-Dtvbox.native.patch=${p.join(cache, 'native', 'patch')}',
          '-Dtvbox.d2j.java=$java',
          '-Dtvbox.d2j.cp=${_d2jJars(jvmDir)}',
          '-Dtvbox.d2j.cache=${p.join(cache, 'native', 'runtime_dex')}',
        ],
      );
    } catch (_) {
      return (
        ready: false,
        classpath: const <String>[],
        props: const <String>[],
      );
    }
  }

  /// 合成 jar 的纯逻辑（单测可直接喂临时文件）。
  static Uint8List? buildPayloadShim({
    required File payload,
    required Map<String, File> patched,
    bool excludeAowuCrypto = false,
  }) {
    try {
      final source = ZipDecoder().decodeBytes(payload.readAsBytesSync());
      final archive = Archive();
      const awInit = 'com/github/catvod/spider/AwInit.class';
      const myCrypto = 'com/github/catvod/spider/MyCrypto.class';
      // 嗷呜系载荷自带**真实** AwInit（init/context/get，>1 KB），它同时也是宿主
      // 上下文单例；只有极小（<1 KB）的占位 AwInit 才需要用下面的 show 垫片替换。
      final hasRealAwInit = source.files.any(
        (f) => f.isFile && f.name == awInit && f.size > 1024,
      );
      for (final f in source.files) {
        if (!f.isFile) continue;
        final name = f.name;
        if (name == awInit && !hasRealAwInit) continue;
        if (excludeAowuCrypto && name == myCrypto) continue;
        final override = patched[name];
        final data = override != null
            ? override.readAsBytesSync()
            : f.readBytes();
        if (data == null) continue;
        archive.addFile(ArchiveFile.bytes(name, data));
      }
      for (final entry in patched.entries) {
        if (entry.key == awInit) continue;
        if (excludeAowuCrypto && entry.key == myCrypto) continue;
        if (archive.files.any((f) => f.name == entry.key)) continue;
        archive.addFile(
          ArchiveFile.bytes(entry.key, entry.value.readAsBytesSync()),
        );
      }
      // 新版 libdecjni 的 JNI_OnLoad 会反射调用 AwInit.show(String)V，
      // 而载荷自带的 AwInit 只有构造函数 → 补一个空实现，native 装载才能走完。
      // 嗷呜载荷的 AwInit 是真实类（含 init/context），必须保留原类。
      if (!hasRealAwInit) {
        archive.addFile(ArchiveFile.bytes(awInit, _awInitStub()));
      }
      return Uint8List.fromList(ZipEncoder().encode(archive));
    } catch (_) {
      return null;
    }
  }

  /// `AwInit` 的最小合法 class（Java 6）：只保留默认构造函数，并补
  /// `public static void show(String)` 空实现。
  static Uint8List _awInitStub() {
    final out = <int>[
      0xca,
      0xfe,
      0xba,
      0xbe,
      0x00,
      0x00,
      0x00,
      0x32,
      0x00,
      0x0c,
    ];
    void utf8Text(String text) {
      final bytes = utf8.encode(text);
      out.addAll([
        0x01,
        (bytes.length >> 8) & 0xff,
        bytes.length & 0xff,
        ...bytes,
      ]);
    }

    utf8Text('com/github/catvod/spider/AwInit');
    out.addAll([0x07, 0x00, 0x01]);
    utf8Text('java/lang/Object');
    out.addAll([0x07, 0x00, 0x03]);
    utf8Text('<init>');
    utf8Text('()V');
    utf8Text('Code');
    utf8Text('show');
    utf8Text('(Ljava/lang/String;)V');
    out.addAll([0x0c, 0x00, 0x05, 0x00, 0x06]);
    out.addAll([0x0a, 0x00, 0x02, 0x00, 0x0a]);
    out.addAll([
      0x00,
      0x21,
      0x00,
      0x02,
      0x00,
      0x04,
      0x00,
      0x00,
      0x00,
      0x00,
      0x00,
      0x02,
    ]);
    // <init>()V：aload_0 / invokespecial #11 / return
    out.addAll([
      0x00,
      0x01,
      0x00,
      0x05,
      0x00,
      0x06,
      0x00,
      0x01,
      0x00,
      0x07,
      0x00,
      0x00,
      0x00,
      0x11,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x05,
      0x2a,
      0xb7,
      0x00,
      0x0b,
      0xb1,
      0x00,
      0x00,
      0x00,
      0x00,
    ]);
    // show(String)V：直接 return
    out.addAll([
      0x00,
      0x09,
      0x00,
      0x08,
      0x00,
      0x09,
      0x00,
      0x01,
      0x00,
      0x07,
      0x00,
      0x00,
      0x00,
      0x0d,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0xb1,
      0x00,
      0x00,
      0x00,
      0x00,
    ]);
    out.addAll([0x00, 0x00]);
    return Uint8List.fromList(out);
  }

  /// 已被验证可用的 payload（`className` → 文件名，`*` = 全局默认）。
  Future<Map<String, String>> _payloadIndex(String key) async {
    final cached = _payloadIndexCache[key];
    if (cached != null) return cached;
    final index = <String, String>{};
    final dir = Directory(p.join((await _cacheDir()).path, 'payloads', key));
    final file = File(p.join(dir.path, 'index.json'));
    try {
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final name = '${v ?? ''}';
            if (name.isNotEmpty && File(p.join(dir.path, name)).existsSync()) {
              index['$k'] = name;
            }
          });
        }
      }
    } catch (_) {
      // 索引损坏时当作没有：下一次成功会重写
    }
    // 清掉「让某只壳加载失败」的脏记录。
    //
    // 老版本曾把 `*` 无条件当候选，导致某些壳被记到不含它的包上；这些记录会
    // 一直留着，表现为「以前能用、现在一直失败」。精确记录若不含目标类，
    // 说明它是在错误候选上写下的，删除后由本次调用重新扫描出正确包。
    await _dropStaleIndexEntries(key, dir, index);
    _payloadIndexCache[key] = index;
    return index;
  }

  /// 校验并删除 index 里「包中不含目标类」的精确记录。
  Future<void> _dropStaleIndexEntries(
    String key,
    Directory dir,
    Map<String, String> index,
  ) async {
    final stale = <String>[];
    for (final entry in index.entries) {
      if (entry.key == '*') continue; // `*` 在选择时另行校验，见 _payloadCandidates
      final cls = entry.key;
      final wanted = _payloadClassEntries(cls);
      if (wanted.isEmpty) continue;
      final file = File(p.join(dir.path, entry.value));
      if (!file.existsSync()) continue;
      try {
        final names = await _zipNames(file);
        if (!names.any(wanted.contains)) {
          stale.add(cls);
          AppLog.i(
            'jar',
            '清理过期载荷索引 key=$key class=$cls pkg=${entry.value}（包内无该类）',
          );
        }
      } catch (_) {
        // 读不了包就保持原样，交给运行时判定
      }
    }
    if (stale.isEmpty) return;
    for (final cls in stale) {
      index.remove(cls);
    }
    try {
      final file = File(p.join(dir.path, 'index.json'));
      await file.writeAsString(jsonEncode(index), flush: true);
    } catch (_) {
      // 写失败时至少内存里已清掉
    }
  }

  Future<void> _rememberPayload(
    String key,
    String className,
    String path,
  ) async {
    final index = await _payloadIndex(key);
    final name = p.basename(path);
    var changed = false;
    if (index[className] != name) {
      index[className] = name;
      changed = true;
    }
    if (!index.containsKey('*')) {
      index['*'] = name;
      changed = true;
    }
    if (!changed) return;
    try {
      final dir = Directory(p.join((await _cacheDir()).path, 'payloads', key));
      dir.createSync(recursive: true);
      await File(p.join(dir.path, 'index.json'))
          .writeAsString(jsonEncode(index), flush: true);
    } catch (_) {
      // 索引写失败只影响下次选择，不阻断调用
    }
  }

  /// 加固壳类名 → payload 里可能出现的真实类（壳类去掉 Guard / DexNative 后缀）。
  List<String> _payloadClassEntries(String? className) {
    if (className == null || className.isEmpty) return const [];
    final full = className.replaceAll('/', '.');
    final simple = full.split('.').last;
    final base = simple.endsWith('Guard')
        ? simple.substring(0, simple.length - 'Guard'.length)
        // 嗷呜系壳（AowuShinidie）：壳类 `WoggAmns` → 真实实现 `Wogg`。
        : simple.endsWith('Amns')
        ? simple.substring(0, simple.length - 'Amns'.length)
        : simple.endsWith('DexNative')
        ? simple.substring(0, simple.length - 'DexNative'.length)
        : '';
    final names = <String>[full];
    if (base.isNotEmpty) {
      names.add('${full.substring(0, full.length - simple.length)}$base');
    }
    return names.map((e) => '${e.replaceAll('.', '/')}.class').toList();
  }

  /// 把本次原生调用中新产生的解密产物收进 payload 缓存。
  ///
  /// 一次解包就是一份 1.9 MB 的整包：历史实现每搜一次就多存一份，既占盘又会让
  /// shell-shim 的类加载路径变乱。这里按内容去重，并只留最新两份。
  Future<void> _cachePayload(
    String key,
    int startedAtMs, {
    String? className,
  }) async {
    final root = (await _cacheDir()).path;
    final dest = Directory(p.join(root, 'payloads', key));
    if (dest.existsSync()) {
      for (final f in dest.listSync().whereType<File>()) {
        if (p.basename(f.path).contains('.part.jar')) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    }
    final src = Directory(p.join(root, 'native', 'runtime_dex'));
    if (src.existsSync()) {
      for (final f in src.listSync().whereType<File>()) {
        if (!_isPayloadJar(f)) continue;
        if (f.lastModifiedSync().millisecondsSinceEpoch < startedAtMs - 2000) {
          continue;
        }
        if ((await _zipNames(f)).isEmpty) continue;
        dest.createSync(recursive: true);
        final target = File(p.join(dest.path, p.basename(f.path)));
        if (target.existsSync()) continue;
        final digest = await _fileMd5(f);
        var duplicate = false;
        for (final old in dest.listSync().whereType<File>()) {
          if (!_isPayloadJar(old) || old.lengthSync() != f.lengthSync()) {
            continue;
          }
          if (await _fileMd5(old) == digest) {
            duplicate = true;
            break;
          }
        }
        if (!duplicate) f.copySync(target.path);
      }
    }
    // 壳复用 runtime_dex 里的旧产物时不会再重写文件（mtime 过滤会一份都不收）——
    // payloads 目录因此变空，调用侧就会「payload 已解包却没有候选」。这里按类名补收。
    if (!dest.existsSync() ||
        !dest.listSync().whereType<File>().any((f) => _isPayloadJar(f))) {
      await _adoptRuntimePayloads(key, className: className);
    }
    if (!dest.existsSync()) return;
    final kept =
        dest
            .listSync()
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.r2.jar'))
            .toList()
          ..sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );
    // 只留「索引指向的可用包 + 最新两个 + 最早一个」：新包可能是热更新拉到的不兼容
    // 版本，旧包反而能配当前兼容层，不能只按时间裁。
    final index = await _payloadIndex(key);
    final keepNames = <String>{
      ...index.values,
      for (var i = 0; i < kept.length && i < 2; i++) p.basename(kept[i].path),
      if (kept.isNotEmpty) p.basename(kept.last.path),
    };
    for (final file in kept) {
      if (keepNames.contains(p.basename(file.path))) continue;
      try {
        file.deleteSync();
      } catch (_) {}
    }
  }

  bool _isPayloadJar(File f) {
    final lower = f.path.toLowerCase();
    return lower.endsWith('.r2.jar') && f.lengthSync() > 1024;
  }

  /// 把 `native/runtime_dex` 里已解包、但没进 `payloads/<key>` 的包补进缓存。
  ///
  /// 触发场景（实测）：壳复用同一份解包产物时不再重写文件，`_cachePayload` 的
  /// mtime 过滤会一份都不收 → `payloads/<key>` 为空 → 明明解包成功却找不到候选，
  /// 播放直接报「依赖模拟器进程」。这里按当前壳类名从 runtime_dex 补收。
  Future<void> _adoptRuntimePayloads(String key, {String? className}) async {
    if (className == null || className.isEmpty) return;
    final root = (await _cacheDir()).path;
    final dest = Directory(p.join(root, 'payloads', key));
    if (dest.existsSync() &&
        dest.listSync().whereType<File>().any((f) => _isPayloadJar(f))) {
      return;
    }
    final src = Directory(p.join(root, 'native', 'runtime_dex'));
    if (!src.existsSync()) return;
    final wanted = _payloadClassEntries(className)
        .map((e) => e.toLowerCase())
        .toList();
    if (wanted.isEmpty) return;
    // index.json 里记录的是「本机已验证可用」的包：优先补它，别让热更新拉到的新包顶掉。
    final preferred = <String>{};
    try {
      final indexFile = File(p.join(dest.path, 'index.json'));
      if (indexFile.existsSync()) {
        final decoded = jsonDecode(indexFile.readAsStringSync());
        if (decoded is Map) {
          for (final value in decoded.values) {
            final name = '$value'.trim();
            if (name.isNotEmpty) preferred.add(name);
          }
        }
      }
    } catch (_) {
      // 索引损坏 → 只按时间兜底
    }
    final candidates =
        src.listSync().whereType<File>().where(_isPayloadJar).toList()
          ..sort((a, b) {
            final ap = preferred.contains(p.basename(a.path)) ? 0 : 1;
            final bp = preferred.contains(p.basename(b.path)) ? 0 : 1;
            if (ap != bp) return ap - bp;
            return b.lastModifiedSync().compareTo(a.lastModifiedSync());
          });
    var copied = 0;
    for (final file in candidates) {
      if (copied >= _payloadMaxCandidates) break;
      final names = await _zipNames(file);
      if (names.isEmpty ||
          !names.any((n) => wanted.contains(n.toLowerCase()))) {
        continue;
      }
      try {
        dest.createSync(recursive: true);
        final target = File(p.join(dest.path, p.basename(file.path)));
        if (!target.existsSync()) {
          file.copySync(target.path);
        }
        copied++;
      } catch (_) {
        // 复制失败（占用/磁盘）不阻断：调用侧会退回原生解包
      }
    }
  }

  Future<void> _markNativeOnly(String key, String className) async {
    // 只在本次会话内记住：下次启动会重新尝试 shell-shim（payload 可能已被重新解包）。
    _nativeOnly.add('$key|$className');
  }

  Future<String> _invoke(
    SourceBean site,
    String method,
    List<String> args, {
    bool hold = false,
    bool allowPayloadRetry = true,
    void Function(JarServeHost host, String key)? serveHostListener,
    String? servePoolSuffix,
    bool forceAowu = false,
  }) async {
    if (!await runtime.installed()) {
      final result = await RuntimeInstallPrompt.instance.ensure(
        RuntimeExtension.jvm,
      );
      if (result != RuntimePromptResult.ready) {
        throw SourceException(result.messageFor(RuntimeExtension.jvm));
      }
    }
    final java = await runtime.javaExecutable();
    if (java.isEmpty) throw SourceException('JVM 运行时缺少 java.exe，请在设置中重新安装');
    final jvmDir = (await runtime.directory()).path;
    await runtime.ensureShims();
    await _syncCreds(site);

    final raw = await _rawJar(site);
    final key = p.basenameWithoutExtension(raw.path);
    final hasSo = await _jarHasSo(raw);
    final className = _className(site);
    // 只有本次要调用的壳类确实是嗷呜系，才挂 aowu-shim；wex 的 WoggGuard
    // 不能被同一个聚合 jar 里的 Amns 类带偏。
    final aowu = hasSo && (forceAowu || _jarHasAowu(className));
    final realShim = hasSo ? await _realShellShim(raw, className) : null;

    // 加固壳且没有缓存 payload/内置真实实现：先确认 ARM 桥已安装，避免先花几分钟
    // dex2jar 转换、最后才提示「需要下载加固壳支持」。
    if (hasSo && realShim == null) {
      final payloads = await _payloadCandidates(
        key,
        className: className,
        preferAssets: true,
      );
      if (payloads.isEmpty && !await ArmBridgeRuntime.instance.installed()) {
        final result = await RuntimeInstallPrompt.instance.ensure(
          RuntimeExtension.guard,
        );
        if (result != RuntimePromptResult.ready) {
          throw SourceException(result.messageFor(RuntimeExtension.guard));
        }
      }
    }

    final jar = await _jarFor(site);
    final ext = enrichSpiderExt(site.ext, driveTokens?.call() ?? const {});
    final spiderDir = p.join((await _cacheDir()).path, 'spider');

    if (!hasSo) {
      final classpath = await _baseShims(jvmDir);
      // 播放（hold）也必须常驻：普通 jar 的 `playerContent` 同样会回
      // `http://127.0.0.1:9978/proxy?do=bili&…` 这类**宿主代理**地址
      // （哔哩合集 / csp_Bili 就是这样），一次性进程打完结果即退出，地址随即
      // 失效。挂上宿主代理 props，`com.github.catvod.Proxy` 才会监听，
      // 播放器打到该 JVM 的真实端口才有响应。
      if (hold) {
        try {
          return await _runHold(
            java: java,
            classpath: classpath,
            jar: jar,
            className: className,
            method: method,
            ext: ext,
            args: args,
            heap: '256m',
            timeout: Duration(seconds: site.timeout + 120),
            jvmDir: jvmDir,
            extraProps: await _proxyProps(jar),
          );
        } on SourceException catch (e) {
          await _releasePlayHost();
          // 拿不到常驻 host 时仍退回一次性进程：远程直链的源不受影响。
          AppLog.w(
            'jar',
            '--hold 失败，回退一次性进程 ${site.key} '
                'method=$method: ${shorten(e.message, 160)}',
          );
        }
      } else {
        try {
          return await _runServe(
            key: servePoolSuffix == null ? key : '$key$servePoolSuffix',
            java: java,
            classpath: classpath,
            jar: jar,
            className: className,
            method: method,
            ext: ext,
            args: args,
            heap: '256m',
            timeout: Duration(seconds: site.timeout + 30),
            proxy: false,
            serveHostListener: serveHostListener,
          );
        } on ServeHostException {
          // 常驻进程起不来（JVM 启动失败等）→ 退回一次性进程
        }
      }
      return _runJava(
        java: java,
        classpath: classpath,
        jar: jar,
        className: className,
        method: method,
        ext: ext,
        args: args,
        heap: '256m',
        timeout: Duration(seconds: site.timeout + 30),
        jvmDir: jvmDir,
      );
    }

    // 内置真实实现（winbox `shell-shim/real/<壳名>.jar`）：纯 Java 快路径，
    // 不挂 unidbg（模拟器在 x64 上对 ftyshinidie 系会崩在 toIntPeer(null)），
    // 也不需要 payload/原生桥。
    if (realShim != null) {
      final classpath = [
        p.join(jvmDir, 'shims', 'shell-shim.jar'),
        ...await _baseShims(jvmDir),
      ];
      final baseProps = [
        '-Dtvbox.shellShimClasses=${await _shimSpecWithProxyBridge(realShim)}',
        '-Dtvbox.spiderCacheDir=$spiderDir',
      ];
      if (hold) {
        try {
          return await _runHold(
            java: java,
            classpath: classpath,
            jar: jar,
            className: className,
            method: method,
            ext: ext,
            args: args,
            heap: '384m',
            timeout: Duration(seconds: site.timeout + 120),
            jvmDir: jvmDir,
            extraProps: [...baseProps, ...await _proxyProps(jar)],
          );
        } on SourceException catch (e) {
          await _releasePlayHost();
          // 内置实现与当前壳版本不匹配 → 继续走下面的 payload / 原生路径
          if (!_shimMiss(e.message)) rethrow;
        }
      } else {
        try {
          return await _runServe(
            key: servePoolSuffix == null
                ? '$key|real'
                : '$key|real$servePoolSuffix',
            java: java,
            classpath: classpath,
            jar: jar,
            className: className,
            method: method,
            ext: ext,
            args: args,
            heap: '384m',
            timeout: Duration(seconds: site.timeout + 60),
            proxy: true,
            extraProps: baseProps,
            serveHostListener: serveHostListener,
          );
        } on ServeHostException {
          // 常驻起不来 → 一次性
        } on SourceException catch (e) {
          if (!_shimMiss(e.message)) rethrow;
        }
        try {
          return await _runJava(
            java: java,
            classpath: classpath,
            jar: jar,
            className: className,
            method: method,
            ext: ext,
            args: args,
            heap: '384m',
            timeout: Duration(seconds: site.timeout + 60),
            jvmDir: jvmDir,
            extraProps: [...baseProps, ...await _proxyProps(jar)],
          );
        } on SourceException catch (e) {
          if (!_shimMiss(e.message)) rethrow;
        }
      }
    }

    // 加固壳：优先 shell-shim 纯 Java 快路径（payload 已解包过）。
    // 缓存里可能同时躺着多个版本的 payload（壳会从远端热更新），只有和本机兼容层
    // 匹配的那份才跑得起来；所以逐个候选试，成功即记为该类的可用包。
    final ownPayloads = await _payloadCandidates(
      key,
      className: className,
      preferAssets: true,
    );
    if (ownPayloads.isNotEmpty) {
      // 站点自己的 payload 可能缺少匿名类（桌面解包产物常见），失败后到其它
      // 壳缓存里找同一个真实实现；壳类只是委托，换包通常能直接跑通。
      // 回退搜索只在第一次遇到类不兼容错误时做，正常源不额外扫其它缓存。
      final payloads = <String>[...ownPayloads];
      var fallbackLoaded = false;
      final ownSet = ownPayloads.toSet();
      // 载荷类自带 ARM native（LoadNiMa / MyCrypto / GoProxy）：必须把原生桥挂在
      // 快路径上，并加载「解包时打好补丁」的合成 jar，否则 x64 JVM 一调 native 就
      // UnsatisfiedLinkError / 载荷桥未登记方法。
      final native = await _payloadBridge(java: java, jvmDir: jvmDir);
      final cp = [
        p.join(jvmDir, 'shims', 'shell-shim.jar'),
        if (aowu) p.join(jvmDir, 'shims', 'aowu-shim.jar'),
        ...await _baseShims(jvmDir),
        ...native.classpath,
      ];
      final heap = native.ready ? '768m' : '384m';
      for (var index = 0; index < payloads.length; index++) {
        final payload = payloads[index];
        final shim = native.ready
            ? await _payloadShim(payload, excludeAowuCrypto: aowu)
            : null;
        final aowuShim = aowu ? await _aowuPayloadShim(payload) : null;
        final classes = shim?.path ?? aowuShim?.path ?? payload;
        final baseProps = [
          '-Dtvbox.shellShimClasses=${await _shimSpecWithProxyBridge(classes)}',
          '-Dtvbox.spiderCacheDir=$spiderDir',
          ...native.props,
        ];
        if (hold) {
          try {
            final text = await _runHold(
              java: java,
              classpath: cp,
              jar: jar,
              className: className,
              method: method,
              ext: ext,
              args: args,
              heap: heap,
              timeout: Duration(
                seconds: site.timeout + (native.ready ? 180 : 120),
              ),
              jvmDir: jvmDir,
              extraProps: [...baseProps, ...await _proxyProps(jar)],
            );
            if (text.trim().isNotEmpty) {
              final used = ownSet.contains(payload)
                  ? payload
                  : await _adoptForeignPayload(key, className, payload);
              await _rememberPayload(key, className, used);
            }
            return text;
          } on SourceException catch (e) {
            final incompatible = _payloadIncompatible(e.message);
            final candidateFailure =
                _shimMiss(e.message) ||
                incompatible ||
                _looksLikeAowuError(e.message);
            if (!candidateFailure) rethrow;
            if (incompatible) {
              _brokenPayloads.add(payload);
              if (ownSet.contains(payload)) {
                // 本壳的坏包（dex2jar NEW 抽象类误译等）当场隔离：留着只会让每次
                // 调用都白起一只 JVM。隔离后下次从 runtime_dex 收编修复后的新包，
                // 或走原生重解包（见 _quarantinePayload）。
                await _quarantinePayload(payload);
              }
              if (!fallbackLoaded) {
                fallbackLoaded = true;
                payloads.addAll(await _fallbackPayloads(key, className));
              }
            }
            _dropPayload(payload, e.message);
            continue;
          }
        }
        final poolKey =
            '${_servePoolKey(key, payload)}${shim == null ? '' : '|shim'}';
        final runKey = servePoolSuffix == null
            ? poolKey
            : '$poolKey$servePoolSuffix';
        try {
          final text = await _runServe(
            key: runKey,
            java: java,
            classpath: cp,
            jar: jar,
            className: className,
            method: method,
            ext: ext,
            args: args,
            heap: heap,
            timeout: Duration(
              seconds: site.timeout + (native.ready ? 120 : 30),
            ),
            proxy: true,
            extraProps: baseProps,
            serveHostListener: serveHostListener,
          );
          if (text.trim().isNotEmpty) {
            final used = ownSet.contains(payload)
                ? payload
                : await _adoptForeignPayload(key, className, payload);
            await _rememberPayload(key, className, used);
          }
          return text;
        } on ServeHostException {
          // 常驻进程起不来（JVM 启动失败等）→ 退回一次性进程
          break;
        } on SourceException catch (e) {
          final incompatible = _payloadIncompatible(e.message);
          final candidateFailure =
              _shimMiss(e.message) ||
              incompatible ||
              _looksLikeAowuError(e.message);
          if (!candidateFailure) rethrow;
          if (incompatible) {
            _brokenPayloads.add(payload);
            if (ownSet.contains(payload)) await _quarantinePayload(payload);
            if (!fallbackLoaded) {
              fallbackLoaded = true;
              payloads.addAll(await _fallbackPayloads(key, className));
            }
          }
          _dropPayload(payload, e.message);
          await _closeServePool(runKey);
        }
      }
      // 所有候选都不行：一次性进程再试第一个未确认损坏的候选（类加载器不同，偶有差异）。
      // 坏包已全部隔离时不要再起一次性进程 —— 直接落到原生重解包。
      final available = payloads
          .where((p) => !_brokenPayloads.contains(p))
          .toList();
      if (available.isNotEmpty) {
        final first = available.first;
        final shim = native.ready
            ? await _payloadShim(first, excludeAowuCrypto: aowu)
            : null;
        final aowuShim = aowu ? await _aowuPayloadShim(first) : null;
        final classes = shim?.path ?? aowuShim?.path ?? first;
        final baseProps = [
          '-Dtvbox.shellShimClasses=${await _shimSpecWithProxyBridge(classes)}',
          '-Dtvbox.spiderCacheDir=$spiderDir',
          ...native.props,
        ];
        try {
          final text = await _runJava(
            java: java,
            classpath: cp,
            jar: jar,
            className: className,
            method: method,
            ext: ext,
            args: args,
            heap: heap,
            timeout: Duration(
              seconds: site.timeout + (native.ready ? 120 : 30),
            ),
            jvmDir: jvmDir,
            extraProps: [...baseProps, ...await _proxyProps(jar)],
          );
          if (text.trim().isNotEmpty) {
            final used = ownSet.contains(first)
                ? first
                : await _adoptForeignPayload(key, className, first);
            await _rememberPayload(key, className, used);
          }
          return text;
        } on SourceException catch (e) {
          final incompatible = _payloadIncompatible(e.message);
          final candidateFailure =
              _shimMiss(e.message) ||
              incompatible ||
              _looksLikeAowuError(e.message);
          if (!candidateFailure) rethrow;
          if (incompatible) {
            _brokenPayloads.add(first);
            if (ownSet.contains(first)) await _quarantinePayload(first);
            // 不再直接抛错：坏包已隔离，继续走下面的原生重解包，产出修复后的新包
          } else {
            _dropPayload(first, e.message);
            await _markNativeOnly(key, className);
          }
        }
      }
    }

    // 还没有 payload：只允许一个 unidbg 解包。搜索会并发派发多个加固壳源，
    // 同时起 3 只 768m 的模拟器进程就是「一搜内存就爆」的根因；排队后先到的
    // 解出整包，后面的直接用它的产物走 shell-shim 快路径。
    final previousGate = _nativeGate;
    final unlock = Completer<void>();
    _nativeGate = unlock.future;
    await previousGate;
    try {
      if ((await _payloadCandidates(
        key,
        className: className,
        preferAssets: true,
      )).isNotEmpty) {
        return await _invoke(
          site,
          method,
          args,
          hold: hold,
          allowPayloadRetry: allowPayloadRetry,
          serveHostListener: serveHostListener,
          servePoolSuffix: servePoolSuffix,
          forceAowu: forceAowu,
        );
      }
      final armReady = await ArmBridgeRuntime.instance.installed();
      if (!armReady) {
        final result = await RuntimeInstallPrompt.instance.ensure(
          RuntimeExtension.guard,
        );
        if (result != RuntimePromptResult.ready) {
          throw SourceException(result.messageFor(RuntimeExtension.guard));
        }
      }
      await _ensureNativeDirs();
      final bridge = await runtime.ensureBridgeJar();
      final uniJars = await ArmBridgeRuntime.instance.jarPaths();
      if (uniJars.isEmpty) throw SourceException('加固壳支持不完整，请在设置中重新下载');
      final startedAt = DateTime.now().millisecondsSinceEpoch;
      final nativeProps = [
        '-Dtvbox.native.backend=dynarmic',
        '-Dtvbox.native.work=${p.join((await _cacheDir()).path, 'native', 'work')}',
        '-Dtvbox.native.patch=${p.join((await _cacheDir()).path, 'native', 'patch')}',
        '-Dtvbox.d2j.java=$java',
        '-Dtvbox.d2j.cp=${_d2jJars(jvmDir)}',
        '-Dtvbox.d2j.cache=${p.join((await _cacheDir()).path, 'native', 'runtime_dex')}',
        '-Dtvbox.spiderCacheDir=$spiderDir',
        ...await _proxyProps(jar),
      ];
      final nativeClasspath = [
        ...await _baseShims(jvmDir),
        bridge.path,
        ...uniJars,
      ];

      // 播放必须让「解包它的这只 JVM」常驻：壳的取流地址指向壳内多线程服务 / 宿主代理，
      // 一次性进程返回后模拟器与代理都已退出，地址必然连不上（用户侧「依赖模拟器进程」）。
      // 这里直接以原生桥跑 `--hold`，成功后地址在整个播放期间始终可达。
      if (hold) {
        String nativeError = '';
        try {
          final text = await _runHold(
            java: java,
            classpath: nativeClasspath,
            jar: jar,
            className: className,
            method: method,
            ext: ext,
            args: args,
            heap: '768m',
            timeout: const Duration(seconds: 300),
            jvmDir: jvmDir,
            extraProps: nativeProps,
          );
          await _cachePayload(key, startedAt, className: className);
          if (text.trim().isNotEmpty) return text;
        } on SourceException catch (e) {
          nativeError = e.message;
          await _releasePlayHost();
        }
        // 原生常驻失败（模拟器兼容层/壳看门狗）时仍要跑一次**一次性**原生：
        // 它的结果地址不可用于播放，但这次调用会让壳把 payload 解出来并落进
        // runtime_dex（旧实现正是靠这一步），随后就能按 shell-shim 快路径常驻。
        try {
          await _runJava(
            java: java,
            classpath: nativeClasspath,
            jar: jar,
            className: className,
            method: method,
            ext: ext,
            args: args,
            heap: '768m',
            timeout: const Duration(seconds: 300),
            jvmDir: jvmDir,
            extraProps: nativeProps,
          );
        } on SourceException catch (e) {
          if (nativeError.isEmpty) nativeError = e.message;
        } finally {
          await _cachePayload(key, startedAt, className: className);
        }
        // 刚解出的 payload 已进缓存：清掉 native-only 标记后按 shell-shim 快路径
        // 常驻重试一次（只重试一次，避免兼容包死循环）。
        _nativeOnly.remove('$key|$className');
        if (allowPayloadRetry &&
            (await _payloadCandidates(
              key,
              className: className,
              preferAssets: true,
            )).isNotEmpty) {
          return await _invoke(
            site,
            method,
            args,
            hold: true,
            allowPayloadRetry: false,
            serveHostListener: serveHostListener,
            servePoolSuffix: servePoolSuffix,
            forceAowu: forceAowu,
          );
        }
        throw SourceException(
          nativeError.isEmpty
              ? '该加固壳的取流地址依赖模拟器进程，暂不支持播放；请重试一次（payload 已解包）'
              : '加固壳取流进程启动失败：$nativeError',
        );
      }

      String nativeResult;
      try {
        try {
          nativeResult = await _runJava(
            java: java,
            classpath: nativeClasspath,
            jar: jar,
            className: className,
            method: method,
            ext: ext,
            args: args,
            heap: '768m',
            timeout: const Duration(seconds: 300),
            jvmDir: jvmDir,
            extraProps: nativeProps,
          );
        } finally {
          await _cachePayload(key, startedAt, className: className);
          // 下次调用自动走 shell-shim；本次已返回原生结果
        }
        return nativeResult;
      } on SourceException {
        // 嗷呜系壳的专有原生加密库在桌面装不起来（awenc 只支持 64 位 Dalvik），
        // 但这次调用已经把真实实现解包落盘。立刻改走 shell-shim 快路径：标准
        // 加密（MD5/SHA/HMAC/AES）由纯 Java 影子类接管，不再整源失败。
        if (aowu &&
            allowPayloadRetry &&
            (await _payloadCandidates(
              key,
              className: className,
              preferAssets: true,
            )).isNotEmpty) {
          return await _invoke(
            site,
            method,
            args,
            hold: hold,
            allowPayloadRetry: false,
            serveHostListener: serveHostListener,
            servePoolSuffix: servePoolSuffix,
            forceAowu: forceAowu,
          );
        }
        rethrow;
      }
    } finally {
      unlock.complete();
    }
  }

  /// 常规壳路径失败后的嗷呜兜底：只在接口本身失败、包里确实带 awenc/awdm、
  /// 且本次壳类不是嗷呜系（`*Amns` / `Aowu`）时才重试一次。
  ///
  /// 这是「wex 先用 wex 的思路，失败后再借嗷呜的修复思路」，不是把所有壳都
  /// 当成嗷呜来解包。
  Future<String> _invokeWithAowuFallback(
    SourceBean site,
    String method,
    List<String> args, {
    bool hold = false,
    bool allowPayloadRetry = true,
    void Function(JarServeHost host, String key)? serveHostListener,
    String? servePoolSuffix,
  }) async {
    try {
      return await _invoke(
        site,
        method,
        args,
        hold: hold,
        allowPayloadRetry: allowPayloadRetry,
        serveHostListener: serveHostListener,
        servePoolSuffix: servePoolSuffix,
      );
    } on SourceException catch (e) {
      if (!_looksLikeAowuError(e.message)) rethrow;
      final className = _className(site);
      if (_jarHasAowu(className)) rethrow;
      File? raw;
      try {
        raw = await _rawJar(site);
      } catch (_) {
        raw = null;
      }
      var hasLibs = false;
      if (raw != null) {
        try {
          hasLibs = await _jarHasAowuLibs(raw);
        } catch (_) {
          hasLibs = false;
        }
      }
      if (!hasLibs) rethrow;
      AppLog.w(
        'jar',
        '常规路径失败，按嗷呜思路重试 class=$className '
            'msg=${shorten(e.message, 160)}',
      );
      return await _invoke(
        site,
        method,
        args,
        hold: hold,
        allowPayloadRetry: false,
        serveHostListener: serveHostListener,
        servePoolSuffix: servePoolSuffix,
        forceAowu: true,
      );
    }
  }

  /// 常驻（`--hold`）：打完结果不退出，让壳内取流服务/宿主代理活着，供播放器取流。
  Future<String> _runHold({
    required String java,
    required List<String> classpath,
    required String jar,
    required String className,
    required String method,
    required String ext,
    required List<String> args,
    required String heap,
    required Duration timeout,
    required String jvmDir,
    List<String> extraProps = const [],
  }) async {
    final argv = <String>[
      '-noverify',
      '-Xmx$heap',
      '-XX:+UseSerialGC',
      '-XX:TieredStopAtLevel=1',
      '-Dfile.encoding=UTF-8',
      '-Dsun.stdout.encoding=UTF-8',
      '-Dsun.stderr.encoding=UTF-8',
      '--add-opens=java.base/java.lang=ALL-UNNAMED',
      '--add-opens=java.base/java.lang.reflect=ALL-UNNAMED',
      '--add-opens=java.base/java.lang.invoke=ALL-UNNAMED',
      '--add-opens=java.base/java.util=ALL-UNNAMED',
      '--add-opens=java.base/java.util.concurrent=ALL-UNNAMED',
      '--add-opens=java.base/java.io=ALL-UNNAMED',
      '--add-opens=java.base/java.net=ALL-UNNAMED',
      '--add-opens=java.base/java.nio=ALL-UNNAMED',
      '--add-opens=java.base/java.security=ALL-UNNAMED',
      '--add-opens=java.base/java.text=ALL-UNNAMED',
      '--add-opens=java.base/sun.net.www.protocol.jar=ALL-UNNAMED',
      ...extraProps,
      ...ProxyRuntime.instance.jvmProps,
      '-cp',
      classpath.join(';'),
      'SpiderHost',
      '--hold',
      jar,
      className,
      method,
      ext,
      ...args,
    ];
    argv.insert(0, await _jvmErrorFile());
    try {
      final host = await JarSpiderHost.start(
        java: java,
        argv: argv,
        timeout: timeout,
      );
      // JVM 会先在 stderr 报实际绑定端口（[host-proxy] listening port=）；
      // 还没报到时用确定性端口兜底，报到了就不覆盖（端口冲突会退化到临时端口）。
      //
      // ★ 兜底必须用**与 `_proxyProps` 完全相同的 key**（jar 的完整路径）。
      // `-Dtvbox.proxy.port` 是按 `_proxyPort(jarPath)` 算的；这里若拿
      // `basenameWithoutExtension` 再算一次，两者是不同的端口（实测同一份 jar：
      // 完整路径 → 19980，basename → 19976）。当 stubs 的 `com.github.catvod.Proxy`
      // 没能起监听、stderr 没有 `[host-proxy]` 那行时，`rewriteLocalProxy` 会把壳吐出的
      // `127.0.0.1:<壳端口>/proxy?do=bili…` 改写到这个**没人监听**的兜底端口，
      // 播放器拿到连接被拒 → 「invalid or unsupported media」（高中课堂 / B站线路实测）。
      if (host.proxyPort <= 0) {
        host.proxyPort = _proxyPort(jar);
      }
      String text;
      try {
        text = await host.firstResult(timeout);
      } catch (e) {
        final tail = host.errorTail;
        await host.close();
        // 只有真正的 JVM 崩溃才算 payload 不兼容；蜘蛛自己的业务异常（如
        // JSONException: JSONObject["data"] not found）不能把候选包丢掉，
        // 否则整个会话都会退化成一次性进程（取流地址随进程退出立即失效）。
        if (_jvmCrashed(tail)) {
          AppLog.e(
            'jar',
            '--hold JVM 崩溃 class=$className method=$method ${_crashKind(tail)}',
          );
          throw SourceException(
            'JVM 崩溃（${_crashKind(tail)}），该 payload 与本机兼容层不匹配',
          );
        }
        final described = JarSpiderHost.describe(_lastHostErrors(host));
        final friendly = await _errorText('', tail);
        AppLog.e(
          'jar',
          '--hold 失败 class=$className method=$method: ${shorten(friendly, 300)}',
        );
        throw SourceException(
          friendly == 'JAR 蜘蛛执行失败' || friendly.isEmpty
              ? (described.isEmpty ? '取流进程启动失败' : described)
              : friendly,
        );
      }
      if (text.isEmpty) {
        final tail = host.errorTail;
        await host.close();
        final message = await _errorText('', tail);
        AppLog.e(
          'jar',
          '--hold 无输出 class=$className method=$method: ${shorten(message, 300)}',
        );
        throw SourceException(message);
      }
      AppLog.i(
        'jar',
        '--hold 就绪 class=$className method=$method pid=${host.pid} '
            'proxy=${host.proxyPort}',
      );
      _playHost = host;
      return text;
    } on ProcessException catch (e) {
      throw SourceException('JVM 启动失败：${e.message}');
    }
  }

  List<String> _lastHostErrors(JarSpiderHost host) {
    final tail = host.errorTail;
    return tail.isEmpty ? const [] : tail.split('\n');
  }

  // ---------------------------------------------------------------------------
  // 常驻 browse / search host（`SpiderHost --serve`）
  // ---------------------------------------------------------------------------

  /// 走常驻 host 调一次方法。host 起不来时抛 [ServeHostException] 让上层退回一次性进程；
  /// 调用本身失败（超时 / 进程退出 / 蜘蛛异常）统一转成 [SourceException]。
  Future<String> _runServe({
    required String key,
    required String java,
    required List<String> classpath,
    required String jar,
    required String className,
    required String method,
    required String ext,
    required List<String> args,
    required String heap,
    required Duration timeout,
    required bool proxy,
    List<String> extraProps = const [],
    void Function(JarServeHost host, String key)? serveHostListener,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final host = await _acquireServeHost(
        key: key,
        java: java,
        classpath: classpath,
        jar: jar,
        heap: heap,
        proxy: proxy,
        extraProps: extraProps,
      );
      _touchServe(key);
      ServeReply reply;
      try {
        reply = await host.call(
          className: className,
          method: method,
          args: [ext, ...args],
          timeout: timeout,
        );
      } on ServeHostException catch (e) {
        // 壳内的守护线程会自行退出（加固壳看门狗）/偶发崩溃：与 payload 无关，
        // 换一只新进程重试一次；池里已剔除死 host。
        if (attempt == 0 &&
            (e.message.contains('已断开') || e.message.contains('已退出'))) {
          continue;
        }
        throw SourceException('常驻蜘蛛调用失败：${e.message}');
      }
      _touchServe(key);
      if (!reply.ok) {
        throw SourceException(await _errorText(reply.data, host.errorTail));
      }
      final text = reply.data.trim();
      // 让播放回退拿到「真正执行过这次调用」的 host（同一个 SpiderPool 实例）。
      // 即使返回空串也要回调：预热用的 homeContent 可能返回空，但实例已经
      // 解完挑战、Cookie 也已就位。
      serveHostListener?.call(host, key);
      return text;
    }
    throw SourceException('常驻蜘蛛调用失败');
  }

  Future<JarServeHost> _acquireServeHost({
    required String key,
    required String java,
    required List<String> classpath,
    required String jar,
    required String heap,
    required bool proxy,
    required List<String> extraProps,
  }) async {
    final pool = _servePools.putIfAbsent(key, () => <JarServeHost>[]);
    pool.removeWhere((host) => !host.alive);

    // 有空闲 host 就直接复用：顺序搜索（一次只派一个请求）不该反复冷启 JVM。
    // 只有全部在忙、且还没到上限时才多开一只换并行度。
    for (final host in pool) {
      if (host.inflight == 0) return host;
    }

    final starting = _serveStarting[key] ?? 0;
    if (pool.length + starting < _servePoolMax) {
      _serveStarting[key] = starting + 1;
      try {
        final seq = _serveHostSeq[key] ?? 0;
        _serveHostSeq[key] = seq + 1;
        // 播放 host 占 _proxyPort(key)，serve host 从 +1 起错开，避免端口冲突。
        final port = _proxyPort(key) + 1 + (seq % 12) * 2;
        final argv = <String>[
          '-noverify',
          '-Xmx$heap',
          '-XX:+UseSerialGC',
          // 常驻 --serve 会连续处理浏览 / 搜索 / 详情，不再限制 C1-only：
          // 允许分层编译进入 C2，JSON / HTML 解析的稳态速度更好。一次性
          // 进程与 --hold 仍保留 TieredStopAtLevel=1，优先快启动。
          '-Dfile.encoding=UTF-8',
          '-Dsun.stdout.encoding=UTF-8',
          '-Dsun.stderr.encoding=UTF-8',
          '--add-opens=java.base/java.lang=ALL-UNNAMED',
          '--add-opens=java.base/java.lang.reflect=ALL-UNNAMED',
          '--add-opens=java.base/java.lang.invoke=ALL-UNNAMED',
          '--add-opens=java.base/java.util=ALL-UNNAMED',
          '--add-opens=java.base/java.util.concurrent=ALL-UNNAMED',
          '--add-opens=java.base/java.io=ALL-UNNAMED',
          '--add-opens=java.base/java.net=ALL-UNNAMED',
          '--add-opens=java.base/java.nio=ALL-UNNAMED',
          '--add-opens=java.base/java.security=ALL-UNNAMED',
          '--add-opens=java.base/java.text=ALL-UNNAMED',
          '--add-opens=java.base/sun.net.www.protocol.jar=ALL-UNNAMED',
          ...extraProps,
          ...ProxyRuntime.instance.jvmProps,
          if (proxy) ...[
            '-Dtvbox.proxy.port=$port',
            '-Dtvbox.proxy.entry=http://127.0.0.1:$port/proxy',
          ],
          '-cp',
          classpath.join(';'),
          'SpiderHost',
          '--serve',
          jar,
        ];
        argv.insert(0, await _jvmErrorFile());
        final started = await JarServeHost.start(java: java, argv: argv);
        pool.add(started);
        _touchServe(key);
      } catch (e) {
        // 起不来就继续用池里已有的 host；池空时由下面抛错让上层回退
      } finally {
        final left = (_serveStarting[key] ?? 1) - 1;
        if (left <= 0) {
          _serveStarting.remove(key);
        } else {
          _serveStarting[key] = left;
        }
      }
    }

    if (pool.isEmpty) throw ServeHostException('常驻蜘蛛进程启动失败');
    // 每个 host 是主线程顺序执行：把新请求派给排队最少的那个。
    pool.sort((a, b) => a.inflight.compareTo(b.inflight));
    return pool.first;
  }

  /// serve 池按「jar + payload 包」分开：不同 payload 起的 JVM 类路径不同，不能混用。
  String _servePoolKey(String key, String payload) =>
      '$key|${p.basename(payload)}';

  void _touchServe(String key) {
    _serveIdleTimers.remove(key)?.cancel();
    _serveIdleTimers[key] = Timer(_serveIdleTimeout, () {
      unawaited(_closeServePool(key));
    });
  }

  /// 空闲后释放 serve host：搜索结束一段时间就把内存还给系统；还有请求时不关。
  Future<void> _closeServePool(String key) async {
    _serveIdleTimers.remove(key)?.cancel();
    final pool = _servePools[key];
    if (pool == null) return;
    if (key == _playServeKey) {
      // 正在为播放提供 /chunk 取流：解除 pin 之前不能回收这只 JVM。
      _touchServe(key);
      return;
    }
    if (pool.any((host) => host.inflight > 0)) {
      _touchServe(key);
      return;
    }
    _servePools.remove(key);
    await Future.wait(pool.map((host) => host.close()));
  }

  /// 把已登录网盘凭据同步成 jar 系蜘蛛期望的落盘格式（不写就报「还没有配置夸克 Cookie」）。
  Future<void> _syncCreds(SourceBean site) async {
    try {
      final cache = await _cacheDir();
      await SpiderEnv.sync(
        spiderCacheDir: p.join(cache.path, 'spider'),
        cookies: driveTokens?.call() ?? const {},
        seed: driveSeed?.call() ?? const {},
        dataDir: p.dirname(cache.path),
        ext: site.ext,
      );
    } catch (e, s) {
      // 同步失败不阻断调用：没有凭据时蜘蛛会给出自己的提示文案
      AppLog.w('jar', '网盘凭据落盘失败（蜘蛛可能提示未登录）', e, s);
    }
  }

  Future<String> _runJava({
    required String java,
    required List<String> classpath,
    required String jar,
    required String className,
    required String method,
    required String ext,
    required List<String> args,
    required String heap,
    required Duration timeout,
    required String jvmDir,
    List<String> extraProps = const [],
  }) async {
    final argv = <String>[
      '-noverify',
      '-Xmx$heap',
      '-XX:+UseSerialGC',
      '-XX:TieredStopAtLevel=1',
      '-Dfile.encoding=UTF-8',
      '-Dsun.stdout.encoding=UTF-8',
      '-Dsun.stderr.encoding=UTF-8',
      '--add-opens=java.base/java.lang=ALL-UNNAMED',
      '--add-opens=java.base/java.lang.reflect=ALL-UNNAMED',
      '--add-opens=java.base/java.lang.invoke=ALL-UNNAMED',
      '--add-opens=java.base/java.util=ALL-UNNAMED',
      '--add-opens=java.base/java.util.concurrent=ALL-UNNAMED',
      '--add-opens=java.base/java.io=ALL-UNNAMED',
      '--add-opens=java.base/java.net=ALL-UNNAMED',
      '--add-opens=java.base/java.nio=ALL-UNNAMED',
      '--add-opens=java.base/java.security=ALL-UNNAMED',
      '--add-opens=java.base/java.text=ALL-UNNAMED',
      '--add-opens=java.base/sun.net.www.protocol.jar=ALL-UNNAMED',
      ...extraProps,
      ...ProxyRuntime.instance.jvmProps,
      '-cp',
      classpath.join(';'),
      'SpiderRunner',
      jar,
      className,
      method,
      ext,
      ...args,
    ];
    argv.insert(0, await _jvmErrorFile());
    try {
      final result = await _runProcess(java, argv, timeout: timeout);
      final stdoutText = result.stdout.trim();
      if (result.timedOut) {
        AppLog.e('jar', '一次性进程超时 class=$className method=$method');
        throw SourceException('JAR 蜘蛛执行超时（$method）');
      }
      if (result.exitCode != 0) {
        if (_jvmCrashed(result.stderr)) {
          AppLog.e(
            'jar',
            '一次性进程崩溃 class=$className method=$method ${_crashKind(result.stderr)}',
          );
          throw SourceException(
            'JVM 崩溃（${_crashKind(result.stderr)}），该 payload 与本机兼容层不匹配',
          );
        }
        final message = await _errorText(stdoutText, result.stderr);
        AppLog.e(
          'jar',
          '一次性进程失败 class=$className method=$method: ${shorten(message, 300)}',
        );
        throw SourceException(message);
      }
      if (stdoutText.isEmpty) {
        throw SourceException(await _errorText('', result.stderr));
      }
      return stdoutText;
    } on ProcessException catch (e) {
      throw SourceException('JVM 启动失败：${e.message}');
    }
  }

  Future<List<String>> _proxyProps(String jarPath) async {
    final port = _proxyPort(jarPath);
    // 入口直接指向**本 JVM 自己的宿主代理**（`com.github.catvod.Proxy` 在 stubs 里，
    // 绑 -Dtvbox.proxy.port，路径只认 /proxy）。旧版 Electron 宿主写的是
    // `http://127.0.0.1:9978/proxy/<port>`，再由 9978 转发回各 JVM —— 我们没有那层中继，
    // 直接自指即可：常驻进程活着期间地址始终可达。
    return [
      '-Dtvbox.proxy.port=$port',
      '-Dtvbox.proxy.entry=http://127.0.0.1:$port/proxy',
    ];
  }

  int _proxyPort(String key) {
    var h = 0;
    for (final c in key.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return 19970 + h % 30;
  }

  String _d2jJars(String jvmDir) {
    return Directory(p.join(jvmDir, 'd2j'))
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.jar'))
        .map((f) => f.path)
        .join(';');
  }

  Future<_ProcResult> _runProcess(
    String exe,
    List<String> args, {
    required Duration timeout,
  }) async {
    final proc = await Process.start(exe, args);
    final outFuture = proc.stdout.transform(utf8.decoder).join();
    final errFuture = proc.stderr.transform(utf8.decoder).join();
    var timedOut = false;
    var exitCode = -1;
    try {
      exitCode = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      try {
        proc.kill();
      } catch (_) {}
    }
    String out = '';
    String err = '';
    try {
      out = await outFuture.timeout(const Duration(seconds: 10));
    } catch (_) {}
    try {
      err = await errFuture.timeout(const Duration(seconds: 10));
    } catch (_) {}
    return _ProcResult(
      exitCode: exitCode,
      stdout: out,
      stderr: err,
      timedOut: timedOut,
    );
  }

  /// 桌面 shell-shim 跑不动这份 payload 的典型类错误（缺匿名类 / 类版本不兼容）。
  /// 这类失败换一份 payload 通常就好了，不应直接放弃整个源。
  bool _payloadIncompatible(String message) {
    return message.contains(
          'Must only create direct subclasses of TypeToken',
        ) ||
        message.contains('InstantiationError') ||
        message.contains('AbstractMethodError') ||
        message.contains('IncompatibleClassChangeError');
  }

  /// 与 payload 兼容性相关的失败：换下一个候选包还有机会。
  bool _shimMiss(String message) {
    return isJarShimMissMessage(message) ||
        _payloadIncompatible(message) ||
        _payloadCrash(message);
  }

  /// payload 把 JVM 直接拖崩（hs_err / 进程消失 / 看门狗退出）。
  ///
  /// 这类失败换进程重试同一个包没有意义：只有换包（或重新解包）才可能恢复。
  bool _payloadCrash(String message) {
    return message.contains('常驻蜘蛛进程已退出') ||
        message.contains('常驻蜘蛛进程已断开') ||
        message.contains('JVM 崩溃') ||
        message.contains('EXCEPTION_ACCESS_VIOLATION') ||
        message.contains('SIGSEGV');
  }

  /// 确认是崩溃型失败的候选包，本会话内不再尝试。
  void _dropPayload(String path, String message) {
    if (_payloadCrash(message)) _brokenPayloads.add(path);
  }

  /// 把「本壳自己的坏 payload」移出候选目录（改名为 `<包>.bad`）。
  ///
  /// 触发场景（实测）：旧版解包产物在同一会话里没跑到 DexJarRepair（或修复失败，
  /// 但 `.fix.ok` 标记已写），缓存里留下 `NEW b1/g`（abstract）这类 dex2jar 误译；
  /// 每次调用都只能报 `InstantiationError` / `TypeToken`，而且换包回退会把它永久
  /// 留在候选里。隔离后下一次进源没有候选 → 走原生重解包，新产物会经
  /// `BaseDexClassLoader.finalizeProduct` → `DexJarRepair` 真正修好。
  ///
  /// 只隔离本 key 目录里的包：从别的壳借来的包失败后不能动别人的缓存。
  Future<void> _quarantinePayload(String path) async {
    _brokenPayloads.add(path);
    final key = p.basename(p.dirname(path));
    try {
      final file = File(path);
      if (file.existsSync()) {
        final bad = File('$path.bad');
        try {
          if (bad.existsSync()) bad.deleteSync();
        } catch (_) {}
        file.renameSync(bad.path);
      }
    } catch (_) {}
    try {
      final shim = File('$path.shim.jar');
      if (shim.existsSync()) shim.deleteSync();
    } catch (_) {}
    // 同一产物在 native/runtime_dex 里还有一份（同名 md5）：一并移走，
    // 否则 _adoptRuntimePayloads 收编时又会把坏包捞回来。
    try {
      final source = File(
        p.join(
          (await _cacheDir()).path,
          'native',
          'runtime_dex',
          p.basename(path),
        ),
      );
      if (source.existsSync()) {
        final bad = File('${source.path}.bad');
        try {
          if (bad.existsSync()) bad.deleteSync();
        } catch (_) {}
        source.renameSync(bad.path);
      }
    } catch (_) {}
    // 索引里指向坏包的名字一并清掉，避免下一次又被排到最前面。
    final index = await _payloadIndex(key);
    final name = p.basename(path);
    var changed = false;
    index.removeWhere((_, value) {
      if (value != name) return false;
      changed = true;
      return true;
    });
    if (!changed) return;
    try {
      final dir = Directory(p.join((await _cacheDir()).path, 'payloads', key));
      await File(p.join(dir.path, 'index.json'))
          .writeAsString(jsonEncode(index), flush: true);
    } catch (_) {
      // 索引写失败只影响下次选择，不阻断调用
    }
  }

  /// JVM 自己的 hs_err 会先往 stderr 打一行 fatal error 头：exitCode 非 0 且命中即崩。
  bool _jvmCrashed(String stderr) =>
      stderr.contains('A fatal error has been detected') ||
      stderr.contains('EXCEPTION_ACCESS_VIOLATION') ||
      stderr.contains('SIGSEGV');

  String _crashKind(String stderr) {
    if (stderr.contains('EXCEPTION_ACCESS_VIOLATION')) {
      return 'EXCEPTION_ACCESS_VIOLATION';
    }
    if (stderr.contains('SIGSEGV')) return 'SIGSEGV';
    return 'fatal error';
  }

  Future<String> _fileMd5(File file) async {
    final digest = await crypto.md5.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<String> _errorText(String stdout, String stderr) async {
    final text = '${stderr.trim()}\n${stdout.trim()}'.trim();
    if (text.isEmpty) return 'JAR 蜘蛛执行失败';
    final lines = text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .where((e) => !e.startsWith('OpenJDK 64-Bit Server VM warning'))
        .where((e) => !e.contains('-noverify were deprecated'))
        .where((e) => !e.contains('BouncyCastle provider unavailable'))
        .where((e) => !e.startsWith('at '))
        .where((e) => !e.startsWith('Caused by:'))
        .where((e) => !e.startsWith('... '))
        .where((e) => !e.startsWith('[android.'))
        .where((e) => !e.startsWith('[native-bridge]'))
        .where((e) => !e.startsWith('[SpiderRunner]'))
        .where((e) => !e.startsWith('[go-shim]'))
        .where((e) => !e.contains('PanDebug'))
        .where((e) => !e.contains('SpiderLog:'))
        .where((e) => !e.contains('Cannot run program "chmod"'))
        .where((e) => !e.contains('Cannot run program "getprop"'))
        .toList();
    for (final line in lines) {
      if (line.contains('[SpiderRunner.ERROR]')) {
        return line.replaceFirst('[SpiderRunner.ERROR]', '').trim();
      }
    }
    if (text.contains('JSONObject["data"] not found') ||
        text.contains('org.json.JSONException')) {
      return '网盘接口没有返回数据（分享可能已失效或登录态过期），请重新登录对应网盘后重试';
    }
    // 只按「主错误」判断 Go 代理，避免后台 Go 日志把真正的类加载错误盖掉。
    if (stdout.contains(
          '载荷桥未就绪或未登记方法: com/github/catvod/spider/GoProxy.startServer',
        ) ||
        stdout.contains('Go proxy health check failed')) {
      return '该源依赖 Android 专用 Go 取流组件，桌面端暂不支持播放；请换用其他线路或源';
    }
    if (text.contains('需要加固壳原生库')) {
      return '该源使用加固壳的专有原生加密算法（桌面缺少原生库），暂不支持；请换用其它源或线路';
    }
    if (text.contains('载荷桥未就绪或未登记方法')) {
      // 嗷呜系壳的专有加密（extDe/get 等）最终落到这里：桌面已经用纯 Java 接管
      // 标准算法，只剩这部分必须依赖 Android 原生库，给出可操作的说明。
      if (text.contains('MyCrypto.')) {
        return '该源使用加固壳的专有原生加密算法（桌面缺少原生库），暂不支持；请换用其它源或线路';
      }
      final armReady = await ArmBridgeRuntime.instance.installed();
      return armReady
          ? '加固壳的原生库没有装载成功（可重试一次；仍失败请在设置 → 播放中重新安装加固壳支持）'
          : '该源需要加固壳支持（设置 → 播放 → 加固壳支持），下载完成后重试';
    }
    if (text.contains('DexNative') || text.contains('BaseSpiderGuard')) {
      final armReady = await ArmBridgeRuntime.instance.installed();
      return armReady
          ? '加固壳解包失败（DexNative / BaseSpiderGuard），请重试或查看设置中的加固壳支持'
          : '该源是加固壳，需要先下载「加固壳支持」（设置 → 播放 → 加固壳支持）';
    }
    final noClass = RegExp(r'NoClassDefFoundError: ([^\s]+)').firstMatch(text);
    if (noClass != null &&
        noClass.group(1)!.startsWith('com/github/catvod/spider/')) {
      return '该源需要加固壳支持（${noClass.group(1)}），请在设置 → 播放中下载';
    }
    final missing = RegExp(r'Could not find or load main class (\S+)')
        .firstMatch(text);
    if (missing != null) return 'JVM 运行时不完整：找不到 ${missing.group(1)}（请重新安装）';
    return lines.isEmpty ? text : lines.last;
  }

  void _throwIfError(String text) {
    final t = text.trim();
    if (!t.startsWith('{')) return;
    try {
      final decoded = jsonDecode(t);
      if (decoded is Map && decoded['__error'] != null) {
        throw SourceException('蜘蛛返回错误：${decoded['__error']}');
      }
    } on SourceException {
      rethrow;
    } catch (_) {
      // 非 JSON 文本交给上层解析
    }
  }
}

class _ProcResult {
  const _ProcResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.timedOut,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../parse_play.dart';
import '../../core/platform/window_service.dart';
import '../../core/theme/app_theme.dart';
import '../../models/site_config.dart';
import '../../models/user_data.dart';
import '../../models/vod.dart';
import '../../services/artwork/artwork_service.dart';
import '../../services/discover/cover_images.dart';
import '../../services/discover/discover_models.dart';
import '../../services/drive/drive_line_hint.dart';
import '../../services/jar_spider/hyms_native.dart';
import '../../services/mpv_extension.dart';
import '../../services/player/external_players.dart';
import '../../services/torrent/torrent_play.dart';
import '../../state/app_state.dart';
import '../open_player.dart';
import '../raw_play.dart';
import '../widgets/drive_login_prompt.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass.dart';
import '../widgets/hover_marquee_text.dart';
import '../widgets/hyms_captcha_dialog.dart';
import '../widgets/mouse_drag_scroll.dart';
import '../widgets/poster_card.dart';
import '../immersive/immersive_widgets.dart';
import 'player_page.dart';

class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.item});
  final VodItem item;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  VodDetail? _detail;
  bool _loading = true;
  String? _error;
  String? _flag;
  bool _initialized = false;
  DoubanInfo? _douban;
  DoubanDetailExtra? _extra;

  /// 播放器正在打开（取链 / 压栈）：防止连续点击重复解析、打开多份。
  bool _opening = false;
  int _playSeq = 0;

  /// 详情页内的加载 / 错误遮罩；非空时盖在整个页面上。
  ValueNotifier<_PlayGateState>? _playGate;
  VoidCallback? _gateCancel;
  VoidCallback? _gateConfirm;
  VoidCallback? _gateSwitchSource;

  /// 沉浸观影：简介是否展开、选集横向滚动控制器。
  bool _immersiveIntroOpen = false;
  ScrollController? _immersiveEpsScroll;

  /// 沉浸观影：TMDB 分集封面（与当前线路顺序一致，缺失为 null）。
  List<String?> _episodeStills = const [];
  String _episodeStillsKey = '';

  @override
  void dispose() {
    _immersiveEpsScroll?.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  SourceBean? _site(AppState app) {
    final config = app.config;
    if (config == null) return null;
    final key = widget.item.sourceKey;
    if (key.isNotEmpty) {
      for (final s in config.sites) {
        if (s.key == key) return s;
      }
    }
    return app.activeSite;
  }

  Future<void> _load() async {
    final app = AppScope.of(context);
    final site = _site(app);
    if (site == null) {
      setState(() {
        _loading = false;
        _error = '找不到对应站点，请重新选择站点';
      });
      return;
    }
    if (!app.isSiteUsable(site)) {
      setState(() {
        _loading = false;
        _error = site.unsupportedReason;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await app.sourceService.detail(
        site,
        widget.item.id,
        name: widget.item.name,
      );
      if (!mounted) return;
      if (detail == null) {
        setState(() {
          _loading = false;
          _error = '详情为空，可能是源站未返回数据';
        });
        return;
      }
      setState(() {
        _detail = detail;
        _loading = false;
        _flag = detail.flags.isNotEmpty ? detail.flags.first : null;
      });
      unawaited(_loadDouban(detail));
      unawaited(_loadEpisodeStills(detail));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 豆瓣元数据：封面 / 简介 / 评分 / 相关推荐 / 影评。失败不影响选集与播放。
  Future<void> _loadDouban(VodDetail detail) async {
    final app = AppScope.of(context);
    final name = detail.name.trim().isEmpty
        ? widget.item.name.trim()
        : detail.name.trim();
    if (name.isEmpty) return;
    final info = await app.discoverService.loadInfo(name, year: detail.year);
    if (!mounted) return;
    if (info != null) {
      setState(() => _douban = info);
      unawaited(_loadEpisodeStills(detail));
    }
    final extra = await app.discoverService.loadDetailExtra(
      name,
      year: detail.year,
    );
    if (!mounted) return;
    if (extra != null) setState(() => _extra = extra);
  }

  /// 沉浸模式的分集封面：按当前线路的集数/集号从 TMDB 取 still。
  ///
  /// 未开沉浸模式、未配置 TMDB Key 或匹配失败时不请求，选集卡继续用横图。
  Future<void> _loadEpisodeStills(VodDetail detail) async {
    final app = AppScope.of(context);
    if (!mounted || !app.playerSettings.immersiveMode) return;
    if (app.playerSettings.tmdbApiKey.trim().isEmpty) return;
    final flag = _flag ?? (detail.flags.isNotEmpty ? detail.flags.first : '');
    final episodes = detail.episodeList(flag);
    if (episodes.isEmpty) return;
    final name = detail.name.trim().isNotEmpty
        ? detail.name.trim()
        : widget.item.name.trim();
    if (name.isEmpty) return;
    final rawYear = detail.year.trim().isNotEmpty
        ? detail.year
        : (_douban?.year ?? '');
    final year = _validYear(rawYear) ? rawYear.trim() : '';
    final numbers = <int>[];
    // 单集（电影 / 单文件）不做集号映射，避免把文件名里的 1080 之类当集号。
    if (episodes.length > 1) {
      for (final episode in episodes) {
        final number = ArtworkService.episodeNumber(episode.name);
        if (number <= 0) {
          numbers.clear();
          break;
        }
        numbers.add(number);
      }
    }
    final key = '$name|$year|$flag|${episodes.length}|${numbers.join(',')}';
    if (key == _episodeStillsKey) return;
    _episodeStillsKey = key;
    setState(() => _episodeStills = const []);
    final stills = await app.artworkService.episodeStills(
      name,
      year: year,
      episodeCount: episodes.length,
      seasonHint:
          ArtworkService.seasonHintOf(name, trailingSequel: true) ??
          ArtworkService.seasonHintOf(flag),
      episodeNumbers: numbers,
    );
    if (!mounted || key != _episodeStillsKey) return;
    setState(() => _episodeStills = stills);
  }

  /// 点演员 / 推荐条目 → 回主界面并执行一次全源搜索。
  void _search(String keyword) {
    final k = keyword.trim();
    if (k.isEmpty) return;
    final app = AppScope.of(context);
    app.requestSearch(k);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _openCover(String url, Map<String, String> headers) {
    if (url.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: InteractiveViewer(
            maxScale: 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(
                url,
                headers: headers.isEmpty ? null : headers,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 简介超出详情页红框区域时，用与影评相同的弹窗展示全文。
  void _showFullIntro(String name, String text, {required bool fromDouban}) {
    if (text.trim().isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          name.trim().isEmpty
              ? (fromDouban ? '简介 · 豆瓣' : '简介')
              : '$name · ${fromDouban ? '豆瓣简介' : '简介'}',
        ),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(
                fontFamily: AppTheme.bodyFontFamily,
                fontFamilyFallback: AppTheme.bodyFontFamilyFallback,
                height: 1.7,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showReview(DoubanReviewItem review) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(review.title),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    if (review.author.isNotEmpty) review.author,
                    if (review.rating != null)
                      '${review.rating!.toStringAsFixed(1)} 星',
                    if (review.useful > 0) '有用 ${review.useful}',
                    if (review.date.isNotEmpty) review.date,
                  ].join(' · '),
                  style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurface
                        .withValues(alpha: 0.70),
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  review.abstract,
                  style: const TextStyle(
                    fontFamily: AppTheme.bodyFontFamily,
                    fontFamilyFallback: AppTheme.bodyFontFamilyFallback,
                    height: 1.7,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 打开播放器：先在详情页遮罩下取链 / 解析 / 登录，成功后带已解析地址
  /// 进入播放器；失败或超时则在同一个遮罩里显示错误。
  Future<void> _playEpisode(
    int index, {
    int startMs = 0,
    bool allowLogin = true,
  }) async {
    final app = AppScope.of(context);
    final site = _site(app);
    final detail = _detail;
    final config = app.config;
    if (site == null || detail == null || config == null || _opening) return;
    final seq = ++_playSeq;
    final flag = _flag ?? (detail.flags.isNotEmpty ? detail.flags.first : '');
    final episodes = detail.episodeList(flag);
    if (index < 0 || index >= episodes.length) {
      _toast('这一集没有可播放地址');
      return;
    }
    // 线路名就写明是哪个网盘时，先补登录再解析：只查本地账号，不联网，不会拖慢打开。
    // 可选增强（哔哩）不拦：没 Cookie 也能播 360P / 480P，只是画质低。
    final hint = driveHintFromFlag(flag);
    if (allowLogin &&
        hint != null &&
        hint.supported &&
        !hint.optional &&
        !app.hasDriveAccount(hint.provider)) {
      final ready = await promptDriveLogin(context, hint);
      if (!mounted) return;
      if (!ready) {
        _toast('未登录${hint.name}，已取消播放');
        return;
      }
    }
    if (!mounted) return;
    _opening = true;
    try {
      await _openPlayerWithLoading(
        site: site,
        detail: detail,
        flag: flag,
        index: index,
        episodes: episodes,
        startMs: startMs,
        allowLogin: allowLogin,
      );
    } finally {
      // 取消后用户可能马上重新点播放：旧请求收尾时不能把新一轮的锁清掉。
      if (_playSeq == seq) _opening = false;
    }
    if (mounted) setState(() {});
  }

  /// 在详情页盖一层加载框，先把播放地址取好再进播放器。
  ///
  /// 20 秒后加载框出现「取消」；取链 / 解析 / 超时会原地变成错误提示，
  /// 点「确定」关闭后仍停留在详情页。
  Future<void> _openPlayerWithLoading({
    required SourceBean site,
    required VodDetail detail,
    required String flag,
    required int index,
    required List<Episode> episodes,
    required int startMs,
    required bool allowLogin,
  }) async {
    final app = AppScope.of(context);
    final config = app.config;
    if (config == null) return;

    var cancelled = false;
    var stopped = false;
    final gate = ValueNotifier<_PlayGateState>(const _PlayGateState.loading());
    final dismissed = Completer<void>();
    Timer? cancelHintTimer;

    void removeGate() {
      cancelHintTimer?.cancel();
      if (!mounted) return;
      setState(() {
        if (_playGate == gate) {
          _playGate = null;
          _gateCancel = null;
          _gateConfirm = null;
          _gateSwitchSource = null;
        }
      });
    }

    void completeDismissed() {
      if (!dismissed.isCompleted) dismissed.complete();
    }

    /// 取链失败时按片名回主界面做全源搜索，用户可直接换到别的源。
    void switchSource() {
      if (cancelled || !mounted) return;
      final name = detail.name.trim().isEmpty
          ? widget.item.name.trim()
          : detail.name.trim();
      if (name.isEmpty) return;
      cancelled = true;
      removeGate();
      _search(name);
    }

    _gateSwitchSource = switchSource;

    void showError(String title, String message) {
      stopped = true;
      if (cancelled || !mounted || _playGate != gate) return;
      cancelHintTimer?.cancel();
      gate.value = _PlayGateState.error(
        title,
        message.isEmpty ? '没有可用的播放地址' : message,
      );
    }

    _gateCancel = () {
      if (cancelled) return;
      cancelled = true;
      stopped = true;
      _opening = false;
      cancelHintTimer?.cancel();
      removeGate();
      completeDismissed();
      _toast('已取消加载');
    };
    _gateConfirm = () {
      removeGate();
      completeDismissed();
    };
    setState(() => _playGate = gate);

    // 不等到整体超时才让用户脱身：20 秒后加载框出现取消。
    cancelHintTimer = Timer(const Duration(seconds: 20), () {
      if (cancelled || !mounted || _playGate != gate) return;
      gate.value = const _PlayGateState.loading(canCancel: true);
    });

    final timeout = site.isJarSpider
        ? const Duration(minutes: 5)
        : (site.type == 3
              ? const Duration(seconds: 90)
              : const Duration(seconds: 45));
    final started = DateTime.now();
    PlayResult? play;
    try {
      play = await _resolvePlayForGate(
        app: app,
        site: site,
        config: config,
        flag: flag,
        episode: episodes[index],
        allowLogin: allowLogin,
        isCancelled: () => stopped,
      ).timeout(timeout);
    } on TimeoutException {
      showError(
        '加载超时',
        '资源加载超过 ${timeout.inMinutes >= 2 ? '${timeout.inMinutes} 分钟' : '${timeout.inSeconds} 秒'}'
            '仍未完成，请换线路或稍后重试。',
      );
    } catch (e) {
      showError('播放失败', e.toString());
    }

    if (cancelled || !mounted) {
      gate.dispose();
      return;
    }
    // 极快的直链会让加载框一闪而过；至少展示 400ms，让点击有明确反馈。
    final elapsed = DateTime.now().difference(started);
    const minShow = Duration(milliseconds: 400);
    if (elapsed < minShow) {
      await Future<void>.delayed(minShow - elapsed);
      if (cancelled || !mounted) {
        gate.dispose();
        return;
      }
    }

    if (play == null || !play.playable) {
      // 磁力链接直接交给内置 BT 引擎：这是「新6V|磁力」这类源的主要播放方式，
      // 走普通播放器只会得到「不可用」并触发自动换源。
      final magnet = _magnetLinkOf(play);
      if (magnet.isNotEmpty) {
        removeGate();
        completeDismissed();
        gate.dispose();
        await _playMagnet(magnet);
        return;
      }
      // 其它外部链接（ed2k / ftp / 迅雷专用链等）保留 BT 播放 / 复制链接操作。
      if (play != null && play.externalLink.isNotEmpty) {
        removeGate();
        completeDismissed();
        gate.dispose();
        await _showUnplayable(play);
        return;
      }
      // 开启自动换线时，首条线路取链失败也进播放器页：由它继续尝试下一条
      // 线路，再不行搜索其他源的同名资源。否则详情页会在这里直接卡死。
      if (app.playerSettings.autoSwitchLine) {
        removeGate();
        completeDismissed();
        gate.dispose();
        if (!mounted) return;
        await openVodPlayer(
          context,
          app,
          PlayerSession(
            detail: detail,
            site: site,
            flag: flag,
            episodeIndex: index,
            episodes: episodes,
            initialPlay: play,
            startPositionMs: startMs,
          ),
          rootNavigator: true,
        );
        return;
      }
      if (!gate.value.error) {
        showError(
          '播放失败',
          play?.message.isNotEmpty == true ? play!.message : '没有可用的播放地址',
        );
      }
      // 等用户点「确定」再收起加载框。
      await dismissed.future;
      removeGate();
      gate.dispose();
      return;
    }

    removeGate();
    completeDismissed();
    gate.dispose();
    if (cancelled || !mounted) return;
    if (await _tryDefaultExternalPlayer(
      app: app,
      site: site,
      detail: detail,
      flag: flag,
      index: index,
      episodes: episodes,
      play: play,
      startMs: startMs,
    )) {
      return;
    }
    if (!mounted) return;
    await openVodPlayer(
      context,
      app,
      PlayerSession(
        detail: detail,
        site: site,
        flag: flag,
        episodeIndex: index,
        episodes: episodes,
        initialPlay: play,
        startPositionMs: startMs,
      ),
      rootNavigator: true,
    );
  }

  /// 按设置里的默认播放器把地址交给外部播放器；成功返回 true（不再开内置播放器）。
  Future<bool> _tryDefaultExternalPlayer({
    required AppState app,
    required SourceBean site,
    required VodDetail detail,
    required String flag,
    required int index,
    required List<Episode> episodes,
    required PlayResult play,
    required int startMs,
  }) async {
    final setting = app.playerSettings.defaultPlayer;
    if (normalizeDefaultPlayer(setting) == kDefaultPlayerBuiltin) return false;

    final resource = '${detail.sourceKey}|${detail.id}';
    final rawName = episodes[index].name.trim();
    final episodeKey = rawName.isEmpty ? '第${index + 1}集' : rawName;
    // 全局无痕模式与内置播放器的临时会话一致：不套用跳过片头片尾。
    final skip = app.playerSettings.incognito
        ? null
        : app.skipFor(resource, episodeKey);
    final effectiveStart = startMs > 0 ? startMs : (skip?.intro ?? 0) * 1000;
    final seconds = effectiveStart ~/ 1000;
    final source = app.preparePlay(play, forceRelay: true);
    // PotPlayer 等外部播放器打开 `/chunk` 会并发多条探针，先做一次预热，
    // 避免壳内取流服务在会话登记前后互相覆盖，最终一直加载。
    if (play.url.contains('/chunk') && play.url.contains('127.0.0.1')) {
      _toast('正在准备取流地址…');
    }
    if (!await app.sourceService.jar.warmUpLocalPlayUrl(play.url)) {
      _toast('取流地址准备失败，已改用内置播放器');
      return false;
    }
    final isMpv = setting == kDefaultPlayerYaozhiMpv;
    final customPath = app.playerSettings.defaultCustomPlayerPathValue;
    var playerName = isMpv
        ? 'Yaozhi MPV'
        : externalPlayerDisplayName(customPath);
    // 多集时把整份选集列表交给外部播放器（M3U 每项回指本机中继）。
    final service = app.externalPlaylist;
    final playlist = service == null || episodes.length < 2
        ? null
        : await service.createPlaylist(
            site: site,
            flag: flag,
            episodes: episodes,
            currentIndex: index,
            currentUrl: source.url,
          );
    try {
      if (isMpv) {
        final exe = await MpvExtension.instance.executablePath;
        if (exe.isEmpty) {
          _toast('Yaozhi MPV 未安装，已改用内置播放器');
          return false;
        }
        await MpvExtension.instance.open(
          playlist ?? source.url,
          headers: playlist == null ? source.headers : const {},
          startSeconds: playlist == null ? seconds : 0,
        );
      } else {
        if (customPath.isEmpty) return false;
        if (!externalPlayerExists(customPath)) {
          _toast('默认第三方播放器文件不存在，已改用内置播放器');
          return false;
        }
        for (final entry in app.playerSettings.externalPlayers) {
          if (entry.path.trim().toLowerCase() == customPath.toLowerCase()) {
            final name = entry.name.trim();
            playerName = name.isEmpty
                ? externalPlayerDisplayName(entry.path)
                : name;
            break;
          }
        }
        final ok = launchExternalPlayer(
          customPath,
          playlist ?? source.url,
          extraArgs: playlist == null
              ? externalSeekArgs(externalPlayerKind(customPath), seconds)
              : const [],
        );
        if (!ok) {
          _toast('启动 $playerName 失败，已改用内置播放器');
          return false;
        }
      }
    } catch (e) {
      _toast('启动 $playerName 失败：$e');
      return false;
    }

    // 播放器已经拉起，历史记录失败不能再回退内置（否则会同时出现两个播放器）。
    app.sourceService.jar.holdPlaybackForExternal();
    if (app.playerSettings.incognito) {
      // 全局无痕模式：外部播放器同样不写观看历史。
      if (mounted) _toast('已在 $playerName 中打开（无痕模式，未记录历史）');
      return true;
    }
    try {
      await app.recordHistory(
        detail: detail,
        site: site,
        flag: flag,
        episodeName: episodeKey,
        episodeIndex: index,
        url: play.url,
        rawUrl: episodes[index].url,
        headers: play.headers,
        positionMs: effectiveStart,
      );
    } catch (_) {
      // 历史写入失败不影响本次外部播放
    }
    if (mounted) _toast('已在 $playerName 中打开');
    return true;
  }

  Future<PlayResult> _resolvePlayForGate({
    required AppState app,
    required SourceBean site,
    required SiteConfig config,
    required String flag,
    required Episode episode,
    required bool allowLogin,
    required bool Function() isCancelled,
  }) async {
    var canLogin = allowLogin;
    PlayResult play = const PlayResult(url: '');
    for (var attempt = 0; attempt < 2; attempt++) {
      HymsNative.captchaHandler = (url) {
        if (!mounted) return Future.value(null);
        return showHymsCaptchaDialog(context, url);
      };
      try {
        play = await app.sourceService.resolvePlay(
          site: site,
          config: config,
          flag: flag,
          rawUrl: episode.url,
          jarReady: app.jarReady,
        );
      } finally {
        HymsNative.captchaHandler = null;
      }
      if (isCancelled() || !mounted) return play;
      if (play.parse != 0 && play.externalLink.isEmpty) {
        play = await resolveParsedPlay(
          context,
          app,
          site,
          play,
          rawUrl: episode.url,
        );
        if (isCancelled() || !mounted) return play;
      }
      play = await app.unwrapPlayPage(play);
      if (isCancelled() || !mounted) return play;
      if (play.playable || !canLogin) return play;

      final hint = driveHintFromMessage(play.message);
      if (hint == null || !hint.supported || hint.optional) return play;
      final token = (app.driveAccounts[hint.provider]?.extra['uctvToken'] ?? '')
          .trim();
      final ready =
          app.hasDriveAccount(hint.provider) &&
          (!hint.needsToken || token.isNotEmpty);
      if (ready) return play;
      final ok = await promptDriveLogin(context, hint, message: play.message);
      if (isCancelled() || !mounted) return play;
      if (!ok) return play;
      canLogin = false;
    }
    return play;
  }

  /// 从取链结果里找磁力地址（url / externalLink / 错误说明里都可能出现）。
  String _magnetLinkOf(PlayResult? play) {
    if (play == null) return '';
    for (final candidate in [play.url, play.externalLink]) {
      final text = candidate.trim();
      if (RegExp(r'^magnet:', caseSensitive: false).hasMatch(text)) {
        return text;
      }
    }
    final match = RegExp(
      r"magnet:\?[^\s<>']+",
      caseSensitive: false,
    ).firstMatch(play.message);
    return match?.group(0) ?? '';
  }

  Future<void> _showUnplayable(PlayResult play) async {
    final external = play.externalLink.trim();
    final isMagnet = RegExp(
      r'^magnet:',
      caseSensitive: false,
    ).hasMatch(external);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('暂时无法播放'),
        content: Text(play.message.isEmpty ? '没有可用的播放地址' : play.message),
        actions: [
          if (isMagnet)
            FilledButton.tonalIcon(
              onPressed: () {
                Navigator.of(ctx).pop();
                unawaited(_playMagnet(external));
              },
              icon: const Icon(Icons.download_rounded),
              label: const Text('BT 播放'),
            ),
          if (play.externalLink.isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: play.externalLink));
                if (ctx.mounted) {
                  Navigator.of(ctx).pop();
                  _toast('链接已复制到剪贴板');
                }
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('复制链接'),
            ),
          FilledButton.tonalIcon(
            onPressed: () {
              final name = (_detail?.name ?? widget.item.name).trim();
              if (name.isEmpty) return;
              Navigator.of(ctx).pop();
              _search(name);
            },
            icon: const Icon(Icons.swap_horiz_rounded),
            label: const Text('换源'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 磁力播放：优先迅雷云盘离线下载，失败回退 aria2；再按容器选择内置或外部播放器。
  Future<void> _playMagnet(String magnet) async {
    final app = AppScope.of(context);
    final torrent = app.torrentPlay;
    final name = _detail?.name ?? widget.item.name;
    if (torrent == null) {
      _toast('当前平台没有内置 BT 引擎');
      return;
    }
    final progress = ValueNotifier<String>('正在准备磁力播放…');
    var cancelled = false;
    var dialogClosed = false;
    void closeDialog() {
      if (dialogClosed) return;
      dialogClosed = true;
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _BtPreparingDialog(
          status: progress,
          onCancel: () {
            if (cancelled) return;
            cancelled = true;
            closeDialog();
          },
        ),
      ),
    );
    BtPlayOutcome outcome;
    try {
      outcome = await torrent.open(
        magnet,
        title: name,
        isCancelled: () => cancelled,
        onProgress: (message) {
          if (!cancelled && !dialogClosed) progress.value = message;
        },
      );
    } catch (e) {
      outcome = BtPlayOutcome.unsupported('$e');
    }
    if (!mounted) return;
    closeDialog();
    // 用户已取消：后台任务已中止，不再弹任何结果提示。
    if (cancelled) return;
    final provider = outcome.provider.isEmpty ? 'BT' : outcome.provider;
    if (outcome.kind == BtPlayKind.inline) {
      await openRawPlayback(
        context,
        title: outcome.title.isEmpty ? name : outcome.title,
        subtitle: '磁力 · $provider',
        episodes: [Episode(name: '正片', url: outcome.url)],
        sourceKey: 'bt:${outcome.infoHash}',
        flag: provider,
      );
    } else if (outcome.kind == BtPlayKind.external) {
      _toast('已在 ${outcome.player} 中打开（${outcome.title}）');
    } else {
      await _showBtUnsupported(outcome.reason, magnet);
    }
  }

  Future<void> _showBtUnsupported(String reason, String magnet) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('磁力暂时无法播放'),
        content: Text(reason.isEmpty ? '未知原因' : reason),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: magnet));
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
                _toast('磁力链接已复制，可交给下载工具');
              }
            },
            icon: const Icon(Icons.copy_rounded),
            label: const Text('复制磁力'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 线路对应的网盘本机能不能直接扫码、现在是否还没登录（决定是否挂锁）。
  ///
  /// 可选增强（哔哩）不挂锁：没 Cookie 也能播，挂锁只会误导用户以为不能点。
  bool _needsLogin(AppState app, String flag) {
    final hint = driveHintFromFlag(flag);
    return hint != null &&
        hint.supported &&
        !hint.optional &&
        !app.hasDriveAccount(hint.provider);
  }

  /// 演职员名单：豆瓣演员表（已按源顺序过滤并带饰演角色）优先；
  /// 豆瓣还没返回时先显示源字段，过滤掉明显的职务 / 角色说明。
  List<DoubanCastMember> _castMembers(VodDetail detail) {
    final douban = _douban;
    if (douban != null && douban.cast.isNotEmpty) return douban.cast;

    final out = <DoubanCastMember>[];
    final seen = <String>{};
    for (final part in detail.actor.split(RegExp(r'[,，/、;；|]+'))) {
      final name = castNameFromToken(part);
      if (name == null || !seen.add(name)) continue;
      out.add(DoubanCastMember(name: name));
    }
    return out;
  }

  /// 沉浸模式没有 AppBar，加载中 / 加载失败也必须保留返回入口。
  Widget _immersiveBackButton(BuildContext context) {
    return TextButton.icon(
      onPressed: () => Navigator.of(context).pop(),
      icon: const Icon(Icons.arrow_back_rounded, size: 18),
      label: const Text('返回'),
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black.withValues(alpha: 0.45),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
    );
  }

  /// 沉浸观影详情页：全屏横图 + 左侧信息 + 底部选集条。
  Widget _buildImmersive(BuildContext context, AppState app) {
    final immersive = immersiveTheme(context);
    final theme = immersive;
    final detail = _detail;
    final douban = _douban;
    final item = widget.item;
    final name = detail?.name ?? item.name;
    final rawYear = (detail?.year ?? douban?.year ?? '').trim();
    final year = _validYear(rawYear) ? rawYear : '';
    final poster = (detail?.cleanPic.isNotEmpty ?? false)
        ? detail!.cleanPic
        : (douban?.coverUrl.isNotEmpty == true
              ? douban!.coverUrl
              : item.cleanPic);
    final site = _site(app);

    if (_loading || (detail == null && _error == null)) {
      return Theme(
        data: immersiveTheme(context),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(
                child: ImmersiveBackdrop(
                  title: name,
                  year: year,
                  fallback: poster,
                ),
              ),
              const Center(child: CircularProgressIndicator()),
              Positioned(
                top: 24,
                left: 24,
                child: _immersiveBackButton(context),
              ),
            ],
          ),
        ),
      );
    }
    if (_error != null || detail == null) {
      return Theme(
        data: immersiveTheme(context),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              Positioned.fill(
                child: ImmersiveBackdrop(
                  title: name,
                  year: year,
                  fallback: poster,
                ),
              ),
              Center(
                child: ImmersiveEmpty(
                  title: '详情加载失败',
                  message: _error ?? '没有拿到详情数据',
                  action: FilledButton.tonal(
                    onPressed: () => _load(),
                    child: const Text('重试'),
                  ),
                ),
              ),
              Positioned(
                top: 24,
                left: 24,
                child: _immersiveBackButton(context),
              ),
            ],
          ),
        ),
      );
    }

    final flag = _flag ?? (detail.flags.isNotEmpty ? detail.flags.first : '');
    final episodes = detail.episodeList(flag);
    final history = app.historyFor(detail.sourceKey, detail.id);
    final genres = douban?.genres.isNotEmpty == true
        ? douban!.genres.take(4).toList()
        : detail.type
              .split(RegExp(r'[,，/、]'))
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .take(4)
              .toList();
    final intro = detail.des.trim().isNotEmpty
        ? _cleanIntroText(detail.des)
        : _cleanIntroText(douban?.intro ?? '');
    final rating = douban?.rating;
    final typeLabel = switch (douban?.mediaType) {
      'movie' => '电影',
      'tv' => '剧集',
      _ => (detail.type.isEmpty ? '影视' : detail.type),
    };
    final controller = _immersiveEpsScroll ??= ScrollController();

    final currentIndex = history == null
        ? -1
        : (history.flag == flag || history.flag.isEmpty
              ? history.episodeIndex
              : -1);
    final canContinue =
        history != null &&
        history.positionMs > 0 &&
        (history.flag.isEmpty || detail.flags.contains(history.flag));

    void playContinue() {
      if (history != null && detail.flags.contains(history.flag)) {
        _flag = history.flag;
      }
      final index =
          history != null &&
              history.episodeIndex >= 0 &&
              history.episodeIndex < episodes.length
          ? history.episodeIndex
          : 0;
      _playEpisode(index, startMs: history?.positionMs ?? 0);
    }

    void playFromStart() {
      _playEpisode(0);
    }

    void selectFlag(String next) {
      if (next == flag) return;
      setState(() => _flag = next);
      unawaited(_loadEpisodeStills(detail));
      if (controller.hasClients) {
        controller.jumpTo(controller.position.minScrollExtent);
      }
    }

    void scrollEpisodes(double delta) {
      if (!controller.hasClients) return;
      final target = (controller.offset + delta).clamp(
        controller.position.minScrollExtent,
        controller.position.maxScrollExtent,
      );
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }

    void locateCurrent() {
      if (currentIndex < 0 || !controller.hasClients) return;
      final target = (currentIndex * 214.0).clamp(
        controller.position.minScrollExtent,
        controller.position.maxScrollExtent,
      );
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
      );
    }

    return Theme(
      data: immersive,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: ImmersiveBackdrop(
                title: name,
                year: year,
                fallback: poster,
              ),
            ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xF5070906), Color(0x00070906)],
                    stops: [0, 0.70],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 320,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      const Color(0xFF050705).withValues(alpha: 0.92),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(44, 18, 34, 0),
                    child: Row(
                      children: [
                        Text(
                          '$typeLabel · ${site?.displayName ?? item.sourceName}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            letterSpacing: 1.6,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '收藏',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.36,
                            ),
                            minimumSize: const Size(40, 40),
                          ),
                          onPressed: () async {
                            final next = await app.toggleFavorite(detail, site);
                            if (!mounted) return;
                            _toast(next ? '已加入收藏' : '已取消收藏');
                          },
                          icon: Icon(
                            app.isFavorite(detail.sourceKey, detail.id)
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            color: app.isFavorite(detail.sourceKey, detail.id)
                                ? theme.colorScheme.primary
                                : Colors.white.withValues(alpha: 0.86),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: '关闭',
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.36,
                            ),
                            minimumSize: const Size(40, 40),
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(
                            Icons.close_rounded,
                            color: Colors.white.withValues(alpha: 0.86),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(56, 8, 56, 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: MediaQuery.sizeOf(context).width * 0.46,
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.displayMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w900,
                                          color: Colors.white,
                                          height: 1.04,
                                          letterSpacing: -0.8,
                                        ),
                                  ),
                                  const SizedBox(height: 16),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 8,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      if (rating != null)
                                        _ImmersiveMetaChip(
                                          '豆瓣 ${rating.toStringAsFixed(1)}',
                                          highlight: true,
                                        ),
                                      if (year.isNotEmpty)
                                        _ImmersiveMetaChip(year),
                                      if (episodes.isNotEmpty)
                                        _ImmersiveMetaChip(
                                          '${episodes.length} 集',
                                        ),
                                      for (final genre in genres)
                                        _ImmersiveMetaChip(genre),
                                    ],
                                  ),
                                  if (intro.isNotEmpty) ...[
                                    const SizedBox(height: 20),
                                    Text(
                                      intro,
                                      maxLines: _immersiveIntroOpen ? null : 4,
                                      overflow: _immersiveIntroOpen
                                          ? TextOverflow.visible
                                          : TextOverflow.ellipsis,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: Colors.white.withValues(
                                              alpha: 0.78,
                                            ),
                                            height: 1.75,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    TextButton(
                                      onPressed: () => setState(
                                        () => _immersiveIntroOpen =
                                            !_immersiveIntroOpen,
                                      ),
                                      style: TextButton.styleFrom(
                                        padding: EdgeInsets.zero,
                                        minimumSize: const Size(0, 30),
                                      ),
                                      child: Text(
                                        _immersiveIntroOpen ? '收起简介' : '展开简介',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: theme.colorScheme.primary
                                                  .withValues(alpha: 0.86),
                                            ),
                                      ),
                                    ),
                                  ],
                                  if (canContinue) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      '上次看到 ${history.episodeName.isEmpty ? '第${history.episodeIndex + 1}集' : history.episodeName}'
                                      ' · ${_durationLabel(history.positionMs)}',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: Colors.white.withValues(
                                              alpha: 0.52,
                                            ),
                                          ),
                                    ),
                                  ],
                                  const SizedBox(height: 22),
                                  Row(
                                    children: [
                                      FilledButton.icon(
                                        onPressed: canContinue
                                            ? playContinue
                                            : playFromStart,
                                        icon: const Icon(
                                          Icons.play_arrow_rounded,
                                          size: 22,
                                        ),
                                        label: Text(
                                          canContinue ? '继续播放' : '立即播放',
                                        ),
                                        style: FilledButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 26,
                                            vertical: 17,
                                          ),
                                        ),
                                      ),
                                      if (canContinue) ...[
                                        const SizedBox(width: 12),
                                        OutlinedButton.icon(
                                          onPressed: playFromStart,
                                          icon: const Icon(
                                            Icons.replay_rounded,
                                            size: 20,
                                          ),
                                          label: const Text('从头播放'),
                                          style: OutlinedButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 22,
                                              vertical: 17,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    height: 238,
                    padding: const EdgeInsets.fromLTRB(44, 14, 44, 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.42),
                      border: Border(
                        top: BorderSide(
                          color: Colors.white.withValues(alpha: 0.06),
                        ),
                      ),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Text(
                              '选集',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '${episodes.length} 集',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: Colors.white.withValues(alpha: 0.46),
                              ),
                            ),
                            const Spacer(),
                            if (detail.flags.length > 1)
                              Expanded(
                                flex: 3,
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  reverse: true,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      for (final road in detail.flags)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 6,
                                          ),
                                          child: _ImmersiveLineChip(
                                            label: road.isEmpty ? '默认线路' : road,
                                            selected: road == flag,
                                            onTap: () => selectFlag(road),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            if (currentIndex >= 0)
                              TextButton(
                                onPressed: locateCurrent,
                                child: const Text('定位当前'),
                              ),
                            IconButton(
                              tooltip: '上一页',
                              onPressed: () => scrollEpisodes(-660),
                              icon: const Icon(
                                Icons.chevron_left_rounded,
                                color: Colors.white70,
                              ),
                            ),
                            IconButton(
                              tooltip: '下一页',
                              onPressed: () => scrollEpisodes(660),
                              icon: const Icon(
                                Icons.chevron_right_rounded,
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Expanded(
                          child: episodes.isEmpty
                              ? Center(
                                  child: Text(
                                    '该线路没有可播放的剧集',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: 0.52,
                                      ),
                                    ),
                                  ),
                                )
                              : ListView.separated(
                                  controller: controller,
                                  scrollDirection: Axis.horizontal,
                                  itemCount: episodes.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(width: 14),
                                  itemBuilder: (context, index) {
                                    final episode = episodes[index];
                                    final selected = index == currentIndex;
                                    return _ImmersiveEpisodeCard(
                                      episode: episode,
                                      index: index,
                                      title: name,
                                      year: year,
                                      fallback: poster,
                                      still: _episodeStills.length > index
                                          ? (_episodeStills[index] ?? '')
                                          : '',
                                      selected: selected,
                                      onTap: () => _playEpisode(index),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _durationLabel(int ms) {
    final total = ms ~/ 1000;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    if (h > 0) return '$h 小时 $m 分';
    return '$m 分钟';
  }

  bool _validYear(String raw) {
    final value = int.tryParse(raw.trim());
    return value != null && value >= 1900 && value <= 2100;
  }

  /// 源站简介常带 `&nbsp;` / HTML 标签；大屏简介区只显示纯文本。
  String _cleanIntroText(String raw) {
    var text = raw.replaceAll(RegExp(r'<[^>]*>'), ' ');
    const entities = {
      '&nbsp;': ' ',
      '&amp;': '&',
      '&quot;': '"',
      '&#39;': "'",
      '&lt;': '<',
      '&gt;': '>',
      '&ldquo;': '“',
      '&rdquo;': '”',
      '&hellip;': '…',
      '&mdash;': '—',
    };
    for (final entry in entities.entries) {
      text = text.replaceAll(entry.key, entry.value);
    }
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (app.playerSettings.immersiveMode) {
      return _buildImmersive(context, app);
    }
    final theme = Theme.of(context);
    final detail = _detail;
    final douban = _douban;
    final history = detail == null
        ? null
        : app.historyFor(detail.sourceKey, detail.id);
    final backdropImage = detail == null
        ? widget.item.cleanPic
        : (detail.cleanPic.isNotEmpty
              ? detail.cleanPic
              : (douban?.coverUrl ?? widget.item.cleanPic));
    final introText = detail == null
        ? ''
        : (detail.des.trim().isNotEmpty
              ? detail.des.trim()
              : (douban?.intro.trim() ?? ''));
    final cast = detail == null
        ? const <DoubanCastMember>[]
        : _castMembers(detail);

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          _Backdrop(
            image: doubanImageDisplayUrl(backdropImage),
            headers: isDoubanImageUrl(backdropImage)
                ? const <String, String>{}
                : (detail?.picHeaders ?? widget.item.picHeaders),
          ),
          SafeArea(
            child: Column(
              children: [
                _TopBar(
                  title: detail?.name ?? widget.item.name,
                  favorite:
                      detail != null &&
                      app.isFavorite(detail.sourceKey, detail.id),
                  onBack: () => Navigator.of(context).pop(),
                  onFavorite: detail == null
                      ? null
                      : () async {
                          final next = await app.toggleFavorite(
                            detail,
                            _site(app),
                          );
                          if (!mounted) return;
                          _toast(next ? '已加入收藏' : '已取消收藏');
                        },
                  onCopy: () async {
                    await Clipboard.setData(
                      ClipboardData(text: detail?.name ?? widget.item.name),
                    );
                    _toast('名称已复制');
                  },
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _error != null
                      ? Center(
                          child: EmptyState(
                            icon: Icons.error_outline_rounded,
                            title: '详情加载失败',
                            message: _error,
                            action: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              alignment: WrapAlignment.center,
                              children: [
                                FilledButton.tonalIcon(
                                  onPressed: _load,
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('重试'),
                                ),
                                if (widget.item.name.trim().isNotEmpty)
                                  TextButton.icon(
                                    onPressed: () => _search(widget.item.name),
                                    icon: const Icon(Icons.search_rounded),
                                    label: const Text('全源搜索'),
                                  ),
                              ],
                            ),
                          ),
                        )
                      : detail == null
                      ? const EmptyState(
                          icon: Icons.movie_outlined,
                          title: '没有详情数据',
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final narrow = constraints.maxWidth < 760;
                            return SingleChildScrollView(
                              padding: EdgeInsets.fromLTRB(
                                narrow ? 18 : 32,
                                6,
                                narrow ? 18 : 32,
                                40,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _DetailHeader(
                                    detail: detail,
                                    douban: douban,
                                    narrow: narrow,
                                    introText: introText,
                                    introFromDouban: detail.des.trim().isEmpty,
                                    onExpandIntro: () => _showFullIntro(
                                      detail.name,
                                      introText,
                                      fromDouban: detail.des.trim().isEmpty,
                                    ),
                                    onOpenCover: () {
                                      final raw = detail.cleanPic.isNotEmpty
                                          ? detail.cleanPic
                                          : (douban?.coverUrl ?? '');
                                      final isDouban = isDoubanImageUrl(raw);
                                      _openCover(
                                        isDouban
                                            ? doubanImageDisplayUrl(raw)
                                            : raw,
                                        isDouban
                                            ? const <String, String>{}
                                            : (detail.cleanPic.isNotEmpty
                                                  ? detail.picHeaders
                                                  : const {}),
                                      );
                                    },
                                    onPlay: () {
                                      final index =
                                          history != null &&
                                              history.episodeIndex >= 0 &&
                                              history.episodeIndex <
                                                  detail
                                                      .episodeList(_flag ?? '')
                                                      .length
                                          ? history.episodeIndex
                                          : 0;
                                      _playEpisode(
                                        index,
                                        startMs: history?.positionMs ?? 0,
                                      );
                                    },
                                    playLabel: history != null ? '继续播放' : '播放',
                                    progress: history?.progress ?? 0,
                                  ),
                                  const SizedBox(height: 22),
                                  GlassPanel(
                                    padding: const EdgeInsets.fromLTRB(
                                      18,
                                      16,
                                      18,
                                      18,
                                    ),
                                    borderRadius: 24,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              '选集',
                                              style: theme.textTheme.titleLarge,
                                            ),
                                            const Spacer(),
                                            if (detail.flags.length > 1)
                                              Text(
                                                '${detail.flags.length} 条线路',
                                                style: theme
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: theme
                                                          .colorScheme
                                                          .onSurface
                                                          .withValues(
                                                            alpha: 0.6,
                                                          ),
                                                    ),
                                              ),
                                          ],
                                        ),
                                        if (detail.flags.isNotEmpty) ...[
                                          const SizedBox(height: 12),
                                          ScrollConfiguration(
                                            behavior:
                                                const MouseDragScrollBehavior(),
                                            child: SingleChildScrollView(
                                              scrollDirection: Axis.horizontal,
                                              child: Row(
                                                children: [
                                                  for (final flag
                                                      in detail.flags)
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                            right: 8,
                                                          ),
                                                      child: ChoiceChip(
                                                        label: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            Text(flag),
                                                            if (_needsLogin(
                                                              app,
                                                              flag,
                                                            )) ...[
                                                              const SizedBox(
                                                                width: 4,
                                                              ),
                                                              Icon(
                                                                Icons
                                                                    .lock_outline_rounded,
                                                                size: 14,
                                                                color: theme
                                                                    .colorScheme
                                                                    .onSurface
                                                                    .withValues(
                                                                      alpha:
                                                                          0.5,
                                                                    ),
                                                              ),
                                                            ],
                                                          ],
                                                        ),
                                                        selected:
                                                            (_flag ??
                                                                detail
                                                                    .flags
                                                                    .first) ==
                                                            flag,
                                                        onSelected: (_) =>
                                                            setState(
                                                              () =>
                                                                  _flag = flag,
                                                            ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 14),
                                        _EpisodeGrid(
                                          episodes: detail.episodeList(
                                            _flag ?? '',
                                          ),
                                          currentIndex: history?.flag == _flag
                                              ? history?.episodeIndex
                                              : null,
                                          onTap: (index) => _playEpisode(index),
                                        ),
                                        if (detail.flags.isEmpty ||
                                            detail
                                                .episodeList(_flag ?? '')
                                                .isEmpty) ...[
                                          const SizedBox(height: 6),
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  '该源没有可播剧集，换一个源试试',
                                                  style: theme
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: theme
                                                            .colorScheme
                                                            .onSurface
                                                            .withValues(
                                                              alpha: 0.55,
                                                            ),
                                                      ),
                                                ),
                                              ),
                                              TextButton.icon(
                                                onPressed: () =>
                                                    _search(detail.name),
                                                icon: const Icon(
                                                  Icons.search_rounded,
                                                  size: 18,
                                                ),
                                                label: const Text('进入聚合搜索'),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (cast.isNotEmpty) ...[
                                    const SizedBox(height: 22),
                                    GlassPanel(
                                      padding: const EdgeInsets.all(18),
                                      borderRadius: 24,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Text(
                                                '演职员',
                                                style:
                                                    theme.textTheme.titleMedium,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                '点击头像或名字全源搜索',
                                                style: theme
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: theme
                                                          .colorScheme
                                                          .onSurface
                                                          .withValues(
                                                            alpha: 0.6,
                                                          ),
                                                    ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          SizedBox(
                                            height: 136,
                                            child: ScrollConfiguration(
                                              behavior:
                                                  const MouseDragScrollBehavior(),
                                              child: ListView.separated(
                                                scrollDirection:
                                                    Axis.horizontal,
                                                padding: EdgeInsets.zero,
                                                itemCount: cast.length,
                                                separatorBuilder: (_, _) =>
                                                    const SizedBox(width: 10),
                                                itemBuilder: (context, index) {
                                                  final member = cast[index];
                                                  return _CastCard(
                                                    member: member,
                                                    onTap: () =>
                                                        _search(member.name),
                                                  );
                                                },
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  if (_extra != null) ...[
                                    const SizedBox(height: 22),
                                    _DoubanExtraPanel(
                                      extra: _extra!,
                                      onSearch: _search,
                                      onOpenReview: _showReview,
                                    ),
                                  ],
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          if (_playGate != null)
            Positioned.fill(
              child: _PlayGateOverlay(
                state: _playGate!,
                onCancel: _gateCancel ?? () {},
                onConfirm: _gateConfirm ?? () {},
                onSwitchSource: _gateSwitchSource ?? () {},
              ),
            ),
        ],
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.image, required this.headers});
  final String image;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (image.isNotEmpty)
              Opacity(
                opacity: 0.55,
                child: Image.network(
                  image,
                  fit: BoxFit.cover,
                  headers: headers.isEmpty ? null : headers,
                  filterQuality: FilterQuality.low,
                  cacheWidth: 960,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              )
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      theme.colorScheme.primary.withValues(alpha: 0.22),
                      theme.scaffoldBackgroundColor,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    theme.scaffoldBackgroundColor.withValues(alpha: 0.45),
                    theme.scaffoldBackgroundColor.withValues(alpha: 0.72),
                    theme.scaffoldBackgroundColor.withValues(alpha: 0.94),
                  ],
                  stops: const [0, 0.35, 0.75],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.favorite,
    required this.onBack,
    required this.onFavorite,
    required this.onCopy,
  });

  final String title;
  final bool favorite;
  final VoidCallback onBack;
  final VoidCallback? onFavorite;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 详情页隐藏了自绘标题栏，这里的顶栏同时充当窗口拖拽区。
    return windowDragArea(
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(
          children: [
            IconButton.filledTonal(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: HoverMarqueeText(
                  title,
                  key: ValueKey(title),
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            IconButton(
              tooltip: '复制名称',
              onPressed: onCopy,
              icon: const Icon(Icons.ios_share_rounded),
            ),
            IconButton(
              tooltip: favorite ? '取消收藏' : '收藏',
              onPressed: onFavorite,
              icon: Icon(
                favorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: favorite ? theme.colorScheme.error : null,
              ),
            ),
            if (hasCustomWindowChrome)
              IconButton(
                tooltip: '退出软件',
                onPressed: closeAppWindow,
                icon: const Icon(Icons.power_settings_new_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.detail,
    required this.douban,
    required this.narrow,
    required this.introText,
    required this.introFromDouban,
    required this.onExpandIntro,
    required this.onOpenCover,
    required this.onPlay,
    required this.playLabel,
    this.progress = 0,
  });

  final VodDetail detail;
  final DoubanInfo? douban;
  final bool narrow;
  final String introText;
  final bool introFromDouban;
  final VoidCallback onExpandIntro;
  final VoidCallback onOpenCover;
  final VoidCallback onPlay;
  final String playLabel;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverUrl = detail.cleanPic.isNotEmpty
        ? detail.cleanPic
        : (douban?.coverUrl ?? '');
    final coverHeaders = detail.cleanPic.isNotEmpty
        ? detail.picHeaders
        : const <String, String>{};
    final posterWidth = narrow ? 170.0 : 210.0;
    final posterHeight = posterWidth * 1.5;
    final poster = MouseRegion(
      cursor: coverUrl.isEmpty
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: coverUrl.isEmpty ? null : onOpenCover,
        child: Container(
          width: posterWidth,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 30,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: coverUrl.isEmpty
                  ? Container(
                      color: theme.colorScheme.primary.withValues(alpha: 0.18),
                    )
                  : Image.network(
                      coverUrl,
                      fit: BoxFit.cover,
                      headers: coverHeaders.isEmpty ? null : coverHeaders,
                      // 详情海报物理宽度 ~260px，按原图尺寸解码会浪费内存
                      cacheWidth: 360,
                      errorBuilder: (_, _, _) => Container(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.18,
                        ),
                        child: const Icon(Icons.movie_outlined, size: 40),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );

    final heading = <Widget>[
      HoverMarqueeText(
        detail.name,
        maxLines: 2,
        textAlign: narrow ? TextAlign.center : TextAlign.left,
        style: theme.textTheme.headlineMedium?.copyWith(
          fontSize: narrow ? 26 : 34,
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        alignment: narrow ? WrapAlignment.center : WrapAlignment.start,
        spacing: 8,
        runSpacing: 8,
        children: [
          if (detail.year.isNotEmpty)
            _MetaPill(text: detail.year)
          else if (douban != null && douban!.year.isNotEmpty)
            _MetaPill(text: douban!.year),
          if (detail.area.isNotEmpty) _MetaPill(text: detail.area),
          if (detail.type.isNotEmpty)
            _MetaPill(text: detail.type)
          else if (douban != null && douban!.genres.isNotEmpty)
            _MetaPill(text: douban!.genres.take(3).join(' / ')),
          if (douban?.rating != null)
            _MetaPill(
              text: '豆瓣 ${douban!.rating!.toStringAsFixed(1)}',
              highlight: true,
            ),
          if (detail.remarks.isNotEmpty)
            _MetaPill(text: detail.remarks, highlight: true),
        ],
      ),
      if (detail.director.isNotEmpty ||
          detail.actor.isNotEmpty ||
          douban != null) ...[
        const SizedBox(height: 12),
        Text(
          [
            if (detail.director.isNotEmpty)
              '导演 ${detail.director}'
            else if (douban != null && douban!.directors.isNotEmpty)
              '导演 ${douban!.directors.join(' / ')}',
            if (detail.actor.isNotEmpty)
              '主演 ${detail.actor}'
            else if (douban != null && douban!.actors.isNotEmpty)
              '主演 ${douban!.actors.take(4).join(' / ')}',
          ].where((s) => s.isNotEmpty).join('  ·  '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: narrow ? TextAlign.center : TextAlign.left,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
            height: 1.5,
          ),
        ),
      ],
    ];

    final intro = introText.trim().isEmpty
        ? null
        : _HeaderIntro(
            text: introText,
            fromDouban: introFromDouban,
            onExpand: onExpandIntro,
          );
    final playRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          onPressed: onPlay,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(playLabel),
        ),
        if (progress > 0.01) ...[
          const SizedBox(width: 10),
          Text(
            '已看 ${(progress * 100).round()}%',
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppTheme.accentForeground(theme.colorScheme),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );

    if (narrow) {
      return Column(
        children: [
          poster,
          const SizedBox(height: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ...heading,
              if (intro != null) ...[
                const SizedBox(height: 12),
                SizedBox(height: 150, child: intro),
              ],
              const SizedBox(height: 14),
              playRow,
            ],
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        poster,
        const SizedBox(width: 28),
        Expanded(
          child: SizedBox(
            height: posterHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...heading,
                if (intro != null) ...[
                  const SizedBox(height: 10),
                  Expanded(child: intro),
                ] else
                  const Spacer(),
                const SizedBox(height: 10),
                playRow,
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 详情页红框内的简介：固定高度，超出时只显示省略号 + 展开按钮（弹出全文）。
class _HeaderIntro extends StatelessWidget {
  const _HeaderIntro({
    required this.text,
    required this.fromDouban,
    required this.onExpand,
  });

  final String text;
  final bool fromDouban;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 与上方的「导演 / 主演」保持一致：纯文字，不加背景框。
    final style =
        theme.textTheme.bodySmall?.copyWith(
          height: 1.5,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
        ) ??
        const TextStyle(fontSize: 12, height: 1.5);
    return LayoutBuilder(
      builder: (context, constraints) {
        const linkHeight = 26.0;
        final available = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 120.0;
        final lineHeight = (style.fontSize ?? 12) * (style.height ?? 1.5);
        final maxLines = ((available - linkHeight) / lineHeight)
            .floor()
            .clamp(1, 12)
            .toInt();
        final textWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth.clamp(1.0, double.infinity).toDouble()
            : 400.0;
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: maxLines,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: textWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                text,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            if (overflows)
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  height: linkHeight,
                  child: TextButton(
                    onPressed: onExpand,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 26),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      fromDouban ? '展开 · 豆瓣简介' : '展开',
                      style: TextStyle(
                        color: AppTheme.accentForeground(theme.colorScheme),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.text, this.highlight = false});
  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = highlight
        ? AppTheme.accentForeground(theme.colorScheme)
        : theme.colorScheme.onSurface.withValues(alpha: 0.78);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: highlight
            ? theme.colorScheme.primary.withValues(alpha: 0.14)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _EpisodeGrid extends StatefulWidget {
  const _EpisodeGrid({
    required this.episodes,
    required this.currentIndex,
    required this.onTap,
  });

  final List<Episode> episodes;
  final int? currentIndex;
  final ValueChanged<int> onTap;

  @override
  State<_EpisodeGrid> createState() => _EpisodeGridState();
}

class _EpisodeGridState extends State<_EpisodeGrid> {
  /// 单页最多显示的集数：长剧一次铺几百个按钮会明显拖慢详情页。
  static const int _pageSize = 50;
  int _page = 0;

  int get _pageCount =>
      widget.episodes.isEmpty ? 1 : (widget.episodes.length / _pageSize).ceil();

  @override
  void initState() {
    super.initState();
    _page = (widget.currentIndex ?? 0) ~/ _pageSize;
  }

  @override
  void didUpdateWidget(covariant _EpisodeGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episodes != widget.episodes) {
      _page = (widget.currentIndex ?? 0) ~/ _pageSize;
    } else if (widget.currentIndex != oldWidget.currentIndex &&
        widget.currentIndex != null) {
      _page = widget.currentIndex! ~/ _pageSize;
    }
    if (_page >= _pageCount) _page = _pageCount - 1;
    if (_page < 0) _page = 0;
  }

  @override
  Widget build(BuildContext context) {
    final episodes = widget.episodes;
    if (episodes.isEmpty) {
      return const Text('暂无选集', style: TextStyle(fontSize: 13));
    }
    final start = _page * _pageSize;
    final end = (start + _pageSize) > episodes.length
        ? episodes.length
        : start + _pageSize;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_pageCount > 1) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var page = 0; page < _pageCount; page++)
                _RangeChip(
                  label:
                      '${page * _pageSize + 1}-'
                      '${(page + 1) * _pageSize > episodes.length ? episodes.length : (page + 1) * _pageSize}',
                  selected: page == _page,
                  onTap: () => setState(() => _page = page),
                ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = start; i < end; i++)
              _EpisodeTile(
                label: episodes[i].name,
                selected: widget.currentIndex == i,
                onTap: () => widget.onTap(i),
              ),
          ],
        ),
      ],
    );
  }
}

/// 演职员卡片：豆瓣人物头像 + 名字，整卡悬停高亮，点击全源搜索。
class _CastCard extends StatefulWidget {
  const _CastCard({required this.member, required this.onTap});

  final DoubanCastMember member;
  final VoidCallback onTap;

  @override
  State<_CastCard> createState() => _CastCardState();
}

class _CastCardState extends State<_CastCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final member = widget.member;
    final hasAvatar = member.avatar.trim().isNotEmpty;
    return Tooltip(
      message: member.role.isEmpty
          ? member.name
          : '${member.name}\n${member.role}',
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: SizedBox(
            width: 84,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 76,
                  height: 96,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: theme.colorScheme.primary.withValues(
                        alpha: _hover ? 0.75 : 0.16,
                      ),
                      width: _hover ? 1.6 : 1,
                    ),
                    boxShadow: _hover
                        ? [
                            BoxShadow(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.18,
                              ),
                              blurRadius: 14,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  child: hasAvatar
                      ? Image.network(
                          member.avatarUrl,
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          errorBuilder: (_, _, _) => const _CastPlaceholder(),
                          loadingBuilder: (context, child, progress) =>
                              progress == null
                              ? child
                              : const _CastPlaceholder(),
                        )
                      : const _CastPlaceholder(),
                ),
                const SizedBox(height: 6),
                HoverMarqueeText(
                  member.name,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  externalHover: _hover,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface.withValues(
                      alpha: _hover ? 1 : 0.85,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                if (member.role.isNotEmpty)
                  SizedBox(
                    width: 84,
                    child: Text(
                      member.role,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        height: 1.1,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.58,
                        ),
                      ),
                    ),
                  )
                else
                  const SizedBox(height: 11),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 没有豆瓣头像 / 图片加载失败时的占位：渐变底色 + 人像剪影。
///
/// 不再显示姓氏首字：单个字看起来像「不是演职员的名字」，容易被误认。
class _CastPlaceholder extends StatelessWidget {
  const _CastPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primary.withValues(alpha: 0.22),
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.person_rounded,
          size: 28,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

/// 单集按钮：鼠标悬停时给明显的底色 + 描边反馈。
///
/// 以前是 `InkWell` 直接包住不透明背景的 `AnimatedContainer`，水波纹与
/// hover 高亮都画在 Material 上、被容器自身盖住，鼠标移上去毫无变化。
class _EpisodeTile extends StatefulWidget {
  const _EpisodeTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = AppTheme.accentForeground(scheme);
    final Color background;
    final Color borderColor;
    final Color labelColor;
    if (widget.selected) {
      background = scheme.primary.withValues(alpha: 0.2);
      borderColor = accent;
      labelColor = accent;
    } else if (_hover) {
      background = scheme.primary.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.18 : 0.16,
      );
      borderColor = accent.withValues(alpha: 0.55);
      labelColor = accent;
    } else {
      background = scheme.surfaceContainerHighest.withValues(alpha: 0.45);
      borderColor = Colors.transparent;
      labelColor = scheme.onSurface.withValues(alpha: 0.78);
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minWidth: 64),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor),
          ),
          child: HoverMarqueeText(
            widget.label,
            textAlign: TextAlign.center,
            externalHover: _hover,
            style: TextStyle(
              fontSize: 12,
              fontWeight: widget.selected ? FontWeight.w800 : FontWeight.w500,
              color: labelColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _RangeChip extends StatelessWidget {
  const _RangeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.18)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
              color: selected
                  ? AppTheme.accentForeground(theme.colorScheme)
                  : theme.colorScheme.onSurface.withValues(alpha: 0.78),
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情页底部：豆瓣「相关推荐 / 影评」共用一区，文字 tab 切换。
class _DoubanExtraPanel extends StatefulWidget {
  const _DoubanExtraPanel({
    required this.extra,
    required this.onSearch,
    required this.onOpenReview,
  });

  final DoubanDetailExtra extra;
  final ValueChanged<String> onSearch;
  final ValueChanged<DoubanReviewItem> onOpenReview;

  @override
  State<_DoubanExtraPanel> createState() => _DoubanExtraPanelState();
}

class _DoubanExtraPanelState extends State<_DoubanExtraPanel> {
  int _tab = -1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recs = widget.extra.recommendations;
    final reviews = widget.extra.reviews;
    final hasRecs = recs.isNotEmpty;
    final hasReviews = reviews.isNotEmpty;
    if (_tab < 0) _tab = hasRecs ? 0 : 1;
    final showReviews = !hasRecs || _tab == 1;

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      borderRadius: 24,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('豆瓣', style: theme.textTheme.titleMedium),
              const SizedBox(width: 14),
              if (hasRecs)
                _TextTab(
                  label: '相关推荐',
                  selected: !showReviews,
                  onTap: () => setState(() => _tab = 0),
                ),
              if (hasRecs && hasReviews) const SizedBox(width: 14),
              if (hasReviews)
                _TextTab(
                  label: '影评',
                  selected: showReviews,
                  onTap: () => setState(() => _tab = 1),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (!showReviews)
            SizedBox(
              height: 232,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: recs.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final item = recs[index];
                  return SizedBox(
                    width: 124,
                    child: Tooltip(
                      message: item.overview.isNotEmpty
                          ? item.overview
                          : item.subtitle,
                      child: PosterCard(
                        item: VodItem(
                          id: item.id,
                          name: item.title,
                          pic: item.posterUrl,
                          year: item.year?.toString() ?? '',
                          remarks: item.rating != null
                              ? '豆瓣 ${item.rating!.toStringAsFixed(1)}'
                              : '',
                        ),
                        onTap: () => widget.onSearch(item.title),
                        onSecondaryLongPress: () => widget.onSearch(item.title),
                      ),
                    ),
                  );
                },
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < reviews.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 22,
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.4,
                      ),
                    ),
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => widget.onOpenReview(reviews[i]),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            reviews[i].title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (reviews[i].abstract.isNotEmpty) ...[
                            const SizedBox(height: 5),
                            Text(
                              reviews[i].abstract,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.66,
                                ),
                                height: 1.55,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Text(
                            [
                              if (reviews[i].author.isNotEmpty)
                                reviews[i].author,
                              if (reviews[i].rating != null)
                                '${reviews[i].rating!.toStringAsFixed(1)} 星',
                              if (reviews[i].useful > 0)
                                '有用 ${reviews[i].useful}',
                            ].join(' · '),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.42,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _TextTab extends StatelessWidget {
  const _TextTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.only(bottom: 3),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
            color: selected
                ? AppTheme.accentForeground(theme.colorScheme)
                : theme.colorScheme.onSurface.withValues(alpha: 0.72),
          ),
        ),
      ),
    );
  }
}

/// 详情页播放加载框的状态：加载中 → 失败提示。
class _PlayGateState {
  const _PlayGateState.loading({this.canCancel = false})
    : error = false,
      title = '',
      message = '';

  const _PlayGateState.error(this.title, this.message)
    : error = true,
      canCancel = false;

  final bool error;
  final bool canCancel;
  final String title;
  final String message;
}

/// 详情页点击播放后的阻塞加载遮罩；失败时原地切换成错误提示。
///
/// 直接画在详情页的 Stack 里，不依赖 DialogRoute：即使播放器路由正在切换，
/// 遮罩也一定盖在当前详情页上。
class _PlayGateOverlay extends StatelessWidget {
  const _PlayGateOverlay({
    required this.state,
    required this.onCancel,
    required this.onConfirm,
    required this.onSwitchSource,
  });
  final ValueNotifier<_PlayGateState> state;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final VoidCallback onSwitchSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = (MediaQuery.sizeOf(context).height - 40).clamp(
      120.0,
      520.0,
    );
    return Stack(
      children: [
        const ModalBarrier(dismissible: false, color: Color(0x99000000)),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: ValueListenableBuilder<_PlayGateState>(
              valueListenable: state,
              builder: (context, value, _) {
                return Material(
                  color: theme.colorScheme.surface,
                  elevation: 18,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 380,
                      maxHeight: maxHeight,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 22, 24, 14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (value.error) ...[
                            Text(
                              value.title,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 10),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 300),
                              child: SingleChildScrollView(
                                child: Text(
                                  value.message,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    height: 1.55,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton.icon(
                                  onPressed: onSwitchSource,
                                  icon: const Icon(
                                    Icons.swap_horiz_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('换源'),
                                ),
                                const SizedBox(width: 6),
                                FilledButton(
                                  onPressed: onConfirm,
                                  child: const Text('确定'),
                                ),
                              ],
                            ),
                          ] else ...[
                            Row(
                              children: [
                                const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Text(
                                    '正在努力加载',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (value.canCancel) ...[
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: onCancel,
                                  child: const Text('取消'),
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _ImmersiveMetaChip extends StatelessWidget {
  const _ImmersiveMetaChip(this.label, {this.highlight = false});

  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: highlight
            ? theme.colorScheme.primary.withValues(alpha: 0.18)
            : Colors.white.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: highlight
              ? theme.colorScheme.primary.withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: highlight
                ? theme.colorScheme.primary
                : Colors.white.withValues(alpha: 0.72),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ImmersiveLineChip extends StatefulWidget {
  const _ImmersiveLineChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ImmersiveLineChip> createState() => _ImmersiveLineChipState();
}

class _ImmersiveLineChipState extends State<_ImmersiveLineChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: _hover ? 0.14 : 0.07),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.62)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Text(
            widget.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: selected
                  ? theme.colorScheme.primary
                  : Colors.white.withValues(alpha: 0.76),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _ImmersiveEpisodeCard extends StatefulWidget {
  const _ImmersiveEpisodeCard({
    required this.episode,
    required this.index,
    required this.title,
    required this.year,
    required this.fallback,
    this.still = '',
    required this.selected,
    required this.onTap,
  });

  final Episode episode;
  final int index;
  final String title;
  final String year;
  final String fallback;

  /// TMDB 该集的剧照；空串时继续使用片名横图。
  final String still;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ImmersiveEpisodeCard> createState() => _ImmersiveEpisodeCardState();
}

class _ImmersiveEpisodeCardState extends State<_ImmersiveEpisodeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: 198,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 112,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected
                        ? theme.colorScheme.primary
                        : (_hover
                              ? Colors.white.withValues(alpha: 0.42)
                              : Colors.white.withValues(alpha: 0.08)),
                    width: selected ? 2 : 1,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.28,
                            ),
                            blurRadius: 16,
                          ),
                        ]
                      : const [],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ImmersiveBackdrop(
                        title: widget.title,
                        year: widget.year,
                        fallback: widget.fallback,
                        scrim: true,
                      ),
                      if (widget.still.isNotEmpty)
                        Image.network(
                          widget.still,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          frameBuilder: (context, child, frame, sync) {
                            if (sync) return child;
                            return AnimatedOpacity(
                              opacity: frame == null ? 0 : 1,
                              duration: const Duration(milliseconds: 250),
                              child: child,
                            );
                          },
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      Positioned(
                        left: 8,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.58),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${widget.index + 1}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.episode.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: selected
                      ? theme.colorScheme.primary
                      : Colors.white.withValues(alpha: 0.74),
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 磁力解析等待中的模态提示（结果出来后由调用方 pop）。
///
/// 冷门种子取元数据可能要几十秒，弹窗不能没有出口：
/// 等待满 10 秒后出现「取消」，并显示已等待时长，避免用户以为卡死。
class _BtPreparingDialog extends StatefulWidget {
  const _BtPreparingDialog({required this.status, required this.onCancel});

  final ValueListenable<String> status;
  final VoidCallback onCancel;

  @override
  State<_BtPreparingDialog> createState() => _BtPreparingDialogState();
}

class _BtPreparingDialogState extends State<_BtPreparingDialog> {
  static const _cancelAfterSeconds = 10;

  Timer? _timer;
  int _elapsed = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canCancel = _elapsed >= _cancelAfterSeconds;
    final hintStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
    );
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ValueListenableBuilder<String>(
                    valueListenable: widget.status,
                    builder: (_, message, _) => Text(message),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _elapsed < 3
                        ? '冷门资源或云端离线可能需要等待一段时间。'
                        : '已等待 $_elapsed 秒，冷门资源可能需要更久'
                              '${canCancel ? '；也可以取消后重试。' : '。'}',
                    style: hintStyle,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (canCancel)
            TextButton(onPressed: widget.onCancel, child: const Text('取消')),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../app.dart';
import '../parse_play.dart';
import '../../core/logging/app_log.dart';
import '../../core/logging/log_redact.dart';
import '../../core/platform/sleep_inhibitor.dart';
import '../../core/platform/window_service.dart';
import '../../models/player_fit.dart';
import '../../models/site_config.dart';
import '../../models/user_data.dart';
import '../../models/vod.dart';
import '../../models/video_download.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/hover_marquee_text.dart';
import '../widgets/hyms_captcha_dialog.dart';
import '../widgets/mouse_drag_scroll.dart';
import '../widgets/player_overlay_settings.dart';
import '../widgets/sleep_timer_sheet.dart';
import '../widgets/volume_hud.dart';
import '../widgets/volume_sheet.dart';
import '../../services/drive/drive_line_hint.dart';
import '../../services/dlna/dlna.dart';
import '../../services/download/video_download_service.dart';
import '../../services/torrent/magnet.dart';
import '../../services/boss_key/boss_key_service.dart';
import '../../services/artwork/artwork_service.dart';
import '../../services/player/auto_line_switch.dart';
import '../../services/player/network_speed_smoother.dart';
import '../../services/player/external_players.dart';
import '../../services/player/skip_segments.dart';
import '../../services/player/sleep_timer.dart';
import '../../services/relay/local_relay.dart';
import '../../services/party/party_room.dart';
import '../../services/party/watch_party.dart';
import '../../services/jar_spider/hyms_native.dart';
import '../../services/mpv_extension.dart';
import '../../services/play_page_unwrap.dart';
import '../../services/danmaku/danmaku_endpoints.dart';
import '../../services/danmaku/danmaku_models.dart';
import '../../services/danmaku/danmaku_query.dart';
import '../../services/danmaku/danmaku_service.dart';
import '../../services/danmaku/danmaku_settings.dart';
import '../../services/subtitle/subtitle_models.dart';
import '../widgets/dlna_cast_sheet.dart';
import '../widgets/subtitle_panel.dart';
import '../widgets/video_download_dialog.dart';
import '../../state/app_state.dart';
import '../widgets/drive_login_prompt.dart';

part 'player/cast_part.dart';
part 'player/danmaku_part.dart';
part 'player/download_part.dart';
part 'player/party_part.dart';
part 'player/playback_part.dart';

/// 该播放地址是否是 DASH(MPD) 清单。
///
/// 内置内核是 libmdk + 随包 ffmpeg：前者不认 MPD，后者的 `dash` 只编进去了
/// muxer（`dashenc`），没有 `dashdec` 解复用器 —— 所以 MPD 一定播不了。
/// 用来把 fvp 的 "invalid or unsupported media" 翻译成用户能照做的提示。
bool _looksLikeDashUrl(String url) {
  final lower = url.toLowerCase();
  if (lower.isEmpty) return false;
  return lower.contains('.mpd') ||
      lower.contains('type=mpd') ||
      lower.contains('dash%2bxml');
}

class PlayerSession {
  const PlayerSession({
    required this.detail,
    required this.site,
    required this.flag,
    required this.episodeIndex,
    required this.episodes,
    this.initialPlay,
    this.startPositionMs = 0,
    this.ephemeral = false,
  });

  final VodDetail detail;
  final SourceBean site;
  final String flag;
  final int episodeIndex;
  final List<Episode> episodes;

  /// 已取到的播放地址；为 null 时播放器页自己取链（详情页因此可以秒开播放器）。
  final PlayResult? initialPlay;
  final int startPositionMs;

  /// 临时会话（WebDAV 目录 / 磁力流等不属于订阅源的直链）：
  /// 不写观看历史、不记跳过片头片尾 —— 这些记录在收藏页无法恢复。
  final bool ephemeral;
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.session,
    this.onExit,
    this.onSwitchSource,
    this.onVideoAspect,
  });

  final PlayerSession session;

  /// 独立窗口模式下退出播放器（关闭子窗口）；为空 = 普通路由返回。
  final Future<void> Function()? onExit;

  /// 独立窗口模式下「换源」：把片名交给主窗口搜索，然后关闭子窗口。
  final Future<void> Function(String keyword)? onSwitchSource;

  /// 独立窗口模式下的竖版适配：拿到视频分辨率后回调（内嵌播放器传 null）。
  final Future<void> Function(double videoWidth, double videoHeight)?
  onVideoAspect;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _controller;
  late final AnimationController _fsAnim;
  late int _index = widget.session.episodeIndex;

  /// 自动换线 / 换源后，详情、站点、线路和选集都可能变化。
  late VodDetail _detail = widget.session.detail;
  late SourceBean _site = widget.session.site;
  late String _flag = widget.session.flag;
  late List<Episode> _episodes = widget.session.episodes;
  late bool _ephemeral = widget.session.ephemeral;
  bool _opened = false;
  bool _controls = true;
  bool _cursorVisible = true;
  bool _sleepHeld = false;
  bool _buffering = true;

  /// 缓冲超过一小段时间才亮转圈：轻微补帧不会闪一下遮住画面。
  bool _bufferingHint = false;
  Timer? _bufferingHintTimer;
  bool _playing = false;
  bool _fullscreen = false;
  bool _fsToggling = false;
  bool _resolving = false;
  bool _completedHandled = false;
  bool _mpvReady = false;

  /// 睡眠定时器：到点暂停当前播放。
  ///
  /// 放在播放器页而不是全局 AppState：定时器的生命周期应该跟着这一集走，
  /// 关掉播放器就自然失效，避免退出后还在后台倒计时。
  late final SleepTimer _sleepTimer = SleepTimer(
    onExpire: _onSleepTimerExpired,
    onChanged: (_) {
      if (mounted) setState(() {});
    },
  );

  /// 定时器到点：暂停播放并提示。
  void _onSleepTimerExpired() {
    if (!mounted) return;
    _controller?.pause();
    setState(() => _playing = false);
    _toast('睡眠定时器已到点，播放已暂停');
  }
  String _error = '';
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _rate = 1.0;
  double _volume = 1.0;
  bool _danmakuEnabled = false;
  List<DanmakuLine> _danmaku = const [];

  /// 当前集拉到的全量弹幕；屏蔽词变化时据此重新过滤。
  List<DanmakuLine> _allDanmaku = const [];
  int _danmakuSeq = 0;
  String _subtitleStatus = '';
  PlayerFit _fit = PlayerFit.contain;
  int _skipIntro = 0;
  int _skipOutro = 0;
  String _skipInheritedFrom = '';
  bool _outroFired = false;

  /// 已经写进当前内核的缓冲参数：设置页改动后据此判断要不要重新下发。
  double? _lastAppliedBufferMin;
  double? _lastAppliedBufferMax;
  bool _holdingRate = false;
  double? _rateBeforeHold;
  bool _mini = false;

  /// 运行时识别出的直播流：隐藏进度条 / 弹幕 / 片头片尾，底部显示「直播」。
  bool _live = false;

  /// 进度条右键单击 / 双击判定：双击清除记录，单击取点。
  /// 单击要等过双击窗口才执行，否则第二次按下时第一次的设置已经落盘，撤不回来。
  Timer? _skipTapTimer;
  DateTime? _lastSecondaryTapAt;
  double _lastSecondaryTapDx = 0;

  /// 沉浸观影下窗口本来就全屏，离开播放器时不能把外层沉浸全屏退掉。
  bool _immersiveMode = false;

  /// 同一集取链进行中的标记：用于忽略重复点击（`_openSeq` 只负责作废旧结果）。
  int? _loadingIndex;

  /// 正在切换外部 MPV：防止连续点击开出多个播放器。
  bool _openingMpv = false;

  /// 已把当前播放地址交给外部播放器：页面 dispose 时不能回收取流 JVM，
  /// 否则外部播放器随后请求本机 `/chunk` 只会拿到 404。
  bool _handedToExternalPlayer = false;

  /// 该集是否已经因「本机取流地址打不开」自动重取过一次，防止死循环。
  int _mediaRetriedEpisode = -1;

  /// 该集是否已经因初始化超时尝试过绕过本机中继直连，防止反复超时。
  int _directRetriedEpisode = -1;

  /// 本次打开是否已记录过播放内核错误（原生内核闪退前通常只有这一条线索）。
  bool _errorLogged = false;

  /// 自动换线：已尝试过的「站点|详情|线路|集名」，避免回环。
  final Set<String> _autoTriedAttempts = {};

  /// 已经搜索并尝试过的其他源（同一源只换一次）。
  final Set<String> _autoTriedSources = {};

  /// 自动换线流程进行中（防止多个失败回调同时换线）。
  bool _autoSwitching = false;

  /// 自动换线运行代次：用户手动操作会作废旧的一轮。
  int _autoRunSeq = 0;

  /// 当前这次打开是否已经触发过自动换线（内核 error 回调会重复）。
  bool _autoErrorHandled = false;

  /// 用户手动切集 / 换线路计数；自动流程发现它变化就中止。
  int _manualSeq = 0;

  /// 自动换源搜索的订阅 / 超时 / 完成信号；离开播放器时主动收掉。
  Completer<void>? _autoSearchDone;
  StreamSubscription<SearchProgress>? _autoSearchSub;
  Timer? _autoSearchTimer;

  /// 自动换线正在异步释放旧 controller；手动切换前也要等它完成。
  Future<void>? _controllerDisposePending;

  /// 滚轮调音量的落盘防抖：连续滚动时只在停下后写一次播放设置。
  Timer? _volumeWheelTimer;

  /// 快捷键 / 滚轮调音量时短暂显示的音量条。
  bool _volumeHudVisible = false;
  Timer? _volumeHudTimer;

  /// 本次播放会话的窗口置顶状态（不落盘，离开播放器即复位）。
  bool _alwaysOnTop = false;

  /// 进入小窗前的置顶选择，退出小窗时恢复。
  bool _pinnedBeforeMini = false;
  List<_AudioOption> _audioOptions = const [];
  int? _activeAudio;

  /// 当前这一集已解析出的播放地址（投屏时据此解出真实上游地址）。
  PlayResult? _currentPlay;

  /// `_currentPlay` 对应的集数下标；切集取链过程中它仍指旧集，避免被外部播放器误用。
  int? _currentPlayIndex;

  /// 静音前的音量，取消静音时恢复。
  double _lastVolume = 1.0;
  int _openSeq = 0;
  Timer? _hideTimer;
  Timer? _saveTimer;

  /// 一起看：是否已绑定房间状态监听，以及上次广播时间（节流）。
  bool _partyBound = false;
  int _lastPartyPushAt = 0;
  bool _partyMismatchNotified = false;

  /// 播放器「详情」悬浮层开关与每秒刷新时钟 / 网速的计时器。
  bool _detailsVisible = false;
  Timer? _detailsTimer;

  /// 「详情」用的媒体信息缓存：只在 1 秒采样时读一次 fvp，避免播放器
  /// 每帧回调都把瞬时码率直接画到屏幕上（会剧烈跳动、出现关键帧尖峰）。
  _MediaStats? _mediaStats;

  /// 平滑后的展示值，避免 libmdk 实时码率的尖峰直接上屏。
  final NetworkSpeedSmoother _netSmoother = NetworkSpeedSmoother();
  late AppState _app;

  /// 正在刷新取流（防止连点重复起播放器）。
  bool _refreshing = false;

  /// fvp（libmdk）只在桌面端接管 video_player，移动端拿不到 MediaInfo。
  bool get _mdkEnabled =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  String get _episodeName =>
      _index >= 0 && _index < _episodes.length ? _episodes[_index].name : '';

  String _episodeKey(int index) {
    final name = index >= 0 && index < _episodes.length
        ? _episodes[index].name.trim()
        : '';
    return name.isEmpty ? '第${index + 1}集' : name;
  }

  /// 独立窗口里按视频分辨率切竖版；内嵌播放器没有回调，什么都不做。
  void _applyVideoAspect(VideoPlayerController controller) {
    final apply = widget.onVideoAspect;
    if (apply == null) return;
    var size = controller.value.size;
    if (size.width <= 0 || size.height <= 0) {
      // fvp 偶尔不给 VideoPlayerValue 尺寸，退回 libmdk 的 MediaInfo。
      final stats = _readMediaStats();
      if (stats == null) return;
      size = Size(stats.width.toDouble(), stats.height.toDouble());
    }
    if (size.width <= 0 || size.height <= 0) return;
    unawaited(apply(size.width, size.height));
  }

  void _syncAudioTracks(VideoPlayerController controller) {
    if (!_mdkEnabled || controller != _controller) return;
    try {
      final info = controller.getMediaInfo();
      final list = <_AudioOption>[];
      final audio = info?.audio;
      if (audio != null) {
        for (final item in audio) {
          final meta = item.metadata;
          list.add(
            _AudioOption(
              index: item.index,
              codec: item.codec.codec,
              channels: item.codec.channels,
              language: (meta['language'] ?? meta['lang'] ?? '').toString(),
              title: (meta['title'] ?? meta['handler_name'] ?? '').toString(),
            ),
          );
        }
      }
      final active = controller.getActiveAudioTracks();
      if (!mounted) return;
      setState(() {
        _audioOptions = list;
        _activeAudio = (active != null && active.isNotEmpty)
            ? active.first
            : (list.isNotEmpty ? list.first.index : null);
      });
    } catch (_) {
      // 非 fvp / 内核未就绪：没有音轨信息，不显示音轨入口
    }
  }

  @override
  void initState() {
    super.initState();
    // 全屏切换用纯 Flutter 的缩放/淡入过渡（只走合成层，不再逐帧 Resize 窗口）。
    _fsAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controls = false);
    });
    MpvExtension.instance.isInstalled.then((value) {
      if (mounted) setState(() => _mpvReady = value);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_opened) {
      // 设置页改了缓冲参数：当前播放器立刻跟随，不必等下一集起播。
      final settings = _app.playerSettings;
      if (settings.bufferMinSec != _lastAppliedBufferMin ||
          settings.bufferMaxSec != _lastAppliedBufferMax) {
        _lastAppliedBufferMin = settings.bufferMinSec;
        _lastAppliedBufferMax = settings.bufferMaxSec;
        final controller = _controller;
        if (controller != null) _applyBufferRange(controller);
      }
      return;
    }
    _opened = true;
    _app = AppScope.of(context);
    // 设置里的全局无痕模式：本次播放默认就不写历史 / 进度。
    // 播放器里的「无痕播放」开关仍可对本次播放单独关掉，不改全局设置。
    _ephemeral = _ephemeral || _app.playerSettings.incognito;
    if (!_partyBound) {
      _partyBound = true;
      _app.watchParty.addListener(_onPartyUpdate);
    }
    _lastAppliedBufferMin = _app.playerSettings.bufferMinSec;
    _lastAppliedBufferMax = _app.playerSettings.bufferMaxSec;
    _immersiveMode = _app.playerSettings.immersiveMode;
    BossKeyService.instance.bindPlayer(
      this,
      pause: _pauseForBossKey,
      resume: _resumeFromBossKey,
    );
    _rate = _app.playerSettings.speed;
    _fit = normalizePlayerFit(_app.playerSettings.fit);
    _volume = _app.playerSettings.volume.clamp(0.0, 1.0).toDouble();
    if (_volume > 0.001) _lastVolume = _volume;
    _danmakuEnabled = _app.danmakuSettings.enabled;
    // 「详情」开关跨启动记忆：上次开着就继续开，关掉也保持关闭。
    _detailsVisible = _app.playerSettings.overlayVisible;
    if (_detailsVisible) _startDetailsTimer();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _openEpisode(
        index: widget.session.episodeIndex,
        play: widget.session.initialPlay,
        startMs: widget.session.startPositionMs,
      ),
    );
  }

  void _onPlayerValue() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;
    // libmdk 对未知时长的直播会给一个接近 Duration 上限的时长；识别到以后
    // 不再显示进度、弹幕与片头片尾逻辑。
    final live = _live || value.duration > const Duration(hours: 24);
    setState(() {
      _live = live;
      _position = value.position;
      _duration = value.duration;
      _playing = value.isPlaying;
      _buffering = value.isBuffering;
      if (!value.isPlaying) _cursorVisible = true;
      if (value.hasError) {
        _error = value.errorDescription ?? '播放失败';
        _buffering = false;
      }
    });
    _syncBufferingHint(_buffering);
    if (value.hasError && !_errorLogged) {
      _errorLogged = true;
      AppLog.w(
        'player',
        '播放内核报错：$_error url=${redactUrl(_currentPlay?.url ?? '')}',
      );
    }
    if (value.hasError && !_autoErrorHandled && !_autoSwitching) {
      _autoErrorHandled = true;
      unawaited(
        _scheduleAutoSwitch(
          value.errorDescription ?? '播放失败',
          startMs: value.position.inMilliseconds,
        ),
      );
    }
    _syncSleepInhibitor();
    // 一起看：房主把进度广播到局域网（内部按 800ms 节流）。
    final party = _app.watchParty;
    if (party.hosting && !_live) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastPartyPushAt >= 1500) {
        _lastPartyPushAt = now;
        party.publish(
          PartyState(
            title: _detail.name,
            episodeName: _episodeName,
            episodeIndex: _index,
            positionMs: value.position.inMilliseconds,
            playing: value.isPlaying,
          ),
        );
      }
    }
    if (!_live && value.isCompleted && !_completedHandled) {
      _completedHandled = true;
      _onCompleted();
    }
    if (!_live &&
        !_outroFired &&
        shouldSkipOutro(
          value.position.inMilliseconds,
          value.duration.inMilliseconds,
          _skipOutro,
          _outroFired,
        )) {
      _outroFired = true;
      _onOutroReached();
    }
  }

  void _onOutroReached() {
    if (!_app.playerSettings.autoPlayNext) return;
    if (_index + 1 >= _episodes.length) return;
    _toast('已跳过片尾，播放下一集');
    _switchTo(_index + 1);
  }

  Future<bool> _openEpisode({
    required int index,
    PlayResult? play,
    int startMs = 0,
    bool allowLogin = true,
    bool bypassRelay = false,
    bool autoAttempt = false,
  }) async {
    final app = _app;
    if (!mounted || index < 0 || index >= _episodes.length) return false;
    if (!autoAttempt) {
      // 用户手动切集 / 重试：作废正在进行的自动换线，并允许重新尝试全部线路。
      _manualSeq++;
      _autoErrorHandled = false;
      _autoTriedAttempts.clear();
      _autoTriedSources.clear();
      _autoRunSeq++;
      _autoSwitching = false;
      final done = _autoSearchDone;
      if (done != null && !done.isCompleted) done.complete();
      final sub = _autoSearchSub;
      if (sub != null) unawaited(sub.cancel());
      _autoSearchDone = null;
      _autoSearchSub = null;
      _autoSearchTimer?.cancel();
      _autoSearchTimer = null;
    }
    if (index != _index) _directRetriedEpisode = -1;
    // 同一集正在取链时重复点击直接忽略：否则会并发拉多个常驻取流进程、
    // 同时初始化多个 controller，最后真的会同时播放好几份。
    if (play == null && _loadingIndex == index) return false;
    final seq = ++_openSeq;
    if (play == null) {
      _loadingIndex = index;
      setState(() {
        _resolving = true;
        _error = '';
      });
    }
    PlayResult? resolved;
    try {
      resolved = play ?? await _resolve(index);
    } catch (e) {
      if (seq != _openSeq || !mounted) return false;
      if (play == null) _loadingIndex = null;
      setState(() {
        _resolving = false;
        _buffering = false;
        _error = '取链失败：$e';
      });
      _afterFailure('取链失败：$e', autoAttempt: autoAttempt, startMs: startMs);
      return false;
    }
    if (seq != _openSeq || !mounted) return false;
    if (resolved == null) {
      if (play == null) _loadingIndex = null;
      setState(() {
        _resolving = false;
        _buffering = false;
        _error = '没有取到播放地址';
      });
      _afterFailure('没有取到播放地址', autoAttempt: autoAttempt, startMs: startMs);
      return false;
    }
    var target = resolved;
    try {
      if (target.parse != 0 && target.externalLink.isEmpty) {
        target = await resolveParsedPlay(
          context,
          app,
          _site,
          target,
          rawUrl: _episodes[index].url,
        );
        if (seq != _openSeq || !mounted) return false;
      }
      // 详情页“立即播放”传来的地址也可能是云播 HTML 页面。
      target = await app.unwrapPlayPage(target);
    } catch (e) {
      if (seq != _openSeq || !mounted) return false;
      if (play == null) _loadingIndex = null;
      setState(() {
        _resolving = false;
        _buffering = false;
        _error = '解析播放地址失败：$e';
      });
      _afterFailure('解析播放地址失败：$e', autoAttempt: autoAttempt, startMs: startMs);
      return false;
    }
    if (seq != _openSeq || !mounted) return false;
    // 源站把海报 / 截图当播放地址返回：fvp/libmdk 在图像解码路径上可能整进程闪退，
    // 打开前直接拦下并提示换线路。
    if (target.playable && looksLikeImageMediaUrl(target.url)) {
      if (play == null) _loadingIndex = null;
      AppLog.w('player', '拒绝播放图片地址 ${redactUrl(target.url)}');
      setState(() {
        _error = '该线路返回的是图片地址（源站解析异常），请改用其他线路';
        _resolving = false;
        _buffering = false;
      });
      _afterFailure('该线路返回的是图片地址', autoAttempt: autoAttempt, startMs: startMs);
      return false;
    }
    if (!target.playable) {
      // 换集时没登录对应网盘：直接弹扫码，成功后自动重试一次。
      // 可选增强（哔哩）跳过：没 Cookie 也会回低画质直链，重试只会白跑一次。
      if (allowLogin) {
        final hint = driveHintFromMessage(target.message);
        if (hint != null && hint.supported && !hint.optional) {
          if (!mounted) return false;
          final ready = await promptDriveLogin(
            context,
            hint,
            message: target.message,
          );
          if (!mounted) return false;
          if (ready) {
            _loadingIndex = null;
            await _openEpisode(
              index: index,
              startMs: startMs,
              allowLogin: false,
              autoAttempt: autoAttempt,
            );
            return false;
          }
        }
      }
      if (play == null) _loadingIndex = null;
      final message = target.message.isEmpty ? '无法播放这一集' : target.message;
      setState(() {
        _error = message;
        _resolving = false;
      });
      _afterFailure(message, autoAttempt: autoAttempt, startMs: startMs);
      return false;
    }
    if (play == null) _loadingIndex = null;
    final source = bypassRelay
        ? target
        : app.preparePlay(target, forceRelay: true);
    _currentPlay = target;
    _currentPlayIndex = index;
    final resource = '${_detail.sourceKey}|${_detail.id}';
    final episodeKey = _episodeKey(index);
    final skip = _ephemeral ? null : app.skipFor(resource, episodeKey);
    final effectiveStart = startMs > 0 ? startMs : (skip?.intro ?? 0) * 1000;
    setState(() {
      _index = index;
      _resolving = true;
      _error = '';
      _buffering = true;
      _completedHandled = false;
      _position = Duration.zero;
      _duration = Duration.zero;
      _subtitleStatus = '';
      _danmaku = const [];
      _allDanmaku = const [];
      _danmakuSeq++;
      _skipIntro = skip?.intro ?? 0;
      _skipOutro = skip?.outro ?? 0;
      _skipInheritedFrom = skip?.inheritedFrom ?? '';
      _outroFired = false;
      _audioOptions = const [];
      _activeAudio = null;
      _errorLogged = false;
      _mediaStats = null;
      _netSmoother.reset();
      _live = false;
    });
    final old = _controller;
    _controller = null;
    old?.removeListener(_onPlayerValue);
    // 必须等旧 controller 释放完再建新的：fvp/libmdk 的销毁与初始化都在原生侧，
    // 换集/换线路时并发会让播放内核在驱动/解析线程上崩溃（整进程闪退，没有 Dart 栈）。
    try {
      await old?.dispose();
    } catch (_) {
      // 旧实例释放失败不影响新一集
    }
    final pendingDispose = _controllerDisposePending;
    if (pendingDispose != null) {
      try {
        await pendingDispose;
      } catch (_) {
        // 自动换线释放失败也不阻断手动切换
      }
    }
    if (seq != _openSeq || !mounted) return false;
    AppLog.i(
      'player',
      '开始打开 ${_detail.name} · ${_episodeName.isEmpty ? '正片' : _episodeName} '
          'url=${redactUrl(source.url)}',
    );
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(source.url),
        httpHeaders: source.headers,
      );
      _controller = controller;
      controller.addListener(_onPlayerValue);
      // 4K / HDR 线路经过本机中继时，个别清单会让 fvp 一直没首帧；
      // 25 秒没有初始化完成就放弃，后面会尝试绕过中继直连。
      await controller.initialize().timeout(const Duration(seconds: 25));
      // 缓冲参数要在起播前设好：fvp 的 bufferRange 只影响后续拉流。
      _applyBufferRange(controller);
      final live = _detectLive(controller);
      _live = live;
      await controller.setPlaybackSpeed(_rate);
      await controller.setVolume(_volume);
      final durationMs = controller.value.duration.inMilliseconds;
      // 片头记录可能超过片长（换集后沿用旧设置）：越界就不跳。
      // 直播没有时间轴，不做起播跳转。
      final canSeek =
          !live &&
          (startMs > 0 ||
              durationMs <= 0 ||
              effectiveStart < durationMs - 1000);
      final appliedStart = canSeek ? effectiveStart : 0;
      if (appliedStart > 0) {
        await controller.seekTo(Duration(milliseconds: appliedStart));
      }
      await controller.play();
      if (seq != _openSeq || !mounted) return false;
      AppLog.i(
        'player',
        '打开成功 ${_detail.name} · ${_episodeName.isEmpty ? '正片' : _episodeName} '
            'url=${redactUrl(source.url)}',
      );
      _mediaRetriedEpisode = -1;
      _directRetriedEpisode = -1;
      setState(() {
        _resolving = false;
        _buffering = false;
        _live = live;
        _position = controller.value.position;
        _duration = controller.value.duration;
        _playing = controller.value.isPlaying;
      });
      _syncSleepInhibitor();
      _syncAudioTracks(controller);
      _applyVideoAspect(controller);
      if (!_ephemeral) {
        await app.recordHistory(
          detail: _detail,
          site: _site,
          flag: _flag,
          episodeName: _episodeName,
          episodeIndex: _index,
          url: target.url,
          rawUrl: _episodes[_index].url,
          headers: target.headers,
          positionMs: appliedStart,
        );
      }
      _startSaveTimer();
      _showControls();
      if (_danmakuEnabled && !live) unawaited(_loadDanmaku());
      return true;
    } catch (e) {
      if (seq != _openSeq || !mounted) return false;
      final controller = _controller;
      _controller = null;
      controller?.removeListener(_onPlayerValue);
      try {
        await controller?.dispose();
      } catch (_) {
        // 释放失败不影响后续提示 / 重新取链
      }
      // 加固壳/网盘源的地址是本机 JVM 的 /chunk、/proxy：JVM 已退出或端口没起来时
      // fvp 只会报 invalid or unsupported media。自动重新取链一次（会重起常驻进程）。
      final localSpiderUrl =
          target.url.contains('127.0.0.1') &&
          (target.url.contains('/chunk') || target.url.contains('/proxy'));
      final timedOut = e is TimeoutException;
      AppLog.e(
        'player',
        '打开失败 ${_detail.name} · ${_episodeName.isEmpty ? '正片' : _episodeName} '
            'url=${redactUrl(target.url)}',
        e,
      );
      // 4K / 大码率清单经中继初始化超时：再试一次直连上游，避免一直转圈。
      // 自动换线尝试不再占用时间做直连重试，直接交给下一条线路。
      if (!autoAttempt &&
          timedOut &&
          !bypassRelay &&
          source.url != target.url &&
          _directRetriedEpisode != index) {
        _directRetriedEpisode = index;
        AppLog.w(
          'player',
          '初始化超时，改用直连上游地址重试 index=$index url=${redactUrl(target.url)}',
        );
        setState(() {
          _resolving = true;
          _buffering = true;
          _error = '';
        });
        _toast('线路加载超时，正在尝试直连播放');
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 500), () {
            if (mounted) {
              _openEpisode(
                index: index,
                play: target,
                startMs: startMs,
                bypassRelay: true,
              );
            }
          }),
        );
        return false;
      }
      if (!autoAttempt && localSpiderUrl && _mediaRetriedEpisode != index) {
        _mediaRetriedEpisode = index;
        AppLog.w('player', '本机取流地址打不开，自动重新取链一次 index=$index');
        setState(() {
          _resolving = true;
          _error = '';
        });
        _toast('取流进程未就绪，正在重新取链');
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 800), () {
            if (mounted) _openEpisode(index: index, startMs: startMs);
          }),
        );
        return false;
      }
      // 远程直链被防盗链拒绝（403 / 过期签名）时，fvp 同样只报
      // `invalid or unsupported media`。历史续播复用的是上一次解析出的地址，
      // 旧记录没存请求头、新记录的头也可能过期 —— 重新取一次链即可恢复。
      final mediaOpenFailed =
          e is PlatformException && '$e'.contains('invalid or unsupported media');
      final canResolveAgain =
          index >= 0 &&
          index < _episodes.length &&
          _episodes[index].url.trim().isNotEmpty &&
          _episodes[index].url != target.url &&
          !_looksLikeDashUrl(target.url);
      if (!autoAttempt &&
          mediaOpenFailed &&
          canResolveAgain &&
          _mediaRetriedEpisode != index) {
        _mediaRetriedEpisode = index;
        AppLog.w(
          'player',
          '播放地址打不开，自动重新取链一次 index=$index url=${redactUrl(target.url)}',
        );
        setState(() {
          _resolving = true;
          _buffering = true;
          _error = '';
        });
        _toast('播放地址可能已过期，正在重新获取');
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 500), () {
            if (mounted) _openEpisode(index: index, startMs: startMs);
          }),
        );
        return false;
      }
      _mediaRetriedEpisode = -1;
      // DASH(MPD) 线路：内置内核（libmdk + 随包 ffmpeg 只有 muxer、没有 dashdec）
      // 解不了这种清单，fvp 只会回 "invalid or unsupported media"。这不是
      // 网络或防盗链问题，换线路才有用 —— 给出可操作的说明，而不是英文原文。
      // 实测：wex 的 BiliGuard（高中课堂 / 少儿教育）只下发 dash+xml。
      final dashLine = _looksLikeDashUrl(target.url);
      final message = timedOut
          ? '播放器加载超时：该线路可能是 4K / HDR 或编码不受支持，请换线路或改用外部播放器'
          : dashLine
          ? '该线路是 DASH(MPD) 格式，内置播放内核不支持；请切换到其它线路'
          : '播放器打开失败：$e';
      setState(() {
        _resolving = false;
        _buffering = false;
        _error = message;
      });
      _afterFailure(message, autoAttempt: autoAttempt, startMs: startMs);
      return false;
    }
  }

  Future<PlayResult?> _resolve(int index) async {
    if (index < 0 || index >= _episodes.length) return null;
    final app = _app;
    HymsNative.captchaHandler = (url) {
      if (!mounted) return Future.value(null);
      return showHymsCaptchaDialog(context, url);
    };
    try {
      final play = await app.sourceService.resolvePlay(
        site: _site,
        config: app.config ?? const SiteConfig(),
        flag: _flag,
        rawUrl: _episodes[index].url,
        jarReady: app.jarReady,
      );
      // 云播线路给的是 HTML 播放页（/play/<id>、/share/<hash>），先解出直链。
      return await app.unwrapPlayPage(play);
    } finally {
      HymsNative.captchaHandler = null;
    }
  }

  /// 一次播放失败后的收尾：手动播放才触发自动换线，自动尝试由外层继续。
  void _afterFailure(
    String reason, {
    required bool autoAttempt,
    int startMs = 0,
  }) {
    if (autoAttempt) return;
    if (!_app.playerSettings.autoSwitchLine) return;
    if (_ephemeral) return;
    // startMs 是这一次打开想要的起播位置；不能拿全局 _position 代替，
    // 否则「上一集播到 30 分钟、这一集取链失败」会把这一集也跳到 30 分钟。
    unawaited(_scheduleAutoSwitch(reason, startMs: startMs));
  }

  /// 当前源线路全部失败后，换到其他源的同名资源继续尝试。
  Future<void> _scheduleAutoSwitch(String reason, {int startMs = 0}) async {
    if (_autoSwitching || !mounted) return;
    if (!_app.playerSettings.autoSwitchLine || _ephemeral) return;
    _autoSwitching = true;
    final run = ++_autoRunSeq;
    final manual = _manualSeq;
    try {
      // 旧 controller 必须在下一只初始化前彻底释放；否则 fvp/libmdk 的
      // 销毁与初始化并发会把播放内核拖崩。失败时旧画面也可能还在放。
      await _disposeControllerForSwitch();
      if (!mounted || manual != _manualSeq) return;
      // 当前这条线路已经失败，先记入已尝试集合，避免下一步又切回来。
      _autoTriedAttempts.add(
        _attemptKey(_site.key, _detail.id, _flag, _episodeName),
      );
      for (final flag in nextLineCandidates(_detail.flags, _flag)) {
        if (!mounted || manual != _manualSeq) return;
        final episodes = _detail.episodeList(flag);
        final index = matchEpisodeIndex(episodes, _episodeName, _index);
        if (index < 0) continue;
        final key = _attemptKey(
          _site.key,
          _detail.id,
          flag,
          episodes[index].name,
        );
        if (!_autoTriedAttempts.add(key)) continue;
        final oldFlag = _flag;
        AppLog.i('player', '自动换线路 $oldFlag → $flag index=$index');
        _applyAutoAttempt(_site, _detail, flag, episodes, index);
        _toast('线路「$oldFlag」播放失败，正在自动切换…');
        final ok = await _openEpisode(
          index: index,
          startMs: startMs,
          allowLogin: false,
          autoAttempt: true,
        );
        if (ok) return;
      }
      await _tryOtherSources(reason: reason, startMs: startMs, manual: manual);
    } finally {
      if (run == _autoRunSeq) _autoSwitching = false;
    }
  }

  /// 当前源没有可用线路时，搜索其他源里同名（优先同年）的资源。
  Future<void> _tryOtherSources({
    required String reason,
    required int startMs,
    required int manual,
  }) async {
    if (!mounted || manual != _manualSeq) return;
    setState(() {
      _resolving = true;
      _buffering = true;
      _error = '';
    });
    _toast('本源线路不可用，正在搜索其他源的《${_detail.name}》…');
    // 资源名常带「《…》动漫高清完整版在线观看」这类后缀，直接拿去搜索
    // 和比对会找不到同名资源；先归一成剧名再搜索。
    final searchTitle = ArtworkService.dramaTitle(_detail.name).trim();
    final keyword = searchTitle.isEmpty ? _detail.name : searchTitle;
    AppLog.i('player', '自动换源搜索 $keyword（资源名 ${_detail.name}）');
    final app = _app;
    final filter = app.contentFilter;
    final sites = filter.active
        ? app.usableSites.where((s) => !filter.blocksSource(s)).toList()
        : app.usableSites;
    final stream = app.searchService.search(keyword, sites);
    final fetched = <String, List<VodItem>>{};
    final done = _autoSearchDone = Completer<void>();
    final sub = _autoSearchSub = stream.listen(
      (progress) {
        fetched.clear();
        fetched.addAll(progress.sourceItems);
        if (progress.finished && !done.isCompleted) done.complete();
      },
      onError: (_) {
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    _autoSearchTimer = Timer(const Duration(seconds: 60), () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    _autoSearchTimer?.cancel();
    _autoSearchTimer = null;
    try {
      await sub.cancel();
    } catch (_) {}
    if (identical(_autoSearchSub, sub)) _autoSearchSub = null;
    if (identical(_autoSearchDone, done)) _autoSearchDone = null;
    if (!mounted || manual != _manualSeq) return;

    final targetTitle = titleSignature(ArtworkService.dramaTitle(_detail.name));
    final targetYear = _detail.year.trim();
    final candidates = <({SourceBean site, VodItem item})>[];
    final seen = <String>{};
    for (final entry in fetched.entries) {
      if (entry.key == _site.key || _autoTriedSources.contains(entry.key)) {
        continue;
      }
      final site = _siteByKey(entry.key);
      if (site == null || !app.isSiteUsable(site)) continue;
      for (final item in entry.value) {
        if (titleSignature(ArtworkService.dramaTitle(item.name)) !=
            targetTitle) {
          continue;
        }
        if (item.id.trim().isEmpty) continue;
        if (!seen.add('${site.key}|${item.id}')) continue;
        candidates.add((site: site, item: item));
      }
    }
    candidates.sort((a, b) {
      final ay = targetYear.isNotEmpty && a.item.year.trim() == targetYear
          ? 0
          : 1;
      final by = targetYear.isNotEmpty && b.item.year.trim() == targetYear
          ? 0
          : 1;
      if (ay != by) return ay - by;
      final an = a.item.name == _detail.name ? 0 : 1;
      final bn = b.item.name == _detail.name ? 0 : 1;
      return an - bn;
    });
    if (candidates.isEmpty) {
      _autoFail('没有找到其他源的相同片名：$reason');
      return;
    }

    final episodeName = _episodeName;
    final fallbackIndex = _index;
    for (final candidate in candidates) {
      if (!mounted || manual != _manualSeq) return;
      _autoTriedSources.add(candidate.site.key);
      VodDetail? detail;
      try {
        detail = await app.sourceService.detail(
          candidate.site,
          candidate.item.id,
          name: candidate.item.name,
        );
      } catch (e) {
        AppLog.w('player', '自动换源详情失败 ${candidate.site.key} $e');
      }
      if (!mounted || manual != _manualSeq) return;
      if (detail == null || detail.episodes.isEmpty) continue;
      if (titleSignature(ArtworkService.dramaTitle(detail.name)) !=
          targetTitle) {
        continue;
      }
      // 同名但类型不同（单集电影 ↔ 多集剧集）：不要拿电影去配剧集第 1 集。
      if (_episodes.length == 1 &&
          detail.episodes.values.any((list) => list.length > 1)) {
        continue;
      }
      final detailFlags = detail.flags.isEmpty ? const [''] : detail.flags;
      for (final flag in detailFlags) {
        if (!mounted || manual != _manualSeq) return;
        final episodes = detail.episodeList(flag);
        final index = matchEpisodeIndex(episodes, episodeName, fallbackIndex);
        if (index < 0) continue;
        final key = _attemptKey(
          candidate.site.key,
          detail.id,
          flag,
          episodes[index].name,
        );
        if (!_autoTriedAttempts.add(key)) continue;
        AppLog.i('player', '自动换源 ${candidate.site.key} · $flag index=$index');
        _applyAutoAttempt(candidate.site, detail, flag, episodes, index);
        _toast('已切换到其他源「${candidate.site.displayName}」·「$flag」');
        final ok = await _openEpisode(
          index: index,
          startMs: startMs,
          allowLogin: false,
          autoAttempt: true,
        );
        if (ok) return;
      }
    }
    _autoFail(_error.isNotEmpty ? '所有线路和其他源都失败：$_error' : '所有线路和其他源都失败');
  }

  Future<void> _disposeControllerForSwitch() async {
    final old = _controller;
    _controller = null;
    old?.removeListener(_onPlayerValue);
    final future = old?.dispose();
    if (future == null) return;
    _controllerDisposePending = future;
    try {
      await future;
    } catch (_) {
      // 释放失败不影响下一只初始化
    } finally {
      if (identical(_controllerDisposePending, future)) {
        _controllerDisposePending = null;
      }
    }
  }

  void _applyAutoAttempt(
    SourceBean site,
    VodDetail detail,
    String flag,
    List<Episode> episodes,
    int index,
  ) {
    if (!mounted) return;
    setState(() {
      _site = site;
      _detail = detail;
      _flag = flag;
      _episodes = episodes;
      _index = index;
      _resolving = true;
      _buffering = true;
      _playing = false;
      _error = '';
      _autoErrorHandled = false;
      _position = Duration.zero;
      _duration = Duration.zero;
      _subtitleStatus = '';
      _danmaku = const [];
      _allDanmaku = const [];
      _danmakuSeq++;
      _audioOptions = const [];
      _activeAudio = null;
      _errorLogged = false;
      _mediaStats = null;
      _netSmoother.reset();
      _live = false;
    });
  }

  void _autoFail(String message) {
    if (!mounted) return;
    setState(() {
      _resolving = false;
      _buffering = false;
      _error = message;
    });
    _toast(message);
  }

  String _attemptKey(
    String siteKey,
    String detailId,
    String flag,
    String episodeName,
  ) => '$siteKey|$detailId|$flag|${episodeSignature(episodeName)}';

  SourceBean? _siteByKey(String key) {
    for (final site in _app.config?.sites ?? const <SourceBean>[]) {
      if (site.key == key) return site;
    }
    return null;
  }

  /// 打开睡眠定时器弹层并应用选择。
  Future<void> _openSleepTimer() async {
    final choice = await showSleepTimerSheet(
      context: context,
      current: _sleepTimer.state,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (choice == null || !mounted) return;
    if (choice.cancel) {
      _sleepTimer.cancel();
      _toast('已关闭睡眠定时');
      return;
    }
    if (choice.atEndOfVideo) {
      _sleepTimer.startAtEndOfVideo();
      _toast('这一集播完后暂停，不会自动连播');
      return;
    }
    final duration = choice.duration;
    if (duration != null) {
      _sleepTimer.startForDuration(duration);
      _toast('${SleepTimer.formatDuration(duration.inMilliseconds)} 后自动暂停');
    }
  }

  void _onCompleted() {
    if (_live) return;
    // 睡眠定时器优先于自动连播：「播完当前视频后暂停」就是让这一集播完后停下，
    // 不能被下面的自动连播逻辑抢先切到下一集。
    if (_sleepTimer.handleVideoEnded()) {
      _controller?.pause();
      _toast('已播完，睡眠定时器已暂停播放');
      return;
    }
    if (_outroFired) return; // 片尾跳过已经接管了切集
    final app = _app;
    if (!app.playerSettings.autoPlayNext) return;
    if (_index + 1 < _episodes.length) {
      Future<void>.delayed(const Duration(milliseconds: 700), () {
        if (mounted) _switchTo(_index + 1);
      });
    }
  }

  Future<void> _switchTo(int index, {bool allowLogin = true}) {
    // 取链 / 打开过程中忽略换集点击，避免并发打开多份。
    if (_resolving) return Future<void>.value();
    if (index != _index) {
      // 新的一集重新开始自动换线记录，避免上一集的失败源被误跳过。
      _autoTriedAttempts.clear();
      _autoTriedSources.clear();
    }
    return _openEpisode(index: index, allowLogin: allowLogin);
  }

  /// 选集面板里手动换线路：线路和选集一起切换，再打开对应线路的这一集。
  Future<void> _switchLine(String flag, int index) async {
    if (_resolving) return;
    if (flag == _flag) {
      if (index != _index) await _switchTo(index);
      return;
    }
    final episodes = _detail.episodeList(flag);
    if (index < 0 || index >= episodes.length) return;
    setState(() {
      _flag = flag;
      _episodes = episodes;
      _index = index;
      _error = '';
      _directRetriedEpisode = -1;
      _mediaRetriedEpisode = -1;
    });
    _toast('已切换到线路「${flag.isEmpty ? '默认线路' : flag}」');
    await _openEpisode(index: index);
  }

  void _startSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
  }

  Future<void> _saveProgress() async {
    if (_live) return;
    final app = _app;
    if (_ephemeral) return;
    if (!app.playerSettings.rememberProgress) return;
    if (_duration.inMilliseconds <= 0) return;
    final key = '${_detail.sourceKey}|${_detail.id}';
    await app.updateHistoryProgress(
      key,
      _position.inMilliseconds,
      _duration.inMilliseconds,
    );
  }

  void _showControls() {
    if (!mounted) return;
    setState(() {
      _controls = true;
      _cursorVisible = true;
    });
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) {
        setState(() {
          _controls = false;
          _cursorVisible = false;
        });
      }
    });
  }

  /// 鼠标移动**不再**唤出控制栏（控制栏改为单击唤出）。
  ///
  /// 只负责光标：控制栏收起时光标也跟着隐藏，此时移动鼠标必须能看见指针，
  /// 否则用户既看不到控制栏、也看不到自己在点哪里。静止 3 秒后再收起。
  void _onPointerMove() {
    if (!mounted || _controls) return;
    if (!_cursorVisible) setState(() => _cursorVisible = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_controls) setState(() => _cursorVisible = false);
    });
  }

  /// 缓冲提示：短暂缓冲（不到 350ms）不亮转圈。
  ///
  /// 最大缓冲偏小时，每个分片交界处都可能出现一次很短的 buffering；
  /// 立刻盖一层转圈会让本来只是轻微补帧的播放看起来「一卡一卡」。
  void _syncBufferingHint(bool buffering) {
    if (buffering) {
      if (_bufferingHint || _bufferingHintTimer != null) return;
      _bufferingHintTimer = Timer(const Duration(milliseconds: 350), () {
        _bufferingHintTimer = null;
        if (!mounted || !_buffering) return;
        setState(() => _bufferingHint = true);
      });
    } else {
      _bufferingHintTimer?.cancel();
      _bufferingHintTimer = null;
      if (_bufferingHint) setState(() => _bufferingHint = false);
    }
  }

  /// 播放中阻止系统自动休眠 / 关屏；暂停、出错时立即恢复系统策略。
  void _syncSleepInhibitor() {
    final active = _error.isEmpty && (_playing || _buffering);
    if (active && !_sleepHeld) {
      _sleepHeld = true;
      SleepInhibitor.acquire();
    } else if (!active && _sleepHeld) {
      _sleepHeld = false;
      SleepInhibitor.release();
    }
  }

  /// 单击画面：控制栏在「显示」与「收缩」之间切换。
  ///
  /// 与双击全屏不冲突：两者挂在同一个 GestureDetector 上，Flutter 的手势
  /// 仲裁会等双击判定窗口过去再决定是否派发 onTap —— 快速双击只会进入全屏，
  /// 不会顺带把控制栏切一下。
  void _toggleControls() {
    if (!mounted) return;
    if (_controls) {
      // 收缩：光标一起收，并取消待执行的自动收设计时器，
      // 否则下次唤出后旧的计时器可能立刻把控制栏又收掉。
      _hideTimer?.cancel();
      setState(() {
        _controls = false;
        _cursorVisible = false;
      });
    } else {
      _showControls();
    }
  }

  /// 长按画面：临时 1.5x（松开恢复原倍速）。
  Future<void> _startHoldRate() async {
    if (_holdingRate || _controller == null) return;
    _holdingRate = true;
    _rateBeforeHold = _rate;
    final boost = _rate < 1.5 ? 1.5 : _rate;
    setState(() => _rate = boost);
    await _controller?.setPlaybackSpeed(boost);
    if (boost != _rateBeforeHold) _toast('长按 1.5x 快进中');
  }

  Future<void> _endHoldRate() async {
    if (!_holdingRate) return;
    _holdingRate = false;
    final back = _rateBeforeHold ?? _app.playerSettings.speed;
    _rateBeforeHold = null;
    if (mounted) setState(() => _rate = back);
    await _controller?.setPlaybackSpeed(back);
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
    _showControls();
  }

  /// 老板键：暂停当前视频；返回是否真的从播放中暂停（原本暂停就不恢复）。
  bool _pauseForBossKey() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return false;
    if (!controller.value.isPlaying) return false;
    controller.pause();
    return true;
  }

  /// 老板键恢复：只有按下前正在播放时才继续播放。
  void _resumeFromBossKey() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (!controller.value.isPlaying) controller.play();
  }

  void _seekBy(Duration delta) {
    if (_live) return;
    final controller = _controller;
    if (controller == null) return;
    final total = controller.value.duration;
    var target = controller.value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    controller.seekTo(target);
  }

  void _seekTo(Duration target) {
    if (_live) return;
    final controller = _controller;
    if (controller == null) return;
    final total = controller.value.duration;
    var safe = target;
    if (safe < Duration.zero) safe = Duration.zero;
    if (total > Duration.zero && safe > total) safe = total;
    controller.seekTo(safe);
  }

  IconData get _volumeIcon {
    if (_volume <= 0.001) return Icons.volume_off_rounded;
    if (_volume < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  /// 调播放器自己的音量（0–1），`persist` 为 true 时写入播放设置。
  Future<void> _setVolume(double value, {bool persist = false}) async {
    final volume = value.clamp(0.0, 1.0).toDouble();
    if (_volume > 0.001) _lastVolume = _volume;
    if (mounted) setState(() => _volume = volume);
    await _controller?.setVolume(volume);
    if (!persist) return;
    final app = _app;
    await app.setPlayerSettings(app.playerSettings.copyWith(volume: volume));
  }

  /// 鼠标滚轮：向上加音量，向下减音量（每次一格 5%，与 ↑/↓ 一致）。
  void _onWheelVolume(double dy) {
    if (dy == 0) return;
    unawaited(_setVolume(_volume + (dy < 0 ? 0.05 : -0.05)));
    _flashVolumeHud();
    _showControls();
    _volumeWheelTimer?.cancel();
    _volumeWheelTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      unawaited(_setVolume(_volume, persist: true));
    });
  }

  /// 音量提示：每次调整重置计时，停手 1.2 秒后自动收起。
  void _flashVolumeHud() {
    if (!mounted) return;
    setState(() => _volumeHudVisible = true);
    _volumeHudTimer?.cancel();
    _volumeHudTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _volumeHudVisible = false);
    });
  }

  void _toggleMute() {
    if (_volume > 0.001) {
      unawaited(_setVolume(0, persist: true));
    } else {
      unawaited(
        _setVolume(_lastVolume <= 0.001 ? 1 : _lastVolume, persist: true),
      );
    }
  }

  Future<void> _showVolume() => showVolumeSheet(
    context: context,
    volume: _volume,
    onChanged: (v) => _setVolume(v),
    onCommit: (v) => _setVolume(v, persist: true),
    onToggleMute: _toggleMute,
    hint: '↑ / ↓ 以 5% 步进调节，M 静音；播放器音量与 Windows 系统音量互不影响。',
  );

  Future<void> _toggleFullscreen() async {
    // 小窗也允许全屏：进入全屏后临时铺满屏幕，退出全屏时窗口恢复成原来的
    // 小窗尺寸，`_mini` 状态保持不变。
    if (_fsToggling) return;
    _fsToggling = true;
    final next = !_fullscreen;
    try {
      // 先把过渡动画归零，窗口切换后的第一帧就从缩放/半透明状态开始，
      // 不再出现「先满帧闪一下、再开始动画」的突兀感。
      setState(() {
        _fullscreen = next;
        _fsAnim.value = 0;
      });
      if (_isMobile) {
        await SystemChrome.setEnabledSystemUIMode(
          next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
      } else {
        await setWindowFullscreen(next);
      }
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      // 纯 Flutter 合成层动画：不触发逐帧窗口 resize，不会卡顿。
      _fsAnim.forward();
    } finally {
      _fsToggling = false;
    }
  }

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool get _isDesktop => !kIsWeb && !_isMobile;

  Future<void> _toggleAlwaysOnTop() async {
    if (!_isDesktop) return;
    final next = !_alwaysOnTop;
    setState(() => _alwaysOnTop = next);
    await setAppWindowAlwaysOnTop(next);
    if (mounted) _toast(next ? '窗口已置顶（仅本次播放生效）' : '已取消窗口置顶');
  }

  Future<void> _toggleMini() => _setMini(!_mini);

  /// 展开 / 收起小窗；[announce] 只在用户手动切换时提示。
  Future<void> _setMini(bool next, {bool announce = true}) async {
    if (!_isDesktop || next == _mini) return;
    if (next && _fullscreen) await _toggleFullscreen();
    if (next) {
      _pinnedBeforeMini = _alwaysOnTop;
      await enterMiniPlayerWindow();
    } else {
      await exitMiniPlayerWindow();
    }
    if (!mounted) return;
    setState(() {
      _mini = next;
      if (next) {
        // 小窗本身始终置顶；顶栏图钉同步为「已置顶」，可在小窗里手动取消。
        _alwaysOnTop = true;
        _controls = false;
      } else {
        _alwaysOnTop = _pinnedBeforeMini;
      }
    });
    // exitMiniPlayerWindow 会把置顶关掉，这里恢复退出小窗后的选择。
    if (!next) await setAppWindowAlwaysOnTop(_alwaysOnTop);
    if (next && announce) _toast('小窗模式：窗口已置顶，点画面显示控制');
  }

  Future<void> _exitPage() async {
    // 独立窗口关闭后主窗口会重新读盘，先把最后进度落下来。
    try {
      await _saveProgress();
    } catch (_) {}
    final exit = widget.onExit;
    if (exit != null) {
      await exit();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _requestExit() => unawaited(_exitPage());

  @override
  void dispose() {
    // 离开播放器即作废睡眠定时器：它的作用域就是这一集，不该在后台继续倒计时。
    _sleepTimer.dispose();
    _bufferingHintTimer?.cancel();
    BossKeyService.instance.unbindPlayer(this);
    // 一起看：房主关掉播放器就散场；观众停止轮询。
    if (_partyBound) {
      _app.watchParty.removeListener(_onPartyUpdate);
      if (_app.watchParty.active) _app.watchParty.leave();
      _partyBound = false;
    }
    if (_opened) _saveProgress();
    // 网盘取流地址指向常驻 JVM 自己的内存服务，离开播放器就回收该进程。
    // 但地址已交给外部播放器时不能回收：Yaozhi MPV / PotPlayer 还在读 /chunk。
    if (_opened && !_handedToExternalPlayer) {
      unawaited(_app.sourceService.jar.stopPlayback());
    }
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _detailsTimer?.cancel();
    _cancelPendingSkipPick();
    final autoSearchDone = _autoSearchDone;
    if (autoSearchDone != null && !autoSearchDone.isCompleted) {
      autoSearchDone.complete();
    }
    final autoSearchSub = _autoSearchSub;
    if (autoSearchSub != null) unawaited(autoSearchSub.cancel());
    _autoSearchSub = null;
    _autoSearchTimer?.cancel();
    _autoSearchTimer = null;
    if (_sleepHeld) {
      _sleepHeld = false;
      SleepInhibitor.releaseAll();
    }
    if (_mini) unawaited(exitMiniPlayerWindow());
    // 置顶只在本次播放会话内有效：离开播放器时无论如何都复位。
    unawaited(setAppWindowAlwaysOnTop(false));
    _volumeWheelTimer?.cancel();
    _volumeHudTimer?.cancel();
    _fsAnim.dispose();
    _controller?.removeListener(_onPlayerValue);
    _controller?.dispose();
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if (_fullscreen && isDesktop && !_immersiveMode) {
      setWindowFullscreen(false);
    } else if (_fullscreen && !isDesktop) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(const Duration(seconds: -10));
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(const Duration(seconds: 10));
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      unawaited(_setVolume(_volume + 0.05, persist: true));
      _flashVolumeHud();
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      unawaited(_setVolume(_volume - 0.05, persist: true));
      _flashVolumeHud();
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
      _flashVolumeHud();
      _showControls();
      return KeyEventResult.handled;
    }
    // F / Enter 都切换全屏：Enter 是遥控器与客厅键盘上最顺手的那个键。
    if (key == LogicalKeyboardKey.keyF ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_fullscreen) {
        _toggleFullscreen();
      } else {
        _requestExit();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 播放失败时按片名回主界面做一次全源搜索，方便直接换到其他源。
  void _switchSource() {
    final name = _detail.name.trim();
    if (name.isEmpty) {
      _toast('没有可搜索的片名');
      return;
    }
    final remote = widget.onSwitchSource;
    if (remote != null) {
      unawaited(remote(name));
      return;
    }
    AppScope.of(context).requestSearch(name);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// part 里的 extension 不能直接调用 @protected 的 setState，统一走这里。
  void _setState(VoidCallback fn) => setState(fn);

  void _toast(String message) {
    if (!mounted) return;
    // 播放器底栏是自绘的：默认 fixed SnackBar 会压在进度条和播放键上。
    // 改成悬浮提示，并抬高到底栏上方，效果接近 Android Toast。
    const bottomGap = 150.0;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final gap = (bottomGap + MediaQuery.paddingOf(context).bottom)
        .clamp(24.0, screenHeight * 0.5)
        .toDouble();
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.black.withValues(alpha: 0.86),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: EdgeInsets.fromLTRB(24, 0, 24, gap),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// 悬浮层的进度格式：`1:08` / `30:00` / `1:02:00`（分钟不补零）。
  String _fmtOverlay(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  void _toggleDetails() {
    setState(() => _detailsVisible = !_detailsVisible);
    _startDetailsTimer();
    if (_detailsVisible) _showControls();
    // 记忆开关状态：下次打开播放器沿用这次的选择。
    unawaited(
      _app.setPlayerSettings(
        _app.playerSettings.copyWith(overlayVisible: _detailsVisible),
      ),
    );
  }

  /// 时钟、码率、缓冲这些不是播放器回调驱动，靠每秒重绘。
  void _startDetailsTimer() {
    _detailsTimer?.cancel();
    _detailsTimer = null;
    if (!_detailsVisible) {
      _mediaStats = null;
      _netSmoother.reset();
      _live = false;
      return;
    }
    _updateDetailsStats();
    _detailsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateDetailsStats();
      if (mounted) setState(() {});
    });
  }

  /// 每秒采样一次 fvp MediaInfo，并更新平滑后的网速展示值。
  void _updateDetailsStats() {
    final stats = _readMediaStats();
    _mediaStats = stats;
    _netSmoother.add(stats?.bitRate ?? 0);
  }

  /// 刷新播放（主流播放器行为）：按当前进度重新取链、重建播放器。
  Future<void> _refreshPlayback() async {
    if (_refreshing || _resolving) return;
    final posMs = _position.inMilliseconds;
    _refreshing = true;
    if (mounted) setState(() {});
    _toast('正在刷新播放地址…');
    try {
      await _openEpisode(index: _index, startMs: posMs > 2000 ? posMs : 0);
    } finally {
      _refreshing = false;
      if (mounted) setState(() {});
    }
  }

  /// 长按「详情」：勾选要显示的指标、调整字号，保存到播放设置。
  Future<void> _showDetailsSettings() async {
    final app = _app;
    final result = await showPlayerOverlaySettings(
      context: context,
      title: '播放详情显示',
      metrics: kPlayerOverlayMetrics,
      defaultMetrics: kDefaultPlayerOverlayMetrics,
      selectedMetrics: app.playerSettings.overlayMetrics,
      fontSize: app.playerSettings.overlayFontSize,
    );
    if (result == null) return;
    await app.setPlayerSettings(
      app.playerSettings.copyWith(
        overlayMetrics: result.metrics,
        overlayFontSize: result.fontSize,
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _detailsOverlay(BuildContext context) {
    final settings = _app.playerSettings;
    final fontSize = settings.overlayFontSize.clamp(10.0, 28.0).toDouble();
    final enabled = settings.overlayMetrics.toSet();
    final media = _mediaStats;
    final topLeft = _cornerLines('tl', enabled, fontSize, media);
    final topRight = _cornerLines('tr', enabled, fontSize, media);
    final bottomLeft = _cornerLines('bl', enabled, fontSize, media);
    final bottomRight = _cornerLines('br', enabled, fontSize, media);
    if (topLeft.isEmpty &&
        topRight.isEmpty &&
        bottomLeft.isEmpty &&
        bottomRight.isEmpty) {
      return const SizedBox.shrink();
    }
    final padding = EdgeInsets.fromLTRB(
      18,
      MediaQuery.paddingOf(context).top + (_controls ? 62 : 16),
      18,
      MediaQuery.paddingOf(context).bottom + (_controls ? 108 : 16),
    );
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 220),
          padding: padding,
          child: Stack(
            children: [
              if (topLeft.isNotEmpty)
                Align(
                  alignment: Alignment.topLeft,
                  child: _overlayColumn(topLeft),
                ),
              if (topRight.isNotEmpty)
                Align(
                  alignment: Alignment.topRight,
                  child: _overlayColumn(topRight, end: true),
                ),
              if (bottomLeft.isNotEmpty)
                Align(
                  alignment: Alignment.bottomLeft,
                  child: _overlayColumn(bottomLeft),
                ),
              if (bottomRight.isNotEmpty)
                Align(
                  alignment: Alignment.bottomRight,
                  child: _overlayColumn(bottomRight, end: true),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _overlayColumn(List<Widget> lines, {bool end = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: end
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: lines,
    );
  }

  List<Widget> _cornerLines(
    String corner,
    Set<String> enabled,
    double fontSize,
    _MediaStats? media,
  ) {
    final lines = <Widget>[];
    for (final metric in kPlayerOverlayMetrics) {
      if (metric.corner != corner || !enabled.contains(metric.id)) continue;
      final text = _metricText(metric.id, media);
      if (text == null || text.isEmpty) continue;
      final title = metric.id == 'title';
      lines.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            text,
            style: TextStyle(
              color: Colors.white,
              fontSize: title ? fontSize + 4 : fontSize,
              fontWeight: title ? FontWeight.w700 : FontWeight.w500,
              height: 1.25,
              shadows: const [Shadow(color: Colors.black87, blurRadius: 4)],
            ),
          ),
        ),
      );
    }
    return lines;
  }

  String? _metricText(String id, _MediaStats? media) {
    final value = _controller?.value;
    switch (id) {
      case 'title':
        return _detail.name;
      case 'episode':
        if (_live) return '直播';
        return _episodeName.isEmpty ? '${_index + 1}集' : _episodeName;
      case 'resolution':
        final w = media?.width ?? value?.size.width.round() ?? 0;
        final h = media?.height ?? value?.size.height.round() ?? 0;
        return w > 0 && h > 0 ? '$w×$h' : null;
      case 'fps':
        final fps = media?.fps ?? 0;
        return fps > 0
            ? '${fps.toStringAsFixed(fps % 1 == 0 ? 0 : 2)} fps'
            : null;
      case 'codec':
        final codec = media?.videoCodec ?? '';
        return codec.isEmpty ? null : codec;
      case 'format':
        final format = media?.format ?? '';
        return format.isEmpty ? null : format;
      case 'source':
        return _site.displayName;
      case 'line':
        return _flag;
      case 'clock':
        final now = DateTime.now();
        final h = now.hour.toString().padLeft(2, '0');
        final m = now.minute.toString().padLeft(2, '0');
        final s = now.second.toString().padLeft(2, '0');
        return '$h:$m:$s';
      case 'progress':
        if (_live) return null;
        return _duration.inMilliseconds > 0
            ? '${_fmtOverlay(_position)}/${_fmtOverlay(_duration)}'
            : null;
      case 'remaining':
        if (_live || _duration.inMilliseconds <= 0) return null;
        final left = _duration - _position;
        return left.isNegative ? null : '-${_fmtOverlay(left)}';
      case 'net':
        final bits = _netSmoother.value;
        if (bits <= 0) return null;
        return bits >= 1000000
            ? '${(bits / 1000000).toStringAsFixed(1)} Mb/s'
            : '${(bits / 1000).round()} kb/s';
      case 'buffer':
        if (_live) return null;
        final ahead = _bufferedAhead(value);
        return ahead == null ? null : '缓冲 ${ahead.toStringAsFixed(1)}s';
      case 'audio':
        final codec = media?.audioCodec ?? '';
        if (codec.isEmpty) return null;
        final channels = media?.audioChannels ?? 0;
        return channels > 0 ? '$codec ${channels}ch' : codec;
      case 'volume':
        return value == null ? null : '音量 ${(value.volume * 100).round()}%';
      case 'rate':
        return '${_rate.toStringAsFixed(_rate % 1 == 0 ? 0 : 2)}x';
    }
    return null;
  }

  double? _bufferedAhead(VideoPlayerValue? value) {
    if (value == null || value.buffered.isEmpty) return null;
    var end = Duration.zero;
    for (final range in value.buffered) {
      if (range.end > end) end = range.end;
    }
    final ahead = end - value.position;
    return ahead.inMilliseconds <= 0 ? null : ahead.inMilliseconds / 1000;
  }

  /// 已缓冲到的位置（毫秒）：取所有 buffered range 里最靠后的 end。
  double _bufferedEndMs() {
    final value = _controller?.value;
    if (value == null || value.buffered.isEmpty) return 0;
    var end = Duration.zero;
    for (final range in value.buffered) {
      if (range.end > end) end = range.end;
    }
    return end.inMilliseconds.toDouble();
  }

  /// 把设置里的「起播预缓冲 / 最大缓冲」写进 fvp（libmdk）内核。
  ///
  /// video_player 没有等价参数，非 fvp 内核时直接跳过。换集时调用一次；
  /// 设置变更由 didChangeDependencies 触发重新下发，当前集立即生效。
  void _applyBufferRange(VideoPlayerController controller) {
    if (!_mdkEnabled) return;
    final settings = _app.playerSettings;
    final minMs = (settings.bufferMinSec * 1000)
        .round()
        .clamp(200, 30000)
        .toInt();
    final maxMs = (settings.bufferMaxSec * 1000)
        .round()
        .clamp(minMs + 500, 120000)
        .toInt();
    try {
      controller.setBufferRange(min: minMs, max: maxMs);
    } catch (_) {
      // 内核未接管时扩展会抛 StateError，退化为内核默认缓冲
    }
  }

  /// 读 fvp 的 MediaInfo：分辨率、帧率、编码、容器与实时码率（当作网速）。
  ///
  /// fvp 未接管时扩展会抛 StateError，读不到就退化为 VideoPlayerValue。
  _MediaStats? _readMediaStats() {
    if (!_mdkEnabled) return null;
    final controller = _controller;
    if (controller == null) return null;
    try {
      final info = controller.getMediaInfo();
      if (info == null) return null;
      final video = (info.video?.isNotEmpty ?? false)
          ? info.video!.first
          : null;
      final audio = (info.audio?.isNotEmpty ?? false)
          ? info.audio!.first
          : null;
      return _MediaStats(
        width: video?.codec.width ?? 0,
        height: video?.codec.height ?? 0,
        fps: video?.codec.frameRate ?? 0,
        bitRate: info.bitRate,
        videoCodec: video?.codec.codec ?? '',
        audioCodec: audio?.codec.codec ?? '',
        audioChannels: audio?.codec.channels ?? 0,
        format: info.format ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _openWithMpv() async {
    if (_openingMpv) return;
    _openingMpv = true;
    try {
      final cached = _currentPlay;
      final useCached =
          cached != null && _currentPlayIndex == _index && cached.playable;
      final play = useCached ? cached : await _resolve(_index);
      if (play == null || !play.playable) {
        _toast(
          play?.message.isNotEmpty == true ? play!.message : '当前地址无法交给 MPV 播放',
        );
        return;
      }
      if (!await _warmUpExternalPlay(play)) return;
      await _saveProgress();
      final source = _app.preparePlay(play, forceRelay: true);
      AppLog.i(
        'player',
        '交给 Yaozhi MPV 前${useCached ? '复用当前播放地址' : '重新取链'} '
            'index=$_index 原地址=${redactUrl(play.url)} '
            'MPV地址=${redactUrl(source.url)} len=${source.url.length}',
      );
      final playlist = await _externalPlaylistPath(currentUrl: source.url);
      await MpvExtension.instance.open(
        playlist ?? source.url,
        headers: playlist == null ? source.headers : const {},
        startSeconds: playlist == null ? _position.inSeconds : 0,
      );
      // MPV 已在读本机 /chunk：页面 dispose 时保留取流 JVM，否则外部播放器 404。
      _handedToExternalPlayer = true;
      _app.sourceService.jar.holdPlaybackForExternal();
      if (!mounted) return;
      _toast(
        playlist == null
            ? '已在 Yaozhi MPV 中打开'
            : '已在 Yaozhi MPV 中打开（共 ${_episodes.length} 集选集）',
      );
      // 已经交给外部播放器：退掉内置播放器页，控制器、置顶/小窗状态都随
      // dispose 释放；取流 JVM 由上面的 holdPlaybackForExternal 保活。
      unawaited(_exitPage());
    } catch (e, s) {
      AppLog.e('player', 'Yaozhi MPV 启动失败', e, s);
      _toast('$e');
    } finally {
      _openingMpv = false;
    }
  }

  /// 识别直播流：fvp 的 isLive() 优先；拿不到时用时长上限哨兵兜底。
  bool _detectLive(VideoPlayerController controller) {
    if (_mdkEnabled) {
      try {
        if (controller.isLive()) return true;
      } catch (_) {
        // 非 fvp 内核没有 isLive
      }
    }
    // libmdk 对未知时长的直播会返回接近 Duration 上限的时长。
    return controller.value.duration > const Duration(hours: 24);
  }

  Widget _videoView() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.expand();
    }
    final value = controller.value;
    final video = VideoPlayer(controller);
    final aspect = value.aspectRatio <= 0 ? 16 / 9 : value.aspectRatio;
    final width = value.size.width <= 0 ? 1280.0 : value.size.width;
    final height = value.size.height <= 0 ? 720.0 : value.size.height;
    return switch (_fit) {
      PlayerFit.contain => Center(
        child: AspectRatio(aspectRatio: aspect, child: video),
      ),
      PlayerFit.fill => SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.fill,
          child: SizedBox(width: width, height: height, child: video),
        ),
      ),
      PlayerFit.cover => ClipRect(
        child: SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(width: width, height: height, child: video),
          ),
        ),
      ),
      PlayerFit.ratio169 => Center(
        child: AspectRatio(aspectRatio: 16 / 9, child: video),
      ),
      PlayerFit.ratio43 => Center(
        child: AspectRatio(aspectRatio: 4 / 3, child: video),
      ),
      PlayerFit.original => ClipRect(
        child: Center(
          child: SizedBox(width: width, height: height, child: video),
        ),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: _fsAnim,
        builder: (context, child) {
          // 只做合成层的缩放 + 黑色压暗，不对整页做 Opacity/saveLayer，
          // 4K 视频全屏时也不会掉帧。
          final t = Curves.easeOutCubic.transform(_fsAnim.value);
          final scale = _fullscreen ? 1.045 - 0.045 * t : 0.955 + 0.045 * t;
          // 窗口切换瞬间整屏压黑，视觉上只剩「从黑场淡入并归位」，
          // 完全看不到系统窗口从小变大的硬跳。
          final dim = 1 - t;
          return Stack(
            fit: StackFit.expand,
            children: [
              Transform.scale(
                scale: scale,
                alignment: Alignment.center,
                child: child,
              ),
              if (dim > 0)
                IgnorePointer(
                  child: ColoredBox(color: Colors.black.withValues(alpha: dim)),
                ),
            ],
          );
        },
        child: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent) return;
              _onWheelVolume(event.scrollDelta.dy);
            },
            child: MouseRegion(
              cursor: _cursorVisible
                  ? MouseCursor.defer
                  : SystemMouseCursors.none,
              // 鼠标移动只维持光标可见，不唤出控制栏（单击才唤出）。
              onHover: (_) => _onPointerMove(),
              child: GestureDetector(
                // 单击切换控制栏；双击全屏。二者由 Flutter 手势仲裁区分：
                // 双击判定窗口内的第二次点击会取消 onTap，因此快速双击不会
                // 顺带把控制栏切一下。
                // opaque：加载中/无控制栏时子级（进度圈、弹幕层）不吸收点击，
                // 默认的 deferToChild 会导致单击落空、无法唤出控制栏返回。
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onDoubleTap: () => unawaited(_toggleFullscreen()),
                onLongPressStart: (_) => _startHoldRate(),
                onLongPressEnd: (_) => _endHoldRate(),
                onLongPressCancel: _endHoldRate,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _videoView(),
                    DanmakuOverlay(
                      items: _danmaku,
                      position:
                          _position +
                          Duration(
                            milliseconds: (_app.danmakuSettings.offset * 1000)
                                .round(),
                          ),
                      enabled: _danmakuEnabled && !_live && !_mini,
                      playing: _playing && !_buffering && !_resolving,
                      rate: _rate,
                      fontSize: _app.danmakuSettings.fontSize,
                      opacity: _app.danmakuSettings.opacity,
                      speed: _app.danmakuSettings.speed,
                      density: _app.danmakuSettings.density,
                      regionRatio: _app.danmakuSettings.regionRatio,
                    ),
                    if (_bufferingHint || _resolving)
                      const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    if (_error.isNotEmpty && !_buffering)
                      Center(
                        child: Container(
                          margin: const EdgeInsets.all(28),
                          padding: const EdgeInsets.all(22),
                          constraints: const BoxConstraints(maxWidth: 520),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.error_outline_rounded,
                                color: Colors.white70,
                                size: 36,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _error,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Wrap(
                                spacing: 10,
                                alignment: WrapAlignment.center,
                                children: [
                                  FilledButton.tonalIcon(
                                    onPressed: () => _openEpisode(
                                      index: _index,
                                      startMs: _position.inMilliseconds,
                                    ),
                                    icon: const Icon(Icons.refresh_rounded),
                                    label: const Text('重试'),
                                  ),
                                  if (!_ephemeral)
                                    FilledButton.tonalIcon(
                                      onPressed: _switchSource,
                                      icon: const Icon(
                                        Icons.swap_horiz_rounded,
                                      ),
                                      label: const Text('换源'),
                                    ),
                                  if (_mpvReady)
                                    FilledButton.tonalIcon(
                                      onPressed: _openWithMpv,
                                      icon: const Icon(
                                        Icons.open_in_new_rounded,
                                      ),
                                      label: const Text('用 MPV 播放'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    AnimatedOpacity(
                      opacity: _controls ? 1 : 0,
                      duration: const Duration(milliseconds: 220),
                      child: IgnorePointer(
                        ignoring: !_controls,
                        child: Stack(
                          children: [
                            _topBar(context),
                            if (!_mini)
                              Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!_live)
                                      _roundButton(
                                        icon: Icons.replay_10_rounded,
                                        onTap: () => _seekBy(
                                          const Duration(seconds: -10),
                                        ),
                                      ),
                                    if (!_live) const SizedBox(width: 22),
                                    _roundButton(
                                      icon: _playing
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      size: 64,
                                      onTap: _togglePlay,
                                    ),
                                    if (!_live) const SizedBox(width: 22),
                                    if (!_live)
                                      _roundButton(
                                        icon: Icons.forward_10_rounded,
                                        onTap: () => _seekBy(
                                          const Duration(seconds: 10),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            _bottomBar(context),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 110,
                      child: Center(
                        child: VolumeHud(
                          volume: _volume,
                          visible: _volumeHudVisible,
                        ),
                      ),
                    ),
                    if (_detailsVisible && !_mini) _detailsOverlay(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final mini = _mini;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          8,
          MediaQuery.paddingOf(context).top + 8,
          12,
          24,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xCC000000), Colors.transparent],
          ),
        ),
        // 播放器页没有自绘标题栏，顶栏这一行同时作为窗口拖拽区。
        child: windowDragArea(
          Row(
            children: [
              if (!mini)
                IconButton(
                  onPressed: _requestExit,
                  icon: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HoverMarqueeText(
                      _detail.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    HoverMarqueeText(
                      '${_live ? '直播' : (_episodeName.isEmpty ? '正片' : _episodeName)} · ${_site.displayName} · $_flag',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (_isDesktop)
                IconButton(
                  tooltip: _alwaysOnTop ? '取消窗口置顶' : '窗口置顶（仅本次播放）',
                  onPressed: _toggleAlwaysOnTop,
                  icon: _alwaysOnTop
                      ? const Icon(Icons.push_pin_rounded, color: Colors.white)
                      : const Icon(
                          Icons.push_pin_outlined,
                          color: Colors.white,
                        ),
                ),
              if (!mini && _isDesktop)
                IconButton(
                  tooltip: '投屏到电视（DLNA）',
                  onPressed: _castToDevice,
                  icon: const Icon(Icons.cast_rounded, color: Colors.white),
                ),
              if (!mini && _isDesktop)
                IconButton(
                  tooltip: _app.watchParty.active ? '一起看（进行中）' : '一起看（局域网同看）',
                  onPressed: _showWatchParty,
                  icon: Icon(
                    _app.watchParty.active
                        ? Icons.groups_rounded
                        : Icons.groups_outlined,
                    color: _app.watchParty.active
                        ? const Color(0xFF7DD3FC)
                        : Colors.white,
                  ),
                ),
              if (_isDesktop)
                IconButton(
                  tooltip: _mini ? '回归正常窗口' : '小窗播放（始终置顶）',
                  onPressed: _toggleMini,
                  icon: _mini
                      ? const Icon(
                          Icons.open_in_full_rounded,
                          color: Colors.white,
                        )
                      : const Icon(
                          Icons.picture_in_picture_alt_outlined,
                          color: Colors.white,
                        ),
                ),
              if (!mini)
                IconButton(
                  tooltip: _sleepTimer.active
                      ? '睡眠定时：${sleepTimerBadge(_sleepTimer.state, DateTime.now().millisecondsSinceEpoch)}'
                      : '睡眠定时',
                  onPressed: _openSleepTimer,
                  icon: Icon(
                    _sleepTimer.active
                        ? Icons.bedtime_rounded
                        : Icons.bedtime_outlined,
                    color: _sleepTimer.active
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white,
                  ),
                ),
              if (!mini)
                IconButton(
                  tooltip: '播放列表',
                  onPressed: _showEpisodes,
                  icon: const Icon(
                    Icons.format_list_bulleted_rounded,
                    color: Colors.white,
                  ),
                ),
              if (!mini && hasCustomWindowChrome)
                IconButton(
                  tooltip: '退出软件',
                  onPressed: closeAppWindow,
                  icon: const Icon(
                    Icons.power_settings_new_rounded,
                    color: Colors.white,
                  ),
                ),
            ],
          ),
          enabled: !_fullscreen,
        ),
      ),
    );
  }

  /// 直播时替代进度条的一行：红点 + 直播 + 实时。
  Widget _liveHeadline() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Colors.redAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            '直播',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            '实时',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.38),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  /// 小窗底栏只保留暂停和下一集，避免 480×292 里塞满按钮。
  Widget _miniBottomBar(BuildContext context) {
    final canNext = !_live && _index + 1 < _episodes.length;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          14,
          24,
          14,
          MediaQuery.paddingOf(context).bottom + 10,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xDD000000), Colors.transparent],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: _playing ? '暂停' : '播放',
              onPressed: _togglePlay,
              iconSize: 34,
              icon: Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 36),
            IconButton(
              tooltip: '下一集',
              onPressed: canNext ? () => _switchTo(_index + 1) : null,
              iconSize: 34,
              icon: Icon(
                Icons.skip_next_rounded,
                color: canNext ? Colors.white : Colors.white24,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    if (_mini) return _miniBottomBar(context);
    final total = _duration.inMilliseconds <= 0 ? 1 : _duration.inMilliseconds;
    final value = _position.inMilliseconds.clamp(0, total).toDouble();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          14,
          30,
          14,
          MediaQuery.paddingOf(context).bottom + 10,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xDD000000), Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_live)
              _liveHeadline()
            else
              Row(
                children: [
                  Text(
                    _fmt(_position),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Expanded(
                    // 进度条右键一次点选即生效：开头 5 分钟内取片头、结尾 5 分钟内取片尾；
                    // 右键双击则清除本资源的记录。
                    child: LayoutBuilder(
                      builder: (_, constraints) => Listener(
                        onPointerDown: (event) {
                          if (event.kind != PointerDeviceKind.mouse) return;
                          if ((event.buttons & kSecondaryMouseButton) != 0) {
                            _onProgressSecondaryDown(
                              width: constraints.maxWidth,
                              dx: event.localPosition.dx,
                            );
                            return;
                          }
                          // 左键按下（拖动 / 跳转）就放弃还没执行的右键取点。
                          _cancelPendingSkipPick();
                        },
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // 已缓冲区间：画在轨道下方，位置与 Slider 可见轨道对齐
                            // （两端各内缩 overlay 半径 12）。
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _BufferedBarPainter(
                                    played: total <= 0
                                        ? 0
                                        : (value / total).clamp(0.0, 1.0),
                                    buffered: total <= 0
                                        ? 0
                                        : (_bufferedEndMs() / total).clamp(
                                            0.0,
                                            1.0,
                                          ),
                                    inset: 12,
                                  ),
                                ),
                              ),
                            ),
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 12,
                                ),
                                activeTrackColor: Colors.white,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                              ),
                              child: Slider(
                                value: value,
                                max: total.toDouble(),
                                onChanged: (v) => setState(
                                  () => _position = Duration(
                                    milliseconds: v.round(),
                                  ),
                                ),
                                onChangeEnd: (v) =>
                                    _seekTo(Duration(milliseconds: v.round())),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Text(
                    _fmt(_duration),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            Row(
              children: [
                if (!_live)
                  IconButton(
                    tooltip: '上一集',
                    onPressed: _index > 0 ? () => _switchTo(_index - 1) : null,
                    icon: Icon(
                      Icons.skip_previous_rounded,
                      color: _index > 0 ? Colors.white : Colors.white24,
                    ),
                  ),
                IconButton(
                  tooltip: _playing ? '暂停' : '播放',
                  onPressed: _togglePlay,
                  icon: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                  ),
                ),
                if (!_live)
                  IconButton(
                    tooltip: '下一集',
                    onPressed: _index + 1 < _episodes.length
                        ? () => _switchTo(_index + 1)
                        : null,
                    icon: Icon(
                      Icons.skip_next_rounded,
                      color: _index + 1 < _episodes.length
                          ? Colors.white
                          : Colors.white24,
                    ),
                  ),
                IconButton(
                  tooltip: '刷新（重新取流）',
                  onPressed: (_refreshing || _resolving)
                      ? null
                      : _refreshPlayback,
                  icon: _refreshing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                        )
                      : Icon(
                          Icons.refresh_rounded,
                          color: (_resolving || _index < 0)
                              ? Colors.white24
                              : Colors.white,
                        ),
                ),
                IconButton(
                  tooltip: '音量 ${(_volume * 100).round()}%（↑/↓ 调节）',
                  onPressed: _showVolume,
                  icon: Icon(_volumeIcon, color: Colors.white),
                ),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 2,
                    children: [
                      if (!_live)
                        Tooltip(
                          message: '弹幕：点击开关，长按调节速度 / 屏占 / 屏蔽词',
                          child: _barAction(
                            icon: Icons.chat_bubble_outline_rounded,
                            label: '弹幕',
                            active: _danmakuEnabled,
                            onTap: _toggleDanmaku,
                            onLongPress: _showDanmakuPanel,
                          ),
                        ),
                      if (_mdkEnabled && !_live)
                        _barAction(
                          icon: Icons.subtitles_outlined,
                          label: '字幕',
                          active: _subtitleStatus.isNotEmpty,
                          onTap: _showSubtitlePanel,
                        ),
                      // 多音轨的视频直接给入口，不用再进「播放设置」里翻。
                      if (_mdkEnabled && !_live && _audioOptions.length > 1)
                        _barAction(
                          icon: Icons.graphic_eq_rounded,
                          label: '音轨',
                          onTap: _showAudioTracks,
                        ),
                      if (!_live)
                        Tooltip(
                          message: '跳过片头 / 片尾：${_skipSummary()}',
                          child: _barAction(
                            icon: Icons.content_cut_rounded,
                            label: '跳过',
                            active: _skipIntro > 0 || _skipOutro > 0,
                            onTap: _showSkipSettings,
                          ),
                        ),
                      _barAction(
                        icon: Icons.analytics_outlined,
                        label: '详情',
                        active: _detailsVisible,
                        onTap: _toggleDetails,
                        onLongPress: _showDetailsSettings,
                      ),
                      IconButton(
                        tooltip: '播放设置（画面比例 / 音轨 / 外部播放器）',
                        onPressed: _showPlaybackSettings,
                        icon: const Icon(
                          Icons.tune_rounded,
                          color: Colors.white,
                        ),
                      ),
                      if (_mpvReady)
                        TextButton.icon(
                          onPressed: _openWithMpv,
                          icon: const Icon(
                            Icons.open_in_new_rounded,
                            color: Colors.white70,
                            size: 18,
                          ),
                          label: const Text(
                            'MPV',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      TextButton.icon(
                        onPressed: _showSpeed,
                        icon: const Icon(
                          Icons.speed_rounded,
                          color: Colors.white70,
                          size: 18,
                        ),
                        label: Text(
                          '${_rate.toStringAsFixed(_rate % 1 == 0 ? 0 : 2)}x',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '全屏（F / Enter）',
                        onPressed: _toggleFullscreen,
                        icon: Icon(
                          _fullscreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required VoidCallback onTap,
    double size = 52,
  }) {
    return Material(
      color: Colors.black.withValues(alpha: 0.42),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: size * 0.5),
        ),
      ),
    );
  }

  /// 底栏的文字按钮（支持长按，「详情」靠长按打开自定义面板）。
  Widget _barAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    bool active = false,
  }) {
    final color = active ? Colors.white : Colors.white70;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: color, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Future<void> _showEpisodes() async {
    var sheetFlag = _flag;
    final lineScroll = ScrollController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final theme = Theme.of(ctx);
            final flags = <String>[..._detail.flags];
            if (flags.isEmpty) flags.add(_flag);
            if (flags.length == 1 && flags.first != sheetFlag) {
              flags.insert(0, sheetFlag);
            }
            final episodes = _detail.episodeList(sheetFlag);
            // 当前线路高亮正在播放的集；切到别的线路后按集名 / 集号找到同一集。
            final activeIndex = sheetFlag == _flag
                ? _index
                : matchEpisodeIndex(episodes, _episodeName, _index);
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('选集', style: theme.textTheme.titleLarge),
                    if (flags.length > 1) ...[
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text('线路', style: theme.textTheme.bodySmall),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ScrollConfiguration(
                              behavior: const MouseDragScrollBehavior(),
                              child: Scrollbar(
                                controller: lineScroll,
                                thumbVisibility: true,
                                interactive: true,
                                scrollbarOrientation:
                                    ScrollbarOrientation.bottom,
                                child: SingleChildScrollView(
                                  controller: lineScroll,
                                  scrollDirection: Axis.horizontal,
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      for (final flag in flags)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8,
                                          ),
                                          child: _lineChip(
                                            ctx,
                                            label: flag.isEmpty ? '默认线路' : flag,
                                            selected: flag == sheetFlag,
                                            onTap: () {
                                              if (flag == sheetFlag) return;
                                              setSheet(() => sheetFlag = flag);
                                            },
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      '${sheetFlag.isEmpty ? '默认线路' : sheetFlag} · '
                      '共 ${episodes.length} 集',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 14),
                    Flexible(
                      child: GridView.builder(
                        shrinkWrap: true,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 120,
                              mainAxisExtent: 44,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                        itemCount: episodes.length,
                        itemBuilder: (_, index) {
                          final active = index == activeIndex;
                          return InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              if (sheetFlag == _flag) {
                                if (index != _index) _switchTo(index);
                              } else {
                                _switchLine(sheetFlag, index);
                              }
                            },
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: active
                                    ? theme.colorScheme.primary.withValues(
                                        alpha: 0.2,
                                      )
                                    : theme.colorScheme.surfaceContainerHighest
                                          .withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: active
                                      ? theme.colorScheme.primary
                                      : Colors.transparent,
                                ),
                              ),
                              child: HoverMarqueeText(
                                episodes[index].name,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: active
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    lineScroll.dispose();
  }

  /// 选集面板上方的线路按钮。
  Widget _lineChip(
    BuildContext ctx, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(ctx);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.18)
              : theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.45,
                ),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? theme.colorScheme.primary : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

}

class _AudioOption {
  const _AudioOption({
    required this.index,
    required this.codec,
    required this.channels,
    required this.language,
    required this.title,
  });

  /// 封装内的流索引（传给 fvp `setAudioTracks`）。
  final int index;
  final String codec;
  final int channels;
  final String language;
  final String title;
}

/// 桌面端从 fvp（libmdk）读到的媒体信息，供「详情」悬浮层显示。
class _MediaStats {
  const _MediaStats({
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.bitRate = 0,
    this.videoCodec = '',
    this.audioCodec = '',
    this.audioChannels = 0,
    this.format = '',
  });

  final int width;
  final int height;
  final double fps;

  /// 实时码率（bit/s），播放中由 libmdk 更新，用作「实时网速」。
  final int bitRate;
  final String videoCodec;
  final String audioCodec;
  final int audioChannels;
  final String format;
}

/// 进度条上的「已缓冲」条：从播放位置画到缓冲区末尾。
///
/// 与 Slider 的可见轨道对齐：轨道两端各内缩 overlay 半径（这里 12），
/// 否则缓冲条会比轨道宽出一截，看起来像错位。
class _BufferedBarPainter extends CustomPainter {
  const _BufferedBarPainter({
    required this.played,
    required this.buffered,
    required this.inset,
  });

  /// 已播放比例（0–1）。
  final double played;

  /// 已缓冲比例（0–1）。
  final double buffered;

  /// 轨道两端的缩进（= SliderTheme.overlayShape 的半径）。
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final track = size.width - inset * 2;
    if (track <= 0 || buffered <= played) return;
    final left = inset + track * played;
    final right = inset + track * buffered;
    final centerY = size.height / 2;
    final rect = Rect.fromLTRB(left, centerY - 1.5, right, centerY + 1.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(2)),
      Paint()..color = Colors.white.withValues(alpha: 0.45),
    );
  }

  @override
  bool shouldRepaint(covariant _BufferedBarPainter oldDelegate) =>
      oldDelegate.played != played ||
      oldDelegate.buffered != buffered ||
      oldDelegate.inset != inset;
}

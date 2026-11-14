import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fvp/fvp.dart';
import 'package:video_player/video_player.dart';

import '../../app.dart';
import '../../core/logging/app_log.dart';
import '../../core/logging/log_redact.dart';
import '../../core/net/proxy_runtime.dart';
import '../../core/platform/sleep_inhibitor.dart';
import '../../core/platform/window_service.dart';
import '../../core/utils/text_utils.dart';
import '../../models/live.dart';
import '../../models/site_config.dart';
import '../../models/user_data.dart';
import '../../services/live/epg.dart';
import '../../services/live/live_ua_policy.dart';
import '../../services/live_service.dart';
import '../../services/boss_key/boss_key_service.dart';
import '../../services/relay/local_relay.dart';
import '../widgets/hover_marquee_text.dart';
import '../widgets/player_overlay_settings.dart';
import '../widgets/volume_hud.dart';
import '../widgets/volume_sheet.dart';

class LivePlayerPage extends StatefulWidget {
  const LivePlayerPage({
    super.key,
    required this.bean,
    required this.channel,
    required this.initialLine,
    this.epg,
    this.groups = const [],
    this.epgEntries = const {},
    this.initialGroup = '',
    this.onExit,
  });

  final LiveBean bean;
  final LiveChannel channel;
  final LiveLine initialLine;
  final EpgEntry? epg;

  /// 当前直播源的全部分组，换台菜单用；为空时不显示换台入口。
  final List<LiveGroup> groups;

  /// 频道节目单（键与 [epgRefOf] 一致），换台后同步顶栏 EPG。
  final Map<String, EpgEntry> epgEntries;

  /// 打开播放器时所在的分组名，换台菜单默认停在这一组。
  final String initialGroup;

  /// 独立窗口模式下退出播放器（关闭子窗口）；为空 = 普通路由返回。
  final Future<void> Function()? onExit;

  @override
  State<LivePlayerPage> createState() => _LivePlayerPageState();
}

class _LivePlayerPageState extends State<LivePlayerPage>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _controller;
  late final AnimationController _fsAnim;
  late LiveLine _line = widget.initialLine;
  late LiveChannel _channel = widget.channel;
  late String _groupName = widget.initialGroup;
  late EpgEntry? _epg = widget.epg;
  bool _opened = false;
  bool _controls = true;
  bool _playing = false;
  bool _buffering = true;
  bool _fullscreen = false;
  bool _fsToggling = false;
  bool _mini = false;

  /// 沉浸观影下窗口本来就全屏，离开直播播放器时不要退掉外层全屏。
  bool _immersiveMode = false;
  bool _alwaysOnTop = false;
  bool _pinnedBeforeMini = false;
  bool _sleepHeld = false;
  String _error = '';
  int _openSeq = 0;
  Timer? _hideTimer;

  /// 「详情」悬浮层开关与每秒刷新时钟 / 码率 / EPG 进度的计时器。
  bool _detailsVisible = false;
  Timer? _detailsTimer;

  /// 播放器音量（与点播播放器共用同一份偏好）。
  double _volume = 1.0;

  /// 静音前的音量，取消静音时恢复。
  double _lastVolume = 1.0;

  /// 滚轮调音量的落盘防抖：连续滚动时只在停下后写一次播放设置。
  Timer? _volumeWheelTimer;

  /// 快捷键 / 滚轮调音量时短暂显示的音量条。
  bool _volumeHudVisible = false;
  Timer? _volumeHudTimer;

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  bool get _isDesktop => !kIsWeb && !_isMobile;

  List<LiveLine> get _lines => channelLines(_channel);

  @override
  void initState() {
    super.initState();
    _fsAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controls = false);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_opened) return;
    _opened = true;
    final app = AppScope.of(context);
    _immersiveMode = app.playerSettings.immersiveMode;
    BossKeyService.instance.bindPlayer(
      this,
      pause: _pauseForBossKey,
      resume: _resumeFromBossKey,
    );
    _volume = app.playerSettings.volume.clamp(0.0, 1.0).toDouble();
    if (_volume > 0.001) _lastVolume = _volume;
    // 「详情」开关与点播播放器共用，上次开着就继续开。
    _detailsVisible = app.playerSettings.overlayVisible;
    if (_detailsVisible) _startDetailsTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open(_line));
  }

  void _onPlayerValue() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;
    setState(() {
      _playing = value.isPlaying;
      _buffering = value.isBuffering;
      if (value.hasError) {
        _error = value.errorDescription ?? '直播播放失败';
        _buffering = false;
        // 失败时把控制栏显示出来，否则用户找不到返回按钮。
        _controls = true;
      }
    });
    _syncSleepInhibitor();
  }

  /// 直播播放中同样阻止系统自动休眠 / 关屏；暂停、出错时恢复默认策略。
  /// 直播是长时间挂着的场景，笔记本息屏会比点播更频繁。
  void _syncSleepInhibitor() {
    final active =
        _error.isEmpty && _controller != null && (_playing || _buffering);
    if (active && !_sleepHeld) {
      _sleepHeld = true;
      SleepInhibitor.acquire();
    } else if (!active && _sleepHeld) {
      _sleepHeld = false;
      SleepInhibitor.release();
    }
  }

  Future<void> _open(LiveLine line) async {
    // 频道地址可能带 `@referer=...@user-agent=...` 形式的头（TVBox 常见写法）：
    // 直接丢给 Uri.parse 会得到一个无效地址，播放器只能报 invalid media。
    var cleanUrl = splitUrlHeadersClean(line.url);
    final inline = splitUrlHeaders(line.url);
    final headers = <String, String>{
      ...?_channel.header,
      ...inline,
      // 频道自己的 ua 只在还没有 UA 时补上：订阅 header 里可能已经用小写
      // `user-agent` 写过，两个键并存时发包用哪个取决于遍历顺序。
      if (_channel.ua.isNotEmpty &&
          liveHeaderValue(_channel.header ?? const {}, 'user-agent').isEmpty &&
          liveHeaderValue(inline, 'user-agent').isEmpty)
        'User-Agent': _channel.ua,
      if (_channel.referer.isNotEmpty) 'Referer': _channel.referer,
      if (_channel.origin.isNotEmpty) 'Origin': _channel.origin,
    };
    // 自定义直播 UA（设置 → 直播源）按**实际取流地址**再解一次：直播单地址与
    // 频道流地址常常不在同一个 host（CDN 线路），只信列表阶段的结果会漏。
    // 头名大小写不敏感：订阅里常写小写 `user-agent`，直接读 `User-Agent`
    // 会当成「没有 UA」，再写一个同名不同大小写的键。
    applyLiveStreamUa(headers, cleanUrl);
    AppLog.i(
      'live',
      '打开直播 ${_channel.name} scheme=${Uri.tryParse(cleanUrl)?.scheme} '
          'ua=${headers['User-Agent'] ?? ''} ref=${headers['Referer'] ?? ''} '
          'url=${redactUrl(cleanUrl)}',
    );
    final seq = ++_openSeq;
    setState(() {
      _line = line;
      _error = '';
      _buffering = true;
    });
    _syncSleepInhibitor();
    final old = _controller;
    _controller = null;
    old?.removeListener(_onPlayerValue);
    unawaited(old?.dispose());
    try {
      // 蜘蛛直播的频道地址是本机 `/proxy?do=py`：点击时才向蜘蛛取动态地址。
      if (LiveService.isSpiderProxyUrl(cleanUrl)) {
        final app = AppScope.of(context);
        cleanUrl = await app.liveService.resolveProxyPlay(
          widget.bean,
          cleanUrl,
        );
        if (seq != _openSeq || !mounted) return;
        AppLog.i('live', '蜘蛛直播取址 ${redactUrl(cleanUrl)}');
      }
      // 原生播放器不读 Dart 的代理覆盖，启用内置代理时把远端流包进本机中继。
      final uri = Uri.tryParse(cleanUrl);
      final viaRelay =
          ProxyRuntime.instance.enabled &&
          uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          !ProxyRuntime.isLocalHost(uri.host);
      final target = viaRelay
          ? LocalRelay.instance.playUrl(cleanUrl, headers: headers)
          : cleanUrl;
      if (viaRelay) {
        AppLog.i('live', '经中继/代理打开直播 ${redactUrl(cleanUrl)}');
      }
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(target),
        httpHeaders: viaRelay ? const {} : headers,
      );
      _controller = controller;
      controller.addListener(_onPlayerValue);
      await controller.initialize();
      await controller.setVolume(_volume);
      await controller.play();
      if (seq != _openSeq || !mounted) return;
      setState(() {
        _buffering = false;
        _playing = controller.value.isPlaying;
      });
      _syncSleepInhibitor();
      _showControls();
    } catch (e) {
      if (seq != _openSeq || !mounted) return;
      AppLog.e('live', '打开直播失败 ${_channel.name} url=${redactUrl(cleanUrl)}', e);
      final controller = _controller;
      _controller = null;
      controller?.removeListener(_onPlayerValue);
      unawaited(controller?.dispose());
      setState(() {
        _buffering = false;
        _controls = true;
        _error = '打开直播失败：$e';
      });
      _syncSleepInhibitor();
    }
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
    _syncSleepInhibitor();
    _showControls();
  }

  /// 老板键：暂停直播；返回是否真的从播放中暂停。
  bool _pauseForBossKey() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return false;
    if (!controller.value.isPlaying) return false;
    controller.pause();
    _syncSleepInhibitor();
    return true;
  }

  /// 老板键恢复：按下前正在播才继续。
  void _resumeFromBossKey() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (!controller.value.isPlaying) controller.play();
    _syncSleepInhibitor();
  }

  IconData get _volumeIcon {
    if (_volume <= 0.001) return Icons.volume_off_rounded;
    if (_volume < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  Future<void> _setVolume(double value, {bool persist = false}) async {
    final volume = value.clamp(0.0, 1.0).toDouble();
    if (_volume > 0.001) _lastVolume = _volume;
    if (mounted) setState(() => _volume = volume);
    await _controller?.setVolume(volume);
    if (!persist || !mounted) return;
    final app = AppScope.of(context);
    await app.setPlayerSettings(app.playerSettings.copyWith(volume: volume));
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

  Future<void> _showVolume() async {
    _showControls();
    await showVolumeSheet(
      context: context,
      volume: _volume,
      onChanged: (v) => _setVolume(v),
      onCommit: (v) => _setVolume(v, persist: true),
      onToggleMute: _toggleMute,
    );
    _showControls();
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

  void _showControls() {
    if (!mounted) return;
    setState(() => _controls = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) setState(() => _controls = false);
    });
  }

  bool get _mdkEnabled =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// 详情开关与点播播放器共用 `overlayVisible`，指标和字号各自独立。
  void _toggleDetails() {
    setState(() => _detailsVisible = !_detailsVisible);
    _startDetailsTimer();
    if (_detailsVisible) _showControls();
    final app = AppScope.of(context);
    unawaited(
      app.setPlayerSettings(
        app.playerSettings.copyWith(overlayVisible: _detailsVisible),
      ),
    );
  }

  void _startDetailsTimer() {
    _detailsTimer?.cancel();
    _detailsTimer = null;
    if (!_detailsVisible) return;
    _detailsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _showDetailsSettings() async {
    final app = AppScope.of(context);
    final result = await showPlayerOverlaySettings(
      context: context,
      title: '直播详情显示',
      metrics: kLivePlayerOverlayMetrics,
      defaultMetrics: kDefaultLivePlayerOverlayMetrics,
      selectedMetrics: app.playerSettings.liveOverlayMetrics,
      fontSize: app.playerSettings.overlayFontSize,
    );
    if (result == null) return;
    await app.setPlayerSettings(
      app.playerSettings.copyWith(
        liveOverlayMetrics: result.metrics,
        overlayFontSize: result.fontSize,
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _detailsOverlay(BuildContext context) {
    final settings = AppScope.of(context).playerSettings;
    final fontSize = settings.overlayFontSize.clamp(10.0, 28.0).toDouble();
    final enabled = settings.liveOverlayMetrics.toSet();
    final media = _readMediaStats();
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
      // 直播顶栏比点播多一行 EPG，控制栏显示时详情层再往下让一点。
      MediaQuery.paddingOf(context).top + (_controls ? 104 : 16),
      18,
      MediaQuery.paddingOf(context).bottom + (_controls ? 96 : 16),
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
    _LiveMediaStats? media,
  ) {
    final lines = <Widget>[];
    for (final metric in kLivePlayerOverlayMetrics) {
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

  String? _metricText(String id, _LiveMediaStats? media) {
    final value = _controller?.value;
    switch (id) {
      case 'title':
        return _channel.name;
      case 'group':
        final group = _groupName.isEmpty ? _groupOf(_channel) : _groupName;
        return group.isEmpty ? null : group;
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
        return widget.bean.displayName;
      case 'line':
        return _line.name.isEmpty ? null : _line.name;
      case 'clock':
        final now = DateTime.now();
        final h = now.hour.toString().padLeft(2, '0');
        final m = now.minute.toString().padLeft(2, '0');
        final s = now.second.toString().padLeft(2, '0');
        return '$h:$m:$s';
      case 'status':
        if (_error.isNotEmpty) return '出错';
        if (_buffering) return '缓冲中';
        return _playing ? '直播中' : '已暂停';
      case 'epg':
        final current = _epg?.current;
        return current == null ? null : '${current.range} ${current.title}';
      case 'epg_next':
        final next = _epg?.next;
        return next == null ? null : '下一档 ${next.start} ${next.title}';
      case 'epg_progress':
        final current = _epg?.current;
        if (current == null) return null;
        final total = current.endTime - current.startTime;
        if (total <= 0) return null;
        final passed =
            DateTime.now().millisecondsSinceEpoch - current.startTime;
        final percent = (passed / total * 100).clamp(0, 100).round();
        return '节目 $percent%';
      case 'net':
        final bits = media?.bitRate ?? 0;
        if (bits <= 0) return null;
        return bits >= 1000000
            ? '${(bits / 1000000).toStringAsFixed(1)} Mb/s'
            : '${(bits / 1000).round()} kb/s';
      case 'buffer':
        final ahead = _bufferedAhead(value);
        return ahead == null ? null : '缓冲 ${ahead.toStringAsFixed(1)}s';
      case 'audio':
        final codec = media?.audioCodec ?? '';
        if (codec.isEmpty) return null;
        final channels = media?.audioChannels ?? 0;
        return channels > 0 ? '$codec ${channels}ch' : codec;
      case 'volume':
        return value == null ? null : '音量 ${(value.volume * 100).round()}%';
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

  /// 读 fvp 的 MediaInfo；移动端 / 未启用 fvp 时返回 null。
  _LiveMediaStats? _readMediaStats() {
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
      return _LiveMediaStats(
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

  Future<void> _toggleFullscreen() async {
    // 小窗是独立的置顶小窗口，不参与全屏切换。
    if (_mini || _fsToggling) return;
    _fsToggling = true;
    final next = !_fullscreen;
    setState(() {
      _fullscreen = next;
      _fsAnim.value = 0;
    });
    try {
      if (!_isMobile) await setWindowFullscreen(next);
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      _fsAnim.forward();
    } finally {
      _fsToggling = false;
    }
  }

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
    final exit = widget.onExit;
    if (exit != null) {
      await exit();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _requestExit() => unawaited(_exitPage());

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 点击画面：出错时始终显示控制栏（保证返回按钮可用），正常时切换显隐。
  void _handleTap() {
    if (!mounted) return;
    if (_error.isNotEmpty) {
      _showControls();
      return;
    }
    if (_controls) {
      setState(() => _controls = false);
    } else {
      _showControls();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
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
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      unawaited(_toggleFullscreen());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_fullscreen) {
        unawaited(_toggleFullscreen());
      } else {
        _requestExit();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    BossKeyService.instance.unbindPlayer(this);
    _hideTimer?.cancel();
    _detailsTimer?.cancel();
    _volumeWheelTimer?.cancel();
    _volumeHudTimer?.cancel();
    _fsAnim.dispose();
    if (_sleepHeld) {
      _sleepHeld = false;
      SleepInhibitor.releaseAll();
    }
    _controller?.removeListener(_onPlayerValue);
    _controller?.dispose();
    if (_mini) unawaited(exitMiniPlayerWindow());
    // 置顶只在本次播放会话内有效：离开直播播放器时无论如何都复位。
    unawaited(setAppWindowAlwaysOnTop(false));
    if (_fullscreen &&
        !_immersiveMode &&
        (kIsWeb ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      setWindowFullscreen(false);
    }
    super.dispose();
  }

  Widget _videoView() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.expand();
    }
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio <= 0
            ? 16 / 9
            : controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: _fsAnim,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(_fsAnim.value);
          final scale = _fullscreen ? 1.045 - 0.045 * t : 0.955 + 0.045 * t;
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
        child: Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            _onWheelVolume(event.scrollDelta.dy);
          },
          child: Focus(
            autofocus: true,
            onKeyEvent: _onKey,
            child: MouseRegion(
              // 鼠标移动不再唤出控制栏：与点播播放器一致，改为单击切换
              // （_handleTap）。移开期间仍由 4 秒计时器自动收缩。
              child: GestureDetector(
                // 画面为空时（加载中 / 出错）整块区域没有可命中的子组件，
                // 必须用 opaque 才能让点击回到控制栏显隐逻辑。
                behavior: HitTestBehavior.opaque,
                onTap: _handleTap,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _videoView(),
                    if (_buffering)
                      const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    if (_error.isNotEmpty)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          margin: const EdgeInsets.all(28),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.error_outline_rounded,
                                color: Colors.white70,
                                size: 34,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                _error,
                                style: const TextStyle(color: Colors.white70),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (widget.groups.isNotEmpty) ...[
                                    TextButton(
                                      onPressed: _showChannelPicker,
                                      child: const Text('换台'),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  TextButton(
                                    onPressed: _requestExit,
                                    child: const Text('返回'),
                                  ),
                                  const SizedBox(width: 8),
                                  FilledButton.tonal(
                                    onPressed: () => _open(_line),
                                    child: const Text('重试'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    AnimatedOpacity(
                      opacity: _controls ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !_controls,
                        child: Stack(
                          children: [
                            Positioned(
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
                                    colors: [
                                      Color(0xCC000000),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                                // 直播页没有自绘标题栏，顶栏这一行同时作为窗口拖拽区。
                                child: windowDragArea(
                                  Row(
                                    children: [
                                      IconButton(
                                        onPressed: _requestExit,
                                        icon: const Icon(
                                          Icons.arrow_back_rounded,
                                          color: Colors.white,
                                        ),
                                      ),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            HoverMarqueeText(
                                              _channel.name,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            HoverMarqueeText(
                                              '${_line.name} · ${widget.bean.displayName}',
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 12,
                                              ),
                                            ),
                                            if (_epg?.current != null)
                                              HoverMarqueeText(
                                                '正在播 ${_epg!.current!.range} '
                                                '${_epg!.current!.title}',
                                                style: const TextStyle(
                                                  color: Colors.white54,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            if (_epg?.next != null)
                                              HoverMarqueeText(
                                                '下一档 ${_epg!.next!.start} ${_epg!.next!.title}',
                                                style: const TextStyle(
                                                  color: Colors.white38,
                                                  fontSize: 11,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      if (_isDesktop)
                                        IconButton(
                                          tooltip: _alwaysOnTop
                                              ? '取消窗口置顶'
                                              : '窗口置顶（仅本次播放）',
                                          onPressed: _toggleAlwaysOnTop,
                                          icon: Icon(
                                            _alwaysOnTop
                                                ? Icons.push_pin_rounded
                                                : Icons.push_pin_outlined,
                                            color: Colors.white,
                                          ),
                                        ),
                                      if (_isDesktop)
                                        IconButton(
                                          tooltip: _mini
                                              ? '退出小窗'
                                              : '小窗播放（始终置顶）',
                                          onPressed: _toggleMini,
                                          icon: Icon(
                                            _mini
                                                ? Icons
                                                      .picture_in_picture_alt_rounded
                                                : Icons
                                                      .picture_in_picture_alt_outlined,
                                            color: Colors.white,
                                          ),
                                        ),
                                      if (_lines.length > 1)
                                        TextButton.icon(
                                          onPressed: _showLines,
                                          icon: const Icon(
                                            Icons.list_rounded,
                                            color: Colors.white,
                                          ),
                                          label: Text(
                                            '${_lines.length} 条线路',
                                            style: const TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      if (hasCustomWindowChrome)
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
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding: EdgeInsets.fromLTRB(
                                  14,
                                  30,
                                  14,
                                  MediaQuery.paddingOf(context).bottom + 12,
                                ),
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                    colors: [
                                      Color(0xDD000000),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    IconButton(
                                      onPressed: _togglePlay,
                                      icon: Icon(
                                        _playing
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        color: Colors.white,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '音量 ${(_volume * 100).round()}%',
                                      onPressed: _showVolume,
                                      icon: Icon(
                                        _volumeIcon,
                                        color: Colors.white,
                                      ),
                                    ),
                                    if (widget.groups.isNotEmpty)
                                      TextButton.icon(
                                        onPressed: _showChannelPicker,
                                        icon: const Icon(
                                          Icons.grid_view_rounded,
                                          color: Colors.white,
                                          size: 19,
                                        ),
                                        label: const Text(
                                          '换台',
                                          style: TextStyle(color: Colors.white),
                                        ),
                                      ),
                                    Expanded(
                                      child: Wrap(
                                        alignment: WrapAlignment.end,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        spacing: 2,
                                        children: [
                                          _barAction(
                                            icon: Icons.analytics_outlined,
                                            label: '详情',
                                            active: _detailsVisible,
                                            onTap: _toggleDetails,
                                            onLongPress: _showDetailsSettings,
                                          ),
                                          IconButton(
                                            tooltip: '刷新',
                                            onPressed: () => _open(_line),
                                            icon: const Icon(
                                              Icons.refresh_rounded,
                                              color: Colors.white,
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: '全屏（Enter）',
                                            onPressed: _toggleFullscreen,
                                            icon: Icon(
                                              _fullscreen
                                                  ? Icons
                                                        .fullscreen_exit_rounded
                                                  : Icons.fullscreen_rounded,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 100,
                      child: Center(
                        child: VolumeHud(
                          volume: _volume,
                          visible: _volumeHudVisible,
                        ),
                      ),
                    ),
                    if (_detailsVisible) _detailsOverlay(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _groupOf(LiveChannel channel) {
    for (final group in widget.groups) {
      for (final item in group.channels) {
        if (item.name == channel.name &&
            item.urls.join('|') == channel.urls.join('|')) {
          return group.group;
        }
      }
    }
    return widget.groups.isEmpty ? '' : widget.groups.first.group;
  }

  Future<void> _showChannelPicker() async {
    if (widget.groups.isEmpty) return;
    final picked =
        await showModalBottomSheet<({LiveChannel channel, String group})>(
          context: context,
          isScrollControlled: true,
          builder: (ctx) => _ChannelPickerSheet(
            groups: widget.groups,
            current: _channel,
            initialGroup: _groupName.isEmpty ? _groupOf(_channel) : _groupName,
          ),
        );
    if (picked == null || !mounted) return;
    _groupName = picked.group;
    final same =
        picked.channel.name == _channel.name &&
        picked.channel.urls.join('|') == _channel.urls.join('|');
    if (same) return;
    _switchChannel(picked.channel);
  }

  void _switchChannel(LiveChannel channel) {
    final lines = channelLines(channel);
    if (lines.isEmpty) return;
    setState(() {
      _channel = channel;
      _epg = entryOf(widget.epgEntries, epgRefOf(channel));
      _error = '';
      _controls = true;
    });
    unawaited(_open(lines.first));
  }

  Future<void> _showLines() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('选择线路', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              for (final line in _lines)
                ListTile(
                  leading: Icon(
                    line.url == _line.url
                        ? Icons.check_circle_rounded
                        : Icons.play_circle_outline_rounded,
                  ),
                  title: Text(line.name),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    if (line.url != _line.url) _open(line);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 换台菜单：左侧分类（分组）、右侧该分类下的频道，在一个界面内完成两级选择。
class _ChannelPickerSheet extends StatefulWidget {
  const _ChannelPickerSheet({
    required this.groups,
    required this.current,
    required this.initialGroup,
  });

  final List<LiveGroup> groups;
  final LiveChannel current;
  final String initialGroup;

  @override
  State<_ChannelPickerSheet> createState() => _ChannelPickerSheetState();
}

class _ChannelPickerSheetState extends State<_ChannelPickerSheet> {
  late int _groupIndex = _initialIndex();
  int? _hoveredGroupIndex;
  String? _hoveredChannelKey;

  String _channelKey(LiveChannel channel) =>
      '${channel.name}\u0000${channel.urls.join('|')}';

  int _initialIndex() {
    final byName = widget.groups.indexWhere(
      (g) => g.group == widget.initialGroup,
    );
    if (byName >= 0) return byName;
    for (var i = 0; i < widget.groups.length; i++) {
      for (final channel in widget.groups[i].channels) {
        if (channel.name == widget.current.name &&
            channel.urls.join('|') == widget.current.urls.join('|')) {
          return i;
        }
      }
    }
    return 0;
  }

  bool _isCurrent(LiveChannel channel) {
    return channel.name == widget.current.name &&
        channel.urls.join('|') == widget.current.urls.join('|');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = widget.groups;
    final group = groups[_groupIndex];
    final total = groups.fold<int>(0, (sum, g) => sum + g.channels.length);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.66,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('换台', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  Text(
                    '${groups.length} 个分组 · $total 个台',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 150,
                      child: ListView.separated(
                        itemCount: groups.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (_, index) {
                          final item = groups[index];
                          final active = index == _groupIndex;
                          return InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => setState(() => _groupIndex = index),
                            onHover: (hovering) => setState(() {
                              if (hovering) {
                                _hoveredGroupIndex = index;
                              } else if (_hoveredGroupIndex == index) {
                                _hoveredGroupIndex = null;
                              }
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: active
                                    ? theme.colorScheme.primary.withValues(
                                        alpha: 0.16,
                                      )
                                    : theme.colorScheme.surfaceContainerHighest
                                          .withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: active
                                      ? theme.colorScheme.primary
                                      : Colors.transparent,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: HoverMarqueeText(
                                      item.group,
                                      externalHover:
                                          _hoveredGroupIndex == index,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: active
                                            ? FontWeight.w800
                                            : FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${item.channels.length}',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.72),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 170,
                              mainAxisExtent: 54,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                            ),
                        itemCount: group.channels.length,
                        itemBuilder: (_, index) {
                          final channel = group.channels[index];
                          final active = _isCurrent(channel);
                          return InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => Navigator.of(context)
                                .pop((channel: channel, group: group.group)),
                            onHover: (hovering) => setState(() {
                              final key = _channelKey(channel);
                              if (hovering) {
                                _hoveredChannelKey = key;
                              } else if (_hoveredChannelKey == key) {
                                _hoveredChannelKey = null;
                              }
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
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
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  HoverMarqueeText(
                                    channel.name,
                                    externalHover:
                                        _hoveredChannelKey ==
                                        _channelKey(channel),
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: active
                                          ? FontWeight.w800
                                          : FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${channel.urls.length} 条线路',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontSize: 10.5,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.70),
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
      ),
    );
  }
}

/// 桌面端从 fvp（libmdk）读到的直播媒体信息，供「详情」悬浮层显示。
class _LiveMediaStats {
  const _LiveMediaStats({
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

  /// 实时码率（bit/s），直播中由 libmdk 更新。
  final int bitRate;
  final String videoCodec;
  final String audioCodec;
  final int audioChannels;
  final String format;
}

import 'dart:async';
import 'dart:io';

import '../../core/logging/log_redact.dart';
import '../player/external_players.dart';
import '../relay/local_relay.dart';
import 'aria2_sidecar.dart';
import 'bt_stream.dart';
import 'magnet.dart';
import 'xunlei_cloud.dart';

/// 元数据（磁力握手/文件清单）等待上限。
const Duration _metaTimeout = Duration(seconds: 60);

/// 起播门控：等文件头 [btHeadGateBytes] 落盘的上限（做种冷时早点给用户结论，别一直转圈）。
///
/// 冷门种子常见「连上几十个 peer、只有 1 个做种、首包 30~40s 才到」，
/// stall 必须留够，否则会在数据到达前误判为无做种。
const Duration _headGateTimeout = Duration(seconds: 90);
const Duration _headGateStall = Duration(seconds: 60);

/// 播放中单次区间门控：总上限 / 零进度放弃阈值（拖到未下载区时，还要给播放器持续供流的机会）。
const Duration _streamGateTimeout = Duration(minutes: 20);
const Duration _streamGateStall = Duration(minutes: 2);

/// 会话回收：空闲多久停 / 最多同时保留几个。
const Duration _idleStop = Duration(minutes: 10);
const int _maxSessions = 3;

/// 磁力播放出口：
///   · `inline`：mp4/webm 等直接给本机中继地址（`/bt` 做 Range + piece 门控）；
///   · `external`：mkv/hevc 等拉起已安装的桌面播放器接力；
///   · `unsupported`：引擎缺失 / 冷门无做种 / 无外部播放器…（调用方给「复制链接」兜底）。
enum BtPlayKind { inline, external, unsupported }

class BtPlayOutcome {
  const BtPlayOutcome.inline({
    required this.url,
    required this.infoHash,
    required this.fileIndex,
    required this.title,
    this.provider = 'BT',
  }) : kind = BtPlayKind.inline,
       player = '',
       reason = '';

  const BtPlayOutcome.external({
    required this.player,
    required this.title,
    this.provider = 'BT',
  }) : kind = BtPlayKind.external,
       url = '',
       infoHash = '',
       fileIndex = 0,
       reason = '';

  const BtPlayOutcome.unsupported(this.reason)
    : kind = BtPlayKind.unsupported,
      url = '',
      infoHash = '',
      fileIndex = 0,
      title = '',
      player = '',
      provider = '';

  final BtPlayKind kind;
  final String url;
  final String infoHash;
  final int fileIndex;
  final String title;
  final String player;
  final String reason;

  /// 实际出流引擎（`BT` / `迅雷云盘`），播放器标题栏显示用。
  final String provider;
}

class _BtSession {
  _BtSession({
    required this.infoHash,
    required this.gid,
    required this.title,
    required this.fileName,
    required this.fileIndex,
    required this.absPath,
    required this.fileLength,
    required this.fileOffset,
    required this.pieceLength,
    this.complete = false,
  });

  final String infoHash;
  final String gid;
  final String title;
  final String fileName;
  final int fileIndex;
  final String absPath;
  final int fileLength;
  final int fileOffset;
  final int pieceLength;
  DateTime lastAccess = DateTime.now();
  bool complete;
}

/// 磁力播放编排：`magnet → 起任务 → 选片 → 等首段可读 → 交播放器`。
///
/// 会话表按 infoHash 常驻（同一磁力重复点播/切集复用已下 piece），
/// 空闲 10 分钟或超过 3 个会话时回收。
class TorrentPlay implements BtStreamSource {
  TorrentPlay({
    required String supportDir,
    String downloadDir = '',
    this.customPlayers = _noPlayers,
    this.xunleiCloud,
    void Function(String message)? logger,
  }) : _supportDir = supportDir,
       _downloadDir = downloadDir.trim(),
       _log = logger ?? ((_) {}) {
    _sidecar = Aria2Sidecar(
      supportDir: supportDir,
      downloadDir: _downloadDir,
      logger: _log,
    );
  }

  static List<ExternalPlayer> _noPlayers() => const [];

  /// 用户手动添加的第三方播放器（优先级高于自动探测）。
  final List<ExternalPlayer> Function() customPlayers;

  /// 迅雷云盘离线下载；未登录 / 关闭开关 / 失败时回落 aria2。
  final XunleiCloudService? xunleiCloud;
  final void Function(String message) _log;
  final String _supportDir;
  String _downloadDir;

  /// 用户自定义磁力下载目录变化：销毁旧 aria2 进程并在新目录重新拉起。
  void setDownloadDir(String path) {
    final next = path.trim();
    if (next == _downloadDir) return;
    _downloadDir = next;
    _sidecar.dispose();
    _sessions.clear();
    _sidecar = Aria2Sidecar(
      supportDir: _supportDir,
      downloadDir: next,
      logger: _log,
    );
    _log('磁力下载目录已切换：${_sidecar.dir}');
  }

  late Aria2Sidecar _sidecar;
  final Map<String, _BtSession> _sessions = {};

  /// 下载管理器复用同一个 aria2 进程（避免两个引擎抢端口/抢任务）。
  Aria2Sidecar get engine => _sidecar;

  /// `/bt` 路由取流入口：命中会话且文件序号一致才给（其余一律 404）。
  @override
  BtStreamInfo? resolveStream(String infoHash, int fileIndex) {
    final session = _sessions[infoHash];
    if (session == null || session.fileIndex != fileIndex) return null;
    session.lastAccess = DateTime.now();
    return BtStreamInfo(
      absPath: session.absPath,
      length: session.fileLength,
      fileOffset: session.fileOffset,
      pieceLength: session.pieceLength,
    );
  }

  /// 门控：等 [start,end]（文件内相对字节）所在 piece 全部落盘校验完成。
  ///
  /// 返回 false = 超时/零进度放弃（调用方应 503，而不是喂零字节坏流）。
  @override
  Future<bool> waitCovered(
    String infoHash,
    int fileIndex,
    int start,
    int end, {
    Duration? timeout,
    Duration? stall,
    bool Function()? isCancelled,
  }) async {
    final session = _sessions[infoHash];
    if (session == null || session.fileIndex != fileIndex) return false;
    session.lastAccess = DateTime.now();
    if (session.complete) return true;
    final timeoutMs = (timeout ?? _streamGateTimeout).inMilliseconds;
    final stallMs = (stall ?? _streamGateStall).inMilliseconds;
    final started = DateTime.now();
    var prevDone = -1;
    var prevAt = started;
    var round = 0;
    while (true) {
      if (isCancelled?.call() == true) {
        _log('BT 门控已取消：${infoHash.substring(0, 8)}');
        return false;
      }
      Aria2Status? status;
      try {
        status = await _sidecar.status(session.gid);
      } catch (e) {
        if (round % 25 == 0) _log('BT 门控轮询失败：$e');
      }
      if (status != null) {
        if (status.status == 'error') {
          _log(
            'BT 任务出错：${status.status} code=${status.errorCode} ${status.errorMessage}',
          );
          return false;
        }
        final done = status.completedLength;
        final pieceLength = status.pieceLength > 0
            ? status.pieceLength
            : session.pieceLength;
        final bitfield = status.bitfield;
        if (status.status == 'complete') {
          session.complete = true;
          return true;
        }
        if (done != prevDone) {
          prevDone = done;
          prevAt = DateTime.now();
        }
        if (bitfield.isNotEmpty && pieceLength > 0) {
          final range = piecesForByteRange(
            session.fileOffset,
            pieceLength,
            start,
            end,
          );
          if (isPieceRangeSet(bitfield, range.first, range.last) &&
              _fileHasBytes(session.absPath, end + 1)) {
            return true;
          }
        }
        // 每 10 秒留一条进度：做种者为 0 时能直接看出来，不用再猜。
        if (round % 25 == 0) {
          _log(
            'BT 门控等待 ${round * 400}ms：status=${status.status} '
            'done=${status.completedLength}/${status.totalLength} '
            'conn=${status.connections} seeders=${status.numSeeders} '
            'speed=${status.downloadSpeed}B/s',
          );
        }
      }
      round++;
      final now = DateTime.now();
      if (now.difference(started).inMilliseconds > timeoutMs) {
        _log(
          'BT 门控超时（${timeoutMs ~/ 1000}s）：${infoHash.substring(0, 8)} [$start,$end] '
          'conn=${status?.connections} seeders=${status?.numSeeders} '
          'done=${status?.completedLength}/${status?.totalLength}',
        );
        return false;
      }
      if (now.difference(prevAt).inMilliseconds > stallMs) {
        _log(
          'BT 门控零进度放弃（${stallMs ~/ 1000}s 无新增）：${infoHash.substring(0, 8)} [$start,$end] '
          'conn=${status?.connections} seeders=${status?.numSeeders}',
        );
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// 磁盘上是否真的已有这么多字节（file-allocation=none 时文件是长出来的）。
  bool _fileHasBytes(String absPath, int need) {
    try {
      return File(absPath).lengthSync() >= need;
    } catch (_) {
      return false;
    }
  }

  /// 磁力 → 可播地址（inline）/ 外部播放器接力 / 不可用原因。
  ///
  /// `title` 用于选片线索与显示（通常传集名或片名）。
  /// 已登录迅雷云盘且开关打开时先走云端离线下载，失败自动回退 aria2。
  /// `isCancelled` 为用户在准备弹窗点「取消」后的中止探针。
  Future<BtPlayOutcome> open(
    String magnet, {
    String title = '',
    void Function(String message)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final info = parseMagnet(magnet);
    if (info == null) return const BtPlayOutcome.unsupported('磁力链接格式无法识别');
    // 同磁力已在 aria2 会话表（还在播/还在下）→ 直接复用，不重建任务。
    final existed = _sessions[info.infoHash];
    if (existed != null) return _handOff(existed);
    if (isCancelled?.call() == true) {
      return const BtPlayOutcome.unsupported('已取消');
    }

    final cloud = xunleiCloud;
    if (cloud != null && cloud.ready) {
      try {
        final play = await cloud.openMagnet(
          magnet,
          title: title,
          onProgress: onProgress,
        );
        if (isCancelled?.call() == true) {
          return const BtPlayOutcome.unsupported('已取消');
        }
        final outcome = _handOffCloud(play);
        if (outcome.kind != BtPlayKind.unsupported) return outcome;
        _log('迅雷云盘不可播：${outcome.reason}');
        return outcome;
      } on XunleiCloudException catch (e) {
        _log('迅雷云盘失败，回落 aria2：${e.message}');
        onProgress?.call('迅雷云盘失败（${e.message}），改用 aria2…');
      } catch (e) {
        _log('迅雷云盘异常，回落 aria2：$e');
        onProgress?.call('迅雷云盘不可用，改用 aria2…');
      }
    } else {
      _log('迅雷云盘未启用（未登录/开关关闭），改用 aria2');
    }
    return _openWithAria2(
      magnet,
      info: info,
      title: title,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  Future<BtPlayOutcome> _openWithAria2(
    String magnet, {
    required MagnetInfo info,
    required String title,
    void Function(String message)? onProgress,
    bool Function()? isCancelled,
  }) async {
    onProgress?.call('正在准备 BT 引擎…');
    if (!await _sidecar.available()) {
      return BtPlayOutcome.unsupported('未内置 BT 引擎（${_sidecar.exePath} 缺失）');
    }
    if (!await _sidecar.ensure()) {
      return const BtPlayOutcome.unsupported(
        'BT 引擎启动失败（可关闭后重试，或查看调试日志 [aria2] 行）',
      );
    }
    if (isCancelled?.call() == true) {
      return const BtPlayOutcome.unsupported('已取消');
    }
    await _reap();
    try {
      onProgress?.call('正在获取种子元数据…');
      final gid = await _sidecar.addMagnet(
        withTrackers(magnet),
        addUriOptions(_sidecar.dir),
      );
      final torrentGid = await _waitFollowed(
        gid,
        _metaTimeout,
        isCancelled: isCancelled,
      );
      if (isCancelled?.call() == true) {
        unawaited(_sidecar.remove(gid));
        return const BtPlayOutcome.unsupported('已取消');
      }
      if (torrentGid.isEmpty) {
        unawaited(_sidecar.remove(gid));
        return const BtPlayOutcome.unsupported(
          '等待种子元数据超时（该磁力可能已无做种/无 tracker 可达）',
        );
      }
      final raw = await _sidecar.files(torrentGid);
      final files = withTorrentOffsets([
        for (final file in raw)
          (index: file.index, path: file.path, length: file.length),
      ]);
      final pick = pickVideoFile(files, preferName: title);
      if (pick == null) {
        unawaited(_sidecar.remove(torrentGid));
        return const BtPlayOutcome.unsupported('种子内未找到视频文件（可能只是字幕/图片包）');
      }
      // 只下选中的正片（其余文件不占带宽）。
      await _sidecar.selectFile(torrentGid, pick.index);
      await _sidecar.unpause(torrentGid);
      final status = await _sidecar.status(torrentGid);
      final fileNameOnly = pick.path.split(RegExp(r'[\\/]')).last;
      final session = _BtSession(
        infoHash: info.infoHash,
        gid: torrentGid,
        title: info.displayName.isNotEmpty
            ? info.displayName
            : (fileNameOnly.isEmpty ? pick.path : fileNameOnly),
        fileName: pick.path,
        fileIndex: pick.index,
        absPath: pick.path, // aria2 返回的就是绝对路径（含 dir 前缀）
        fileLength: pick.length,
        fileOffset: pick.offset,
        pieceLength: status.pieceLength,
        complete: pick.length == 0,
      );
      _sessions[info.infoHash] = session;
      _log(
        'BT 会话建立：${info.infoHash.substring(0, 8)}「${session.title}」file#${pick.index} '
        '${(pick.length / 1048576).round()}MB',
      );
      onProgress?.call('正在等待首段数据…');
      // 起播门控：先等文件头一小段落盘（播放器一上来就要读容器头）。
      final gateEnd = btHeadGateBytes < pick.length - 1
          ? btHeadGateBytes
          : (pick.length - 1 < 0 ? 0 : pick.length - 1);
      final ok = await waitCovered(
        info.infoHash,
        pick.index,
        0,
        gateEnd,
        timeout: _headGateTimeout,
        stall: _headGateStall,
        isCancelled: isCancelled,
      );
      if (!ok) {
        drop(info.infoHash);
        if (isCancelled?.call() == true) {
          return const BtPlayOutcome.unsupported('已取消');
        }
        return const BtPlayOutcome.unsupported('BT 缓冲超时（做种者过少或无做种）');
      }
      return _handOff(session);
    } catch (e) {
      _log('BT 会话建立失败 $e');
      final message = '$e';
      return BtPlayOutcome.unsupported(
        'BT 会话建立失败：${message.length > 80 ? message.substring(0, 80) : message}',
      );
    }
  }

  /// 等 `followedBy`（元数据下载完成 → 生成真正的种子任务）。aria2 1.37 里它是**数组**。
  Future<String> _waitFollowed(
    String metaGid,
    Duration timeout, {
    bool Function()? isCancelled,
  }) async {
    final started = DateTime.now();
    var round = 0;
    while (DateTime.now().difference(started) < timeout) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      round++;
      if (isCancelled?.call() == true) {
        _log('BT 元数据等待已取消');
        return '';
      }
      try {
        final status = await _sidecar.status(metaGid);
        final gid = firstFollowedBy(status.followedBy);
        if (gid.isNotEmpty) {
          _log('BT 元数据就绪：$metaGid → $gid（${round * 700}ms）');
          return gid;
        }
        if (status.status == 'error' ||
            (status.errorCode.isNotEmpty && status.errorCode != '0')) {
          _log('BT 元数据下载出错：${status.errorCode} ${status.errorMessage}');
          return '';
        }
        // 每 5 秒留一条进度：无做种时日志里能看出「连了 N 个节点、0 个做种」。
        if (round % 7 == 0) {
          _log(
            'BT 元数据等待 ${round * 700}ms：status=${status.status} '
            'conn=${status.connections} seeders=${status.numSeeders} '
            'speed=${status.downloadSpeed}B/s',
          );
        }
      } catch (e) {
        if (round % 7 == 0) _log('BT 元数据轮询失败：$e');
      }
    }
    return '';
  }

  /// 会话 → 播放出口（内联 / 外部接力 / 不可用原因）。
  BtPlayOutcome _handOff(_BtSession session) {
    session.lastAccess = DateTime.now();
    final relay = LocalRelay.instance;
    if (!relay.running) {
      return const BtPlayOutcome.unsupported('本地播放中继未启动，无法把磁力流转给播放器');
    }
    final url = btStreamUrl(relay.baseUrl, session.infoHash, session.fileIndex);
    final block = webPlayBlockReason(session.fileName);
    if (block == null) {
      return BtPlayOutcome.inline(
        url: url,
        infoHash: session.infoHash,
        fileIndex: session.fileIndex,
        title: session.title,
      );
    }
    final players = detectExternalPlayers(custom: customPlayers());
    if (players.isEmpty) {
      return BtPlayOutcome.unsupported(
        '$block，且未配置外部播放器（可在 设置 → 播放 → 自定义第三方播放器 选择播放器 exe）',
      );
    }
    final player = players.firstWhere(
      (p) => externalPlayerExists(p.path),
      orElse: () => players.first,
    );
    if (!launchExternalPlayer(player.path, url)) {
      return BtPlayOutcome.unsupported('外部播放器启动失败（${player.name}）');
    }
    _log('BT 外部接力：${player.name} ← $url（$block）');
    return BtPlayOutcome.external(player: player.name, title: session.title);
  }

  /// 迅雷云盘直链 → 内置播放（mp4/webm）或外部播放器接力。
  BtPlayOutcome _handOffCloud(XunleiCloudPlay play) {
    final relay = LocalRelay.instance;
    if (!relay.running) {
      return const BtPlayOutcome.unsupported('本地播放中继未启动，无法把磁力流转给播放器');
    }
    // 云端直链通常要求迅雷下载 UA；套上中继让内置/外部播放器都能带上。
    final url = relay.playUrl(play.url, headers: play.headers);
    final block = webPlayBlockReason(play.fileName);
    if (block == null) {
      return BtPlayOutcome.inline(
        url: url,
        infoHash: play.infoHash,
        fileIndex: 1,
        title: play.title,
        provider: '迅雷云盘',
      );
    }
    final players = detectExternalPlayers(custom: customPlayers());
    if (players.isEmpty) {
      return BtPlayOutcome.unsupported(
        '$block，且未配置外部播放器（可在 设置 → 播放 → 自定义第三方播放器 选择播放器 exe）',
      );
    }
    final player = players.firstWhere(
      (p) => externalPlayerExists(p.path),
      orElse: () => players.first,
    );
    if (!launchExternalPlayer(player.path, url)) {
      return BtPlayOutcome.unsupported('外部播放器启动失败（${player.name}）');
    }
    _log('迅雷云盘外部接力：${player.name} ← ${redactUrl(play.url)}（$block）');
    return BtPlayOutcome.external(
      player: player.name,
      title: play.title,
      provider: '迅雷云盘',
    );
  }

  /// 回收空闲/超量会话（只在开新会话前跑；正在播的会话靠 lastAccess 保命）。
  Future<void> _reap() async {
    final now = DateTime.now();
    final list = _sessions.values.toList()
      ..sort((a, b) => a.lastAccess.compareTo(b.lastAccess));
    for (final session in list) {
      final idle = now.difference(session.lastAccess) > _idleStop;
      final over = _sessions.length > _maxSessions;
      if (!idle && !over) break;
      drop(session.infoHash);
    }
  }

  /// 结束一个会话（移除任务 + 清表；下载的部分文件保留在缓存目录，二次播放可续）。
  void drop(String infoHash) {
    final session = _sessions.remove(infoHash);
    if (session == null) return;
    unawaited(_sidecar.remove(session.gid).catchError((Object _) {}));
    _log('BT 会话结束：${infoHash.substring(0, 8)}');
  }

  void dispose() {
    for (final infoHash in _sessions.keys.toList()) {
      drop(infoHash);
    }
    _sidecar.dispose();
  }
}

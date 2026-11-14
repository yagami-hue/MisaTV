import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../models/download_task.dart';
import 'magnet.dart';

/// aria2 `getFiles` 条目（数值字段 JSON 里是**字符串**）。
class Aria2FileRaw {
  const Aria2FileRaw({
    required this.index,
    required this.path,
    required this.length,
  });

  final int index;
  final String path;
  final int length;

  static Aria2FileRaw fromJson(Map<String, dynamic> json) => Aria2FileRaw(
    index: _num(json['index']),
    path: (json['path'] ?? '').toString(),
    length: _num(json['length']),
  );
}

/// aria2 `tellStatus` 关心的字段（只取用得到的，减少轮询开销）。
class Aria2Status {
  const Aria2Status(this._raw);

  final Map<String, dynamic> _raw;

  String get status => (_raw['status'] ?? '').toString();
  int get totalLength => _num(_raw['totalLength']);
  int get completedLength => _num(_raw['completedLength']);
  int get downloadSpeed => _num(_raw['downloadSpeed']);
  int get pieceLength => _num(_raw['pieceLength']);
  String get bitfield => (_raw['bitfield'] ?? '').toString();
  String get errorCode => (_raw['errorCode'] ?? '').toString();
  String get errorMessage => (_raw['errorMessage'] ?? '').toString();
  int get connections => _num(_raw['connections']);
  int get numSeeders => _num(_raw['numSeeders']);
  Object? get followedBy => _raw['followedBy'];
}

int _num(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

Future<void> _sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// aria2c 命令行（导出供单测/排障对拍：参数写错会静默劣化体验，值得锁死）。
List<String> aria2Args({
  required int port,
  required String secret,
  required String dir,
  int? stopWithPid,
}) {
  return [
    // 绝不读用户的 aria2.conf：外部配置可能把 dir/端口/限速带偏，甚至与本进程抢端口。
    '--no-conf=true',
    '--enable-rpc=true',
    '--rpc-listen-all=false',
    '--rpc-listen-port=$port',
    '--rpc-secret=$secret',
    '--dir=$dir',
    // 不预分配（NTFS 稀疏/整块预分配都会拖住起播）；断点续传靠 .aria2 控制文件。
    '--file-allocation=none',
    '--continue=true',
    '--allow-overwrite=false',
    '--auto-file-renaming=false',
    // 元数据落 .torrent：二次播放免 DHT 再拉元数据；未选中文件既不下也不删。
    '--bt-save-metadata=true',
    '--bt-remove-unselected-file=false',
    '--seed-time=0',
    // 首尾优先：mp4 的 moov 常在**文件尾**，不取尾片连元数据都读不到（起播慢的第一大坑）。
    '--bt-prioritize-piece=head=8M,tail=8M',
    // 死 tracker 默认要拖 60s 才放行，压到 20s；UDP tracker 连接更快失败重试。
    '--bt-tracker-timeout=20',
    '--bt-tracker-connect-timeout=10',
    '--enable-dht=true',
    '--enable-dht6=false',
    '--bt-enable-lpd=true',
    '--enable-peer-exchange=true',
    '--max-concurrent-downloads=3',
    '--disk-cache=32M',
    '--console-log-level=error',
    '--log-level=error',
    '--summary-interval=0',
    '--quiet=true',
    // Windows 专有：本进程退（含被强杀）→ aria2c 自行退出，不留孤儿。
    if (stopWithPid != null) '--stop-with-process=$stopWithPid',
  ];
}

/// 内置 BT 引擎（aria2c sidecar，磁力播放的地基）。
///
/// 为什么是 aria2c（而不是纯 Dart BT 实现）：
///   · 纯 exe、无运行时依赖；自带 DHT / PEX / UDP tracker / 元数据预取 / 选择性下载；
///   · JSON-RPC 的 `bitfield` 能**精确回答「某段字节是否已落盘校验」**——
///     这是本地中继不喂零字节的前提。
///
/// 生命周期：
///   · **懒启动**：首次磁力播放才拉起，不拖慢应用首帧；常驻复用（一个进程服务所有会话）；
///   · `--stop-with-process=<本进程 pid>`（Windows 专有）→ 应用被强杀也不留孤儿；
///   · 退出走 `dispose()`（应用 shutdown）。
class Aria2Sidecar {
  Aria2Sidecar({
    required String supportDir,
    String downloadDir = '',
    void Function(String message)? logger,
  }) : dir = downloadDir.trim().isNotEmpty
           ? downloadDir.trim()
           : p.join(supportDir, 'bt'),
       _exe = p.join(supportDir, 'aria2', 'aria2c.exe'),
       _log = logger ?? ((_) {});

  static const String assetPath = 'assets/aria2/aria2c.exe';

  /// 会话目录（所有 BT 会话共用；按 infoHash 分子目录由 aria2 按种子名自动创建）。
  final String dir;
  final String _exe;
  final void Function(String message) _log;

  Process? _proc;
  int _port = 0;
  String _secret = '';
  Future<bool>? _starting;

  String get exePath => _exe;
  bool get alive => _proc != null && _port > 0;

  /// 引擎文件是否就位（缺文件时上层给「未内置 BT 引擎」的人话提示，而不是空等超时）。
  Future<bool> available() async {
    // 内置的是 Windows 版 aria2c.exe：其它平台直接判定不可用（不做无意义的解包）。
    if (!Platform.isWindows) return false;
    try {
      if (File(_exe).existsSync()) return true;
      return await _extract();
    } catch (_) {
      return false;
    }
  }

  /// 把打包的 aria2c.exe 释放到应用数据目录（只在缺失时写；资产是只读的）。
  Future<bool> _extract() async {
    try {
      final data = await rootBundle.load(assetPath);
      final file = File(_exe);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return file.existsSync();
    } catch (e) {
      _log('BT 引擎资源释放失败：$e');
      return false;
    }
  }

  /// 懒启动 + 就绪等待（幂等；并发调用共享同一次启动）。
  Future<bool> ensure() {
    if (alive) return Future.value(true);
    final starting = _starting;
    if (starting != null) return starting;
    final future = _start().whenComplete(() => _starting = null);
    _starting = future;
    return future;
  }

  Future<bool> _start() async {
    if (!await available()) {
      _log('BT 引擎缺失：$_exe（磁力播放不可用，将回落到「复制链接」提示）');
      return false;
    }
    try {
      await Directory(dir).create(recursive: true);
      _port = await _freePort();
      _secret = _randomSecret();
      final args = aria2Args(
        port: _port,
        secret: _secret,
        dir: dir,
        stopWithPid: Platform.isWindows ? pid : null,
      );
      final proc = await Process.start(
        _exe,
        args,
        // 必须是 normal：detachedWithStdio 模式下 `proc.exitCode` 会抛
        // `Bad state: Process is detached`，刚启动就被当成启动失败；
        // 父进程退出后的清理由 `--stop-with-process=<本进程 pid>` 兜底。
        mode: ProcessStartMode.normal,
        runInShell: false,
      );
      proc.stderr.transform(utf8.decoder).listen((line) {
        final text = line.trim();
        if (text.isNotEmpty) {
          _log('[aria2] ${text.length > 300 ? text.substring(0, 300) : text}');
        }
      }, onError: (Object _) {});
      proc.stdout.drain<void>();
      proc.exitCode.then((code) {
        _log('BT 引擎退出（code=$code）');
        if (_proc == proc) {
          _proc = null;
          _port = 0;
        }
      });
      _proc = proc;
      // 等 RPC 起（正常 < 1s；冷启动磁盘慢时给足 8s）。
      for (var i = 0; i < 40; i++) {
        await _sleep(200);
        try {
          await _call<Object?>(
            'aria2.getVersion',
            const [],
            timeout: const Duration(seconds: 2),
          );
          _log('BT 引擎就绪：aria2c pid=${proc.pid} rpc=127.0.0.1:$_port dir=$dir');
          return true;
        } catch (_) {
          // 还没起：继续等
        }
      }
      _log('BT 引擎启动超时（RPC 未就绪）');
      dispose();
      return false;
    } catch (e) {
      _log('BT 引擎启动异常 $e');
      dispose();
      return false;
    }
  }

  /// 取一个空闲端口（aria2 RPC 只监听 127.0.0.1）。
  Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  String _randomSecret() {
    final rand = DateTime.now().microsecondsSinceEpoch;
    final salt = DateTime.now().millisecondsSinceEpoch ^ 0x5f3759df;
    return '$rand${salt.toRadixString(16)}';
  }

  /// JSON-RPC（只连本机；token 认证）。
  Future<T> _call<T>(
    String method,
    List<Object?> params, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final port = _port;
    final secret = _secret;
    if (port == 0 || secret.isEmpty) throw StateError('aria2 未启动');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/jsonrpc'),
      );
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      final body = utf8.encode(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 'kniephos',
          'method': method,
          'params': ['token:$secret', ...params],
        }),
      );
      // aria2 的 HTTP 服务不认 chunked 请求体：不显式写 Content-Length 时
      // 会直接回 -32700 Parse error（连 getVersion 都调不通）。
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join();
      final decoded = jsonDecode(text);
      if (decoded is! Map) throw StateError('$method: 非法 RPC 应答');
      final error = decoded['error'];
      if (error is Map) {
        throw StateError('$method: ${error['message'] ?? 'rpc error'}');
      }
      return decoded['result'] as T;
    } finally {
      client.close(force: true);
    }
  }

  /// 加磁力（只下元数据并暂停，等上层按文件清单 select-file）。
  Future<String> addMagnet(String magnet, Map<String, String> options) {
    return _call<String>('aria2.addUri', [
      [magnet],
      options,
    ], timeout: const Duration(seconds: 20));
  }

  /// 通用添加（下载管理器用：http/https/ftp/磁力都走这里）。
  Future<String> addDownload(
    List<String> uris,
    Map<String, String> options,
  ) => _call<String>('aria2.addUri', [
    uris,
    options,
  ], timeout: const Duration(seconds: 20));

  /// 下载管理器：当前活动 / 等待 / 已结束任务。
  Future<List<Map<String, dynamic>>> tellActive() =>
      _tellList('aria2.tellActive', const []);

  Future<List<Map<String, dynamic>>> tellWaiting({
    int offset = 0,
    int num = 100,
  }) => _tellList('aria2.tellWaiting', [offset, num]);

  Future<List<Map<String, dynamic>>> tellStopped({
    int offset = 0,
    int num = 100,
  }) => _tellList('aria2.tellStopped', [offset, num]);

  Future<List<Map<String, dynamic>>> _tellList(
    String method,
    List<Object?> leading,
  ) async {
    final keys = DownloadTask.statusKeys;
    final raw = await _call<List<dynamic>>(method, [
      ...leading,
      keys,
    ]);
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// 全局速度统计（下载 / 上传）。
  Future<Map<String, dynamic>> globalStat() async {
    final raw = await _call<Map<String, dynamic>>(
      'aria2.getGlobalStat',
      const [],
    );
    return raw;
  }

  Future<void> pause(String gid) => _call<dynamic>('aria2.pause', [gid]);

  Future<void> pauseAll() => _call<dynamic>('aria2.pauseAll', const []);

  Future<void> unpauseAll() => _call<dynamic>('aria2.unpauseAll', const []);

  Future<void> removeDownloadResult(String gid) =>
      _call<dynamic>('aria2.removeDownloadResult', [gid]);

  Future<void> changeGlobalOption(Map<String, String> options) =>
      _call<dynamic>('aria2.changeGlobalOption', [options]);

  Future<Aria2Status> status(String gid) async {
    final raw = await _call<Map<String, dynamic>>('aria2.tellStatus', [
      gid,
      statusKeys,
    ]);
    return Aria2Status(raw);
  }

  Future<List<Aria2FileRaw>> files(String gid) async {
    final raw = await _call<List<dynamic>>('aria2.getFiles', [gid]);
    return raw
        .whereType<Map>()
        .map((e) => Aria2FileRaw.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 选择性下载（对**暂停中**的下载改选项 —— aria2 官方文件选择流程）。
  Future<void> selectFile(String gid, int fileIndex) async {
    await _call<dynamic>('aria2.changeOption', [
      gid,
      {'select-file': '$fileIndex'},
    ]);
  }

  Future<void> unpause(String gid) async {
    await _call<dynamic>('aria2.unpause', [gid]);
  }

  /// 移除任务（忽略「已不存在」类错误）。
  Future<void> remove(String gid) async {
    try {
      await _call<dynamic>('aria2.remove', [
        gid,
      ], timeout: const Duration(seconds: 10));
    } catch (_) {
      try {
        await _call<dynamic>('aria2.removeDownloadResult', [
          gid,
        ], timeout: const Duration(seconds: 10));
      } catch (_) {}
    }
  }

  /// 退出清理：杀进程（`--stop-with-process` 是第二重保险）。
  void dispose() {
    final proc = _proc;
    _proc = null;
    _port = 0;
    _secret = '';
    if (proc == null) return;
    try {
      proc.kill();
    } catch (_) {}
  }
}

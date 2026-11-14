import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../services/artwork/tmdb_network.dart';
import '../logging/app_log.dart';
import 'proxy_config.dart';
import 'system_proxy.dart';

/// 全局代理运行时：本机 HTTP 代理桥 + 各客户端接入参数。
///
/// 设计：
///   · Dart HttpClient / package:http 通过 [HttpOverrides] 自动把非本机请求
///     指向本机桥（`PROXY 127.0.0.1:<port>`）；
///   · JVM 蜘蛛通过 `-Dhttp(s).proxyHost/-Port` 指向同一个桥；
///   · Python 蜘蛛通过 `HTTP_PROXY`/`HTTPS_PROXY` 环境变量指向同一个桥；
///   · 桥再把请求转给用户配置的上游 HTTP 或 SOCKS5（含认证）。
///
/// 这样 SOCKS5、上游认证、本机地址绕过都只实现一次，所有客户端行为一致。
class ProxyRuntime {
  ProxyRuntime._();
  static final ProxyRuntime instance = ProxyRuntime._();

  ProxyConfig config = const ProxyConfig();
  ProxyBridge? _bridge;

  /// 真正在用的上游（手动配置，或从系统代理解析出来的那份）。
  ProxyConfig? _effective;
  Timer? _followRetry;
  static const _followRetryInterval = Duration(seconds: 20);

  bool get enabled => _bridge != null;
  int get bridgePort => _bridge?.port ?? 0;

  /// 当前是否在跟随系统代理（没有手动配置、且开了跟随）。
  bool get followingSystem => !config.valid && config.followSystem;

  /// 正在使用的上游描述：设置页直接显示这个，用户能看到「跟随系统代理 127.0.0.1:7897」。
  String get summary {
    final effective = _effective;
    if (effective == null || !effective.valid) {
      return config.followSystem ? '跟随系统代理（未发现可用代理）' : '直连';
    }
    final address =
        '${effective.typeLabel} ${effective.host.trim()}:${effective.port}';
    return config.valid ? address : '跟随系统代理 → $address';
  }

  /// 端口是否连得上（诊断时先探一下，避免把超时误判成代理可用）。
  Future<bool> isReachable(
    String host,
    int port, {
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> apply(ProxyConfig next) async {
    config = next;
    _followRetry?.cancel();
    _followRetry = null;
    await _restart();
    // Clash / v2rayN 常常比本应用晚启动：先空跑，拿到系统代理后自动接上。
    if (followingSystem && _bridge == null) {
      _followRetry = Timer.periodic(_followRetryInterval, (_) {
        unawaited(_restart());
      });
    }
  }

  Future<void> _restart() async {
    final manual = config.valid ? config : null;
    final resolved = manual ?? await _systemProxy();
    // 上游没变就别重建桥：重建会换端口，正在跑的隧道/请求会被打断，
    // 表现出来就是「封面偶尔加载不出来」这种随机失败。
    final current = _effective;
    if (_bridge != null &&
        current != null &&
        resolved != null &&
        current.type == resolved.type &&
        current.host == resolved.host &&
        current.port == resolved.port &&
        current.username == resolved.username &&
        current.password == resolved.password) {
      return;
    }
    final old = _bridge;
    _bridge = null;
    _effective = resolved;
    await old?.stop();
    if (resolved != null && resolved.valid) {
      try {
        _bridge = await ProxyBridge.start(resolved);
      } catch (_) {
        _bridge = null;
      }
    }
    if (_bridge != null) {
      _followRetry?.cancel();
      _followRetry = null;
    }
    final upstreamLabel = resolved == null ? '无' : resolved.summary;
    AppLog.i('proxy', '代理状态：$summary（上游=$upstreamLabel，桥端口=$bridgePort）');
  }

  /// 读系统代理：环境变量优先，其次 Windows 的「局域网设置」。
  Future<ProxyConfig?> _systemProxy() async {
    if (!config.followSystem) return null;
    final fromEnv = SystemProxy.fromEnvironment(Platform.environment);
    if (fromEnv != null) return fromEnv;
    AppLog.i('proxy', '环境变量里没有代理，继续读 Windows 系统代理');
    if (!Platform.isWindows) return null;
    try {
      const key =
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      final enable = await _regValue(key, 'ProxyEnable');
      final server = await _regValue(key, 'ProxyServer');
      return SystemProxy.fromWindowsSettings(
        proxyEnable: enable == '0x1' || enable == '1',
        proxyServer: server,
      );
    } catch (_) {
      // 读不到注册表就当没有系统代理
      return null;
    }
  }

  Future<String> _regValue(String key, String name) async {
    final result = await Process.run('reg', ['query', key, '/v', name]);
    final text = '${result.stdout}';
    final match = RegExp(RegExp.escape(name) + r'\s+REG_\w+\s+(.+)')
        .firstMatch(text);
    return (match?.group(1) ?? '').trim();
  }

  static bool isLocalHost(String host) {
    final h = host.trim().toLowerCase();
    return h.isEmpty ||
        h == 'localhost' ||
        h == '127.0.0.1' ||
        h == '::1' ||
        h == '0.0.0.0';
  }

  /// 给 `HttpClient.findProxy` 的返回值。
  String proxyFor(Uri uri) {
    if (!enabled || isLocalHost(uri.host)) return 'DIRECT';
    return 'PROXY 127.0.0.1:$bridgePort';
  }

  static bool _overridesInstalled = false;

  /// 安装全局 HttpOverrides。必须在创建任何 HttpClient 之前调用一次。
  static void installHttpOverrides() {
    if (_overridesInstalled) return;
    _overridesInstalled = true;
    HttpOverrides.global = ProxyHttpOverrides();
  }

  /// 代理自检：给设置页一个「到底哪层坏了」的结论，而不是让用户猜。
  Future<List<String>> diagnose() async {
    final lines = <String>['当前状态：$summary'];
    final upstream = _effective;
    if (upstream == null || !upstream.valid) {
      lines.add('没有可用代理：先在 Clash / v2rayN 打开「系统代理」，或在这里填手动代理。');
    } else {
      try {
        final socket = await Socket.connect(
          upstream.host,
          upstream.port,
          timeout: const Duration(seconds: 5),
        );
        socket.destroy();
        lines.add('代理端口 ${upstream.host}:${upstream.port} 可连接 ✓');
      } catch (_) {
        lines.add('代理端口 ${upstream.host}:${upstream.port} 连不上 ✗（代理没启动或端口不对）');
      }
    }
    try {
      final resolved = await InternetAddress.lookup('api.themoviedb.org')
          .timeout(const Duration(seconds: 5));
      lines.add(
        describeTmdbDns(
          addresses: [for (final item in resolved) item.address],
          proxyActive: _bridge != null,
        ),
      );
    } catch (_) {
      lines.add('api.themoviedb.org 解析失败（当前 DNS 不可用）。');
    }
    return lines;
  }

  List<String> get jvmProps {
    if (!enabled) return const [];
    final port = bridgePort;
    return [
      '-Dhttp.proxyHost=127.0.0.1',
      '-Dhttp.proxyPort=$port',
      '-Dhttps.proxyHost=127.0.0.1',
      '-Dhttps.proxyPort=$port',
      '-Dhttp.nonProxyHosts=localhost|127.0.0.1',
      '-Dhttps.nonProxyHosts=localhost|127.0.0.1',
    ];
  }

  Map<String, String> get pythonEnv {
    if (!enabled) return const {};
    final url = 'http://127.0.0.1:$bridgePort';
    return {
      'HTTP_PROXY': url,
      'HTTPS_PROXY': url,
      'ALL_PROXY': url,
      'http_proxy': url,
      'https_proxy': url,
      'all_proxy': url,
      'NO_PROXY': '127.0.0.1,localhost,::1',
      'no_proxy': '127.0.0.1,localhost,::1',
    };
  }

  Future<void> shutdown() async {
    _followRetry?.cancel();
    _followRetry = null;
    final old = _bridge;
    _bridge = null;
    _effective = null;
    await old?.stop();
  }
}

class ProxyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) => ProxyRuntime.instance.proxyFor(uri);
    return client;
  }
}

/// 本机 HTTP 代理桥：接收 HTTP 代理请求，再按配置转发到上游 HTTP/SOCKS5。
class ProxyBridge {
  ProxyBridge._(this._server, this._config) {
    _server.listen((socket) {
      unawaited(_handle(socket));
    }, onError: (Object _) {});
  }

  final ServerSocket _server;
  final ProxyConfig _config;
  static const _timeout = Duration(seconds: 20);

  int get port => _server.port;

  static Future<ProxyBridge> start(ProxyConfig config) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return ProxyBridge._(server, config);
  }

  Future<void> stop() async {
    try {
      await _server.close();
    } catch (_) {}
  }

  Future<void> _handle(Socket client) async {
    try {
      client.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    final reader = _SocketReader(client);
    try {
      final header = await reader.readUntil('\r\n\r\n', timeout: _timeout);
      if (header == null) {
        await _reply(client, 400, 'Bad Request');
        return;
      }
      final lines = header.split('\r\n');
      final parts = lines.first.split(' ');
      if (parts.length < 3) {
        await _reply(client, 400, 'Bad Request');
        return;
      }
      final method = parts[0].toUpperCase();
      final target = parts[1];

      if (method == 'CONNECT') {
        final hp = _splitHostPort(target, 443);
        if (hp == null) {
          await _reply(client, 400, 'Bad CONNECT target');
          return;
        }
        final upstream = await _connectTunnel(hp.$1, hp.$2);
        if (upstream == null) {
          await _reply(client, 502, 'Proxy connect failed');
          return;
        }
        client.add(utf8.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
        await client.flush();
        _tunnel(client, reader, upstream);
        return;
      }

      final targetInfo = _targetOf(target, lines);
      if (targetInfo == null) {
        await _reply(client, 400, 'Bad target');
        return;
      }
      final upstream = await _connectHttp(
        targetInfo.$1,
        targetInfo.$2,
        method: method,
        target: target,
        lines: lines,
      );
      if (upstream == null) {
        await _reply(client, 502, 'Proxy connect failed');
        return;
      }
      // 普通 HTTP 不做双向隧道：强制上游 Connection: close，等响应读完后
      // 一次性写给客户端并关掉。双向 keep-alive 很容易让 HttpClient 收到
      // 「unsolicited response」——尤其 SOCKS5 上联时。
      try {
        final contentLength = _contentLength(lines);
        final body = reader.takeBuffer();
        if (contentLength > body.length) {
          final rest = await reader.readExact(
            contentLength - body.length,
            timeout: _timeout,
          );
          if (rest != null) body.addAll(rest);
        }
        if (body.isNotEmpty) upstream.socket.add(Uint8List.fromList(body));
        final response = await upstream.reader.readHttpResponse(
          timeout: _timeout,
        );
        client.add(_rewriteResponseConnection(response));
        await client.flush();
      } finally {
        try {
          await client.close();
        } catch (_) {}
        try {
          upstream.socket.destroy();
        } catch (_) {}
      }
    } catch (e) {
      try {
        await _reply(client, 502, 'Proxy error');
      } catch (_) {}
    }
  }

  void _tunnel(Socket client, _SocketReader clientReader, _Upstream upstream) {
    var finished = 0;
    void closeAll() {
      try {
        client.destroy();
      } catch (_) {}
      try {
        upstream.socket.destroy();
      } catch (_) {}
    }

    void onDirectionDone() {
      finished++;
      if (finished >= 2) closeAll();
    }

    // 两个方向各自泵数据，任一侧先结束都不动另一侧（见 pipeTo 的注释）。
    unawaited(
      clientReader
          .pipeTo(upstream.socket, closeDestination: false)
          .whenComplete(onDirectionDone),
    );
    unawaited(
      upstream.reader
          .pipeTo(client, closeDestination: false)
          .whenComplete(onDirectionDone),
    );
  }

  Future<_Upstream?> _connectTunnel(String host, int port) async {
    // 本机目标（JVM 的 /chunk、本地 relay 等）一律直连，绝不走上游代理。
    if (ProxyRuntime.isLocalHost(host)) return _directConnect(host, port);
    if (_config.isSocks5) {
      return _socks5Connect(host, port);
    }
    final socket = await Socket.connect(
      _config.host,
      _config.port,
      timeout: _timeout,
    );
    final reader = _SocketReader(socket);
    final auth = _proxyAuthHeader;
    socket.add(
      utf8.encode(
        'CONNECT $host:$port HTTP/1.1\r\n'
        'Host: $host:$port\r\n'
        '${auth == null ? '' : 'Proxy-Authorization: $auth\r\n'}'
        '\r\n',
      ),
    );
    await socket.flush();
    final resp = await reader.readUntil('\r\n\r\n', timeout: _timeout);
    if (resp == null || !_isSuccess(resp)) {
      socket.destroy();
      return null;
    }
    return _Upstream(socket, reader);
  }

  Future<_Upstream?> _connectHttp(
    String host,
    int port, {
    required String method,
    required String target,
    required List<String> lines,
  }) async {
    Socket socket;
    _SocketReader reader;
    final headers = lines.sublist(1);
    final direct = ProxyRuntime.isLocalHost(host);
    if (direct) {
      final up = await _directConnect(host, port);
      if (up == null) return null;
      socket = up.socket;
      reader = up.reader;
    } else if (_config.isSocks5) {
      final up = await _socks5Connect(host, port);
      if (up == null) return null;
      socket = up.socket;
      reader = up.reader;
    } else {
      socket = await Socket.connect(
        _config.host,
        _config.port,
        timeout: _timeout,
      );
      reader = _SocketReader(socket);
    }
    final out = StringBuffer();
    // 直连/SOCKS5 使用 origin-form；上游 HTTP 代理必须保留 absolute-form。
    out.write(
      '${direct || _config.isSocks5 ? '$method ${_originForm(target)}' : '$method $target'} HTTP/1.1\r\n',
    );
    var hasHost = false;
    for (final line in headers) {
      final lower = line.toLowerCase();
      if (lower.startsWith('proxy-authorization:') ||
          lower.startsWith('proxy-connection:') ||
          lower.startsWith('connection:')) {
        continue;
      }
      if (lower.startsWith('host:')) hasHost = true;
      out.write('$line\r\n');
    }
    if (!hasHost) out.write('Host: $host:$port\r\n');
    if (!direct && !_config.isSocks5) {
      final auth = _proxyAuthHeader;
      if (auth != null) out.write('Proxy-Authorization: $auth\r\n');
      out.write('Proxy-Connection: close\r\n');
    }
    out.write('Connection: close\r\n\r\n');
    socket.add(utf8.encode(out.toString()));
    await socket.flush();
    return _Upstream(socket, reader);
  }

  Future<_Upstream?> _directConnect(String host, int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: _timeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      return _Upstream(socket, _SocketReader(socket));
    } catch (_) {
      socket?.destroy();
      return null;
    }
  }

  Future<_Upstream?> _socks5Connect(String host, int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        _config.host,
        _config.port,
        timeout: _timeout,
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      final reader = _SocketReader(socket);
      final hasAuth =
          _config.username.isNotEmpty || _config.password.isNotEmpty;

      socket.add([5, hasAuth ? 2 : 1, 0, if (hasAuth) 2]);
      await socket.flush();
      final greet = await reader.readExact(2, timeout: _timeout);
      if (greet == null || greet[0] != 5) {
        socket.destroy();
        return null;
      }
      // 服务端可能挑「无认证」（0x00）或「用户名/密码」（0x02），按协商结果走。
      if (greet[1] == 2) {
        if (!hasAuth) {
          socket.destroy();
          return null;
        }
        final user = utf8.encode(_config.username);
        final pass = utf8.encode(_config.password);
        socket.add([1, user.length, ...user, pass.length, ...pass]);
        await socket.flush();
        final auth = await reader.readExact(2, timeout: _timeout);
        if (auth == null || auth[0] != 1 || auth[1] != 0) {
          socket.destroy();
          return null;
        }
      } else if (greet[1] != 0) {
        socket.destroy();
        return null;
      }
      final name = utf8.encode(host);
      socket.add([
        5,
        1,
        0,
        3,
        name.length,
        ...name,
        (port >> 8) & 0xff,
        port & 0xff,
      ]);
      await socket.flush();
      final rep = await reader.readExact(4, timeout: _timeout);
      if (rep == null || rep[0] != 5 || rep[1] != 0) {
        socket.destroy();
        return null;
      }
      int addrLen;
      if (rep[3] == 1) {
        addrLen = 4;
      } else if (rep[3] == 4) {
        addrLen = 16;
      } else if (rep[3] == 3) {
        final len = await reader.readExact(1, timeout: _timeout);
        if (len == null) {
          socket.destroy();
          return null;
        }
        addrLen = len[0];
      } else {
        socket.destroy();
        return null;
      }
      final tail = await reader.readExact(addrLen + 2, timeout: _timeout);
      if (tail == null) {
        socket.destroy();
        return null;
      }
      return _Upstream(socket, reader);
    } catch (_) {
      socket?.destroy();
      return null;
    }
  }

  String? get _proxyAuthHeader {
    if (_config.username.isEmpty && _config.password.isEmpty) return null;
    final token = base64Encode(
      utf8.encode('${_config.username}:${_config.password}'),
    );
    return 'Basic $token';
  }

  static bool _isSuccess(String header) {
    final first = header.split('\r\n').first.split(' ');
    final code = first.length > 1 ? int.tryParse(first[1]) : null;
    return code != null && code >= 200 && code < 300;
  }

  static Future<void> _reply(Socket socket, int code, String message) async {
    try {
      socket.add(
        utf8.encode(
          'HTTP/1.1 $code ${message.isEmpty ? '' : message}\r\n'
          'Content-Length: 0\r\nConnection: close\r\n\r\n',
        ),
      );
      await socket.flush();
    } catch (_) {}
    try {
      await socket.close();
    } catch (_) {}
  }

  static int _contentLength(List<String> lines) {
    for (final line in lines) {
      if (line.toLowerCase().startsWith('content-length:')) {
        return int.tryParse(line.substring(15).trim()) ?? 0;
      }
    }
    return 0;
  }

  /// 桥在写完响应后会关连接，所以必须把上游的 `Connection: keep-alive`
  /// 改成 `Connection: close`；否则 Dart HttpClient 会复用这条已经关闭的
  /// 代理连接，收到任何残留字节就报 `unsolicited response`。
  static Uint8List _rewriteResponseConnection(Uint8List raw) {
    final headerEnd = _indexOfBytes(raw, const [13, 10, 13, 10]);
    if (headerEnd < 0) return raw;
    final header = utf8.decode(raw.sublist(0, headerEnd), allowMalformed: true);
    final lines = <String>[];
    for (final line in header.split('\r\n')) {
      final lower = line.toLowerCase();
      if (lower.startsWith('connection:') ||
          lower.startsWith('proxy-connection:')) {
        continue;
      }
      lines.add(line);
    }
    lines.add('Connection: close');
    final headerBytes = utf8.encode('${lines.join('\r\n')}\r\n\r\n');
    return Uint8List.fromList([...headerBytes, ...raw.sublist(headerEnd + 4)]);
  }

  static int _indexOfBytes(List<int> data, List<int> needle) {
    if (needle.isEmpty || data.length < needle.length) return -1;
    for (var i = 0; i <= data.length - needle.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (data[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  static String _originForm(String target) {
    final uri = Uri.tryParse(target);
    if (uri == null || !uri.hasScheme) {
      return target.startsWith('/') ? target : '/$target';
    }
    final path = uri.path.isEmpty ? '/' : uri.path;
    return uri.hasQuery ? '$path?${uri.query}' : path;
  }

  /// 返回 `(host, port)`；绝对 URL 或 `Host` 头都支持。
  static (String, int)? _targetOf(String target, List<String> lines) {
    final uri = Uri.tryParse(target);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
      return (uri.host, port);
    }
    for (final line in lines) {
      if (line.toLowerCase().startsWith('host:')) {
        return _splitHostPort(line.substring(5).trim(), 80);
      }
    }
    return null;
  }

  static (String, int)? _splitHostPort(String target, int defaultPort) {
    var value = target.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('[')) {
      final end = value.indexOf(']');
      if (end < 0) return null;
      final host = value.substring(1, end);
      final rest = value.substring(end + 1);
      final port = rest.startsWith(':')
          ? int.tryParse(rest.substring(1))
          : defaultPort;
      return (host, port ?? defaultPort);
    }
    final idx = value.lastIndexOf(':');
    if (idx < 0) return (value, defaultPort);
    final host = value.substring(0, idx);
    final port = int.tryParse(value.substring(idx + 1));
    if (host.isEmpty || port == null) return null;
    return (host, port);
  }
}

class _Upstream {
  const _Upstream(this.socket, this.reader);
  final Socket socket;
  final _SocketReader reader;
}

/// 单次监听的 socket 读取器：支持按分隔符/定长读取，读完后可把剩余字节
/// 继续灌给对端，避免 `Socket.listen` 被注册两次导致丢数据。
class _SocketReader {
  _SocketReader(this.socket) {
    _sub = socket.listen(
      (data) {
        _buffer.addAll(data);
        _wakeUp();
      },
      onDone: () {
        _done = true;
        _wakeUp();
      },
      onError: (Object error) {
        _error = error;
        _done = true;
        _wakeUp();
      },
      cancelOnError: true,
    );
  }

  final Socket socket;
  final List<int> _buffer = [];
  bool _done = false;
  Object? _error;
  Completer<void>? _wake;
  StreamSubscription<List<int>>? _sub;

  void _wakeUp() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> _wait() {
    if (_done) return Future.value();
    final wake = _wake;
    if (wake != null) return wake.future;
    final created = Completer<void>();
    _wake = created;
    return created.future;
  }

  Future<List<int>?> readExact(
    int count, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (_buffer.length < count) {
      if (_done) return null;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      await _wait().timeout(left, onTimeout: () {});
      if (_error != null) return null;
    }
    final out = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return out;
  }

  Future<String?> readUntil(
    String delimiter, {
    Duration timeout = const Duration(seconds: 20),
    int max = 128 * 1024,
  }) async {
    final needle = utf8.encode(delimiter);
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final index = _indexOf(needle);
      if (index >= 0) {
        final end = index + needle.length;
        final out = utf8.decode(_buffer.sublist(0, end), allowMalformed: true);
        _buffer.removeRange(0, end);
        return out;
      }
      if (_done || _buffer.length > max) return null;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      await _wait().timeout(left, onTimeout: () {});
      if (_error != null) return null;
    }
  }

  int _indexOf(List<int> needle) {
    if (needle.isEmpty || _buffer.length < needle.length) return -1;
    for (var i = 0; i <= _buffer.length - needle.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (_buffer[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  /// 取出当前已缓冲的字节（不含后续数据）。
  List<int> takeBuffer() {
    final out = List<int>.from(_buffer);
    _buffer.clear();
    return out;
  }

  /// 读到本端关闭为止，返回完整响应。
  Future<Uint8List> readAll({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    final out = <int>[];
    while (true) {
      if (_buffer.isNotEmpty) {
        out.addAll(_buffer);
        _buffer.clear();
      }
      if (_done) break;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) break;
      await _wait().timeout(left, onTimeout: () {});
      if (_error != null) break;
    }
    if (_buffer.isNotEmpty) {
      out.addAll(_buffer);
      _buffer.clear();
    }
    return Uint8List.fromList(out);
  }

  /// 读一个完整的 HTTP 响应：按 Content-Length / chunked 终止符判断结束，
  /// 不依赖服务端主动关连接（Cloudflare 等会无视 Connection: close 保持
  /// keep-alive，靠 readAll 会一直等到超时，chunked 还会缺终止块）。
  Future<Uint8List> readHttpResponse({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final header = await readUntil('\r\n\r\n', timeout: timeout);
    if (header == null) return Uint8List(0);
    final out = <int>[...utf8.encode(header)];
    final lower = header.toLowerCase();
    if (lower.contains('transfer-encoding: chunked')) {
      while (true) {
        final line = await readUntil('\r\n', timeout: timeout);
        if (line == null) break;
        out.addAll(utf8.encode(line));
        final sizeText = line.split(';').first.trim();
        final size = int.tryParse(sizeText, radix: 16) ?? 0;
        if (size == 0) {
          final tail = await readUntil('\r\n', timeout: timeout);
          if (tail != null) out.addAll(utf8.encode(tail));
          break;
        }
        final data = await readExact(size + 2, timeout: timeout);
        if (data == null) break;
        out.addAll(data);
      }
    } else {
      final length = ProxyBridge._contentLength(header.split('\r\n'));
      if (length > 0) {
        final body = await readExact(length, timeout: timeout);
        if (body != null) out.addAll(body);
      } else {
        out.addAll(await readAll(timeout: timeout));
      }
    }
    return Uint8List.fromList(out);
  }

  /// 把缓冲区和后续字节写给对端。
  ///
  /// [closeDestination] 只在**普通转发**时为 true；隧道里必须传 false ——
  /// Dart 的 `Socket.close()` 是整条连接一起关（没有 half-close），
  /// 上传方向读完就关会顺手把下载方向掐断，表现就是服务端/客户端侧的
  /// 「Connection closed before full header」「handshake terminated」这类随机失败。
  Future<void> pipeTo(
    Socket destination, {
    bool closeDestination = true,
  }) async {
    if (_buffer.isNotEmpty) {
      destination.add(Uint8List.fromList(_buffer));
      _buffer.clear();
      try {
        await destination.flush();
      } catch (_) {}
    }
    while (!_done) {
      await _wait();
      if (_buffer.isNotEmpty) {
        destination.add(Uint8List.fromList(_buffer));
        _buffer.clear();
        try {
          await destination.flush();
        } catch (_) {}
      }
    }
    if (_error != null) {
      try {
        destination.destroy();
      } catch (_) {}
    } else if (closeDestination) {
      try {
        await destination.close();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }
}

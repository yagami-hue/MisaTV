import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/file_url.dart';
import 'esm_transform.dart';
import 'js_bootstrap.dart';

/// 后台 JS 蜘蛛执行器：一个独立 isolate，内部为每个站点维护一个 QuickJS 运行时。
///
/// 之所以放到后台 isolate：`req()` 是同步的（内部用 curl 子进程），在 UI isolate
/// 里执行会卡住界面。isolate 里串行处理请求，互不干扰。
void jsSpiderWorkerMain(Map<String, dynamic> args) {
  final ready = ReadyPort(args['ready'] as SendPort);
  final worker = _JsWorker(
    libs: (args['libs'] as Map).map(
      (k, v) => MapEntry(k.toString(), v.toString()),
    ),
    storagePath: (args['storage'] as String?) ?? '',
  );
  final receive = ReceivePort();
  ready.send(receive.sendPort);
  worker.bind(receive);
}

class ReadyPort {
  ReadyPort(this.port);
  final SendPort port;
  void send(SendPort workerPort) =>
      port.send({'op': 'ready', 'port': workerPort});
}

class _SiteRuntime {
  _SiteRuntime({
    required this.api,
    required this.hash,
    required this.ext,
    required this.js,
  });

  final String api;
  final String hash;
  final String ext;
  final QuickJsRuntime2 js;
}

class _JsWorker {
  _JsWorker({required this.libs, required this.storagePath});

  final Map<String, String> libs;
  final String storagePath;
  final Map<String, _SiteRuntime> _runtimes = {};
  final Map<String, String> _moduleCache = {};
  final Map<String, String> _localStore = {};
  final Map<String, SendPort> _replyPorts = {};
  bool _localLoaded = false;
  int _tempSeq = 0;
  Directory? _tempDir;

  Future<void> _tail = Future.value();

  void bind(ReceivePort port) {
    port.listen((msg) {
      if (msg is! Map) return;
      _tail = _tail.then((_) => _handle(Map<String, dynamic>.from(msg)));
    });
  }

  Future<void> _handle(Map<String, dynamic> msg) async {
    final id = (msg['id'] as num?)?.toInt() ?? 0;
    final reply = msg['reply'] as SendPort?;
    if (reply != null) _replyPorts['$id'] = reply;
    try {
      final op = (msg['op'] ?? '').toString();
      if (op == 'invoke') {
        final data = await _invoke(msg);
        _send(reply, {'id': id, 'ok': true, 'data': data});
      } else if (op == 'dispose') {
        final key = (msg['key'] ?? '').toString();
        if (key.isEmpty) {
          for (final rt in _runtimes.values) {
            _safeDispose(rt.js);
          }
          _runtimes.clear();
        } else {
          final rt = _runtimes.remove(key);
          if (rt != null) _safeDispose(rt.js);
        }
        _send(reply, {'id': id, 'ok': true, 'data': ''});
      } else if (op == 'ping') {
        _send(reply, {'id': id, 'ok': true, 'data': 'pong'});
      } else {
        _send(reply, {'id': id, 'ok': false, 'error': '未知操作 $op'});
      }
    } catch (e) {
      _send(reply, {'id': id, 'ok': false, 'error': '$e'});
    } finally {
      _replyPorts.remove('$id');
    }
  }

  void _send(SendPort? port, Map<String, dynamic> msg) => port?.send(msg);

  void _safeDispose(QuickJsRuntime2 js) {
    try {
      js.dispose();
    } catch (_) {
      // isolate 内引擎释放失败不影响后续请求
    }
  }

  Future<String> _invoke(Map<String, dynamic> msg) async {
    final key = (msg['key'] ?? '').toString();
    final api = (msg['api'] ?? '').toString();
    final ext = (msg['ext'] ?? '').toString();
    final script = msg['script'] as String?;
    final scriptHash = (msg['hash'] ?? '').toString();
    final action = (msg['action'] ?? '').toString();
    final args = msg['args'];
    _applySeed(msg['seed']);

    var rt = _runtimes[key];
    if (rt == null ||
        rt.api != api ||
        rt.hash != scriptHash ||
        rt.ext != ext ||
        script != null) {
      if (script == null) {
        throw StateError('蜘蛛脚本未就绪');
      }
      if (rt != null) _safeDispose(rt.js);
      final cjs = transformToCjs(script, api);
      rt = _createRuntime(key, api, scriptHash, ext);
      _runtimes[key] = rt;
      final initArg = jsonEncode(ext);
      final isModule = RegExp(r'(^|[\n;])\s*(import|export)\b')
          .hasMatch(script);
      final res = rt.js.evaluate(
        '__kniephosInitSpider(${jsonEncode(cjs)}, ${jsonEncode(api)}, ${jsonEncode(initArg)}, $isModule)',
        name: 'kniephos:init',
      );
      final raw = _unwrap(res);
      final decoded = jsonDecode(raw is String ? raw : '$raw');
      if (decoded is Map && decoded['ok'] != true) {
        throw StateError('JS 蜘蛛加载失败：${decoded['error'] ?? raw}');
      }
    }

    final js = rt.js;
    final argLiteral = jsonEncode(args is List ? args : const []);
    final result = js.evaluate(
      '__kniephosInvoke(${jsonEncode(action)}, $argLiteral)',
      name: 'kniephos:$action',
    );
    var value = await _awaitResult(js, result);
    if (value is! String) {
      try {
        value = jsonEncode(value);
      } catch (_) {
        value = '$value';
      }
    }
    return value;
  }

  _SiteRuntime _createRuntime(
    String key,
    String api,
    String scriptHash,
    String ext,
  ) {
    // QuickJS 的解释器栈要和宿主线程栈留出余量：Windows 默认两者都是 1MB，
    // drpy2 这类深递归脚本会先撞穿线程栈，在 quickjs_c_bridge.dll 里触发
    // c0000409 / 栈溢出，整个 App 直接闪退。缩到 512KB 后 QuickJS 会在
    // 自己的栈检查里抛出可捕获的 `stack overflow`，不再拖垮进程。
    final js = QuickJsRuntime2(
      stackSize: Platform.isWindows ? 512 * 1024 : 1024 * 1024,
    );
    js.enableHandlePromises();
    final channels =
        JavascriptRuntime.channelFunctionsRegistered[js.getEngineInstanceId()]!;
    channels['__net'] = (dynamic payload) => _handleNet(payload);
    channels['__module'] = (dynamic payload) => _handleModule(payload);
    channels['__local'] = (dynamic payload) => _handleLocal(payload);
    channels['__md5'] = (dynamic payload) =>
        _hash((payload as Map)['s'], crypto.md5);
    channels['__sha1'] = (dynamic payload) =>
        _hash((payload as Map)['s'], crypto.sha1);
    channels['__sha256'] = (dynamic payload) =>
        _hash((payload as Map)['s'], crypto.sha256);
    channels['__b64e'] = (dynamic payload) =>
        base64.encode(utf8.encode(((payload as Map)['s'] ?? '').toString()));
    channels['__b64d'] = (dynamic payload) =>
        _b64Decode(((payload as Map)['s'] ?? '').toString());
    js.evaluate(spiderJsBootstrap, name: 'kniephos:bootstrap');
js.evaluate(
  "if (typeof globalThis.SpiderDebug === 'undefined') { "
  "globalThis.SpiderDebug = { "
  "log: function() { try { if (typeof console !== 'undefined' && console.log) console.log.apply(console, arguments); } catch (_) {} }, "
  "info: function() { try { if (typeof console !== 'undefined' && (console.info || console.log)) (console.info || console.log).apply(console, arguments); } catch (_) {} }, "
  "warn: function() { try { if (typeof console !== 'undefined' && (console.warn || console.log)) (console.warn || console.log).apply(console, arguments); } catch (_) {} }, "
  "error: function() { try { if (typeof console !== 'undefined' && (console.error || console.log)) (console.error || console.log).apply(console, arguments); } catch (_) {} } "
  "}; }",
  name: 'kniephos:spider_debug',
);
    return _SiteRuntime(api: api, hash: scriptHash, ext: ext, js: js);
  }

  String _hash(dynamic raw, crypto.Hash hash) =>
      hash.convert(utf8.encode(raw == null ? '' : raw.toString())).toString();

  String _b64Decode(String text) {
    try {
      return utf8.decode(base64.decode(text), allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  Future<dynamic> _awaitResult(QuickJsRuntime2 js, JsEvalResult result) async {
    if (result.isError) throw StateError(result.stringResult);
    final raw = result.rawResult;
    if (raw is Future) {
      try {
        js.dispatch();
        final value = await raw.timeout(const Duration(seconds: 60));
        return value;
      } catch (e) {
        throw StateError('$e');
      }
    }
    return result.stringResult;
  }

  dynamic _unwrap(JsEvalResult res) {
    if (res.isError) throw StateError(res.stringResult);
    return res.rawResult ?? res.stringResult;
  }

  // ---------------------------------------------------------------------------
  // 宿主桥：HTTP
  // ---------------------------------------------------------------------------
  String _handleNet(dynamic payload) {
    final map = payload is Map
        ? Map<String, dynamic>.from(payload)
        : <String, dynamic>{};
    final url = (map['url'] ?? '').toString();
    if (url.isEmpty) {
      return jsonEncode({'headers': <String, String>{}, 'content': ''});
    }
    final headersRaw = map['headers'];
    final headers = <String, String>{};
    if (headersRaw is Map) {
      headersRaw.forEach((k, v) {
        if (v != null) headers[k.toString()] = v.toString();
      });
    }
    final method = (map['method'] ?? 'get').toString().toLowerCase();
    final body = (map['body'] ?? '').toString();
    final timeoutMs = (map['timeout'] as num?)?.toInt() ?? 10000;
    final charset = (map['charset'] ?? '').toString();
    final buffer = (map['buffer'] as num?)?.toInt() ?? 0;
    final redirect = (map['redirect'] as num?)?.toInt() ?? 1;

    final res = _curl(
      url: url,
      method: method,
      headers: headers,
      body: body,
      timeoutMs: timeoutMs,
      redirect: redirect != 0,
    );
    final content = _decodeContent(res.bodyBytes, charset, res.headers, buffer);
    return jsonEncode({
      'headers': res.headers,
      'content': content,
      'status': res.status,
      'ok': res.status >= 200 && res.status < 400,
      'url': url,
    });
  }

  dynamic _decodeContent(
    Uint8List bytes,
    String charset,
    Map<String, String> headers,
    int buffer,
  ) {
    if (buffer == 1) return bytes.toList();
    if (buffer == 2) return base64.encode(bytes);
    final cs = charset.isNotEmpty
        ? charset.toLowerCase()
        : _charsetFromContentType(headers['content-type'] ?? '');
    if (cs == 'gbk' || cs == 'gb2312' || cs == 'gb18030') {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        // 落到 UTF-8
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  String _charsetFromContentType(String contentType) {
    final m = RegExp(
      r'charset\s*=\s*([\w-]+)',
      caseSensitive: false,
    ).firstMatch(contentType);
    return m?.group(1)?.toLowerCase() ?? '';
  }

  // ---------------------------------------------------------------------------
  // 宿主桥：模块源码
  // ---------------------------------------------------------------------------
  String _handleModule(dynamic payload) {
    final map = payload is Map
        ? Map<String, dynamic>.from(payload)
        : <String, dynamic>{};
    final spec = (map['spec'] ?? '').toString().trim();
    final baseUrl = (map['baseUrl'] ?? '').toString();
    if (spec.isEmpty) return jsonEncode({'ok': false});

    final resolved = _resolveModule(spec, baseUrl);
    if (resolved == null) return jsonEncode({'ok': false});
    final cacheKey = resolved.key;
    final cached = _moduleCache[cacheKey];
    if (cached != null) {
      return jsonEncode({'ok': true, 'key': cacheKey, 'source': cached});
    }
    String source;
    if (resolved.source != null) {
      source = resolved.source!;
    } else {
      final res = _curl(
        url: resolved.url!,
        method: 'get',
        headers: const {'User-Agent': 'okhttp/4.12.0'},
        body: '',
        timeoutMs: 20000,
        redirect: true,
      );
      source = utf8.decode(res.bodyBytes, allowMalformed: true);
      final trimmed = source.replaceFirst('\uFEFF', '').trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith('<') ||
          trimmed.startsWith('{"code":404')) {
        return jsonEncode({'ok': false});
      }
    }
    try {
      final cjs = transformToCjs(source, cacheKey);
      _moduleCache[cacheKey] = cjs;
      return jsonEncode({'ok': true, 'key': cacheKey, 'source': cjs});
    } on EsmTransformException {
      return jsonEncode({'ok': false});
    }
  }

  _ResolvedModule? _resolveModule(String spec, String baseUrl) {
    final clean = spec.split('?').first.split('#').first;
    final base = p.basename(clean);
    // 任何 .js 说明符先按文件名命中内置库（对齐安卓 assets://js/lib 语义）
    final bundled = libs[base];
    if (bundled != null) {
      return _ResolvedModule(key: 'lib:$base', source: bundled);
    }

    if (clean.startsWith('assets://js/lib/')) {
      final name = clean.substring('assets://js/lib/'.length);
      final lib = libs[name];
      if (lib != null) return _ResolvedModule(key: 'lib:$name', source: lib);
      return _ResolvedModule(
        key: 'https://raw.githubusercontent.com/hjdhnx/dr_py/main/libs/$name',
        url: 'https://raw.githubusercontent.com/hjdhnx/dr_py/main/libs/$name',
      );
    }
    if (clean.startsWith('http://') || clean.startsWith('https://')) {
      return _ResolvedModule(key: clean, url: clean);
    }
    if (clean.startsWith('//')) {
      return _ResolvedModule(key: 'https:$clean', url: 'https:$clean');
    }

    String target;
    try {
      target = Uri.parse(baseUrl).resolve(clean).toString();
    } catch (_) {
      return null;
    }
    if (target.startsWith('file://')) {
      final file = File(filePathOf(target));
      if (!file.existsSync()) return null;
      return _ResolvedModule(key: target, source: file.readAsStringSync());
    }
    if (!target.startsWith('http')) return null;
    return _ResolvedModule(key: target, url: target);
  }

  // ---------------------------------------------------------------------------
  // 宿主桥：本地存储
  // ---------------------------------------------------------------------------
  /// 把宿主凭据写入 `local`（宿主凭据优先，保证重新授权后立即生效）。
  void _applySeed(dynamic raw) {
    if (raw is! Map || raw.isEmpty) return;
    _loadLocal();
    for (final entry in raw.entries) {
      final key = entry.key.toString();
      if (key.isEmpty) continue;
      final value = entry.value?.toString() ?? '';
      if (value.isEmpty) continue;
      _localStore[key] = value;
    }
  }

  String _handleLocal(dynamic payload) {
    final map = payload is Map
        ? Map<String, dynamic>.from(payload)
        : <String, dynamic>{};
    final op = (map['op'] ?? '').toString();
    final key = (map['key'] ?? '').toString();
    _loadLocal();
    if (op == 'get') return _localStore[key] ?? '';
    if (op == 'set') {
      _localStore[key] = (map['value'] ?? '').toString();
      _saveLocal();
      return '1';
    }
    if (op == 'del') {
      _localStore.remove(key);
      _saveLocal();
      return '1';
    }
    return '';
  }

  void _loadLocal() {
    if (_localLoaded) return;
    _localLoaded = true;
    if (storagePath.isEmpty) return;
    try {
      final file = File(storagePath);
      if (!file.existsSync()) return;
      final raw = file.readAsStringSync();
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          _localStore[k.toString()] = v?.toString() ?? '';
        });
      }
    } catch (_) {
      _localStore.clear();
    }
  }

  void _saveLocal() {
    if (storagePath.isEmpty) return;
    try {
      final file = File(storagePath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(_localStore));
    } catch (_) {
      // 存储失败不影响本次请求
    }
  }

  // ---------------------------------------------------------------------------
  // 同步 HTTP（curl 子进程）
  // ---------------------------------------------------------------------------
  _CurlResult _curl({
    required String url,
    required String method,
    required Map<String, String> headers,
    required String body,
    required int timeoutMs,
    required bool redirect,
  }) {
    // curl.exe 不会自动编码中文路径/参数（`虎牙.js` 会 404 或直接卡住），
    // 先交给 Dart 的 Uri 规范化；已存在的 %XX 转义不会被二次编码。
    final requestUrl = Uri.tryParse(url)?.toString() ?? url;
    final temp = _ensureTempDir();
    final seq = ++_tempSeq;
    final headFile = File(p.join(temp.path, 'h$seq.txt'));
    final bodyFile = File(p.join(temp.path, 'b$seq.bin'));
    File? payloadFile;
    final timeoutSec = (timeoutMs / 1000).ceil().clamp(3, 120);
    final effectiveHeaders = <String, String>{
      'User-Agent': 'okhttp/4.12.0',
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      ...headers,
    };

    List<String> buildArgs(bool insecure) {
      final args = <String>[
        '-sS',
        '--connect-timeout',
        '${timeoutSec.clamp(3, 20)}',
        '--max-time',
        '$timeoutSec',
        '-D',
        headFile.path,
        '-o',
        bodyFile.path,
        '-w',
        '\n%{http_code}',
      ];
      if (redirect) {
        args.addAll(['-L', '--max-redirs', '8']);
      }
      if (insecure) args.add('-k');
      final m = method.toLowerCase();
      if (m == 'post') {
        args.addAll(['-X', 'POST']);
      } else if (m == 'head' || m == 'header') {
        args.add('--head');
      }
      effectiveHeaders.forEach((k, v) {
        args.addAll(['-H', '$k: $v']);
      });
      if (body.isNotEmpty && m != 'head' && m != 'header') {
        final file = File(p.join(temp.path, 'd$seq.txt'));
        file.writeAsStringSync(body);
        payloadFile = file;
        args.addAll(['--data-binary', '@${file.path}']);
      }
      args.addAll(['--url', requestUrl]);
      return args;
    }

    ProcessResult? result;
    try {
      result = Process.runSync(
        'curl.exe',
        buildArgs(false),
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      final stderrText = result.stderr is List<int>
          ? utf8.decode(result.stderr as List<int>, allowMalformed: true)
          : '${result.stderr}';
      final sslFailed =
          result.exitCode != 0 &&
          (stderrText.contains('SSL') || stderrText.contains('certificate'));
      if (sslFailed) {
        result = Process.runSync(
          'curl.exe',
          buildArgs(true),
          stdoutEncoding: null,
          stderrEncoding: null,
        );
      }
    } catch (_) {
      result = null;
    }

    var status = 0;
    var exitCode = -1;
    var stderrText = '';
    if (result != null) {
      exitCode = result.exitCode;
      stderrText = result.stderr is List<int>
          ? utf8.decode(result.stderr as List<int>, allowMalformed: true)
          : '${result.stderr}';
      final out = result.stdout is List<int>
          ? utf8.decode(result.stdout as List<int>, allowMalformed: true)
          : '${result.stdout}';
      final idx = out.lastIndexOf('\n');
      if (idx >= 0) status = int.tryParse(out.substring(idx + 1).trim()) ?? 0;
    }
    if (result == null || exitCode != 0 || status == 0) {
      debugPrint(
        'JS curl 失败 exit=$exitCode status=$status url=$requestUrl stderr=${stderrText.trim()}',
      );
    }

    Uint8List bytes = Uint8List(0);
    try {
      if (bodyFile.existsSync()) bytes = bodyFile.readAsBytesSync();
    } catch (_) {
      bytes = Uint8List(0);
    }
    var headerText = '';
    try {
      if (headFile.existsSync()) {
        headerText = utf8.decode(
          headFile.readAsBytesSync(),
          allowMalformed: true,
        );
      }
    } catch (_) {
      headerText = '';
    }

    try {
      if (headFile.existsSync()) headFile.deleteSync();
      if (bodyFile.existsSync()) bodyFile.deleteSync();
      payloadFile?.deleteSync();
    } catch (_) {
      // 临时文件清理失败忽略
    }

    return _CurlResult(
      status: status,
      headers: _parseHeaders(headerText),
      bodyBytes: bytes,
    );
  }

  Map<String, String> _parseHeaders(String raw) {
    final blocks = raw.split(RegExp(r'\r?\n\r?\n'));
    String last = '';
    for (final block in blocks) {
      if (block.trim().isEmpty) continue;
      if (block.toLowerCase().contains('http/')) last = block;
    }
    final out = <String, String>{};
    for (final line in last.split(RegExp(r'\r?\n'))) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim().toLowerCase();
      final value = line.substring(idx + 1).trim();
      if (key.isNotEmpty) out[key] = value;
    }
    return out;
  }

  Directory _ensureTempDir() {
    final cached = _tempDir;
    if (cached != null && cached.existsSync()) return cached;
    final dir = Directory(
      p.join(
        Directory.systemTemp.path,
        'kniephos_js_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    dir.createSync(recursive: true);
    _tempDir = dir;
    return dir;
  }
}

class _ResolvedModule {
  _ResolvedModule({required this.key, this.source, this.url});
  final String key;
  final String? source;
  final String? url;
}

class _CurlResult {
  _CurlResult({
    required this.status,
    required this.headers,
    required this.bodyBytes,
  });
  final int status;
  final Map<String, String> headers;
  final Uint8List bodyBytes;
}

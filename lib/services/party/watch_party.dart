import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/logging/app_log.dart';
import '../lan/lan_server.dart';
import 'party_room.dart';

/// 「一起看」：房主把播放状态发布到局域网，观众轮询跟随。
///
/// 房主权威：只有房主的进度会被广播，观众不会反向覆盖，避免多人拖动冲突。
class WatchPartyService extends ChangeNotifier {
  WatchPartyService({
    required this.deviceName,
    required this.server,
  });

  final String Function() deviceName;
  final LanServer Function() server;

  bool hosting = false;
  bool joined = false;

  String roomCode = '';
  String hostName = '';
  String hostUrl = '';
  List<String> hostAddresses = const [];

  /// 房主最近发出的状态（展示「正在同步」用）。
  PartyState? lastPublished;

  /// 观众收到的房主状态。
  PartyState? remote;

  String lastError = '';

  Timer? _poll;
  int _pollFailures = 0;
  int _lastPublishAt = 0;

  bool get active => hosting || joined;
  String get myName => deviceName();

  /// 创建房间（会顺带启动局域网服务）。
  Future<String> startHost() async {
    final lan = server();
    final port = await lan.start();
    final code = _newRoomCode();
    lan.party
      ..code = code
      ..hostName = myName
      ..revision = 0
      ..state = null;
    hosting = true;
    joined = false;
    remote = null;
    roomCode = code;
    hostName = myName;
    lastError = '';
    final addresses = await lan.lanAddresses();
    hostAddresses = [
      for (final ip in addresses) 'http://$ip:$port',
    ];
    hostUrl = hostAddresses.isEmpty
        ? 'http://127.0.0.1:$port'
        : hostAddresses.first;
    _poll?.cancel();
    _poll = null;
    notifyListeners();
    AppLog.i('party', '创建一起看房间：$code @ $hostUrl');
    return code;
  }

  /// 加入房间；[baseUrl] 允许只填 `192.168.1.5:9979`。
  Future<void> join({required String baseUrl, required String code}) async {
    final base = normalizeLanBase(baseUrl);
    final room = code.trim().toUpperCase();
    if (base.isEmpty) throw const FormatException('请填写房主地址');
    if (room.isEmpty) throw const FormatException('请填写房间码');
    final url =
        '$base/party?code=${Uri.encodeQueryComponent(room)}';
    final data = await LanClient.getJson(url);
    if (data['ok'] != true) {
      throw const FormatException('房间不存在或已经关闭');
    }
    final rawState = data['state'];
    remote = rawState is Map
        ? PartyState.fromJson(Map<String, dynamic>.from(rawState))
        : null;
    hosting = false;
    joined = true;
    roomCode = room;
    hostName = (data['host'] ?? '').toString();
    hostUrl = base;
    hostAddresses = const [];
    lastError = '';
    _pollFailures = 0;
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollOnce());
    });
    notifyListeners();
    AppLog.i('party', '加入一起看房间：$room @ $base');
  }

  /// 房主发布状态（内部按 800ms 节流，位置变化小于 1.2 秒不重复发）。
  void publish(PartyState state) {
    if (!hosting) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final previous = lastPublished;
    final unchanged =
        previous != null &&
        previous.episodeIndex == state.episodeIndex &&
        previous.episodeName == state.episodeName &&
        previous.title == state.title &&
        previous.playing == state.playing &&
        (previous.positionMs - state.positionMs).abs() < 1200;
    if (unchanged && now - _lastPublishAt < 4000) return;
    if (now - _lastPublishAt < 800) return;
    _lastPublishAt = now;
    final next = state.copyWith(updatedAt: now, sender: myName);
    lastPublished = next;
    server().party.publish(next);
  }

  /// 观众拉取房主状态。
  Future<void> _pollOnce() async {
    if (!joined || hostUrl.isEmpty || roomCode.isEmpty) return;
    try {
      final data = await LanClient.getJson(
        '$hostUrl/party?code=${Uri.encodeQueryComponent(roomCode)}',
        timeout: const Duration(seconds: 5),
      );
      _pollFailures = 0;
      if (data['ok'] != true) {
        lastError = '房间已关闭';
        notifyListeners();
        return;
      }
      if (lastError.isNotEmpty) {
        lastError = '';
        notifyListeners();
      }
      final raw = data['state'];
      if (raw is! Map) return;
      final next = PartyState.fromJson(Map<String, dynamic>.from(raw));
      final current = remote;
      if (current == null || next.updatedAt > current.updatedAt) {
        remote = next;
        lastError = '';
        notifyListeners();
      }
    } catch (e) {
      _pollFailures++;
      // 偶发丢包不打扰用户；连续失败才提示（房主可能已经关掉播放器）。
      if (_pollFailures >= 3 && lastError.isEmpty) {
        lastError = '与房主的连接中断，正在重试…';
        notifyListeners();
      }
    }
  }

  void leave() {
    if (hosting) server().party.clear();
    hosting = false;
    joined = false;
    roomCode = '';
    hostName = '';
    hostUrl = '';
    hostAddresses = const [];
    remote = null;
    lastPublished = null;
    lastError = '';
    _poll?.cancel();
    _poll = null;
    _pollFailures = 0;
    AppLog.i('party', '退出一起看');
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}

/// 归一房主地址：允许省略协议与尾部斜杠。
String normalizeLanBase(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(text)) {
    text = 'http://$text';
  }
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

/// 6 位房间码（去掉了 0/O/1/I 等容易读错的字符）。
String _newRoomCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final random = Random.secure();
  return String.fromCharCodes(
    List.generate(6, (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length))),
  );
}

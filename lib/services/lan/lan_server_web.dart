import '../party/party_room.dart';
import '../sync/sync_bundle.dart';

/// Web 版不能监听局域网端口：保留同样的接口，调用方给出可读提示。
class LanServer {
  LanServer({
    required String Function() deviceName,
    required String Function() token,
    required SyncBundle Function() snapshot,
    required Future<SyncMergeReport> Function(SyncBundle) apply,
  });
  static const int defaultPort = 9979;

  final PartyRoom party = PartyRoom();

  bool get running => false;
  int get port => 0;
  int get lastSyncAt => 0;

  Future<int> start({int port = defaultPort}) =>
      throw UnsupportedError('浏览器版不能开局域网同步服务，请使用桌面版');

  Future<void> stop() async {}

  Future<List<String>> lanAddresses() async => const [];

  Map<String, dynamic> toJson() => const {};
}

class LanClient {
  LanClient._();

  static Future<Map<String, dynamic>> getJson(
    String url, {
    Duration timeout = const Duration(seconds: 6),
  }) => throw UnsupportedError('浏览器版不能访问局域网设备');

  static Future<Map<String, dynamic>> postJson(
    String url,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 20),
  }) => throw UnsupportedError('浏览器版不能访问局域网设备');
}

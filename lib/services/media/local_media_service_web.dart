import '../../models/local_media.dart';
import '../local_store.dart';

/// Web 版不能扫描本地文件夹；保留接口，页面给出可读提示。
class LocalMediaService {
  LocalMediaService(this._store);

  final LocalStore _store;

  List<String> dirs = const [];
  List<LocalMediaFile> files = const [];
  bool scanning = false;
  String error = '';

  void load() {
    // 目录配置照常读出来展示，只是浏览器版无法扫描文件系统。
    dirs = _store.loadLocalMediaDirs();
  }

  Future<void> addDir(String raw) =>
      throw UnsupportedError('浏览器版不能扫描本地文件夹');

  Future<void> removeDir(String path) async {}

  Future<List<LocalMediaFile>> scan({int limit = 800}) async => const [];
}

String localMediaPlayUrl(String path) => '';

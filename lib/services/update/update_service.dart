import 'dart:convert';

import '../../core/app_version.dart';
import '../../core/logging/app_log.dart';
import '../../core/net/app_http.dart';

/// 一次 GitHub release 的解析结果。
class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.notes,
    required this.htmlUrl,
    this.downloadUrl = '',
    this.assetName = '',
    this.assetSize = 0,
    this.assetDigest = '',
    this.publishedAt = '',
  });

  /// 去掉 `v` 前缀的版本号，例如 `0.9.1`。
  final String version;
  final String tag;
  final String notes;
  final String htmlUrl;

  /// 直下资产地址；没有资产时为空，此时用 [htmlUrl] 打开 release 页。
  final String downloadUrl;
  final String assetName;
  final int assetSize;

  /// GitHub 资产摘要（形如 `sha256:...`）；旧 release 可能为空。
  final String assetDigest;
  final String publishedAt;

  /// 实际要打开的下载地址。
  String get openUrl => downloadUrl.isNotEmpty ? downloadUrl : htmlUrl;
}

/// 调试用：`--dart-define=MISA_UPDATE_REPO=owner/name` 可以把检查更新指向别的仓库
/// （比如 `microsoft/vscode`）来验证弹窗；不传时用 [kGithubRepo]，常量会被 tree-shake。
const String _repoOverride = String.fromEnvironment('MISA_UPDATE_REPO');
const String _devRepo = _repoOverride == '' ? kGithubRepo : _repoOverride;

/// 检查 GitHub release 是否有新版本。
///
/// 版本比较、release JSON 解析、资产挑选都是纯函数，网络部分只有 [latest]。
class UpdateService {
  UpdateService({AppHttp? http, String? repo})
    : http = http ?? AppHttp(),
      repo = repo ?? _devRepo;

  final AppHttp http;

  /// 仓库全名 `owner/name`；测试里可以指向别的仓库验证真实接口。
  final String repo;

  static const String latestUrl =
      'https://api.github.com/repos/$kGithubRepo/releases/latest';

  String get _latestUrl => 'https://api.github.com/repos/$repo/releases/latest';

  static const _headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'MisaTV-updater',
  };

  Future<Object?> _getJson(String url) async {
    try {
      final response = await http.getText(
        url,
        headers: _headers,
        timeout: const Duration(seconds: 12),
      );
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body);
    } catch (e) {
      AppLog.w('update', '请求失败（$url）：$e');
      return null;
    }
  }

  /// 取「最新版本」：先看 release，其次 release 列表，最后退回 tag。
  ///
  /// 只打 tag、不发布 release 的仓库很常见，所以不能只看 `/releases/latest`
  /// （没有 release 时它直接 404）。
  Future<AppRelease?> latest() async {
    final direct = await _getJson(_latestUrl);
    if (direct is Map) {
      return parseGithubRelease(Map<String, Object?>.from(direct));
    }

    final list = await _getJson(
      'https://api.github.com/repos/$repo/releases?per_page=10',
    );
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        final map = Map<String, Object?>.from(item);
        if (map['draft'] == true || map['prerelease'] == true) continue;
        final release = parseGithubRelease(map);
        if (release.tag.isNotEmpty) return release;
      }
    }

    final tags = await _getJson(
      'https://api.github.com/repos/$repo/tags?per_page=30',
    );
    if (tags is List) {
      String best = '';
      for (final item in tags) {
        if (item is! Map) continue;
        final name = (item['name'] ?? '').toString();
        // 只认版本形状的 tag：`weekly.2012-03-27` 这种会被当成新版本。
        if (!looksLikeVersionTag(name)) continue;
        if (best.isEmpty ||
            compareVersions(normalizeVersion(name), normalizeVersion(best)) >
                0) {
          best = name;
        }
      }
      if (best.isNotEmpty) {
        return AppRelease(
          version: normalizeVersion(best),
          tag: best,
          // tag 没有更新说明，弹窗里会显示占位文案。
          notes: '',
          htmlUrl: 'https://github.com/$repo/releases/tag/$best',
        );
      }
    }
    AppLog.i('update', '仓库里还没有 release 或 tag，跳过更新提示');
    return null;
  }

  /// 只有确实比本地新才返回 release。
  Future<AppRelease?> check() async {
    final release = await latest();
    if (release == null) return null;
    final newer = isNewer(release.version, kAppVersion);
    AppLog.i(
      'update',
      '检查更新：远端 v${release.version} / 本地 v$kAppVersion → '
          '${newer ? '有更新' : '已是最新'}',
    );
    return newer ? release : null;
  }

  static AppRelease parseGithubRelease(Map<String, Object?> json) {
    final tag = (json['tag_name'] ?? json['name'] ?? '').toString();
    final assets = json['assets'];
    final picked = assets is List
        ? pickAsset([
            for (final item in assets)
              if (item is Map) Map<String, Object?>.from(item),
          ])
        : null;
    return AppRelease(
      version: normalizeVersion(tag),
      tag: tag,
      notes: (json['body'] ?? '').toString().trim(),
      htmlUrl: (json['html_url'] ?? kReleasesUrl).toString(),
      downloadUrl: picked?.url ?? '',
      assetName: picked?.name ?? '',
      assetSize: picked?.size ?? 0,
      assetDigest: picked?.digest ?? '',
      publishedAt: (json['published_at'] ?? '').toString(),
    );
  }

  /// 挑下载资产：优先 Windows 的 zip（本项目就是桌面包），其次任意 zip、exe。
  static ({String name, String url, int size, String digest})? pickAsset(
    List<Map<String, Object?>> assets,
  ) {
    final usable = [
      for (final item in assets)
        if ((item['browser_download_url'] ?? '').toString().isNotEmpty)
          (
            name: (item['name'] ?? '').toString(),
            url: item['browser_download_url'].toString(),
            size: item['size'] is num ? (item['size'] as num).toInt() : 0,
            digest: (item['digest'] ?? '').toString(),
          ),
    ];
    if (usable.isEmpty) return null;
    bool windowsZip(String name) {
      final lower = name.toLowerCase();
      return lower.endsWith('.zip') &&
          (lower.contains('windows') || lower.contains('win'));
    }

    for (final asset in usable) {
      if (windowsZip(asset.name)) return asset;
    }
    for (final asset in usable) {
      if (asset.name.toLowerCase().endsWith('.zip')) return asset;
    }
    for (final asset in usable) {
      if (asset.name.toLowerCase().endsWith('.exe')) return asset;
    }
    return usable.first;
  }

  /// tag 是否长得像版本号：`v0.9.1` / `0.9` / `1.2.3.4` / `v1.0.0-beta.1`。
  static bool looksLikeVersionTag(String raw) =>
      RegExp(r'^[vV]?\d+(\.\d+){1,3}(-[-\w.]+)?$').hasMatch(raw.trim());

  /// `v0.9.1`、`0.9.1-beta+3` 一律归一到 `0.9.1`。
  static String normalizeVersion(String raw) {
    var text = raw.trim();
    if (text.toLowerCase().startsWith('v')) text = text.substring(1);
    final cut = text.indexOf('+');
    if (cut >= 0) text = text.substring(0, cut);
    return text.trim();
  }

  /// 比较两个版本号：a 比 b 新返回正数，旧返回负数，相等返回 0。
  ///
  /// 按点分**逐段数值**比较（0.10.0 > 0.9.9）；段数不同时短的一方补 0，
  /// 所以 `1.2` == `1.2.0`，而 `1.2.3.4` > `1.2.3`。
  /// 同号时带预发布后缀（`-beta`）的更低。
  ///
  /// 不能用「把各段拼成一个数字」的写法（如 `patch + minor*1000 + major*1e6`）：
  /// 段值超过进制时会直接判错，`1.2.1000` 与 `1.2.3` 就会倒挂。
  static int compareVersions(String a, String b) {
    (List<int>, String) split(String raw) {
      final text = normalizeVersion(raw);
      final dash = text.indexOf('-');
      final core = dash >= 0 ? text.substring(0, dash) : text;
      final pre = dash >= 0 ? text.substring(dash + 1) : '';
      final parts = <int>[];
      for (final piece in core.split('.')) {
        parts.add(int.tryParse(piece.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0);
      }
      return (parts, pre);
    }

    final (left, leftPre) = split(a);
    final (right, rightPre) = split(b);
    // 取两边较长的段数：多出来的段（1.2.3.4 的第四段）必须参与比较，
    // 否则 `1.2.3.4` 会被静默当成 `1.2.3`。
    final depth = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < depth; i++) {
      final l = i < left.length ? left[i] : 0;
      final r = i < right.length ? right[i] : 0;
      final diff = l - r;
      if (diff != 0) return diff;
    }
    if (leftPre == rightPre) return 0;
    if (leftPre.isEmpty) return 1;
    if (rightPre.isEmpty) return -1;
    return leftPre.compareTo(rightPre);
  }

  static bool isNewer(String remote, String local) =>
      compareVersions(remote, local) > 0;
}

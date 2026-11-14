/// WebDAV 存储（OpenList / AList / Nextcloud / 群晖 / 坚果云 …）的只读直连契约。
///
/// 与旧版 Win-Box 同口径：只做 **PROPFIND 列目录 + GET 取流**，不做上传/转存。
/// 服务器凭据与网盘 Cookie 一样经本机凭据加密后落盘（Windows DPAPI）。
class DavServer {
  const DavServer({
    required this.id,
    required this.name,
    required this.url,
    this.username = '',
    this.password = '',
  });

  final String id;
  final String name;

  /// 服务器基址（如 `https://host:5244/dav`）；尾斜杠在请求前归一掉。
  final String url;
  final String username;
  final String password;

  DavServer copyWith({String? name, String? url, String? username, String? password}) => DavServer(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        username: username ?? this.username,
        password: password ?? this.password,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'username': username,
        'password': password,
      };

  factory DavServer.fromJson(Map<String, dynamic> json) => DavServer(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        url: (json['url'] ?? '').toString(),
        username: (json['username'] ?? '').toString(),
        password: (json['password'] ?? '').toString(),
      );
}

/// 目录项（PROPFIND Depth:1 的一行）。
class DavEntry {
  const DavEntry({
    required this.name,
    required this.path,
    required this.url,
    required this.isDir,
    this.size = 0,
    this.mtime = '',
  });

  final String name;

  /// 服务器上的路径（URL 解码后，以 `/` 开头；相对基址）。
  final String path;

  /// 直链（绝对；播放时再包成 `/play?dav=id` 中继）。
  final String url;
  final bool isDir;
  final int size;

  /// 原始 Last-Modified 串（RFC1123；展示用）。
  final String mtime;
}

class DavBrowseResult {
  const DavBrowseResult({required this.path, required this.entries});

  /// 本次列出的目录路径（相对基址）。
  final String path;
  final List<DavEntry> entries;
}

/// 把 WebDAV 直链包成「经本地 `/play` 中继并注入 Authorization」的形式。
String wrapDavPlayUrl(String baseUrl, String url, String serverId) {
  final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || serverId.trim().isEmpty) return url;
  final query = Uri(queryParameters: {'url': url, 'dav': serverId.trim()}).query;
  return '$base/play?$query';
}

/// 该文件名是否适合内置播放器直接播（与磁力出口同口径）。
///
/// mp4/m4v/webm/ts/m3u8/flv 内联；mkv/avi/rmvb/mov… 走外部播放器接力。
bool isDavInlinePlayable(String name) {
  return RegExp(r'\.(mp4|m4v|webm|ts|m3u8|flv)$', caseSensitive: false).hasMatch((name).trim());
}

/// 该文件名是否像视频（列表图标 / 排序提示用）。
bool looksVideo(String name) {
  return RegExp(
    r'\.(mp4|m4v|mkv|avi|mov|webm|ts|m2ts|flv|rmvb|wmv|mpg|mpeg|m3u8)$',
    caseSensitive: false,
  ).hasMatch((name).trim());
}

/// 上级目录（相对基址的路径：`/a/b` → `/a`；`/a` 与 `/` → `/`）。
String davParentPath(String path) {
  final s = (path.trim().isEmpty ? '/' : path).replaceAll(RegExp(r'/+$'), '');
  if (s.isEmpty) return '/';
  final i = s.lastIndexOf('/');
  return i <= 0 ? '/' : s.substring(0, i);
}

/// 文件大小上屏（`1.2 GB` / `340 MB`）。
String davSizeLabel(int size) {
  if (size <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = size.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100 || unit == 0 ? value.round().toString() : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

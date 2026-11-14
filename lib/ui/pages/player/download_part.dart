part of '../player_page.dart';

/// 播放器「下载视频」：把当前集保存到边播缓存目录下的 downloads/。
///
/// 下载地址与播放器实际取流地址是同一条：先按播放器的规则包一层本地中继
/// （Referer / UA / Cookie / 网盘凭据都由中继注入），再交给下载任务。
/// 磁力线路则交给已有的 aria2 下载管理器，避免重复建任务。
extension _PlayerDownloadExt on _PlayerPageState {
  Future<void> _downloadCurrentVideo() async {
    final cached = _currentPlay;
    // 切集取链过程中 _currentPlay 仍指旧集，按新集重新解析，避免下错文件。
    final current = (cached != null && _currentPlayIndex == _index)
        ? cached
        : await _resolve(_index);
    if (current == null || !current.playable) {
      _toast('还没有可下载的播放地址');
      return;
    }
    if (!mounted) return;
    final rawEpisode = _index >= 0 && _index < _episodes.length
        ? _episodes[_index].url
        : '';
    if (rawEpisode.toLowerCase().startsWith('magnet:')) {
      await _downloadMagnet(rawEpisode);
      return;
    }
    if (_looksLikeDashUrl(current.url)) {
      _toast('DASH 线路暂不支持下载，请换 HLS / MP4 线路');
      return;
    }
    final prepared = _app.preparePlay(current);
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(prepared.url)) {
      _toast('当前线路不是可直接下载的地址');
      return;
    }
    final title = '${_detail.name} $_episodeName'.trim();
    final VideoDownloadTask task;
    try {
      task = _app.videoDownloads.start(
        title: title,
        url: prepared.url,
        sourceUrl: current.url,
        headers: current.headers,
        provider: _app.providerForPlay(current),
        hls: looksLikeHlsUrl(current.url) || looksLikeHlsUrl(prepared.url),
      );
    } on StateError catch (e) {
      _toast(e.message);
      return;
    }
    _toast('开始下载：$title');
    await showVideoDownloadDialog(context, title: title, task: task);
  }

  Future<void> _downloadMagnet(String magnet) async {
    final manager = _app.downloadManager;
    if (!manager.available) {
      _toast('磁力下载只在桌面版可用');
      return;
    }
    final info = parseMagnet(magnet);
    if (info == null) {
      _toast('磁力链接格式无法识别');
      return;
    }
    final existed = manager.tasks.any(
      (task) => task.infoHash == info.infoHash && !task.isFinished,
    );
    if (existed) {
      _toast('这个磁力已经在下载管理中');
      return;
    }
    try {
      await manager.add(magnet);
      _toast('已加入下载管理：${_detail.name}');
    } catch (e) {
      _toast('加入下载失败：$e');
    }
  }
}

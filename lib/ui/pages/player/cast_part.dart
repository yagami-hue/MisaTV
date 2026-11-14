part of '../player_page.dart';

/// 以下逻辑由 [player_page.dart] 的 part 拆分而来，仍可访问 State 私有成员。
extension _PlayerCastExt on _PlayerPageState {
  Future<void> _castToDevice() async {
    final current = _currentPlay;
    if (current == null || current.url.trim().isEmpty) {
      _toast('还没有可投屏的播放地址');
      return;
    }
    final app = _app;
    final source = app.preparePlay(current);
    final title = '${_detail.name} $_episodeName'.trim();
    final target = parseCastTarget(
      source.url,
      title,
      _position.inMilliseconds,
      relayBase: LocalRelay.instance.baseUrl,
      extraHeaders: source.headers,
    );
    if (target.url.trim().isEmpty) {
      _toast('当前地址无法投屏');
      return;
    }
    await showDlnaCastSheet(
      context,
      target: target,
      davAuth: (id) => app.davService.authHeader(id),
    );
  }

  /// 多集时生成 M3U 选集列表；单集或生成失败返回 null（回退单地址）。
  Future<String?> _externalPlaylistPath({String? currentUrl}) async {
    final service = _app.externalPlaylist;
    if (service == null || _episodes.length < 2) return null;
    final path = await service.createPlaylist(
      site: _site,
      flag: _flag,
      episodes: _episodes,
      currentIndex: _index,
      currentUrl: currentUrl,
    );
    if (path == null) {
      AppLog.w('player', '外部播放器选集列表生成失败，回退为单集地址');
    }
    return path;
  }

  Future<void> _showExternalPlayers() async {
    final players = detectExternalPlayers(custom: _app.customExternalPlayers);
    if (players.isEmpty) {
      if (_mpvReady) {
        await _openWithMpv();
      } else {
        _toast('未检测到外部播放器；可在 设置 → 播放 → 自定义第三方播放器 选择任意播放器 exe');
      }
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.9,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('外部播放器', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                  '用本机播放器打开当前集；多集时会把整份选集列表带过去，可在播放器片单里切集。'
                  '自定义播放器可在 设置 → 播放 中添加。',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                if (_mpvReady)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.play_circle_outline_rounded),
                    title: const Text('Yaozhi MPV（内置扩展）'),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      unawaited(_openWithMpv());
                    },
                  ),
                for (final player in players)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.play_circle_outline_rounded),
                    title: Text(player.name),
                    subtitle: Text(
                      player.isCustom
                          ? externalPlayerExists(player.path)
                                ? '自定义 · ${player.path}'
                                : '文件不存在 · ${player.path}'
                          : player.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      unawaited(_openExternal(player));
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openExternal(ExternalPlayer player) async {
    if (!externalPlayerExists(player.path)) {
      _toast('找不到 ${player.name}；请在 设置 → 播放 → 自定义第三方播放器 重新选择');
      return;
    }
    final cached = _currentPlay;
    final play =
        (cached != null && _currentPlayIndex == _index && cached.playable)
        ? cached
        : await _resolve(_index);
    if (play == null || !play.playable) {
      _toast(
        play?.message.isNotEmpty == true ? play!.message : '当前地址无法交给外部播放器',
      );
      return;
    }
    if (!await _warmUpExternalPlay(play)) return;
    try {
      await _saveProgress();
      final source = _app.preparePlay(play, forceRelay: true);
      // 多集时把整份选集列表交给外部播放器（M3U 每项回指本机中继）。
      final playlist = await _externalPlaylistPath(currentUrl: source.url);
      final ok = launchExternalPlayer(
        player.path,
        playlist ?? source.url,
        extraArgs: playlist == null
            ? externalSeekArgs(player.id, _position.inSeconds)
            : const [],
      );
      if (ok) {
        // 外部播放器拿到的是本机 /chunk 地址：之后离开本页也不能回收取流 JVM。
        _handedToExternalPlayer = true;
        _app.sourceService.jar.holdPlaybackForExternal();
        if (!mounted) return;
        _toast(
          playlist == null
              ? '已在 ${player.name} 中打开'
              : '已在 ${player.name} 中打开（共 ${_episodes.length} 集选集）',
        );
        // 外部播放器已经接手：关闭内置播放器页，避免原视频继续在后台播放/占解码器。
        unawaited(_exitPage());
        return;
      }
      _toast('启动 ${player.name} 失败');
    } catch (e) {
      _toast('$e');
    }
  }

  /// 外部播放器接手 `/chunk` 之前先做一次探针，避免 PotPlayer 的多条
  /// 连接同时触发壳内的会话竞态（详见 `JarSpiderService.warmUpLocalPlayUrl`）。
  Future<bool> _warmUpExternalPlay(PlayResult play) async {
    final url = play.url.trim();
    final isChunk = url.contains('/chunk') && url.contains('127.0.0.1');
    if (isChunk) _toast('正在准备取流地址…');
    final ok = await _app.sourceService.jar.warmUpLocalPlayUrl(url);
    if (!ok) _toast('取流地址准备失败，请重试一次');
    return ok;
  }

  String _audioLabelOf(int? index) {
    if (index == null) return '默认音轨';
    for (final option in _audioOptions) {
      if (option.index == index) return _audioLabel(option);
    }
    return '音轨 $index';
  }

  String _audioLabel(_AudioOption option) {
    final parts = <String>[];
    if (option.title.isNotEmpty) parts.add(option.title);
    final lang = _languageLabel(option.language);
    if (lang.isNotEmpty && !parts.contains(lang)) parts.add(lang);
    if (parts.isEmpty) parts.add('音轨 ${option.index + 1}');
    parts.add(option.codec.toUpperCase());
    return parts.join(' · ');
  }

  String _languageLabel(String raw) {
    final v = raw.trim().toLowerCase();
    if (v.isEmpty || v == 'und' || v == 'unknown') return '';
    if (v == 'chi' ||
        v == 'zho' ||
        v == 'chs' ||
        v == 'cht' ||
        v.startsWith('zh')) {
      return '中文';
    }
    if (v == 'eng' || v.startsWith('en')) return '英语';
    if (v == 'jpn' || v.startsWith('ja')) return '日语';
    if (v == 'kor' || v.startsWith('ko')) return '韩语';
    if (v == 'fra' || v == 'fre' || v.startsWith('fr')) return '法语';
    if (v == 'deu' || v == 'ger' || v.startsWith('de')) return '德语';
    if (v == 'spa' || v.startsWith('es')) return '西班牙语';
    if (v == 'rus' || v.startsWith('ru')) return '俄语';
    return raw;
  }

  Future<void> _showSpeed() async {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('播放速度', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final r in rates)
                    ChoiceChip(
                      label: Text('${r}x'),
                      selected: _rate == r,
                      onSelected: (_) async {
                        final app = _app;
                        Navigator.of(ctx).pop();
                        _setState(() => _rate = r);
                        await _controller?.setPlaybackSpeed(r);
                        await app.setPlayerSettings(
                          app.playerSettings.copyWith(speed: r),
                        );
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

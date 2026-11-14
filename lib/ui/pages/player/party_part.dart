part of '../player_page.dart';

/// 「一起看」：创建 / 加入局域网房间，并让观众跟随房主进度。
///
/// 房主权威：房主每 1.5 秒广播一次「第几集 + 进度 + 播放/暂停」；
/// 观众每 2 秒拉取一次，进度差超过 4 秒才 seek，避免反复抖动。
extension _PlayerPartyExt on _PlayerPageState {
  PartyState _partySnapshot() => PartyState(
    title: _detail.name,
    episodeName: _episodeName,
    episodeIndex: _index,
    positionMs: _position.inMilliseconds,
    playing: _playing,
  );

  Future<void> _showWatchParty() async {
    final party = _app.watchParty;
    if (party.active) {
      await _showPartyRoomSheet(party);
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                '一起看',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '同一 Wi-Fi 下与家人朋友同步追剧：房主控制进度，其他人自动跟随。'
                '需要先开启局域网同步服务（会自动启动）。',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: const Icon(Icons.add_rounded),
              title: const Text('创建房间'),
              subtitle: const Text('本机作为房主，生成房间码'),
              onTap: () => Navigator.of(ctx).pop('host'),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: const Icon(Icons.login_rounded),
              title: const Text('加入房间'),
              subtitle: const Text('输入房主地址与房间码'),
              onTap: () => Navigator.of(ctx).pop('join'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'host') await _startPartyHost();
    if (action == 'join') await _joinParty();
  }

  Future<void> _startPartyHost() async {
    final party = _app.watchParty;
    try {
      final code = await party.startHost();
      if (!mounted) return;
      party.publish(_partySnapshot());
      _setState(() {});
      await _showPartyRoomSheet(party);
      _toast('房间已创建：$code');
    } catch (e) {
      _toast('创建房间失败：$e');
    }
  }

  Future<void> _joinParty() async {
    final url = TextEditingController();
    final code = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('加入一起看'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: url,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '房主地址',
                  hintText: '192.168.1.10:9979',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: code,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: '房间码',
                  hintText: '6 位字母数字',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('加入'),
          ),
        ],
      ),
    );
    final target = url.text.trim();
    final room = code.text.trim();
    url.dispose();
    code.dispose();
    if (confirmed != true || !mounted) return;
    try {
      await _app.watchParty.join(baseUrl: target, code: room);
      if (!mounted) return;
      _setState(() {});
      _toast('已加入房间，正在跟随房主播放');
      _onPartyUpdate();
    } catch (e) {
      _toast('加入失败：$e');
    }
  }

  Future<void> _showPartyRoomSheet(WatchPartyService party) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: party,
          builder: (ctx, _) {
            final theme = Theme.of(ctx);
            final remote = party.remote;
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    party.hosting ? '一起看 · 房主' : '一起看 · 观众',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  _partyInfoRow(theme, '房间码', party.roomCode),
                  if (party.hosting) ...[
                    _partyInfoRow(
                      theme,
                      '本机地址',
                      party.hostAddresses.isEmpty
                          ? party.hostUrl
                          : party.hostAddresses.join('、'),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '让朋友在播放器右上角「一起看 → 加入房间」输入上面的地址与房间码。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ] else ...[
                    _partyInfoRow(
                      theme,
                      '房主',
                      party.hostName.isEmpty ? party.hostUrl : party.hostName,
                    ),
                    if (remote != null)
                      _partyInfoRow(
                        theme,
                        '正在看',
                        '${remote.title}${remote.episodeName.isEmpty ? '' : ' · ${remote.episodeName}'}',
                      ),
                    if (party.lastError.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          party.lastError,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            party.leave();
                            _setState(() {});
                            _toast('已退出一起看');
                          },
                          icon: const Icon(Icons.logout_rounded),
                          label: const Text('退出房间'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _partyInfoRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '—' : value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  /// 观众收到房主状态：切集 / 校正进度 / 跟随播放暂停。
  void _onPartyUpdate() {
    if (!mounted) return;
    final party = _app.watchParty;
    if (!party.joined) {
      _partyMismatchNotified = false;
      return;
    }
    final remote = party.remote;
    if (remote == null) return;
    if (!_samePartyShow(remote.title, _detail.name)) {
      if (!_partyMismatchNotified) {
        _partyMismatchNotified = true;
        _toast('房主正在看《${remote.title}》，请打开同一部片子再跟随');
      }
      return;
    }
    _partyMismatchNotified = false;
    if (remote.episodeIndex != _index &&
        remote.episodeIndex >= 0 &&
        remote.episodeIndex < _episodes.length &&
        !_resolving) {
      unawaited(
        _openEpisode(
          index: remote.episodeIndex,
          startMs: remote.positionMs,
        ),
      );
      _toast('房主切换到了第 ${remote.episodeIndex + 1} 集');
      return;
    }
    final controller = _controller;
    if (controller == null) return;
    final drift =
        (controller.value.position.inMilliseconds - remote.positionMs).abs();
    if (drift > 4000 && !remote.playing) {
      unawaited(controller.seekTo(Duration(milliseconds: remote.positionMs)));
    } else if (drift > 8000) {
      unawaited(controller.seekTo(Duration(milliseconds: remote.positionMs)));
    }
    if (remote.playing && !controller.value.isPlaying) {
      unawaited(controller.play());
    } else if (!remote.playing && controller.value.isPlaying) {
      unawaited(controller.pause());
    }
  }

  /// 片名宽松匹配（两边有一边包含另一边即视为同一部）。
  bool _samePartyShow(String a, String b) {
    final x = a.trim().toLowerCase();
    final y = b.trim().toLowerCase();
    if (x.isEmpty || y.isEmpty) return true;
    return x.contains(y) || y.contains(x);
  }
}

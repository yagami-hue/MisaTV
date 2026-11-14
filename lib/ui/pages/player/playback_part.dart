part of '../player_page.dart';

/// 以下逻辑由 [player_page.dart] 的 part 拆分而来，仍可访问 State 私有成员。
extension _PlayerPlaybackExt on _PlayerPageState {
  Future<void> _showPlaybackSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        Widget item({
          required IconData icon,
          required String title,
          required String subtitle,
          required VoidCallback onTap,
          bool enabled = true,
        }) => ListTile(
          enabled: enabled,
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: enabled ? const Icon(Icons.chevron_right_rounded) : null,
          onTap: enabled
              ? () {
                  Navigator.of(ctx).pop();
                  onTap();
                }
              : null,
        );
        return SafeArea(
          child: ConstrainedBox(
            // 小窗只有 480×292：整张面板必须可滚动，否则底部入口会被窗口
            // 底边裁掉，根本点不到。
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.92,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('播放设置', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  item(
                    icon: Icons.aspect_ratio_rounded,
                    title: '画面比例',
                    subtitle: _fit.label,
                    onTap: _showFit,
                  ),
                  if (_mdkEnabled)
                    item(
                      icon: Icons.audiotrack_rounded,
                      title: '音轨',
                      subtitle: _audioOptions.length > 1
                          ? _audioLabelOf(_activeAudio)
                          : '当前视频只有一条音轨',
                      enabled: _audioOptions.length > 1,
                      onTap: _showAudioTracks,
                    ),
                  item(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: '弹幕设置',
                    subtitle: _danmakuSummary(),
                    onTap: _showDanmakuPanel,
                  ),
                  item(
                    icon: Icons.open_in_new_rounded,
                    title: '外部播放器',
                    subtitle: '自动检测 + 设置中添加的播放器',
                    onTap: _showExternalPlayers,
                  ),
                  item(
                    icon: Icons.download_rounded,
                    title: '下载视频',
                    subtitle: '保存到边播缓存目录下的 downloads 文件夹',
                    onTap: _downloadCurrentVideo,
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _ephemeral,
                    onChanged: (value) {
                      _setState(() => _ephemeral = value);
                      Navigator.of(ctx).pop();
                      _toast(value ? '已开启无痕播放：本次不写观看历史' : '已关闭无痕播放');
                    },
                    secondary: const Icon(Icons.visibility_off_outlined),
                    title: const Text('无痕播放'),
                    subtitle: Text(
                      _app.playerSettings.incognito
                          ? '设置中的无痕模式已开启；这里的开关只对本次播放生效'
                          : '本次播放不写入观看历史，也不更新断点进度',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '长按画面可临时 1.5x 快进，松开恢复原倍速；长按底栏「弹幕」可单独调整速度 / 屏占 / 屏蔽词；小窗按钮在顶栏。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: 0.76,
                      ),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showFit() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('画面比例', style: Theme.of(ctx).textTheme.titleLarge),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final fit in playerFits)
                    ChoiceChip(
                      label: Text(fit.label),
                      selected: _fit == fit,
                      onSelected: (_) {
                        Navigator.of(ctx).pop();
                        unawaited(_setFit(fit));
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

  Future<void> _setFit(PlayerFit fit) async {
    if (mounted) _setState(() => _fit = fit);
    await _app.setPlayerSettings(_app.playerSettings.copyWith(fit: fit.name));
  }

  Future<void> _showAudioTracks() async {
    if (_audioOptions.length < 2) return;
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
                Text('音轨', style: Theme.of(ctx).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                  '按封装内顺序列出，语言来自媒体元数据。',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                for (final option in _audioOptions)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _activeAudio == option.index
                          ? Icons.check_circle_rounded
                          : Icons.audiotrack_rounded,
                      color: _activeAudio == option.index
                          ? Theme.of(ctx).colorScheme.primary
                          : null,
                    ),
                    title: Text(_audioLabel(option)),
                    subtitle: Text(
                      '${option.codec.toUpperCase()}'
                      '${option.channels > 0 ? ' · ${option.channels} 声道' : ''}',
                    ),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _selectAudio(option);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _selectAudio(_AudioOption option) {
    try {
      _controller?.setAudioTracks([option.index]);
      _setState(() => _activeAudio = option.index);
      _toast('已切换音轨：${_audioLabel(option)}');
    } catch (e) {
      _toast('切换音轨失败：$e');
    }
  }

  /// 进度条右键入口：单击取点，双击清除。
  ///
  /// 双击只能靠延迟确认：第一次右键按下先挂起一次取点，过了双击窗口还没等到
  /// 第二次按下才真正执行；窗口内再次按下（位置偏差在 slop 内）就取消挂起、
  /// 改为清除本资源的记录。这样不会出现「双击的第一下已经写进记录」的脏状态。
  void _onProgressSecondaryDown({required double width, required double dx}) {
    final now = DateTime.now();
    final last = _lastSecondaryTapAt;
    final isDoubleTap =
        last != null &&
        isSkipDoubleTap(
          gap: now.difference(last),
          dx: dx,
          lastDx: _lastSecondaryTapDx,
        );
    _skipTapTimer?.cancel();
    _skipTapTimer = null;
    if (isDoubleTap) {
      _lastSecondaryTapAt = null;
      unawaited(_clearSkipSegments());
      return;
    }
    _lastSecondaryTapAt = now;
    _lastSecondaryTapDx = dx;
    _skipTapTimer = Timer(skipDoubleTapWindow, () {
      _skipTapTimer = null;
      _lastSecondaryTapAt = null;
      unawaited(_pickSkipFromProgress(width: width, localDx: dx));
    });
  }

  /// 取消还没执行的右键取点（开始拖进度条或离开页面时）。
  void _cancelPendingSkipPick() {
    _skipTapTimer?.cancel();
    _skipTapTimer = null;
    _lastSecondaryTapAt = null;
  }

  /// 右键双击进度条：清掉本资源的片头 / 片尾记录，与弹窗里的「清除本资源」一致。
  Future<void> _clearSkipSegments() async {
    if (_live) return;
    if (_skipIntro <= 0 && _skipOutro <= 0) {
      _toast('当前没有片头 / 片尾记录');
      return;
    }
    await _saveSkipSegments(0, 0);
    if (!mounted) return;
    _toast('已清除本资源的片头 / 片尾记录');
  }

  /// 进度条右键：直接按点击位置选取片头 / 片尾，不再弹二次菜单。
  ///
  /// 用区间来区分两种设置，避免互相踩：开头 5 分钟内 = 片头，结尾 5 分钟内 =
  /// 片尾；不足 10 分钟的短片按前后各一半切分；中间区域只提示、不写入。
  /// 片头 = 起播直接跳到的绝对秒数；片尾 = 距结尾还剩多少秒开始跳下一集，
  /// 与「跳过片头 / 片尾」弹窗里的语义一致，选完立即落盘并对本资源全部剧集生效。
  Future<void> _pickSkipFromProgress({
    required double width,
    required double localDx,
  }) async {
    if (_live) return;
    final total = _duration.inMilliseconds;
    if (total <= 0) return;
    // Slider 的可见轨道两端各内缩 overlay 半径（上面 SliderTheme 设为 12），
    // 换算前先扣掉这段，点击位置才不会整体偏早。
    const inset = 12.0;
    final usable = width - inset * 2 > 1 ? width - inset * 2 : 1.0;
    final ratio = ((localDx - inset) / usable).clamp(0.0, 1.0);
    final picked = Duration(milliseconds: (ratio * total).round());
    final remaining = picked >= _duration ? Duration.zero : _duration - picked;

    const window = Duration(minutes: 5);
    final bool asIntro;
    if (_duration <= window * 2) {
      // 短片没有 5 分钟窗口可言：按中点分前后，一次右键照样能选到。
      asIntro = picked <= _duration ~/ 2;
    } else if (picked <= window) {
      asIntro = true;
    } else if (remaining <= window) {
      asIntro = false;
    } else {
      _toast('右键取片头 / 片尾：请在开头 5 分钟或结尾 5 分钟内点击');
      return;
    }

    if (asIntro) {
      final intro = clampSkipSeconds(picked.inSeconds);
      if (intro <= 0) {
        _toast('这个位置等于 0 秒，片头无需跳过');
        return;
      }
      await _saveSkipSegments(intro, _skipOutro);
      if (!mounted) return;
      _toast('片头已设为 ${_fmt(picked)}（本资源所有剧集）');
      if (_position.inSeconds < intro) _seekTo(Duration(seconds: intro));
      return;
    }
    final outro = clampSkipSeconds(remaining.inSeconds);
    // 片尾秒数 ≤1 时本就不会触发跳集（见 shouldSkipOutro），别写个死值进去。
    if (outro <= 1) {
      _toast('离结尾太近，请点在更靠前的位置');
      return;
    }
    await _saveSkipSegments(_skipIntro, outro);
    if (!mounted) return;
    _toast('片尾已设为 剩 ${_fmt(remaining)}（本资源所有剧集）');
  }

  /// 落盘片头 / 片尾秒数：本资源所有剧集共用一份，并同步播放器内的跳过状态。
  Future<void> _saveSkipSegments(int intro, int outro) async {
    await _app.saveSkipSegment(
      resource: '${_detail.sourceKey}|${_detail.id}',
      episode: _episodeKey(_index),
      intro: intro,
      outro: outro,
      label: _episodeName.isEmpty ? '第${_index + 1}集' : _episodeName,
    );
    if (!mounted) return;
    _setState(() {
      _skipIntro = intro;
      _skipOutro = outro;
      _skipInheritedFrom = '';
      _outroFired = false;
    });
  }

  Future<void> _showSkipSettings() async {
    final introCtrl = TextEditingController(
      text: _skipIntro > 0 ? '$_skipIntro' : '',
    );
    final outroCtrl = TextEditingController(
      text: _skipOutro > 0 ? '$_skipOutro' : '',
    );
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳过片头 / 片尾'),
        // 小窗里对话框只有 480×292 的可用空间：去掉默认的大边距，并让
        // 标题 + 内容整体可滚动，片头/片尾输入框和快捷按钮才都能操作。
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        scrollable: true,
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: StatefulBuilder(
            builder: (ctx, setDialog) {
              Widget field(TextEditingController controller, String label) =>
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: label,
                      hintText: '0 = 不跳过',
                    ),
                  );
              return LayoutBuilder(
                builder: (ctx, constraints) {
                  // 小窗还能继续缩小到 280×160：窄到并排放不下时改上下排。
                  final narrow = constraints.maxWidth < 360;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_skipInheritedFrom.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '本资源所有剧集共用该设置（当前值来自「$_skipInheritedFrom」）。',
                            style: Theme.of(ctx).textTheme.bodySmall,
                          ),
                        ),
                      if (narrow) ...[
                        field(introCtrl, '片头跳过秒数'),
                        const SizedBox(height: 10),
                        field(outroCtrl, '片尾跳过秒数'),
                      ] else
                        Row(
                          children: [
                            Expanded(child: field(introCtrl, '片头跳过秒数')),
                            const SizedBox(width: 12),
                            Expanded(child: field(outroCtrl, '片尾跳过秒数')),
                          ],
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: () {
                              introCtrl.text = '${_position.inSeconds}';
                              setDialog(() {});
                            },
                            child: Text('片头设为当前（${_fmt(_position)}）'),
                          ),
                          OutlinedButton(
                            onPressed: () {
                              final remain = _duration - _position;
                              final safe = remain.isNegative
                                  ? Duration.zero
                                  : remain;
                              outroCtrl.text = '${safe.inSeconds}';
                              setDialog(() {});
                            },
                            child: Text(
                              '片尾设为当前（剩 ${_fmt(_duration > _position ? _duration - _position : Duration.zero)}）',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '保存后对本资源所有剧集生效；片头 = 起播直接跳到该秒数，'
                        '片尾 = 距结尾还剩这么多秒时自动跳下一集。\n'
                        '进度条上右键可直接取点：开头 5 分钟算片头，结尾 5 分钟算片尾；'
                        '右键双击进度条可清除记录。',
                        style: Theme.of(ctx).textTheme.bodySmall
                            ?.copyWith(height: 1.5),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('clear'),
            child: const Text('清除本资源'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final intro = action == 'clear' ? 0 : clampSkipSeconds(introCtrl.text);
    final outro = action == 'clear' ? 0 : clampSkipSeconds(outroCtrl.text);
    introCtrl.dispose();
    outroCtrl.dispose();
    if (action == null) return;
    await _saveSkipSegments(intro, outro);
    if (!mounted) return;
    if (action == 'clear') {
      _toast('已清除该资源所有剧集的跳过设置');
      return;
    }
    _toast('已保存：片头 ${intro}s / 片尾 ${outro}s（本资源全部剧集）');
    if (intro > 0 && _position.inSeconds < intro) {
      _seekTo(Duration(seconds: intro));
    }
  }

  String _skipSummary() {
    if (_skipIntro <= 0 && _skipOutro <= 0) return '未设置';
    final parts = <String>[
      if (_skipIntro > 0) '片头 $_skipIntro 秒',
      if (_skipOutro > 0) '片尾 $_skipOutro 秒',
    ];
    final base = parts.join(' / ');
    return _skipInheritedFrom.isEmpty ? base : '$base（本资源共用）';
  }
}

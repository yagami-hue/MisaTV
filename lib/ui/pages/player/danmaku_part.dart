part of '../player_page.dart';

/// 以下逻辑由 [player_page.dart] 的 part 拆分而来，仍可访问 State 私有成员。
extension _PlayerDanmakuExt on _PlayerPageState {
  Future<void> _toggleDanmaku() async {
    if (_danmakuEnabled) {
      _danmakuSeq++;
      _setState(() => _danmakuEnabled = false);
      await _app.setDanmakuSettings(
        _app.danmakuSettings.copyWith(enabled: false),
      );
      return;
    }
    _setState(() => _danmakuEnabled = true);
    final settings = _app.danmakuSettings.copyWith(enabled: true);
    await _app.setDanmakuSettings(settings);
    if (_allDanmaku.isEmpty) await _loadDanmaku();
  }

  /// 按弹幕屏蔽词过滤（关键词包含或 `/正则/`）。
  List<DanmakuLine> _filterDanmaku(List<DanmakuLine> items) {
    final words = _app.danmakuSettings.blockWords;
    if (words.isEmpty) return items;
    return [
      for (final item in items)
        if (!isDanmakuBlocked(item.text, words)) item,
    ];
  }

  String _danmakuSummary() {
    final settings = _app.danmakuSettings;
    if (!settings.enabled) return '弹幕已关闭';
    return [
      '${(settings.regionRatio * 100).round()}% 屏',
      '${settings.speed.round()}px/s',
      if (settings.density < 0.995) '密度 ${(settings.density * 100).round()}%',
      '字号 ${settings.fontSize.toStringAsFixed(0)}',
      if (settings.blockWords.isNotEmpty) '屏蔽 ${settings.blockWords.length} 词',
    ].join(' · ');
  }

  /// 播放器内的弹幕独立调节面板：速度、密度、屏占、字号、透明度、偏移、屏蔽词。
  Future<void> _showDanmakuPanel() async {
    var settings = _app.danmakuSettings;
    final wordsCtrl = TextEditingController(
      text: settings.blockWords.join('\n'),
    );
    final result = await showModalBottomSheet<DanmakuSettings>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final theme = Theme.of(ctx);
            Widget slider(
              String label,
              String display,
              double value,
              double min,
              double max,
              int divisions,
              ValueChanged<double> onChanged,
            ) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(label, style: theme.textTheme.bodySmall),
                      const Spacer(),
                      Text(display, style: theme.textTheme.labelSmall),
                    ],
                  ),
                  Slider(
                    value: value.clamp(min, max).toDouble(),
                    min: min,
                    max: max,
                    divisions: divisions,
                    onChanged: (v) => setSheet(() => onChanged(v)),
                  ),
                ],
              );
            }

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(ctx).bottom,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('弹幕设置', style: theme.textTheme.titleLarge),
                          const Spacer(),
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('取消'),
                          ),
                          const SizedBox(width: 4),
                          FilledButton(
                            onPressed: () => Navigator.of(ctx).pop(
                              settings.copyWith(
                                blockWords: normalizeDanmakuBlockWords(
                                  wordsCtrl.text,
                                ),
                              ),
                            ),
                            child: const Text('保存'),
                          ),
                        ],
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: settings.enabled,
                        onChanged: (v) => setSheet(
                          () => settings = settings.copyWith(enabled: v),
                        ),
                        title: const Text('显示弹幕'),
                        subtitle: Text(
                          '当前可用 ${_danmaku.length} 条'
                          '${settings.blockWords.isEmpty ? '' : ' · 已屏蔽 ${_allDanmaku.length - _danmaku.length} 条'}',
                        ),
                      ),
                      slider(
                        '显示区域',
                        '${(settings.regionRatio * 100).round()}% 屏',
                        settings.regionRatio,
                        danmakuRegionMinRatio,
                        danmakuRegionMaxRatio,
                        18,
                        (v) => settings = settings.copyWith(regionRatio: v),
                      ),
                      const SizedBox(height: 8),
                      slider(
                        '滚动速度',
                        '${settings.speed.round()}px/s',
                        settings.speed,
                        40,
                        300,
                        26,
                        (v) => settings = settings.copyWith(speed: v),
                      ),
                      slider(
                        '弹幕密度',
                        '${(settings.density * 100).round()}%',
                        settings.density,
                        0.1,
                        1,
                        9,
                        (v) => settings = settings.copyWith(density: v),
                      ),
                      slider(
                        '字号',
                        '${settings.fontSize.toStringAsFixed(0)}px',
                        settings.fontSize,
                        12,
                        40,
                        28,
                        (v) => settings = settings.copyWith(fontSize: v),
                      ),
                      slider(
                        '透明度',
                        '${(settings.opacity * 100).round()}%',
                        settings.opacity,
                        0.2,
                        1,
                        8,
                        (v) => settings = settings.copyWith(opacity: v),
                      ),
                      slider(
                        '时间偏移',
                        '${settings.offset.toStringAsFixed(1)}s',
                        settings.offset,
                        -10,
                        10,
                        40,
                        (v) => settings = settings.copyWith(offset: v),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: wordsCtrl,
                        minLines: 2,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: '弹幕屏蔽词',
                          hintText: '每行一个关键词；/正则/ 写法也可',
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '关键词不区分大小写；屏蔽只影响当前弹幕层，不会改动拉取到的原始数据。',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.55,
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
      },
    );
    wordsCtrl.dispose();
    if (result == null) return;
    await _app.setDanmakuSettings(result);
    if (!mounted) return;
    _setState(() {
      _danmakuEnabled = result.enabled;
      _danmaku = _filterDanmaku(_allDanmaku);
    });
    if (result.enabled && _allDanmaku.isEmpty) await _loadDanmaku();
  }

  Future<void> _loadDanmaku() async {
    final seq = ++_danmakuSeq;
    final detail = _detail;
    final keyword = detail.name.trim();
    if (keyword.isEmpty) return;
    final episodeName = _episodeName.trim();
    final parsedEp = parseEpisodeInput(episodeName);
    final targetEp = parsedEp.ep?.trim().isNotEmpty == true
        ? parsedEp.ep!.trim()
        : '${_index + 1}';
    final season =
        parsedEp.season ?? seasonOf(detail.name) ?? seasonOf(episodeName);
    final settings = _app.danmakuSettings;
    final enabled = settings.endpoints
        .where((e) => e.enabled && e.url.trim().isNotEmpty)
        .toList();
    final broad = <DanmakuEndpoint>[...enabled];
    const broadLimit = 12;
    if (broad.length < broadLimit) {
      for (final e in settings.endpoints) {
        if (broad.length >= broadLimit) break;
        if (!e.enabled && e.url.trim().isNotEmpty) {
          broad.add(e.copyWith(enabled: true));
        }
      }
    }

    try {
      var broadTried = false;
      var candidates = await _app.danmakuService.search(
        keyword,
        season: season,
      );
      if (!mounted || seq != _danmakuSeq) return;
      if (candidates.isEmpty && broad.length > enabled.length) {
        broadTried = true;
        _toast('主弹幕源未命中，正在扩大搜索…');
        candidates = await _app.danmakuService.search(
          keyword,
          endpoints: broad,
          season: season,
        );
        if (!mounted || seq != _danmakuSeq) return;
      }
      if (candidates.isEmpty) {
        _toast('没有找到「$keyword」的弹幕；可在设置 → 弹幕接口启用更多源');
        return;
      }

      Future<({DanmakuCandidate candidate, List<DanmakuItem> items})?>
      fetchFirst() async {
        final ranked = DanmakuService.rankCandidates(
          candidates,
          keyword,
          season: season,
          ep: targetEp,
        );
        final exact = ranked
            .where((c) => candidateMatchesEp(c, targetEp))
            .toList();
        final noEp = ranked.where((c) => epNumberOf(c) == null).toList();
        final rest = ranked
            .where(
              (c) => !candidateMatchesEp(c, targetEp) && epNumberOf(c) != null,
            )
            .toList();
        final picks = <DanmakuCandidate>{
          ...exact,
          ...noEp,
          ...rest,
        }.take(3).toList();
        Future<({DanmakuCandidate candidate, List<DanmakuItem> items})>
        fetchOne(DanmakuCandidate candidate) async {
          try {
            final items = await _app.danmakuService.fetch(
              candidate,
              timeout: const Duration(seconds: 20),
            );
            return (candidate: candidate, items: items);
          } catch (_) {
            return (candidate: candidate, items: const <DanmakuItem>[]);
          }
        }

        if (picks.isEmpty) return null;
        // 最佳候选先单独拉：命中就立刻上屏；空了再并发试其余候选。
        final first = await fetchOne(picks.first);
        if (first.items.isNotEmpty) return first;
        if (picks.length > 1) {
          final restResults = await Future.wait(picks.skip(1).map(fetchOne));
          for (final result in restResults) {
            if (result.items.isNotEmpty) return result;
          }
        }
        return null;
      }

      var hit = await fetchFirst();
      if ((hit == null) && !broadTried && broad.length > enabled.length) {
        broadTried = true;
        _toast('已找到条目但没有可用弹幕，正在换源重试…');
        candidates = await _app.danmakuService.search(
          keyword,
          endpoints: broad,
          season: season,
        );
        if (!mounted || seq != _danmakuSeq) return;
        if (candidates.isNotEmpty) hit = await fetchFirst();
      }
      if (!mounted || seq != _danmakuSeq) return;
      if (hit == null) {
        _toast('已找到条目，但第 $targetEp 集没有可用弹幕；可在设置 → 弹幕接口启用更多源');
        return;
      }

      final items = hit.items;
      final all = [
        for (final item in items)
          DanmakuLine(
            time: item.time,
            type: item.type,
            text: item.text,
            size: item.size,
            color: item.color,
          ),
      ];
      _setState(() {
        _allDanmaku = all;
        _danmaku = _filterDanmaku(all);
        _danmakuEnabled = true;
      });
      _toast('弹幕已加载 ${items.length} 条（${hit.candidate.sourceName}）');
    } catch (e) {
      if (mounted) _toast('弹幕加载失败：$e');
    }
  }

  Future<void> _showSubtitlePanel() async {
    final detail = _detail;
    final file = await showSubtitlePanel(
      context,
      service: _app.subtitleService,
      query: SubtitleQuery(
        title: detail.name,
        year: int.tryParse(detail.year),
        episode: _index + 1,
        rawName: _episodeName,
      ),
      currentName: _subtitleStatus,
      onClear: _clearSubtitle,
    );
    if (file == null) return;
    await _applySubtitle(file);
  }

  Future<void> _applySubtitle(SubtitleFile file) async {
    final controller = _controller;
    if (controller == null) {
      _toast('播放器还没准备好，稍后再试');
      return;
    }
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'subtitles'))
        ..createSync(recursive: true);
      final ext = switch (file.format.toLowerCase()) {
        'ass' || 'ssa' => 'ass',
        'vtt' => 'vtt',
        _ => 'srt',
      };
      final target = File(
        p.join(
          dir.path,
          'current-${DateTime.now().millisecondsSinceEpoch}.$ext',
        ),
      );
      await target.writeAsString(file.text);
      controller.setExternalSubtitle(target.path);
      final active = controller.getActiveSubtitleTracks();
      if (active == null || active.isEmpty) {
        controller.setSubtitleTracks(const [0]);
        final retry = controller.getActiveSubtitleTracks();
        if (retry == null || retry.isEmpty) {
          controller.setSubtitleTracks(const [1]);
        }
      }
      if (!mounted) return;
      _setState(() => _subtitleStatus = file.name.isEmpty ? '外挂字幕' : file.name);
      _toast('字幕已载入：$_subtitleStatus');
    } catch (e) {
      _toast('字幕挂载失败（当前内核可能不支持外挂字幕）：$e');
    }
  }

  void _clearSubtitle() {
    try {
      _controller?.setExternalSubtitle('');
      _controller?.setSubtitleTracks(const []);
    } catch (_) {
      // 非 fvp 内核忽略
    }
    if (mounted) _setState(() => _subtitleStatus = '');
  }
}

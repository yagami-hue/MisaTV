import 'package:flutter/material.dart';

import '../app.dart';
import '../models/site_config.dart';
import '../models/vod.dart';
import 'open_player.dart';
import 'pages/player_page.dart';

/// 用内置播放器打开一组「外来直链」（WebDAV 目录里的文件 / 磁力流等）。
///
/// 这些地址不属于任何订阅源，所以造一个最小会话：剧名 = 列表标题，
/// 线路 = 目录（或磁力）名，每一集就是一条直链；播放/换集仍走既有播放器与历史记录。
Future<void> openRawPlayback(
  BuildContext context, {
  required String title,
  required String subtitle,
  required List<Episode> episodes,
  int initialIndex = 0,
  String sourceKey = 'local',
  String flag = '本机',
  Map<String, String> headers = const {},
}) async {
  if (episodes.isEmpty) return;
  final index = initialIndex.clamp(0, episodes.length - 1);
  final detail = VodDetail(
    id: title,
    name: title,
    flags: [flag],
    episodes: {flag: episodes},
    sourceKey: sourceKey,
  );
  final site = SourceBean(key: sourceKey, name: subtitle, type: 0, api: '');
  final app = AppScope.of(context);
  await openVodPlayer(
    context,
    app,
    PlayerSession(
      detail: detail,
      site: site,
      flag: flag,
      episodeIndex: index,
      episodes: episodes,
      initialPlay: PlayResult(
        url: episodes[index].url,
        headers: headers,
      ),
      ephemeral: true,
    ),
  );
}

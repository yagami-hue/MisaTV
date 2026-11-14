import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/player_fit.dart';
import 'package:kniephos/models/user_data.dart';
import 'package:kniephos/services/player/external_players.dart';
import 'package:kniephos/services/player/skip_segments.dart';

void main() {
  group('PlayerFit / PlayerSettings', () {
    test('非法画面比例回落到适应', () {
      expect(normalizePlayerFit('cover'), PlayerFit.cover);
      expect(normalizePlayerFit('bad'), PlayerFit.contain);
      expect(normalizePlayerFit(null), PlayerFit.contain);
      expect(playerFitLabel('ratio169'), '强制 16:9');
    });

    test('独立窗口设置：沉浸观影模式下强制不生效', () {
      final popOut = PlayerSettings.fromJson({'popOutPlayer': true});
      expect(popOut.effectivePopOutPlayer, isTrue, reason: '普通模式按设置弹出');
      expect(
        popOut.copyWith(immersiveMode: true).effectivePopOutPlayer,
        isFalse,
        reason: '沉浸观影是独占全屏，独立窗口一律不弹',
      );
      expect(
        popOut
            .copyWith(immersiveMode: true)
            .copyWith(immersiveMode: false)
            .effectivePopOutPlayer,
        isTrue,
        reason: '退出沉浸观影后设置自动恢复',
      );
      expect(PlayerSettings.fromJson({}).effectivePopOutPlayer, isFalse);
    });

    test('设置 JSON 往返保留画面比例与性能开关', () {
      final settings = PlayerSettings.fromJson({
        'speed': 1.25,
        'fit': 'cover',
        'volume': 0.6,
        'jsWorkerPool': true,
        'keepSpiderHosts': true,
        'autoSwitchLine': true,
        'magnetDownloadDir': r'D:\BT下载',
        'externalPlayers': [
          {'name': '我的 VLC', 'path': r'D:\Tools\vlc.exe'},
          {'name': '', 'path': r'D:\Tools\vlc.exe'},
          {'name': 'PotPlayer', 'path': r'D:\Player\PotPlayerMini64.exe'},
        ],
        'defaultPlayer': 'custom:D:\\Tools\\vlc.exe',
        'immersiveMode': true,
        'popOutPlayer': true,
        'artworkPriority': 'tmdb',
        'tmdbApiKey': 'tmdb-key',
        'bossKey': 'alt+q',
      });
      expect(settings.fit, 'cover');
      expect(settings.jsWorkerPool, isTrue);
      expect(settings.keepSpiderHosts, isTrue);
      expect(settings.autoSwitchLine, isTrue);
      expect(settings.magnetDownloadDir, r'D:\BT下载');
      expect(settings.immersiveMode, isTrue);
      expect(settings.popOutPlayer, isTrue);
      expect(settings.artworkPriority, 'tmdb');
      expect(settings.tmdbApiKey, 'tmdb-key');
      expect(settings.bossKey, 'alt+q');
      // 默认不占用任何全局热键：只有用户显式选择才生效。
      expect(PlayerSettings.fromJson({}).bossKey, kUnsetBossKey);
      // 未知值不再回落到某个默认组合（那等于替用户抢一个热键）。
      expect(PlayerSettings.fromJson({'bossKey': 'bogus'}).bossKey, kUnsetBossKey);
      // 旧版本的 'off' 归一到「未设置」。
      expect(PlayerSettings.fromJson({'bossKey': 'OFF'}).bossKey, kUnsetBossKey);
      expect(bossKeyLabel('f12'), 'F12');
      expect(bossKeyLabel(kUnsetBossKey), '未设置');
      expect(isBossKeySet(kUnsetBossKey), isFalse);
      expect(isBossKeySet('f12'), isTrue);
      expect(settings.toJson()['bossKey'], 'alt+q');
      // TMDB 两个凭据各存各的：v3 Key 走 query、v4 Token 走 Authorization 头。
      final tmdb = PlayerSettings.fromJson({
        'tmdbApiKey': '0123456789abcdef0123456789abcdef',
        'tmdbReadToken': 'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ4In0.sig',
      });
      expect(tmdb.tmdbApiKey, '0123456789abcdef0123456789abcdef');
      expect(tmdb.tmdbReadToken, 'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ4In0.sig');
      expect(tmdb.toJson()['tmdbReadToken'], tmdb.tmdbReadToken);
      expect(
        tmdb.copyWith(tmdbReadToken: '').tmdbReadToken,
        isEmpty,
        reason: '清空令牌不能把旧值留下',
      );
      expect(PlayerSettings.fromJson({}).tmdbReadToken, isEmpty);
      expect(normalizeArtworkPriority('IMDB'), 'imdb');
      expect(PlayerSettings.fromJson({}).immersiveMode, isFalse);
      expect(PlayerSettings.fromJson({}).popOutPlayer, isFalse);
      expect(PlayerSettings.fromJson({}).artworkPriority, 'douban');
      expect(
        PlayerSettings.fromJson({'artworkPriority': 'bogus'}).artworkPriority,
        'douban',
      );
      expect(PlayerSettings.fromJson({}).autoSwitchLine, isFalse);
      expect(PlayerSettings.fromJson({}).magnetDownloadDir, isEmpty);
      expect(settings.defaultPlayer, r'custom:D:\Tools\vlc.exe');
      expect(settings.defaultCustomPlayerPathValue, r'D:\Tools\vlc.exe');
      expect(
        settings.copyWith(defaultPlayer: 'bad').defaultPlayer,
        kDefaultPlayerBuiltin,
      );
      expect(
        settings.copyWith(defaultPlayer: kDefaultPlayerYaozhiMpv).defaultPlayer,
        kDefaultPlayerYaozhiMpv,
      );
      expect(settings.externalPlayers.length, 2, reason: '同一路径只保留第一个');
      expect(settings.externalPlayers.first.name, '我的 VLC');
      expect(settings.copyWith(volume: 0.2).fit, 'cover');
      expect(settings.copyWith(fit: 'bad').fit, 'bad');
      expect(settings.toJson()['fit'], 'cover');
      expect(settings.toJson()['jsWorkerPool'], isTrue);
      expect(settings.toJson()['keepSpiderHosts'], isTrue);
      expect(settings.toJson()['autoSwitchLine'], isTrue);
      expect(settings.toJson()['magnetDownloadDir'], r'D:\BT下载');
      expect(settings.toJson()['defaultPlayer'], r'custom:D:\Tools\vlc.exe');
      expect((settings.toJson()['externalPlayers'] as List).first, {
        'name': '我的 VLC',
        'path': r'D:\Tools\vlc.exe',
      });
    });

    test('直播详情指标独立保存，未知项过滤，旧配置用默认值', () {
      final settings = PlayerSettings.fromJson({
        'overlayMetrics': ['title', 'episode', 'bogus'],
        'liveOverlayMetrics': ['title', 'group', 'epg', 'bogus'],
        'overlayFontSize': 16,
      });
      expect(settings.overlayMetrics, ['title', 'episode']);
      expect(settings.liveOverlayMetrics, ['title', 'group', 'epg']);
      expect(settings.overlayFontSize, 16);

      final back = PlayerSettings.fromJson(settings.toJson());
      expect(back.liveOverlayMetrics, settings.liveOverlayMetrics);
      expect(
        PlayerSettings.fromJson({}).liveOverlayMetrics,
        kDefaultLivePlayerOverlayMetrics,
      );
    });
  });

  group('跳过片头 / 片尾', () {
    test('右键双击判定：时间窗口 + 位置容差', () {
      // 窗口内、位置几乎不动 → 双击（清除记录）。
      expect(
        isSkipDoubleTap(
          gap: const Duration(milliseconds: 120),
          dx: 300,
          lastDx: 302,
        ),
        isTrue,
      );
      // 间隔超过 300ms → 两次独立单击，否则连设片头 / 片尾会被误判成清除。
      expect(
        isSkipDoubleTap(
          gap: const Duration(milliseconds: 420),
          dx: 300,
          lastDx: 300,
        ),
        isFalse,
      );
      // 位置偏差超出容差 → 独立单击。
      expect(
        isSkipDoubleTap(
          gap: const Duration(milliseconds: 80),
          dx: 300,
          lastDx: 340,
        ),
        isFalse,
      );
      // 恰好卡在窗口与容差边界上仍算命中。
      expect(
        isSkipDoubleTap(gap: skipDoubleTapWindow, dx: 324, lastDx: 300),
        isTrue,
      );
    });

    test('秒数归一：负数 / 非法 / 超上限', () {
      expect(clampSkipSeconds(-1), 0);
      expect(clampSkipSeconds('abc'), 0);
      expect(clampSkipSeconds(90), 90);
      expect(clampSkipSeconds(skipSecMax + 100), skipSecMax);
    });

    test('所有集都使用资源最近一次设置', () {
      var store = <String, SkipRecord>{};
      store = putSkipRecord(
        store,
        'src|1',
        '第2集',
        const SkipSegment(intro: 80, outro: 30),
        label: '第2集',
        nowMs: 100,
      );
      store = putSkipRecord(
        store,
        'src|1',
        '第3集',
        const SkipSegment(intro: 60, outro: 20),
        label: '第3集',
        nowMs: 200,
      );

      // 旧数据里第 2 集自己的记录也不能再挡住资源级设置。
      final second = resolveSkip(store, 'src|1', '第2集');
      expect(second?.intro, 60);
      expect(second?.outro, 20);
      expect(second?.inheritedFrom, '第3集');

      final third = resolveSkip(store, 'src|1', '第3集');
      expect(third?.intro, 60);
      expect(third?.inheritedFrom, '');

      final fourth = resolveSkip(store, 'src|1', '第4集');
      expect(fourth?.intro, 60);
      expect(fourth?.inheritedFrom, '第3集');
    });

    test('保存资源设置会覆盖该资源所有集的旧记录', () {
      var store = <String, SkipRecord>{};
      store = putSkipRecord(
        store,
        'src|1',
        '第1集',
        const SkipSegment(intro: 40),
        nowMs: 1,
      );
      store = putSkipRecord(
        store,
        'src|1',
        '第2集',
        const SkipSegment(intro: 50),
        nowMs: 2,
      );
      store = putSkipRecord(
        store,
        'src|2',
        '第1集',
        const SkipSegment(intro: 60),
        nowMs: 1,
      );
      store = putResourceSkipRecord(
        store,
        'src|1',
        '第3集',
        const SkipSegment(intro: 80, outro: 15),
        label: '第3集',
        nowMs: 3,
      );

      expect(store.keys.where((key) => key.startsWith('src|1|')).length, 1);
      for (final episode in ['第1集', '第2集', '第3集', '第4集']) {
        final resolved = resolveSkip(store, 'src|1', episode);
        expect(resolved?.intro, 80);
        expect(resolved?.outro, 15);
      }
      expect(resolveSkip(store, 'src|2', '第1集')?.intro, 60);
    });

    test('清除资源设置会移除该资源所有集的记录', () {
      var store = <String, SkipRecord>{};
      store = putSkipRecord(
        store,
        'src|1',
        '第1集',
        const SkipSegment(intro: 10),
        nowMs: 1,
      );
      store = putSkipRecord(
        store,
        'src|1',
        '第2集',
        const SkipSegment(intro: 20),
        nowMs: 2,
      );
      store = putSkipRecord(
        store,
        'src|2',
        '第1集',
        const SkipSegment(intro: 30),
        nowMs: 1,
      );
      store = putResourceSkipRecord(
        store,
        'src|1',
        '第1集',
        const SkipSegment(),
        nowMs: 3,
      );

      expect(store.keys.where((key) => key.startsWith('src|1|')), isEmpty);
      expect(resolveSkip(store, 'src|1', '第2集'), isNull);
      expect(resolveSkip(store, 'src|2', '第1集')?.intro, 30);
    });

    test('两项都为 0 = 清除本集记录', () {
      var store = putSkipRecord(
        <String, SkipRecord>{},
        'src|1',
        '第1集',
        const SkipSegment(intro: 10, outro: 10),
        nowMs: 1,
      );
      expect(store.length, 1);
      store = putSkipRecord(
        store,
        'src|1',
        '第1集',
        const SkipSegment(),
        nowMs: 2,
      );
      expect(store, isEmpty);
    });

    test('不同资源互不继承', () {
      final store = putSkipRecord(
        <String, SkipRecord>{},
        'src|1',
        '第1集',
        const SkipSegment(intro: 10),
        nowMs: 1,
      );
      expect(resolveSkip(store, 'src|2', '第1集'), isNull);
    });

    test('片尾触发点', () {
      expect(shouldSkipOutro(1000, 60000, 0, false), isFalse);
      expect(shouldSkipOutro(1000, 60000, 10, false), isFalse);
      expect(shouldSkipOutro(50000, 60000, 10, false), isTrue);
      expect(shouldSkipOutro(50000, 60000, 10, true), isFalse);
      expect(shouldSkipOutro(5000, 0, 10, false), isFalse);
    });
  });

  group('外部播放器探测', () {
    test('候选路径包含常见播放器', () {
      final list = playerCandidates({
        'ProgramFiles': r'C:\Program Files',
        'ProgramFiles(x86)': r'C:\Program Files (x86)',
        'LOCALAPPDATA': r'C:\Users\a\AppData\Local',
      });
      expect(list.any((p) => p.id == 'potplayer'), isTrue);
      expect(list.any((p) => p.id == 'vlc'), isTrue);
      expect(list.any((p) => p.id == 'mpv'), isTrue);
      expect(list.any((p) => p.id == 'mpc-hc'), isTrue);
    });

    test('只保留真实存在且同路径不重复', () {
      const candidates = [
        ExternalPlayer(id: 'a', name: 'A', path: r'C:\a.exe'),
        ExternalPlayer(id: 'b', name: 'B', path: r'C:\b.exe'),
        ExternalPlayer(id: 'a', name: 'A', path: r'C:\A.exe'),
        ExternalPlayer(id: 'c', name: 'C', path: r'C:\c.exe'),
      ];
      final list = pickPlayers(
        candidates,
        (path) => path.toLowerCase() != r'c:\b.exe',
      );
      expect(list.length, 2);
      expect(list.map((p) => p.path).toList(), [r'C:\a.exe', r'C:\c.exe']);
    });

    test('起播参数按播放器区分', () {
      expect(externalSeekArgs('potplayer', 3725), ['/seek=1:02:05']);
      expect(externalSeekArgs('vlc', 90), ['--start-time=90']);
      expect(externalSeekArgs('mpv', 90), ['--start=90']);
      expect(externalSeekArgs('mpc-hc', 90), isEmpty);
      expect(externalSeekArgs('vlc', 0), isEmpty);
    });

    test('自定义播放器按 exe 文件名推断类型与显示名', () {
      expect(
        externalPlayerKind(r'D:\Tools\PotPlayer\PotPlayerMini64.exe'),
        'potplayer',
      );
      expect(externalPlayerKind(r'D:\Apps\vlc.exe'), 'vlc');
      expect(externalPlayerKind(r'D:\Apps\mpvnet.exe'), 'mpv');
      expect(externalPlayerKind(r'D:\Apps\mpc-hc64.exe'), 'mpc-hc');
      expect(externalPlayerKind(r'D:\Apps\MyPlayer.exe'), 'custom');
      expect(externalPlayerDisplayName(r'D:\Apps\MyPlayer.exe'), 'MyPlayer');
      expect(externalPlayerDisplayName(''), '播放器');
      expect(externalSeekArgs(externalPlayerKind(r'D:\Apps\vlc.exe'), 90), [
        '--start-time=90',
      ]);
    });
  });
}

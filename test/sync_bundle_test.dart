import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/download_task.dart';
import 'package:kniephos/models/sync_settings.dart';
import 'package:kniephos/models/user_data.dart';
import 'package:kniephos/services/player/skip_segments.dart';
import 'package:kniephos/services/sync/history_sync.dart';
import 'package:kniephos/services/sync/sync_bundle.dart';

HistoryItem _history({
  required String key,
  required int updatedAt,
  int positionMs = 1000,
}) => HistoryItem(
  key: key,
  name: key,
  updatedAt: updatedAt,
  positionMs: positionMs,
);

FavoriteItem _favorite({
  required String key,
  required int updatedAt,
  String title = '',
}) => FavoriteItem(
  key: key,
  name: key,
  createdAt: updatedAt,
  updatedAt: updatedAt,
  title: title,
);

void main() {
  group('同步包序列化', () {
    test('往返保持历史版本、收藏与片头片尾', () {
      final bundle = SyncBundle(
        exportedAt: 123,
        deviceName: '客厅',
        history: HistorySyncSnapshot(
          items: [_history(key: 'a|1', updatedAt: 5000)],
          itemVersions: {'a|1': '0000000000005000|dev:1'},
          deletedVersions: {'a|2': '0000000000004000|dev:2'},
          clearVersion: '0000000000003000|dev:3',
        ),
        favorites: [_favorite(key: 'a|1', updatedAt: 6000, title: '片名')],
        skips: {
          'a|1|第1集': const SkipRecord(intro: 90, outro: 30, at: 7000),
        },
      );
      final restored = SyncBundle.fromJson(bundle.toJson());
      expect(restored.deviceName, '客厅');
      expect(restored.history.items.single.key, 'a|1');
      expect(restored.history.itemVersions['a|1'], '0000000000005000|dev:1');
      expect(restored.history.deletedVersions['a|2'], isNotNull);
      expect(restored.history.clearVersion, '0000000000003000|dev:3');
      expect(restored.favorites.single.title, '片名');
      expect(restored.skips['a|1|第1集']?.intro, 90);
    });

    test('坏数据不炸：缺字段按空包处理', () {
      final bundle = SyncBundle.fromJson(const {});
      expect(bundle.isEmpty, isTrue);
      expect(bundle.history.items, isEmpty);
    });
  });

  group('收藏合并', () {
    test('更新的覆盖本地，旧的忽略', () {
      final result = mergeSyncFavorites(
        [_favorite(key: 'a', updatedAt: 100), _favorite(key: 'b', updatedAt: 100)],
        [_favorite(key: 'a', updatedAt: 200, title: '新'), _favorite(key: 'b', updatedAt: 50)],
      );
      expect(result.changed, 1);
      expect(result.items.firstWhere((e) => e.key == 'a').title, '新');
    });

    test('本地没有的新增', () {
      final result = mergeSyncFavorites(
        const [],
        [_favorite(key: 'x', updatedAt: 1)],
      );
      expect(result.changed, 1);
      expect(result.items.single.key, 'x');
    });
  });

  group('片头片尾合并', () {
    test('按写入时间取新', () {
      final local = {
        'r|1': const SkipRecord(intro: 10, outro: 0, at: 100),
      };
      final result = mergeSyncSkips(local, {
        'r|1': const SkipRecord(intro: 20, outro: 5, at: 200),
        'r|2': const SkipRecord(intro: 0, outro: 0, at: 50),
      });
      // 两个都为 0 的记录会被 normalize 过滤，这里手动构造的仍按规则比较。
      expect(result.changed, 2);
      expect(result.items['r|1']?.intro, 20);
      expect(result.items['r|1']?.outro, 5);
    });

    test('旧记录不覆盖新记录', () {
      final local = {
        'r|1': const SkipRecord(intro: 30, at: 300),
      };
      final result = mergeSyncSkips(local, {
        'r|1': const SkipRecord(intro: 10, at: 100),
      });
      expect(result.changed, 0);
      expect(result.items['r|1']?.intro, 30);
    });
  });

  group('历史事件还原', () {
    test('版本号原样重建，墓碑与清空都保留', () {
      final snapshot = HistorySyncSnapshot(
        items: [_history(key: 'a', updatedAt: 5000)],
        itemVersions: {'a': HistorySyncVersion.of(updatedAt: 5000, eventId: 'dev:9')},
        deletedVersions: {
          'b': HistorySyncVersion.of(updatedAt: 4000, eventId: 'dev:8'),
        },
        clearVersion: HistorySyncVersion.of(updatedAt: 3000, eventId: 'dev:7'),
      );
      final events = historyEventsOf(snapshot);
      expect(events.length, 3);
      final upsert = events.firstWhere((e) => e.op == HistorySyncOp.upsert);
      expect(upsert.version, HistorySyncVersion.of(updatedAt: 5000, eventId: 'dev:9'));
      final delete = events.firstWhere((e) => e.op == HistorySyncOp.delete);
      expect(delete.version, HistorySyncVersion.of(updatedAt: 4000, eventId: 'dev:8'));
      final clear = events.firstWhere((e) => e.op == HistorySyncOp.clearAll);
      expect(clear.version, HistorySyncVersion.of(updatedAt: 3000, eventId: 'dev:7'));
    });

    test('删除过的条目不会被旧快照复活', () {
      final deleted = HistorySyncVersion.of(updatedAt: 9000, eventId: 'dev:d');
      final merged = mergeHistory(
        current: [_history(key: 'a', updatedAt: 5000)],
        incoming: historyEventsOf(
          HistorySyncSnapshot(
            items: [_history(key: 'a', updatedAt: 5000, positionMs: 999)],
            itemVersions: {'a': HistorySyncVersion.of(updatedAt: 5000, eventId: 'dev:old')},
            deletedVersions: {'a': deleted},
          ),
        ),
      );
      expect(merged.items, isEmpty);
      expect(merged.deletedVersions['a'], deleted);
    });
  });

  group('同步设置归一', () {
    test('远端路径补前导斜杠并去尾斜杠', () {
      expect(SyncSettings.normalizeRemotePath('MisaTV/sync.json'), '/MisaTV/sync.json');
      expect(SyncSettings.normalizeRemotePath('/a/b/'), '/a/b');
      expect(SyncSettings.normalizeRemotePath('   '), SyncSettings.defaultRemotePath);
    });

    test('配对码是 8 位且不含易混字符', () {
      final token = newSyncPairingToken();
      expect(token.length, 8);
      expect(RegExp(r'^[A-HJ-NP-Z2-9]{8}$').hasMatch(token), isTrue);
    });
  });

  group('下载任务解析', () {
    test('BT 任务取种子名与进度', () {
      final task = DownloadTask.fromJson({
        'gid': 'g1',
        'status': 'active',
        'totalLength': '1000',
        'completedLength': '250',
        'downloadSpeed': '1024',
        'bittorrent': {
          'info': {'name': '测试种子'},
        },
      });
      expect(task.title, '测试种子');
      expect(task.progress, 0.25);
      expect(task.isActive, isTrue);
      expect(formatDownloadSpeed(1024), '1.0 KB/s');
      expect(formatDownloadSize(1536), '1.5 KB');
    });
  });
}

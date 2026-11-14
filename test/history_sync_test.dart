import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/user_data.dart';
import 'package:kniephos/services/sync/history_sync.dart';

HistoryItem _h(String key, {int updatedAt = 1000, int position = 0}) =>
    HistoryItem(
      key: key,
      name: key,
      updatedAt: updatedAt,
      sourceKey: key.split('|').first,
      vodId: key.split('|').last,
      positionMs: position,
      durationMs: 100000,
    );

HistorySyncEvent _upsert(HistoryItem item, {String id = 'd:1'}) =>
    HistorySyncEvent.fromItem(item, deviceId: 'd', seq: int.tryParse(id.split(':').last) ?? 1);

void main() {
  group('HistorySyncVersion', () {
    test('零填充后字典序等于时间序', () {
      final early = HistorySyncVersion.of(updatedAt: 999, eventId: 'a');
      final later = HistorySyncVersion.of(updatedAt: 1000, eventId: 'a');
      expect(HistorySyncVersion.compare(later, early), greaterThan(0));
    });

    test('同一毫秒用 eventId 破平，两端排序一致', () {
      final a = HistorySyncVersion.of(updatedAt: 1000, eventId: 'd1:1');
      final b = HistorySyncVersion.of(updatedAt: 1000, eventId: 'd1:2');
      expect(HistorySyncVersion.compare(a, b), lessThan(0));
      expect(HistorySyncVersion.compare(b, a), greaterThan(0));
    });

    test('解析回原始时间戳', () {
      final v = HistorySyncVersion.of(updatedAt: 1700000000123, eventId: 'x');
      expect(HistorySyncVersion.updatedAtOf(v), 1700000000123);
      expect(HistorySyncVersion.updatedAtOf('坏数据'), 0);
    });
  });

  group('mergeHistory 基本 LWW', () {
    test('更新的 upsert 覆盖旧的，旧的被忽略', () {
      final result = mergeHistory(
        current: [_h('a|1', updatedAt: 100, position: 10)],
        incoming: [
          _upsert(_h('a|1', updatedAt: 50, position: 5)),
          _upsert(_h('a|1', updatedAt: 200, position: 99)),
        ],
      );
      expect(result.items.single.positionMs, 99);
    });

    test('空数据不会凭空产生条目', () {
      final result = mergeHistory(current: const [], incoming: const []);
      expect(result.items, isEmpty);
      expect(result.accepted, 0);
    });

    test('结果按 updatedAt 倒序，与 UI 排序一致', () {
      final result = mergeHistory(
        current: [_h('a|1', updatedAt: 100)],
        incoming: [
          _upsert(_h('b|2', updatedAt: 300)),
          _upsert(_h('c|3', updatedAt: 200)),
        ],
      );
      expect(result.items.map((e) => e.key).toList(), ['b|2', 'c|3', 'a|1']);
    });

    test('keepLimit 截断尾部（保留最新）', () {
      final result = mergeHistory(
        current: [
          for (var i = 0; i < 5; i++) _h('a|$i', updatedAt: 100 + i),
        ],
        incoming: const [],
        keepLimit: 3,
      );
      expect(result.items.length, 3);
      expect(result.items.first.key, 'a|4');
    });
  });

  group('墓碑：删除不复活', () {
    test('删除后旧 upsert 不能复活条目', () {
      // 先在 t=100 删除。
      final afterDelete = mergeHistory(
        current: [_h('a|1', updatedAt: 50)],
        incoming: [
          HistorySyncEvent.delete(
            key: 'a|1',
            updatedAt: 100,
            deviceId: 'd',
            seq: 1,
          ),
        ],
      );
      expect(afterDelete.items, isEmpty);
      expect(afterDelete.deletedVersions.containsKey('a|1'), isTrue);

      // 再来一条更旧的 upsert（t=60）：必须被墓碑挡住。
      final revived = mergeHistory(
        current: afterDelete.items,
        incoming: [_upsert(_h('a|1', updatedAt: 60))],
        deletedVersions: afterDelete.deletedVersions,
      );
      expect(revived.items, isEmpty, reason: '早于墓碑的 upsert 不应复活条目');
      expect(revived.accepted, 0);
    });

    test('删除之后的 upsert（更新）可以重新建立条目', () {
      final afterDelete = mergeHistory(
        current: const [],
        incoming: [
          HistorySyncEvent.delete(
            key: 'a|1',
            updatedAt: 100,
            deviceId: 'd',
            seq: 1,
          ),
        ],
      );
      final revived = mergeHistory(
        current: afterDelete.items,
        incoming: [_upsert(_h('a|1', updatedAt: 200, position: 42))],
        deletedVersions: afterDelete.deletedVersions,
      );
      expect(revived.items.single.positionMs, 42);
      expect(
        revived.deletedVersions.containsKey('a|1'),
        isFalse,
        reason: '条目重建后墓碑应被清掉',
      );
    });

    test('比现有条目旧的删除不生效', () {
      final result = mergeHistory(
        current: [_h('a|1', updatedAt: 500)],
        incoming: [
          HistorySyncEvent.delete(
            key: 'a|1',
            updatedAt: 100,
            deviceId: 'd',
            seq: 1,
          ),
        ],
      );
      expect(result.items.length, 1, reason: '过期删除不该删掉更新的条目');
      expect(result.accepted, 0);
    });
  });

  group('清空历史是全局墓碑', () {
    test('清空之后旧 upsert 全部丢弃', () {
      final cleared = mergeHistory(
        current: [
          _h('a|1', updatedAt: 100),
          _h('b|2', updatedAt: 200),
        ],
        incoming: [
          HistorySyncEvent.clear(updatedAt: 300, deviceId: 'd', seq: 1),
        ],
      );
      expect(cleared.items, isEmpty);
      expect(cleared.clearVersion, isNotNull);

      final revived = mergeHistory(
        current: cleared.items,
        incoming: [
          _upsert(_h('a|1', updatedAt: 150)),
          _upsert(_h('c|3', updatedAt: 250)),
        ],
        deletedVersions: cleared.deletedVersions,
        clearVersion: cleared.clearVersion,
      );
      expect(revived.items, isEmpty, reason: '早于清空版本的历史不该回来');
      expect(revived.accepted, 0);
    });

    test('清空之后的新观看记录可以正常建立', () {
      final cleared = mergeHistory(
        current: [_h('a|1', updatedAt: 100)],
        incoming: [
          HistorySyncEvent.clear(updatedAt: 300, deviceId: 'd', seq: 1),
        ],
      );
      final next = mergeHistory(
        current: cleared.items,
        incoming: [_upsert(_h('a|1', updatedAt: 400))],
        clearVersion: cleared.clearVersion,
      );
      expect(next.items.single.key, 'a|1');
    });

    test('重复清空保留最新版本', () {
      final first = mergeHistory(
        current: const [],
        incoming: [
          HistorySyncEvent.clear(updatedAt: 100, deviceId: 'd', seq: 1),
        ],
      );
      final second = mergeHistory(
        current: const [],
        incoming: [
          HistorySyncEvent.clear(updatedAt: 200, deviceId: 'd', seq: 2),
        ],
        clearVersion: first.clearVersion,
      );
      expect(
        HistorySyncVersion.updatedAtOf(second.clearVersion!),
        200,
      );
    });
  });

  group('乱序到达结果一致', () {
    test('同一组事件正序 / 逆序合并结果相同', () {
      final events = [
        _upsert(_h('a|1', updatedAt: 100, position: 1)),
        _upsert(_h('a|1', updatedAt: 300, position: 3)),
        _upsert(_h('b|2', updatedAt: 200, position: 2)),
        HistorySyncEvent.delete(
          key: 'b|2',
          updatedAt: 400,
          deviceId: 'd',
          seq: 9,
        ),
      ];

      final forward = mergeHistory(current: const [], incoming: events);
      final backward = mergeHistory(
        current: const [],
        incoming: events.reversed,
      );
      expect(
        forward.items.map((e) => '${e.key}:${e.positionMs}').toList(),
        backward.items.map((e) => '${e.key}:${e.positionMs}').toList(),
      );
      expect(forward.items.single.key, 'a|1');
      expect(forward.items.single.positionMs, 3);
    });
  });

  group('HistorySyncStreamMerger 增量打包', () {
    test('每个条目只保留最新事件，内存有界', () {
      final merger = HistorySyncStreamMerger();
      merger.addAll([
        _upsert(_h('a|1', updatedAt: 100)),
        _upsert(_h('a|1', updatedAt: 300)),
        _upsert(_h('a|1', updatedAt: 200)),
      ]);
      final events = merger.toEvents();
      expect(events.length, 1);
      expect(HistorySyncVersion.updatedAtOf(events.single.version), 300);
    });

    test('toEvents 有序，可直接喂给合并器', () {
      final merger = HistorySyncStreamMerger();
      merger.addAll([
        HistorySyncEvent.clear(updatedAt: 500, deviceId: 'd', seq: 3),
        _upsert(_h('a|1', updatedAt: 100)),
        HistorySyncEvent.delete(
          key: 'a|1',
          updatedAt: 200,
          deviceId: 'd',
          seq: 4,
        ),
      ]);
      final events = merger.toEvents();
      for (var i = 1; i < events.length; i++) {
        expect(
          HistorySyncVersion.compare(
            events[i - 1].version,
            events[i].version,
          ),
          lessThanOrEqualTo(0),
        );
      }
      final result = mergeHistory(current: const [], incoming: events);
      expect(result.items, isEmpty);
    });
  });

  group('快照序列化', () {
    test('snapshot JSON 往返保留正文与墓碑', () {
      final snapshot = HistorySyncSnapshot(
        items: [_h('a|1', updatedAt: 100)],
        itemVersions: {
          'a|1': HistorySyncVersion.of(updatedAt: 100, eventId: 'local:a|1'),
        },
        deletedVersions: {
          'b|2': HistorySyncVersion.of(updatedAt: 200, eventId: 'x'),
        },
        clearVersion: HistorySyncVersion.of(updatedAt: 300, eventId: 'y'),
      );
      final restored = HistorySyncSnapshot.fromJson(snapshot.toJson());
      expect(restored.items.single.key, 'a|1');
      expect(restored.deletedVersions['b|2'], isNotNull);
      expect(restored.clearVersion, isNotNull);
    });

    test('坏数据不抛异常', () {
      expect(
        () => HistorySyncSnapshot.fromJson(const {}),
        returnsNormally,
      );
      expect(
        HistorySyncSnapshot.fromJson(const {}).items,
        isEmpty,
      );
    });

    test('fromItems 幂等：同一份历史得到同一组版本号', () {
      final items = [_h('a|1', updatedAt: 100)];
      final first = HistorySyncSnapshot.fromItems(items);
      final second = HistorySyncSnapshot.fromItems(items);
      expect(first.itemVersions, second.itemVersions);
    });

    test('事件 JSON 往返', () {
      final event = _upsert(_h('a|1', updatedAt: 100));
      final restored = HistorySyncEvent.fromJson(event.toJson());
      expect(restored.op, HistorySyncOp.upsert);
      expect(restored.item?.key, 'a|1');
      expect(restored.version, event.version);
    });
  });
}

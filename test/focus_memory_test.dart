import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/ui/immersive/focus_memory.dart';

void main() {
  group('FocusMemory 同步与恢复', () {
    test('记录聚焦并恢复', () {
      final memory = FocusMemory()..syncKeys(['a', 'b', 'c']);
      memory.remember('b');
      expect(memory.lastFocused, 'b');
      expect(memory.restoreTarget(), 'b');
    });

    test('恢复结束时返回 null 而不乱塞焦点', () {
      final memory = FocusMemory()..syncKeys(['a', 'b']);
      expect(memory.restoreTarget(), isNull);
      // 有 fallback 时才用 fallback。
      expect(memory.restoreTarget(fallback: 'a'), 'a');
    });

    test('fallback 不在集合里时也返回 null', () {
      final memory = FocusMemory()..syncKeys(['a']);
      expect(memory.restoreTarget(fallback: 'zzz'), isNull);
    });

    test('忽略不在有效集合里的脏 key', () {
      final memory = FocusMemory()..syncKeys(['a']);
      memory.remember('ghost');
      expect(memory.lastFocused, isNull);
      expect(memory.restoreTarget(), isNull);
    });

    test('空 key 被忽略', () {
      final memory = FocusMemory()..syncKeys(['a']);
      memory.remember('');
      expect(memory.lastFocused, isNull);
    });
  });

  group('FocusMemory 列表变化', () {
    test('syncKeys 返回被移除的 key，供调用方释放节点', () {
      final memory = FocusMemory()..syncKeys(['a', 'b', 'c']);
      final removed = memory.syncKeys(['a', 'c', 'd']);
      expect(removed.toSet(), {'b'});
      expect(memory.length, 3);
    });

    test('聚焦项被移除时退回 fallback', () {
      final memory = FocusMemory()..syncKeys(['a', 'b', 'c']);
      memory.remember('c');
      memory.syncKeys(['a', 'b'], fallback: 'a');
      expect(memory.lastFocused, 'a');
      expect(memory.restoreTarget(), 'a');
    });

    test('聚焦项被移除且无 fallback 时清空记忆', () {
      final memory = FocusMemory()..syncKeys(['a', 'b']);
      memory.remember('b');
      memory.syncKeys(['a']);
      expect(memory.lastFocused, isNull);
      expect(memory.restoreTarget(), isNull);
    });

    test('聚焦项仍存在时保持不动', () {
      final memory = FocusMemory()..syncKeys(['a', 'b']);
      memory.remember('a');
      memory.syncKeys(['a', 'b', 'c']);
      expect(memory.lastFocused, 'a');
    });

    test('变化回调只在真正变化时触发', () {
      final events = <String?>[];
      final memory = FocusMemory(onChanged: events.add)..syncKeys(['a', 'b']);
      memory.remember('a');
      memory.remember('a'); // 重复聚焦不该再回调
      expect(events, ['a']);
    });

    test('clear 清空并通知', () {
      final events = <String?>[];
      final memory = FocusMemory(onChanged: events.add)..syncKeys(['a']);
      memory.remember('a');
      memory.clear();
      expect(memory.lastFocused, isNull);
      expect(events, ['a', null]);
    });
  });

  group('GridNavigator 方向移动', () {
    // 3 列、7 个条目：
    // 0 1 2
    // 3 4 5
    // 6
    const nav = GridNavigator(count: 7, columns: 3);

    test('左右在行内移动', () {
      expect(nav.move(0, FocusDirection.right), 1);
      expect(nav.move(1, FocusDirection.left), 0);
    });

    test('行首按左 / 行尾按右返回 null（不换行）', () {
      expect(nav.move(3, FocusDirection.left), isNull);
      expect(nav.move(2, FocusDirection.right), isNull);
      expect(nav.move(5, FocusDirection.right), isNull);
    });

    test('上下按列数整行跳', () {
      expect(nav.move(0, FocusDirection.down), 3);
      expect(nav.move(4, FocusDirection.up), 1);
    });

    test('首行按上返回 null', () {
      expect(nav.move(1, FocusDirection.up), isNull);
    });

    test('末行按下落到最后一条而不是没反应', () {
      // 从 4 往下：下一行只有 6，应落到 6 而非原地不动。
      expect(nav.move(4, FocusDirection.down), 6);
      // 已经在最后一条：没有下一行。
      expect(nav.move(6, FocusDirection.down), isNull);
      // 从 5 往下同理落到 6。
      expect(nav.move(5, FocusDirection.down), 6);
    });

    test('越界下标归一到第一项', () {
      expect(nav.move(-5, FocusDirection.right), 1);
      expect(nav.move(99, FocusDirection.down), 3);
    });

    test('空列表所有方向都返回 null', () {
      const empty = GridNavigator(count: 0, columns: 3);
      for (final dir in FocusDirection.values) {
        expect(empty.move(0, dir), isNull, reason: dir.name);
        expect(empty.isEmpty, isTrue);
      }
    });

    test('单列时上下即前后', () {
      const single = GridNavigator(count: 3, columns: 1);
      expect(single.move(0, FocusDirection.down), 1);
      expect(single.move(1, FocusDirection.up), 0);
      expect(single.move(0, FocusDirection.right), isNull);
    });

    test('columns 为 0 时按单列处理，不除零', () {
      const broken = GridNavigator(count: 3, columns: 0);
      expect(() => broken.move(0, FocusDirection.down), returnsNormally);
      expect(broken.move(0, FocusDirection.down), 1);
    });
  });
}

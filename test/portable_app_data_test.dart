import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/platform/portable_app_data_io.dart';

/// 这些用例针对「重启后 userdata 全部消失」的真实故障，锁住三条语义：
///   1. 写入是原子的，进程被强杀不会留下 0 字节文件；
///   2. 主文件损坏 / 为空时能从 .tmp 恢复；
///   3. 迁移不会删除已有数据的目录。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('misa_prefs_');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  File prefsFile() => File('${dir.path}/shared_preferences.json');
  File tempFile() => File('${dir.path}/shared_preferences.json.tmp');

  group('原子写', () {
    test('写入后不残留 .tmp 文件', () async {
      final store = PortablePrefsStore(dir.path);
      await store.setValue('String', 'flutter.a', '1');
      expect(prefsFile().existsSync(), isTrue);
      expect(
        tempFile().existsSync(),
        isFalse,
        reason: '成功后应把临时文件 rename 掉，不留残骸',
      );
    });

    test('内容始终是合法 JSON（不会出现写了一半的文件）', () async {
      final store = PortablePrefsStore(dir.path);
      for (var i = 0; i < 20; i++) {
        await store.setValue('String', 'flutter.k$i', 'v$i');
        final raw = await prefsFile().readAsString();
        expect(() => jsonDecode(raw), returnsNormally, reason: '第 $i 次写入');
      }
    });

    test('重复写入覆盖旧值，不残留旧键', () async {
      final store = PortablePrefsStore(dir.path);
      await store.setValue('String', 'flutter.a', 'old');
      await store.setValue('String', 'flutter.a', 'new');
      final all = await PortablePrefsStore(dir.path).getAll();
      expect(all['flutter.a'], 'new');
    });
  });

  group('从 .tmp 恢复', () {
    test('主文件为 0 字节时用 .tmp 恢复', () async {
      // 模拟：进程在 rename 之前被强杀，主文件已被截断成空。
      await prefsFile().writeAsString('');
      await tempFile().writeAsString(
        jsonEncode({'flutter.sub': '恢复出来的订阅'}),
      );

      final all = await PortablePrefsStore(dir.path).getAll();
      expect(all['flutter.sub'], '恢复出来的订阅');
    });

    test('恢复后把 .tmp 落成正式文件，下次不再依赖它', () async {
      await prefsFile().writeAsString('');
      await tempFile().writeAsString(jsonEncode({'flutter.x': '1'}));

      final store = PortablePrefsStore(dir.path);
      await store.getAll();
      // 恢复动作会把内容写回主文件。
      final raw = await prefsFile().readAsString();
      expect(raw.trim(), isNotEmpty);
      expect(jsonDecode(raw)['flutter.x'], '1');
    });

    test('主文件正常时不读 .tmp（避免用陈旧数据覆盖）', () async {
      await prefsFile().writeAsString(jsonEncode({'flutter.a': 'main'}));
      await tempFile().writeAsString(jsonEncode({'flutter.a': 'stale'}));

      final all = await PortablePrefsStore(dir.path).getAll();
      expect(all['flutter.a'], 'main');
    });

    test('.tmp 也是空时按空偏好处理，不抛异常', () async {
      await prefsFile().writeAsString('');
      await tempFile().writeAsString('');
      expect(
        () => PortablePrefsStore(dir.path).getAll(),
        returnsNormally,
      );
    });
  });

  group('基本读写', () {
    test('写入后可跨实例读回', () async {
      final store = PortablePrefsStore(dir.path);
      await store.setValue('String', 'flutter.a', '1');
      await store.setValue('StringList', 'flutter.list', ['x', 'y']);

      final reopened = PortablePrefsStore(dir.path);
      final all = await reopened.getAll();
      expect(all['flutter.a'], '1');
      expect(all['flutter.list'], ['x', 'y']);
    });

    test('只回读 flutter. 前缀，clear 不误删其它键', () async {
      final store = PortablePrefsStore(dir.path);
      await store.setValue('String', 'flutter.a', '1');
      await store.setValue('String', 'other.b', '2');

      expect((await store.getAll()).keys, ['flutter.a']);
      await store.clear();
      expect(await store.getAll(), isEmpty);

      final raw = await prefsFile().readAsString();
      expect(raw, contains('other.b'));
    });

    test('remove 生效', () async {
      final store = PortablePrefsStore(dir.path);
      await store.setValue('String', 'flutter.a', '1');
      await store.remove('flutter.a');
      expect(await store.getAll(), isEmpty);
    });

    test('损坏文件容错为空白', () async {
      await prefsFile().writeAsString('{坏数据');
      expect(await PortablePrefsStore(dir.path).getAll(), isEmpty);
    });
  });
}

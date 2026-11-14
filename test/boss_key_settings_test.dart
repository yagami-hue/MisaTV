import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/models/user_data.dart';

/// 老板键语义：**默认不占用任何全局热键**，只有用户显式选择的组合才生效。
/// 这些用例锁住该约定，防止以后有人再把某个组合加回默认值。
void main() {
  group('默认值', () {
    test('默认未设置', () {
      expect(PlayerSettings.fromJson({}).bossKey, kUnsetBossKey);
      expect(isBossKeySet(PlayerSettings.fromJson({}).bossKey), isFalse);
    });

    test('默认值本身就是空串（不是某个组合）', () {
      expect(kUnsetBossKey, isEmpty);
      expect(normalizeBossKey(kUnsetBossKey), isEmpty);
    });

    test('预设列表第一项是「未设置」', () {
      expect(kBossKeyShortcuts.first.$1, kUnsetBossKey);
      expect(kBossKeyShortcuts.first.$2, '未设置');
    });
  });

  group('归一化', () {
    test('合法组合原样保留', () {
      for (final item in kBossKeyShortcuts) {
        if (item.$1.isEmpty) continue;
        expect(normalizeBossKey(item.$1), item.$1, reason: item.$2);
      }
    });

    test('大小写与空格不敏感', () {
      expect(normalizeBossKey('ALT+Q'), 'alt+q');
      expect(normalizeBossKey('  alt + q  '), 'alt+q');
      expect(normalizeBossKey('F12'), 'f12');
    });

    test('未知值归一到「未设置」，绝不回落到某个组合', () {
      // 这是本次改动的核心：以前会回落到 ctrl+shift+b，等于替用户抢热键。
      expect(normalizeBossKey('bogus'), kUnsetBossKey);
      expect(normalizeBossKey('ctrl+shift+z'), kUnsetBossKey);
      expect(normalizeBossKey(''), kUnsetBossKey);
    });

    test('旧版本的 off 归一到「未设置」', () {
      expect(normalizeBossKey('off'), kUnsetBossKey);
      expect(normalizeBossKey('OFF'), kUnsetBossKey);
      expect(normalizeBossKey(' off '), kUnsetBossKey);
    });
  });

  group('显示名', () {
    test('未设置显示「未设置」而不是假的组合', () {
      expect(bossKeyLabel(kUnsetBossKey), '未设置');
      expect(bossKeyLabel('off'), '未设置');
      expect(bossKeyLabel('bogus'), '未设置');
    });

    test('已设置的组合显示为可读名称', () {
      expect(bossKeyLabel('ctrl+shift+b'), 'Ctrl + Shift + B');
      expect(bossKeyLabel('alt+q'), 'Alt + Q');
      expect(bossKeyLabel('f12'), 'F12');
    });
  });

  group('isBossKeySet', () {
    test('只有合法组合才算已设置', () {
      expect(isBossKeySet(''), isFalse);
      expect(isBossKeySet('off'), isFalse);
      expect(isBossKeySet('bogus'), isFalse);
      expect(isBossKeySet('alt+q'), isTrue);
      expect(isBossKeySet('ctrl+shift+f'), isTrue);
    });
  });

  group('JSON 往返', () {
    test('未设置可以往返', () {
      final settings = PlayerSettings.fromJson({'bossKey': kUnsetBossKey});
      expect(settings.bossKey, kUnsetBossKey);
      expect(PlayerSettings.fromJson(settings.toJson()).bossKey, kUnsetBossKey);
    });

    test('已设置可以往返', () {
      final settings = PlayerSettings.fromJson({'bossKey': 'alt+z'});
      expect(settings.bossKey, 'alt+z');
      expect(PlayerSettings.fromJson(settings.toJson()).bossKey, 'alt+z');
    });

    test('copyWith 归一化输入', () {
      const base = PlayerSettings();
      expect(base.copyWith(bossKey: 'BOGUS').bossKey, kUnsetBossKey);
      expect(base.copyWith(bossKey: 'ALT+Q').bossKey, 'alt+q');
    });
  });
}

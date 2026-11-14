import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/app_version.dart';
import 'package:kniephos/services/update/update_service.dart';

Map<String, Object?> asset(
  String name, {
  String url = 'https://x/a.zip',
  int size = 1,
}) => {'name': name, 'browser_download_url': url, 'size': size};

void main() {
  test('版本号归一：去掉 v 前缀与构建号', () {
    expect(UpdateService.normalizeVersion('v0.9.1'), '0.9.1');
    expect(UpdateService.normalizeVersion('  V1.2.3 '), '1.2.3');
    expect(UpdateService.normalizeVersion('1.2.3+45'), '1.2.3');
  });

  test('版本比较：按数字比，预测后缀更低', () {
    expect(UpdateService.compareVersions('0.10.0', '0.9.9'), greaterThan(0));
    expect(UpdateService.compareVersions('0.9.0', '0.9.0'), 0);
    expect(UpdateService.compareVersions('v0.9.0+10', '0.9.0'), 0);
    expect(UpdateService.compareVersions('0.9.1', '0.9.0'), greaterThan(0));
    expect(UpdateService.compareVersions('1.0.0-beta', '1.0.0'), lessThan(0));
    expect(UpdateService.compareVersions('1.2', '1.2.0'), 0);
  });

  // 这些用例针对「把版本拼成一个数字再比大小」的常见错误写法
  // （例如 patch + minor*1000 + major*1000000，见 Ghosten Player 的 toDouble）。
  // 那种写法在分段数值变大时会直接判错，这里逐条锁住。
  test('版本比较：分段数值不受进位影响', () {
    // patch 超过 1000：数字拼法会把 1.2.1000 与 1.2.3 算成同值或倒挂。
    expect(UpdateService.compareVersions('1.2.1000', '1.2.3'), greaterThan(0));
    expect(UpdateService.compareVersions('1.2.3', '1.2.1000'), lessThan(0));
    // minor 超过 1000 同理。
    expect(UpdateService.compareVersions('1.1000.0', '1.3.999'), greaterThan(0));
    // 正常进位：0.10.0 > 0.9.9（字符串比较会判错，这里必须走数值）。
    expect(UpdateService.compareVersions('0.10.0', '0.9.10'), greaterThan(0));
  });

  test('版本比较：多段 / 少段 / 脏数据都稳定', () {
    expect(UpdateService.compareVersions('1.2.3.4', '1.2.3'), greaterThan(0));
    expect(UpdateService.compareVersions('1', '1.0.0'), 0);
    // 非数字段按 0 处理，不抛异常。
    expect(() => UpdateService.compareVersions('abc', '1.0.0'), returnsNormally);
    expect(UpdateService.compareVersions('', '0.0.0'), 0);
  });

  test('版本比较：预发布标记', () {
    expect(UpdateService.compareVersions('1.0.0-alpha', '1.0.0-beta'), lessThan(0));
    expect(UpdateService.compareVersions('1.0.0-beta.2', '1.0.0-beta.1'), greaterThan(0));
    expect(UpdateService.compareVersions('1.0.0', '1.0.0-beta'), greaterThan(0));
  });

  test('构建号不参与比较（产品决策：只改 +N 不发更新提示）', () {
    // 这条锁住有意为之的语义：pubspec 的 `1.0.0+11` → `+12` 不应触发提示。
    expect(UpdateService.isNewer('1.0.0+12', '1.0.0+11'), isFalse);
    expect(UpdateService.isNewer('1.0.1+1', '1.0.0+99'), isTrue);
  });

  test('是否比本地新', () {
    expect(UpdateService.isNewer('0.9.1', '0.9.0'), isTrue);
    expect(UpdateService.isNewer('0.9.0', '0.9.0'), isFalse);
    expect(UpdateService.isNewer('0.8.9', '0.9.0'), isFalse);
  });

  test('解析 release JSON：tag / 说明 / 资产', () {
    final release = UpdateService.parseGithubRelease({
      'tag_name': 'v0.9.1',
      'body': '### 更新内容\n- 修好封面',
      'html_url': 'https://github.com/yagami-hue/MisaTV/releases/tag/v0.9.1',
      'published_at': '2026-11-11T10:00:00Z',
      'assets': [
        asset('MisaTV-0.9.1-linux.zip'),
        asset('MisaTV-0.9.1-windows-x64.zip'),
      ],
    });
    expect(release.version, '0.9.1');
    expect(release.notes, contains('修好封面'));
    expect(release.assetName, 'MisaTV-0.9.1-windows-x64.zip');
    expect(release.openUrl, 'https://x/a.zip');
  });

  test('没有资产时用 release 页面兜底', () {
    final release = UpdateService.parseGithubRelease({
      'tag_name': '0.9.2',
      'html_url': 'https://github.com/yagami-hue/MisaTV/releases/tag/0.9.2',
      'assets': const [],
    });
    expect(release.assetName, isEmpty);
    expect(release.openUrl, contains('/releases/tag/0.9.2'));
  });

  test('挑资产：Windows zip 优先，其次任意 zip / exe', () {
    expect(
      UpdateService.pickAsset([
        asset('MisaTV.apk'),
        asset('MisaTV-0.9.1-linux.zip'),
        asset('MisaTV-0.9.1-windows-x64.zip'),
      ])?.name,
      'MisaTV-0.9.1-windows-x64.zip',
    );
    expect(
      UpdateService.pickAsset([asset('a.dmg'), asset('b.zip')])?.name,
      'b.zip',
    );
    expect(UpdateService.pickAsset([asset('setup.exe')])?.name, 'setup.exe');
    expect(UpdateService.pickAsset(const []), isNull);
  });

  test('应用版本号与 pubspec 一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([0-9.]+)',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(kAppVersion, match!.group(1));
  });
}

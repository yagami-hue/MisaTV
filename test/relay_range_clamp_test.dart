import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/relay/local_relay.dart';

/// 上游 Range 夹取。
///
/// 背景（实测）：夸克 / 百度 / UC 的直链 CDN 对**一次请求跨越大**的连接做限速，
/// 同一 URL、同一 Cookie、同一节点，只改 Range 跨度：
///
/// | Range            | 速度      |
/// |------------------|-----------|
/// | `bytes=0-`（开放式）| 0.10 MB/s |
/// | 跨度 512MB / 2GB  | 0.10 MB/s |
/// | 跨度 350MB        | 4.57 MB/s |
/// | 跨度 256MB        | 7.81 MB/s |
/// | 跨度 128MB        | 9.80 MB/s |
/// | 跨度 32MB         | 12.99 MB/s|
///
/// 播放器（fvp / mpv）开场习惯发 `bytes=0-`，正好踩在最差档上，
/// 用户看到的就是「能出画面但极慢、几乎无法播放」。
/// 夹到 32MB 后同一地址回到 10~19 MB/s。
void main() {
  const mb = 1024 * 1024;

  group('Range 夹取', () {
    test('开放式区间夹成固定 32MB 跨度', () {
      expect(LocalRelay.clampRange('bytes=0-'), 'bytes=0-${32 * mb - 1}');
      expect(
        LocalRelay.clampRange('bytes=${100 * mb}-'),
        'bytes=${100 * mb}-${132 * mb - 1}',
      );
    });

    test('跨度超过 32MB 的夹到 32MB', () {
      // 2GB 跨度 → 32MB
      expect(
        LocalRelay.clampRange('bytes=0-${2048 * mb - 1}'),
        'bytes=0-${32 * mb - 1}',
      );
      // 64MB 跨度 → 32MB
      expect(
        LocalRelay.clampRange('bytes=0-${64 * mb - 1}'),
        'bytes=0-${32 * mb - 1}',
      );
    });

    test('跨度不超过 32MB 的原样保留', () {
      const small = 'bytes=0-${16 * mb - 1}';
      expect(LocalRelay.clampRange('bytes=0-${16 * mb - 1}'), small);
      const exact = 'bytes=0-${32 * mb - 1}';
      expect(LocalRelay.clampRange('bytes=0-${32 * mb - 1}'), exact);
      expect(LocalRelay.clampRange('bytes=0-1023'), 'bytes=0-1023');
    });

    test('无 Range / 空串原样返回（不猜）', () {
      expect(LocalRelay.clampRange(null), isNull);
      expect(LocalRelay.clampRange(''), '');
      expect(LocalRelay.clampRange('   '), '   ');
    });

    test('多区间、后缀形态、非法语法一律原样透传', () {
      // 多区间（媒体播放几乎不出现）
      const multi = 'bytes=0-1023,2048-3071';
      expect(LocalRelay.clampRange(multi), multi);
      // 后缀形态 `bytes=-500`（最后 500 字节）
      const suffix = 'bytes=-500';
      expect(LocalRelay.clampRange(suffix), suffix);
      // 非法
      const junk = 'items=0-';
      expect(LocalRelay.clampRange(junk), junk);
      const reversed = 'bytes=100-50';
      expect(LocalRelay.clampRange(reversed), reversed);
    });

    test('大小写与空白容错', () {
      expect(
        LocalRelay.clampRange('  BYTES=0-  '),
        'bytes=0-${32 * mb - 1}',
      );
    });
  });
}

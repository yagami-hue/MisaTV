import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放器画面区的点击/双击手势仲裁。
///
/// 控制栏改为「单击唤出、再次单击收缩」后，必须确认：
///   · 单点只切一次控制栏；
///   · 快速双击只触发全屏，不会顺带切换控制栏。
void main() {
  testWidgets('单击与双击不互相污染', (tester) async {
    var toggles = 0;
    var fullscreens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: GestureDetector(
            onTap: () => toggles++,
            onDoubleTap: () => fullscreens++,
            child: Container(
              width: 300,
              height: 200,
              color: Colors.black,
              key: const Key('video-area'),
            ),
          ),
        ),
      ),
    );

    final area = find.byKey(const Key('video-area'));

    // 等待超过 kDoubleTapTimeout(300ms)，让首次点击判定完成。
    await tester.tap(area);
    await tester.pump(const Duration(milliseconds: 400));
    expect(toggles, 1, reason: '单击应切换一次控制栏');
    expect(fullscreens, 0);

    // 快速双击：两次点击间隔远小于 300ms。
    await tester.tap(area);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(area);
    await tester.pump(const Duration(milliseconds: 400));
    expect(fullscreens, 1, reason: '快速双击应进入全屏');
    expect(toggles, 1, reason: '双击不应额外切换控制栏');
  });
}

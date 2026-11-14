import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/app.dart';
import 'package:kniephos/core/net/app_http.dart';
import 'package:kniephos/core/theme/app_theme.dart';
import 'package:kniephos/services/cms_source.dart';
import 'package:kniephos/services/jar_spider_service.dart';
import 'package:kniephos/services/js_spider_service.dart';
import 'package:kniephos/services/live/live_ua_policy.dart';
import 'package:kniephos/services/live_service.dart';
import 'package:kniephos/services/local_store.dart';
import 'package:kniephos/services/py_spider_service.dart';
import 'package:kniephos/services/search_service.dart';
import 'package:kniephos/services/source_service.dart';
import 'package:kniephos/state/app_state.dart';
import 'package:kniephos/ui/pages/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「设置 → 直播源 → 自定义直播 UA」的界面行为验证。
///
/// 走真实控件树（弹窗是设置页的私有 widget，不为了测试把它公开）。
Future<AppState> _app() async {
  final http = AppHttp();
  final tokens = <String, String>{};
  final source = SourceService(
    CmsSource(http),
    JsSpiderService(
      driveTokens: () => tokens,
      localSeed: () => <String, String>{},
    ),
    PySpiderService(driveTokens: () => tokens),
    JarSpiderService(
      driveTokens: () => tokens,
      driveSeed: () => <String, String>{},
      http: http,
    ),
  );
  return AppState(
    store: await LocalStore.create(),
    http: http,
    sourceService: source,
    searchService: SearchService(source),
    liveService: LiveService(http, source),
    driveTokens: tokens,
  );
}

Future<void> _openLiveSection(
  WidgetTester tester,
  AppState app,
) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final base = AppTheme.build(app.accentColor, Brightness.dark);
  // 测试环境没有系统中文字体，强制用随包 MiSans，否则截图全是豆腐块。
  final theme = base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: AppTheme.fontFamily),
  );

  await tester.pumpWidget(
    AppScope(
      state: app,
      child: MaterialApp(
        locale: const Locale('zh', 'CN'),
        theme: theme,
        home: const Scaffold(body: SettingsPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('直播源').first);
  await tester.pumpAndSettle();
}

Future<void> _typeInto(
  WidgetTester tester,
  String label,
  String value,
) async {
  final field = find.ancestor(
    of: find.text(label),
    matching: find.byType(TextField),
  );
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LiveUaPolicy.current = LiveUaPolicy.none;
  });
  tearDown(() => LiveUaPolicy.current = LiveUaPolicy.none);

  testWidgets('直播源分区里有「自定义直播 UA」入口', (tester) async {
    await _openLiveSection(tester, await _app());
    expect(find.text('自定义直播 UA'), findsOneWidget);
    expect(
      find.textContaining('未配置；留空即自动探测'),
      findsOneWidget,
      reason: '未配置时要说明清楚默认行为，不能只留一个空入口',
    );
  });

  testWidgets('填默认 UA 后落盘并立刻生效', (tester) async {
    final app = await _app();
    await _openLiveSection(tester, app);
    await tester.tap(find.text('自定义直播 UA'));
    await tester.pumpAndSettle();

    expect(find.text('自定义直播 UA'), findsWidgets);
    await _typeInto(tester, '默认直播 UA（可选）', 'MyPlayer/2.0');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(app.liveUaPolicy.defaultUa, 'MyPlayer/2.0');
    expect(LiveUaPolicy.current.defaultUa, 'MyPlayer/2.0',
        reason: 'LiveService 读的是静态策略，保存后必须同步');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('kniephos.liveUaPolicy'), contains('MyPlayer/2.0'));
  });

  testWidgets('可以添加「按接口」的例外规则并只对该接口生效', (tester) async {
    final app = await _app();
    await _openLiveSection(tester, app);
    await tester.tap(find.text('自定义直播 UA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加接口规则'));
    await tester.pumpAndSettle();

    await _typeInto(tester, '直播接口', 'live.ottiptv.cc');
    await _typeInto(tester, 'User-Agent', 'qqlive');
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(find.text('live.ottiptv.cc'), findsOneWidget);
    expect(find.text('1 条'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(app.liveUaPolicy.rules.single.pattern, 'live.ottiptv.cc');
    expect(
      app.liveUaPolicy.matchRule('http://live.ottiptv.cc/live.txt'),
      'qqlive',
    );
    expect(app.liveUaPolicy.matchRule('http://other.test/live.txt'), isNull,
        reason: '规则不能传染给别的接口');
  });

  testWidgets('接口规则为空时保存会被拦下，不会写进坏配置', (tester) async {
    final app = await _app();
    await _openLiveSection(tester, app);
    await tester.tap(find.text('自定义直播 UA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加接口规则'));
    await tester.pumpAndSettle();

    await _typeInto(tester, '直播接口', 'a.test');
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    expect(find.text('UA 不能为空'), findsOneWidget);
    expect(find.text('a.test'), findsOneWidget, reason: '已填的内容不该被丢掉');

    final ruleDialog = find.ancestor(
      of: find.text('UA 不能为空'),
      matching: find.byType(AlertDialog),
    );
    await tester.tap(find.descendant(of: ruleDialog, matching: find.text('取消')));
    await tester.pumpAndSettle();
    expect(app.liveUaPolicy.rules, isEmpty);
  });

  testWidgets('清空后恢复自动探测', (tester) async {
    final app = await _app();
    await _openLiveSection(tester, app);
    await tester.tap(find.text('自定义直播 UA'));
    await tester.pumpAndSettle();
    await _typeInto(tester, '默认直播 UA（可选）', 'temp/1.0');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(app.liveUaPolicy.defaultUa, 'temp/1.0');

    // ScaffoldMessenger 一次只显示一条 SnackBar：先让第一次的提示过完，
    // 否则第二次的「已清空」还排在队列里，find 不到。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.tap(find.text('自定义直播 UA'));
    await tester.pumpAndSettle();
    await _typeInto(tester, '默认直播 UA（可选）', '');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(app.liveUaPolicy.isEmpty, isTrue);
    expect(LiveUaPolicy.current.isEmpty, isTrue);
    expect(find.textContaining('已清空自定义直播 UA'), findsOneWidget);
  });
}

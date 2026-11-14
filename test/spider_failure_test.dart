import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/jar_spider/spider_failure.dart';

void main() {
  group('归因：缺少运行时', () {
    test('JVM 缺失', () {
      final f = classifySpiderFailure(
        Exception('缺少 JVM 运行时，请先在设置里下载'),
      );
      expect(f.kind, SpiderFailureKind.runtimeMissing);
      expect(f.actionable, isTrue);
      expect(f.hint, contains('安装'));
    });

    test('dex2jar / 加固壳 / Python 缺失都归这一类', () {
      for (final msg in [
        'dex2jar 工具缺失，请重新安装 JVM 运行时',
        '加固壳支持不完整，请在设置中重新下载',
        '缺少 Python 运行时',
        'JVM 运行时缺少 java.exe，请在设置中重新安装',
      ]) {
        expect(
          classifySpiderFailure(Exception(msg)).kind,
          SpiderFailureKind.runtimeMissing,
          reason: msg,
        );
      }
    });

    test('运行时其实装了却报缺失：提示改成重装', () {
      final f = classifySpiderFailure(
        Exception('缺少 JVM 运行时，请先在设置里下载'),
        runtimeInstalled: true,
      );
      expect(f.kind, SpiderFailureKind.runtimeMissing);
      expect(f.hint, contains('疑似损坏'));
      expect(f.hint, contains('重新安装'));
    });

    test('运行时未装时提示是「去安装」', () {
      final f = classifySpiderFailure(
        Exception('缺少 JVM 运行时'),
        runtimeInstalled: false,
      );
      expect(f.hint, isNot(contains('疑似损坏')));
    });
  });

  group('归因：源失效', () {
    test('HTTP 错误与脚本错误', () {
      for (final msg in [
        'SourceException: HTTP 404',
        '内容过小，源可能已失效',
        'SyntaxError: Unexpected token',
        '蜘蛛返回错误：首页解析失败',
        'JVM 启动失败：exit code 1',
      ]) {
        expect(
          classifySpiderFailure(Exception(msg)).kind,
          SpiderFailureKind.sourceBroken,
          reason: msg,
        );
      }
    });

    test('提示建议换源', () {
      final f = classifySpiderFailure(Exception('HTTP 404'));
      expect(f.hint, contains('换'));
      expect(f.actionable, isTrue);
    });
  });

  group('归因：网络', () {
    test('超时与连接失败', () {
      for (final msg in [
        'SocketException: Connection refused',
        'Future.timeout 超时',
        'Failed host lookup: example.com',
        'HandshakeException: certificate',
        '网络请求失败：Connection closed',
      ]) {
        expect(
          classifySpiderFailure(Exception(msg)).kind,
          SpiderFailureKind.network,
          reason: msg,
        );
      }
    });

    test('提示检查网络与代理', () {
      final f = classifySpiderFailure(Exception('Connection refused'));
      expect(f.hint, contains('网络'));
    });
  });

  group('归因：安装中 / 缺 ext / 未知', () {
    test('正在下载归到安装中，不标记为可操作', () {
      final f = classifySpiderFailure(Exception('运行时正在下载，请稍候'));
      expect(f.kind, SpiderFailureKind.runtimeInstalling);
      expect(f.actionable, isFalse);
    });

    test('缺 ext', () {
      expect(
        classifySpiderFailure(Exception('该源需要 ext 配置')).kind,
        SpiderFailureKind.needsExt,
      );
    });

    test('无法归因时退回 unknown，不抛异常', () {
      final f = classifySpiderFailure(Exception('莫名其妙的问题'));
      expect(f.kind, SpiderFailureKind.unknown);
      expect(f.message, isNotEmpty);
    });

    test('空错误文本不崩溃', () {
      final f = classifySpiderFailure(Exception(''));
      expect(f.kind, SpiderFailureKind.unknown);
      expect(f.detail, isNotEmpty);
    });
  });

  group('文案压缩', () {
    test('多行堆栈压成一行并截断', () {
      final longError = Exception(
        List.generate(50, (i) => '#$i    some/stack/frame.dart line $i').join('\n'),
      );
      final f = classifySpiderFailure(longError);
      expect(f.detail.contains('\n'), isFalse);
      expect(f.detail.length, lessThanOrEqualTo(201));
    });

    test('message 同时包含结论与下一步', () {
      final f = classifySpiderFailure(Exception('HTTP 404'));
      expect(f.message, contains(f.title));
      expect(f.message, contains(f.hint));
    });
  });

  group('优先级：运行时判定先于网络判定', () {
    test('同时含「运行时」与「超时」时按运行时归因', () {
      // 真实场景：下载运行时超时，报错里同时出现两者。
      // 用户该做的是去装运行时，而不是去查网络。
      final f = classifySpiderFailure(
        Exception('缺少 JVM 运行时；下载超时'),
      );
      expect(f.kind, SpiderFailureKind.runtimeMissing);
    });
  });
}

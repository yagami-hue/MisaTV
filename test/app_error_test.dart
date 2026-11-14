import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/errors/app_error.dart';

void main() {
  group('按状态码归类', () {
    test('权限 / 不存在 / 限流 / 服务端异常', () {
      expect(describeAppError(null, statusCode: 401).kind, AppErrorKind.auth);
      expect(describeAppError(null, statusCode: 403).kind, AppErrorKind.auth);
      expect(
        describeAppError(null, statusCode: 404).kind,
        AppErrorKind.notFound,
      );
      expect(
        describeAppError(null, statusCode: 429).kind,
        AppErrorKind.rateLimited,
      );
      expect(describeAppError(null, statusCode: 502).kind, AppErrorKind.server);
      expect(
        describeAppError(null, statusCode: 418).kind,
        AppErrorKind.httpStatus,
      );
    });
  });

  group('按异常文本归类', () {
    test('超时', () {
      expect(
        describeAppError(TimeoutException('slow')).kind,
        AppErrorKind.timeout,
      );
      expect(describeAppError('请求超时').kind, AppErrorKind.timeout);
    });

    test('TLS / 证书', () {
      expect(
        describeAppError('HandshakeException: CERTIFICATE_VERIFY_FAILED').kind,
        AppErrorKind.tls,
      );
      expect(describeAppError('证书链不完整').kind, AppErrorKind.tls);
    });

    test('网络连接', () {
      expect(
        describeAppError('SocketException: Connection refused').kind,
        AppErrorKind.network,
      );
      expect(
        describeAppError('Failed host lookup: example.com').kind,
        AppErrorKind.network,
      );
      expect(describeAppError('网络请求失败').kind, AppErrorKind.network);
    });

    test('格式错误 / 取消', () {
      expect(
        describeAppError('FormatException: Unexpected character').kind,
        AppErrorKind.format,
      );
      expect(describeAppError('操作已取消').kind, AppErrorKind.cancelled);
    });

    test('文本里的 HTTP 状态码也能识别', () {
      expect(
        describeAppError('HttpException: 下载失败 HTTP 403').kind,
        AppErrorKind.auth,
      );
      expect(
        describeAppError('下载失败 http 503').kind,
        AppErrorKind.server,
      );
    });

    test('无法归因时退回 unknown，不抛异常', () {
      expect(describeAppError(null).kind, AppErrorKind.unknown);
      expect(describeAppError('').kind, AppErrorKind.unknown);
      expect(describeAppError(Exception('莫名其妙')).kind, AppErrorKind.unknown);
    });
  });

  group('文案', () {
    test('message 同时包含结论与下一步', () {
      final info = describeAppError(TimeoutException('x'));
      expect(info.message, contains('请求超时'));
      expect(info.message, contains('重试'));
    });

    test('取消不可重试，网络类可重试', () {
      expect(describeAppError('cancelled').retryable, isFalse);
      expect(describeAppError('Connection reset').retryable, isTrue);
    });
  });
}

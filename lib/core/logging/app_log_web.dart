import 'package:flutter/foundation.dart';

import 'log_redact.dart';

/// Web 版没有可写的应用数据目录：只回显到控制台，接口与文件版一致。
class AppLog {
  AppLog._();

  static bool get initialized => true;

  static String get directory => '';

  static String get currentFile => '';

  static Future<void> init({String? supportDir}) async {}

  static void i(String tag, String message) =>
      debugPrint('[I][$tag] ${redactQueryValues(message)}');

  static void w(
    String tag,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) => debugPrint(
    '[W][$tag] ${redactQueryValues(message)}'
    '${error == null ? '' : ' | ${errorBrief(error)}'}',
  );

  static void e(
    String tag,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) => debugPrint(
    '[E][$tag] ${redactQueryValues(message)}'
    '${error == null ? '' : ' | ${errorBrief(error)}'}',
  );

  static Future<void> flush() async {}

  static Future<void> dispose() async {}

  static Future<void> openDirectory() async {}
}

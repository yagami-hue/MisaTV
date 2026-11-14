import 'dart:io';

/// 本机默认设备名：系统主机名；取不到时给一个中性名字。
String defaultSyncDeviceName() {
  try {
    final host = Platform.localHostname.trim();
    if (host.isNotEmpty) return host;
  } catch (_) {
    // 某些宿主环境不允许读主机名。
  }
  return 'MisaTV 设备';
}

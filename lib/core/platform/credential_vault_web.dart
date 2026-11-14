import 'dart:convert';

/// Web / 无 DPAPI 环境的凭据编码：只做可移植的 base64 包装。
class CredentialVault {
  CredentialVault._();

  static const _dpapiPrefix = 'dpapi1:';
  static const _plainPrefix = 'plain1:';

  static String protect(String plaintext) {
    if (plaintext.isEmpty) return '';
    return '$_plainPrefix${base64Encode(utf8.encode(plaintext))}';
  }

  static String? unprotect(String stored) {
    if (stored.isEmpty) return '';
    if (stored.startsWith(_plainPrefix)) {
      try {
        return utf8.decode(
          base64Decode(stored.substring(_plainPrefix.length)),
          allowMalformed: true,
        );
      } catch (_) {
        return null;
      }
    }
    // Windows 的 DPAPI 密文在 Web 上无法解密。
    if (stored.startsWith(_dpapiPrefix)) return null;
    return stored;
  }
}

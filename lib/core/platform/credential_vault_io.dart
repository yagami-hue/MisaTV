import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../logging/app_log.dart';

/// 本地凭据加密。
///
/// Windows 走 DPAPI（`CryptProtectData`，绑定当前 Windows 用户），密文带
/// `dpapi1:` 前缀；其他平台或 DPAPI 不可用时退化为 `plain1:` + base64，
/// 只保证「不直接出现明文」，不提供跨机器保护。
///
/// 兼容旧数据：没有前缀的值按原明文返回，下一次保存时自动转成密文。
class CredentialVault {
  CredentialVault._();

  static const _dpapiPrefix = 'dpapi1:';
  static const _plainPrefix = 'plain1:';

  static _Dpapi? _dpapi;
  static bool _dpapiUnavailable = false;

  static String protect(String plaintext) {
    if (plaintext.isEmpty) return '';
    if (Platform.isWindows && !_dpapiUnavailable) {
      try {
        final api = _dpapi ??= _Dpapi.open();
        final encrypted = api.protect(utf8.encode(plaintext));
        return '$_dpapiPrefix${base64Encode(encrypted)}';
      } catch (e) {
        _dpapiUnavailable = true;
        AppLog.w('vault', 'DPAPI 不可用，凭据改用可移植编码：$e');
      }
    }
    return '$_plainPrefix${base64Encode(utf8.encode(plaintext))}';
  }

  /// 解密失败（换电脑 / 换用户 / 数据损坏）返回 null，由调用方按「未配置」处理。
  static String? unprotect(String stored) {
    if (stored.isEmpty) return '';
    if (stored.startsWith(_plainPrefix)) {
      return _decodeBase64(stored.substring(_plainPrefix.length));
    }
    if (stored.startsWith(_dpapiPrefix)) {
      if (!Platform.isWindows) {
        AppLog.w('vault', 'DPAPI 凭据来自 Windows，当前平台无法解密');
        return null;
      }
      try {
        final api = _dpapi ??= _Dpapi.open();
        final bytes = base64Decode(stored.substring(_dpapiPrefix.length));
        return utf8.decode(api.unprotect(bytes), allowMalformed: true);
      } catch (e) {
        AppLog.w('vault', 'DPAPI 解密失败（可能从其他电脑/用户复制）：$e');
        return null;
      }
    }
    return stored;
  }

  static String? _decodeBase64(String text) {
    try {
      return utf8.decode(base64Decode(text), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptProtectNative = Int32 Function(
  Pointer<_DataBlob> pDataIn,
  Pointer<Utf16> szDataDescr,
  Pointer<_DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<_DataBlob> pDataOut,
);
typedef _CryptProtectDart = int Function(
  Pointer<_DataBlob> pDataIn,
  Pointer<Utf16> szDataDescr,
  Pointer<_DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<_DataBlob> pDataOut,
);

typedef _CryptUnprotectNative = Int32 Function(
  Pointer<_DataBlob> pDataIn,
  Pointer<Pointer<Utf16>> ppszDataDescr,
  Pointer<_DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<_DataBlob> pDataOut,
);
typedef _CryptUnprotectDart = int Function(
  Pointer<_DataBlob> pDataIn,
  Pointer<Pointer<Utf16>> ppszDataDescr,
  Pointer<_DataBlob> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<_DataBlob> pDataOut,
);

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> hMem);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void> hMem);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

/// DPAPI 的最小 FFI 封装：只做字节数组级别的加解密。
class _Dpapi {
  _Dpapi._(
    this._protect,
    this._unprotect,
    this._localFree,
    this._getLastError,
  );

  factory _Dpapi.open() {
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    return _Dpapi._(
      crypt32.lookupFunction<_CryptProtectNative, _CryptProtectDart>(
        'CryptProtectData',
      ),
      crypt32.lookupFunction<_CryptUnprotectNative, _CryptUnprotectDart>(
        'CryptUnprotectData',
      ),
      kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree'),
      kernel32.lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
        'GetLastError',
      ),
    );
  }

  static const _uiForbidden = 0x1;

  final _CryptProtectDart _protect;
  final _CryptUnprotectDart _unprotect;
  final _LocalFreeDart _localFree;
  final _GetLastErrorDart _getLastError;

  Uint8List protect(List<int> input) => _run(input, encrypt: true);

  Uint8List unprotect(List<int> input) => _run(input, encrypt: false);

  Uint8List _run(List<int> input, {required bool encrypt}) {
    final inputPtr = calloc<Uint8>(input.length);
    final blobIn = calloc<_DataBlob>();
    final blobOut = calloc<_DataBlob>();
    try {
      inputPtr.asTypedList(input.length).setAll(0, input);
      blobIn.ref.cbData = input.length;
      blobIn.ref.pbData = inputPtr;
      final ok = encrypt
          ? _protect(
              blobIn,
              nullptr,
              nullptr,
              nullptr,
              nullptr,
              _uiForbidden,
              blobOut,
            )
          : _unprotect(
              blobIn,
              nullptr,
              nullptr,
              nullptr,
              nullptr,
              _uiForbidden,
              blobOut,
            );
      if (ok == 0) {
        throw StateError('DPAPI 调用失败（${_getLastError()}）');
      }
      final length = blobOut.ref.cbData;
      final data = blobOut.ref.pbData;
      if (length <= 0 || data == nullptr) {
        throw StateError('DPAPI 返回空数据');
      }
      return Uint8List.fromList(data.asTypedList(length));
    } finally {
      final output = blobOut.ref.pbData;
      if (output != nullptr) _localFree(output.cast<Void>());
      calloc.free(inputPtr);
      calloc.free(blobIn);
      calloc.free(blobOut);
    }
  }
}

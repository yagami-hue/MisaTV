import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/core/platform/credential_vault.dart';
import 'package:kniephos/models/dav.dart';
import 'package:kniephos/models/drive_account.dart';
import 'package:kniephos/models/xunlei_account.dart';
import 'package:kniephos/services/local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('CredentialVault', () {
    test('加解密往返，密文不包含明文', () {
      const secret = '__pus=very-secret-cookie';
      final protected = CredentialVault.protect(secret);
      expect(protected, isNot(contains(secret)));
      expect(CredentialVault.unprotect(protected), secret);
    });

    test('Windows 使用 DPAPI，其他平台退化为可移植编码', () {
      final protected = CredentialVault.protect('hello');
      if (Platform.isWindows) {
        expect(protected, startsWith('dpapi1:'));
      } else {
        expect(protected, startsWith('plain1:'));
      }
    });

    test('旧版明文按原样读取，空值保持空', () {
      expect(CredentialVault.unprotect('legacy-plain'), 'legacy-plain');
      expect(CredentialVault.unprotect(''), '');
      expect(CredentialVault.protect(''), '');
    });

    test('损坏 / 跨平台的密文返回 null，不抛异常', () {
      expect(CredentialVault.unprotect('plain1:%%%'), isNull);
      expect(CredentialVault.unprotect('dpapi1:AAAA'), isNull);
    });
  });

  group('LocalStore 凭据落盘', () {
    test('网盘 Cookie / 迅雷 Token / WebDAV 密码 / 代理 / assrt 均为密文', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await LocalStore.create();

      await store.saveDriveAccounts({
        'quark': const DriveAccount(
          provider: 'quark',
          cookie: '__pus=drive-secret',
          updatedAt: 1,
        ),
      });
      await store.saveXunleiAccount(
        const XunleiAccount(refreshToken: 'xunlei-secret'),
      );
      await store.saveDavServers([
        const DavServer(
          id: 'd1',
          name: 'D',
          url: 'https://example.com/dav',
          username: 'u',
          password: 'dav-secret',
        ),
      ]);
      await store.setProxyJson(
        '{"enabled":true,"username":"u","password":"proxy-secret"}',
      );
      await store.setAssrtToken('assrt-secret');

      final prefs = await SharedPreferences.getInstance();
      for (final entry in {
        LocalStore.kDriveAccounts: 'drive-secret',
        LocalStore.kXunleiAccount: 'xunlei-secret',
        LocalStore.kDavServers: 'dav-secret',
        LocalStore.kProxy: 'proxy-secret',
        LocalStore.kAssrtToken: 'assrt-secret',
      }.entries) {
        final raw = prefs.getString(entry.key) ?? '';
        expect(raw, isNotEmpty, reason: entry.key);
        expect(raw, isNot(contains(entry.value)), reason: entry.key);
      }

      expect(store.loadDriveAccounts()['quark']?.cookie, '__pus=drive-secret');
      expect(store.loadXunleiAccount().refreshToken, 'xunlei-secret');
      expect(store.loadDavServers().single.password, 'dav-secret');
      expect(store.proxyJson, contains('proxy-secret'));
      expect(store.assrtToken, 'assrt-secret');
    });

    test('旧版本明文 JSON 可读，下一次保存自动转为密文', () async {
      final legacy = jsonEncode([
        {
          'provider': 'uc',
          'cookie': 'legacy-cookie',
          'username': '',
          'updatedAt': 1,
        },
      ]);
      SharedPreferences.setMockInitialValues({
        LocalStore.kDriveAccounts: legacy,
      });
      final store = await LocalStore.create();
      expect(store.loadDriveAccounts()['uc']?.cookie, 'legacy-cookie');

      await store.saveDriveAccounts(store.loadDriveAccounts());
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(LocalStore.kDriveAccounts),
        isNot(contains('legacy-cookie')),
      );
      expect(store.loadDriveAccounts()['uc']?.cookie, 'legacy-cookie');
    });
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kniephos/services/drive/drive_descriptor.dart';
import 'package:kniephos/services/drive/quark_native.dart';

String _descriptor(String provider, Map<String, Object?> data) =>
    '$provider@${base64.encode(utf8.encode(jsonEncode(data)))}';

/// 嵌套信封：`base64(JSON{a:商, b:内层 JSON 字符串, c, d})`。
String _envelope(
  String provider,
  Map<String, Object?> inner, {
  String displayName = '',
}) => base64.encode(
  utf8.encode(
    jsonEncode(<String, Object?>{
      'a': provider,
      'b': jsonEncode(inner),
      if (displayName.isNotEmpty) 'd': displayName,
    }),
  ),
);

void main() {
  group('夸克分享识别', () {
    test('分享链接与提取码', () {
      final ref = extractQuarkShare(
        'https://pan.quark.cn/s/abcdef123456?pwd=ab12',
      );
      expect(ref, isNotNull);
      expect(ref!.pwdId, 'abcdef123456');
      expect(ref.passcode, 'ab12');
      expect(
        looksLikeQuarkShare('https://pan.quark.cn/s/abcdef123456'),
        isTrue,
      );
    });

    test('描述符直接给出 fid 与 share_fid_token', () {
      final text = _descriptor('quark', <String, Object?>{
        'shareId': 'abcdef1234',
        'fileId': 'cd689cdf',
        'fileToken': '2e0466d4',
        'pdir_fid': '3052bdcd',
        'name': '4K.mp4',
      });
      expect(looksLikeQuarkShare(text), isTrue);
      final ref = extractQuarkShare(text);
      expect(ref, isNotNull);
      expect(ref!.pwdId, 'abcdef1234');
      expect(ref.fileId, 'cd689cdf');
      expect(ref.fileToken, '2e0466d4');
      expect(ref.dirFid, '3052bdcd');
      expect(ref.name, '4K.mp4');
    });

    test('fty 壳的集参数 JSON 只在线路名为夸克时解释', () {
      const ep = '{"pg":"1","parent":"[M-兰]","sId":"329e8e9b9752",'
          '"sToken":"giV1cnKF/QaEQQhM",'
          '"share_fid_token":"2022af50f01650bf",'
          '"fid":"cd689cdfdb534fe6","pdir_fid":"3052bdcd1b9b4cf2",'
          '"vodName":"木兰：血刃","file_name":"4K.mp4"}';
      // 夸克线路：解释
      final quark = extractQuarkShare(ep, flag: '夸父原1');
      expect(quark, isNotNull);
      expect(quark!.pwdId, '329e8e9b9752');
      expect(quark.fileId, 'cd689cdfdb534fe6');
      expect(quark.fileToken, '2022af50f01650bf');
      expect(quark.dirFid, '3052bdcd1b9b4cf2');
      expect(quark.name, '4K.mp4');
      // 集参数自带的 sToken 要复用，省一次 token 请求
      expect(quark.stoken, 'giV1cnKF/QaEQQhM');
      // 百度线路：同样的 JSON 不当夸克（sId 形状相同，只能靠线路名区分）
      expect(extractQuarkShare(ep, flag: '嘟嘟无限3'), isNull);
      expect(looksLikeQuarkShare(ep, flag: '嘟嘟无限3'), isFalse);
    });

    test('非夸克描述符一律不识别', () {
      final uc = _descriptor('uc', <String, Object?>{'shareId': 'abc'});
      expect(looksLikeQuarkShare(uc), isFalse);
      expect(extractQuarkShare(uc), isNull);
    });
  });

  group('嵌套信封短键映射', () {
    test('quark：a→fileId / b→fileToken / c→shareId / d→stoken', () {
      final text = _envelope('quark', <String, Object?>{
        'a': 'fid-1',
        'b': 'tok-1',
        'c': 'share-1',
        'd': 'stoken-1',
        'e': '4K.mp4',
      });
      final desc = parseDriveDescriptor(text);
      expect(desc, isNotNull);
      expect(desc!.provider, 'quark');
      expect(desc.data['fileId'], 'fid-1');
      expect(desc.data['fileToken'], 'tok-1');
      expect(desc.data['shareId'], 'share-1');
      expect(desc.data['stoken'], 'stoken-1');
      expect(desc.data['name'], '4K.mp4');

      final ref = extractQuarkShare(text);
      expect(ref, isNotNull);
      expect(ref!.pwdId, 'share-1');
      expect(ref.fileId, 'fid-1');
      expect(ref.fileToken, 'tok-1');
      expect(ref.stoken, 'stoken-1');
    });

    test('baidu：a→uk / b→name / c→shareId / d→fs_id / e→seKey / g→cookie', () {
      // wex 系壳（9280 那套）实际下发的形状，字段名从真机样本抄来。
      final text = _envelope('baidu', <String, Object?>{
        'a': '271762599896626',
        'b': '01 4K.mkv',
        'c': '3576627086',
        'd': '10420030909',
        'e': 'vlOn10c2a5NjfkUUh4NvdA',
        'f': 'wogg',
        'g': 'BDUSS=xxx; STOKEN=yyy; BDCLND=zzz',
      });
      final desc = parseDriveDescriptor(text);
      expect(desc, isNotNull);
      expect(desc!.provider, 'baidu');
      expect(desc.data['uk'], '271762599896626');
      expect(desc.data['name'], '01 4K.mkv');
      expect(desc.data['shareId'], '3576627086');
      expect(desc.data['fs_id'], '10420030909');
      expect(desc.data['seKey'], 'vlOn10c2a5NjfkUUh4NvdA');
      expect(desc.data['cookie'], contains('BDUSS='));
    });

    test('长短键共存时以长键为准（不被短键覆盖）', () {
      final text = _envelope('baidu', <String, Object?>{
        'a': 'short-uk',
        'uk': 'long-uk',
        'c': '3576627086',
        'shareId': '9999',
      });
      final desc = parseDriveDescriptor(text)!;
      expect(desc.data['uk'], 'long-uk');
      expect(desc.data['shareId'], '9999');
    });

    test('不支持的商返回 null（不抛）', () {
      final text = base64.encode(
        utf8.encode(jsonEncode(<String, Object?>{'a': 'thunder', 'b': '{}'})),
      );
      expect(parseDriveDescriptor(text), isNotNull); // thunder 在允许集合里
      final bad = base64.encode(
        utf8.encode(jsonEncode(<String, Object?>{'a': 'unknown', 'b': '{}'})),
      );
      expect(parseDriveDescriptor(bad), isNull);
    });
  });
}

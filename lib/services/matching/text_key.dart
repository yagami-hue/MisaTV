// 文本归一化的最小公共件：全角转半角、紧凑键、中文数字。
// 只放无副作用的纯函数，供标题匹配与集数归一化共用。

/// 全角转半角（Dart 没有内置 NFKC，这里覆盖标题里最常见的全角区间）。
String normalizeWidth(String value) {
  return value
      .replaceAllMapped(
        RegExp(r'[\uFF01-\uFF5E]'),
        (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xFEE0),
      )
      .replaceAll('\u3000', ' ');
}

/// 紧凑键：小写并去掉所有非字母数字，用于比较与去重。
String compactTitle(String value) => normalizeWidth(
  value,
).toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

const Map<String, int> _chineseDigits = {
  '零': 0,
  '〇': 0,
  '一': 1,
  '二': 2,
  '两': 2,
  '兩': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '七': 7,
  '八': 8,
  '九': 9,
};

/// 中文数字（一 ~ 九十九 / 一百二十三）→ 整数；无法识别返回 null。
int? parseChineseNumber(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  if (RegExp(r'^\d+$').hasMatch(text)) return int.tryParse(text);
  var total = 0;
  var current = 0;
  var matched = false;
  for (final char in text.split('')) {
    final digit = _chineseDigits[char];
    if (digit != null) {
      current = digit;
      matched = true;
      continue;
    }
    if (char == '十') {
      total += (current == 0 ? 1 : current) * 10;
      current = 0;
      matched = true;
      continue;
    }
    if (char == '百') {
      total += (current == 0 ? 1 : current) * 100;
      current = 0;
      matched = true;
      continue;
    }
    return null;
  }
  final result = total + current;
  return matched && result > 0 ? result : null;
}

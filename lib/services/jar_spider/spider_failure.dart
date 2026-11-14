// 蜘蛛调用失败的归因（纯逻辑，便于单测）。
//
// 现状问题：JAR / JS / PY 蜘蛛的失败都收敛成 `SourceException(message)`，
// 界面上只有一段原始英文或堆栈。用户分不清这些情况：
//
//   · 没装 JVM 运行时   → 该去设置里安装，等多久都没用；
//   · 运行时正在下载    → 等一会儿就好；
//   · 源站脚本失效      → 换源；
//   · 网络 / 代理问题   → 检查网络或代理；
//   · 蜘蛛自己抛错      → 源的问题，与软件无关。
//
// 这里把原始错误文本归到上述类别，并给出「下一步该做什么」。
// 只做文本判定，不改调用链：分类失败时退回 [SpiderFailureKind.unknown]，
// 绝不因为归因不准而改变原有错误处理。

/// 失败类别。
enum SpiderFailureKind {
  /// 缺少 JVM / Python / 加固壳运行时：需要在设置里安装。
  runtimeMissing,

  /// 运行时正在下载 / 安装：等一会儿重试即可。
  runtimeInstalling,

  /// 蜘蛛脚本失效（404、内容过小、脚本语法错、蜘蛛抛错）。
  sourceBroken,

  /// 网络或代理问题（超时、连接失败、证书）。
  network,

  /// 需要补 ext 配置（站点要求额外参数）。
  needsExt,

  /// 无法归因。
  unknown,
}

/// 一次失败的结构化描述。
class SpiderFailure {
  const SpiderFailure({
    required this.kind,
    required this.title,
    required this.hint,
    required this.detail,
    this.actionable = false,
  });

  final SpiderFailureKind kind;

  /// 一句话结论（给列表行用）。
  final String title;

  /// 下一步该做什么（给详情 / 提示条用）。
  final String hint;

  /// 原始错误摘要，排查时仍需要它。
  final String detail;

  /// 用户自己动手能否解决（去设置安装 / 改配置 / 换源）。
  final bool actionable;

  @override
  String toString() => '$title：$hint';

  /// 给界面用的完整一行文案。
  String get message => '$title（$hint）';
}

const Map<SpiderFailureKind, String> _titles = {
  SpiderFailureKind.runtimeMissing: '缺少运行时',
  SpiderFailureKind.runtimeInstalling: '运行时正在安装',
  SpiderFailureKind.sourceBroken: '源脚本失效',
  SpiderFailureKind.network: '网络或代理异常',
  SpiderFailureKind.needsExt: '需要补充 ext 配置',
  SpiderFailureKind.unknown: '源调用失败',
};

const Map<SpiderFailureKind, String> _hints = {
  SpiderFailureKind.runtimeMissing: '到设置 → 运行时组件里安装对应组件',
  SpiderFailureKind.runtimeInstalling: '等下载完成后重试，无需其他操作',
  SpiderFailureKind.sourceBroken: '建议换用其他源，或联系订阅提供者更新',
  SpiderFailureKind.network: '检查网络与代理设置后重试',
  SpiderFailureKind.needsExt: '在站点编辑里补上 ext 参数',
  SpiderFailureKind.unknown: '可到「导入诊断」里对该源单独体检',
};

const Map<SpiderFailureKind, bool> _actionable = {
  SpiderFailureKind.runtimeMissing: true,
  SpiderFailureKind.runtimeInstalling: false,
  SpiderFailureKind.sourceBroken: true,
  SpiderFailureKind.network: true,
  SpiderFailureKind.needsExt: true,
  SpiderFailureKind.unknown: false,
};

/// 把一段原始错误归因。
///
/// [runtimeInstalled] 用来区分「真的没装」与「装了但起不来」：例如都出现
/// `缺少 JVM 运行时` 字样时，前者归到 [SpiderFailureKind.runtimeMissing]，
/// 后者更可能是运行时损坏，仍按缺失处理并提示重装。
SpiderFailure classifySpiderFailure(
  Object error, {
  bool? runtimeInstalled,
}) {
  final detail = _condense(error);
  final lower = detail.toLowerCase();

  SpiderFailureKind kind;
  if (_matches(lower, const [
    '缺少 jvm 运行时',
    'jvm 运行时缺少',
    'dex2jar 工具缺失',
    '加固壳支持不完整',
    '缺少 python',
    'python 运行时',
    '请先在设置里下载',
    '请重新安装 jvm',
  ])) {
    kind = SpiderFailureKind.runtimeMissing;
  } else if (_matches(lower, const [
    '正在安装',
    '正在下载',
    '安装中',
    'downloading',
  ])) {
    kind = SpiderFailureKind.runtimeInstalling;
  } else if (_matches(lower, const [
    'sourceexception: 需要 ext',
    '需要 ext',
    'ext 为空',
    '缺少 ext',
  ])) {
    kind = SpiderFailureKind.needsExt;
  } else if (_matches(lower, const [
    'socketexception',
    'connection refused',
    'connection reset',
    'connection closed',
    'failed host lookup',
    'handshake',
    'certificate',
    'tls',
    '超时',
    'timed out',
    'timeout',
    '网络请求失败',
    '代理',
    'proxy',
  ])) {
    kind = SpiderFailureKind.network;
  } else if (_matches(lower, const [
    'http 404',
    'http 403',
    'http 500',
    'http 502',
    'http 503',
    '内容过小',
    '源可能已失效',
    '脚本为空',
    '脚本解析失败',
    '语法错误',
    'syntaxerror',
    'referenceerror',
    'typeerror',
    '蜘蛛返回错误',
    'jvm 启动失败',
    '常驻蜘蛛进程启动失败',
    'clickhouse', // 加固壳常见报错前缀，归到源失效由用户换源
  ])) {
    kind = SpiderFailureKind.sourceBroken;
  } else {
    kind = SpiderFailureKind.unknown;
  }

  // 已知运行时确实装了，却仍报「缺少运行时」：更可能是损坏，仍归缺失类，
  // 但把提示换成重装，避免用户以为点一下安装就好。
  var hint = _hints[kind]!;
  if (kind == SpiderFailureKind.runtimeMissing && runtimeInstalled == true) {
    hint = '运行时疑似损坏，到设置 → 运行时组件里重新安装';
  }

  return SpiderFailure(
    kind: kind,
    title: _titles[kind]!,
    hint: hint,
    detail: detail,
    actionable: _actionable[kind]!,
  );
}

bool _matches(String haystack, List<String> needles) =>
    needles.any(haystack.contains);

/// 压成一行并截断：错误信息常常带大段堆栈，原样塞进界面会把行撑爆。
String _condense(Object error) {
  final text = error
      .toString()
      .replaceAll(RegExp(r'#[0-9]+[\s\S]*$'), '') // 去掉 dart 堆栈
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.isEmpty) return '未知错误';
  return text.length <= 200 ? text : '${text.substring(0, 200)}…';
}

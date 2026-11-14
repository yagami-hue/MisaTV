# 开发约定与实现记录

面向改代码的人。用户向的功能说明、下载与免责声明在根目录 [README](../README.md)。

## 架构一句话

`AppState : ChangeNotifier` + `InheritedNotifier` 管全部状态，`shared_preferences` 管全部持久化，
不引入状态管理框架、路由框架与数据库。页面全部是 `StatefulWidget` / `StatelessWidget`，
跨页面取状态一律 `AppScope.of(context)`。

跨平台能力统一拆成三件套：`foo.dart` 做条件导出
（`export 'foo_io.dart' if (dart.library.js_interop) 'foo_web.dart';`），
`foo_io.dart` 是桌面 / 移动实现，`foo_web.dart` 是 Web 桩。新增涉及 `dart:io` 的能力时照此办理。

## 请求链路

```text
AppState ──> SourceService ──> CmsSource      (type 0 / 1 / 4，MovieParser 解析 XML / JSON)
                          ├──> JsSpiderService (type 3, .js  → QuickJS isolate)
                          ├──> PySpiderService (type 3, .py  → 嵌入式 Python)
                          ├──> JarSpiderService(type 3, jar  → JVM 反射调用)
                          └──> KazumiSource    (type 5, 规则源)
```

播放链路：`SourceService.resolvePlay` → `play_result_parser` 归一化 → `AppState.preparePlay`
（判断是否需要中继）→ `LocalRelay` 生成 `http://127.0.0.1:<port>/play?...` → fvp 播放。

直播回看：`LiveChannel` 的 `catchupType` / `catchupSource` 由 `live_parser` 解析，
`services/live/catchup.dart` 负责生成 `append` / `shift` / `xc` / `flussonic` 回看地址；
节目单来自 `EpgService.loadProgramsFor`（只保留最近 7 天到未来 1 天），
回看走 `openRawPlayback` 的临时会话（不写观看历史、不参与自动换源）。

## 本地中继

单例 `LocalRelay`，首选 `127.0.0.1:9978`，被占用时换临时端口（生成的中继地址都带真实端口）。

| 路由 | 作用 |
| --- | --- |
| `/play` | 注入 UA / Referer / Cookie，HLS 清单与分片递归改写，可选 m3u8 去广告 |
| `/file` `/pkg` | 中继应用数据目录内的本地文件（本地包源、字幕、封面） |
| `/img` | 图片兜底中继，补豆瓣要求的 `Referer` |
| `/bt/<infohash>/<index>` | 磁力 Range 取流 + piece 门控（512KB 一片） |
| `/ext/<token>/<index>` | 第三方播放器选集：按需解析后 302 到真实播放地址 |
| `/proxy` `/proxy/<port>` | 直播代理；壳内路由（如 `do=hmys`）原样转发给常驻取流 JVM |

两个必须遵守的约束：

1. **请求头与超长地址要换成短 token**（`hk=` / `p=`）。网盘直链 + Cookie + UA + Referer 全塞进 query
   会超过 FFmpeg 的 `MAX_URL_SIZE`（4096），外部 MPV 直接报「URL too long」；内置 fvp 走 Dart 能忍，
   所以只在外部播放器上暴露。
2. **加固壳播放必须让 JVM 常驻**（`SpiderHost --hold`）。壳返回的播放地址指向该 JVM 自己的
   `127.0.0.1:<port>`，一次性进程退出后地址立即失效。

## 独立播放器窗口

设置 → 播放 → 「内置播放器独立窗口」打开后，点播 / 直播不在主界面里压路由，而是用
`desktop_multi_window` 另起一个窗口播放，主界面保持原样可见。**沉浸观影模式下强制不生效**：
判定只看 `PlayerSettings.effectivePopOutPlayer`（`popOutPlayer && !immersiveMode`），
设置本身保留，退出沉浸后自动恢复。

| 环节 | 实现 |
| --- | --- |
| 判定 | `ui/open_player.dart` 的 `shouldUseStandalonePlayer`：Windows + `effectivePopOutPlayer`；窗口创建失败回落到内嵌播放器，不能点了没反应 |
| 传参 | `services/player/player_window_session.dart` 把详情 / 线路 / 选集 / 首播地址序列化成一个 JSON 文件，文件路径作为窗口 `arguments`（`misa-player:` 前缀） |
| 子窗口启动 | `main.dart` 先按 `multi_window <id> <arg>` 入口参数分流；`player_window_io.dart` 重建一套 AppState / 服务 / 中继（9978 被主窗口占用时换临时端口）后只渲染播放器页 |
| 原生 | `windows/runner/flutter_window.cpp` 在 `DesktopMultiWindowSetWindowCreatedCallback` 里给子引擎注册插件，缺这步子窗口里 fvp / window_manager 都不可用 |
| 回写 | 子窗口写 shared_preferences 后给主窗口发 `closed` / `search`；主窗口 `AppState.reloadUserDataFromStore` 先让 `PortablePrefsStore` 的缓存失效再重读，否则看到的还是旧进度 |

子窗口和主窗口一样是**无边框**的：播放器页自带顶栏（标题 + 返回 + 画面控制），那一行本来就是
拖拽区（`windowDragArea`），边缘缩放由 `windowFrame` 的 Flutter 边缘层接管，所以不要再给子窗口
挂系统标题栏（会白占一行高度，还多出一套和播放器顶栏重复的按钮）。全屏因此也走主窗口同一套
「`setTitleBarStyle(hidden)` + `setFullScreen` → 退出时 `setAsFrameless`」补丁。

### 竖版视频的窗口形态

独立窗口播放时，播放器页拿到视频分辨率后回调 `fitAppWindowToVideo`（`core/platform/window_service_io.dart`）：
竖版视频（高 > 宽）把窗口按视频比例压成竖版并居中，最小尺寸同步换成 `320 × (320/比例)`；
横版视频再把记住的原尺寸/位置还原。只有**视频分辨率变化**才动手，所以同一段视频里用户自己拖出来的尺寸不会被反复覆盖。
尺寸换算靠 `_workAreaSize()`：`screen_retriever` 的 `visibleSize` 与 `window_manager` 的尺寸接口是同一套逻辑像素，
不要再自己乘除 DPI（多除一次会让窗口缩成巴掌大）。小窗模式也按当前视频的横竖来摆。

### 冒烟测试独立窗口

`flutter build windows --release --dart-define=MISA_TEST_POPOUT=<视频地址或本地 file://>`：
启动 2 秒后自动弹一个独立播放器窗口，用来验证多窗口链路（子引擎插件注册、载荷解析、窗口形态）。
正式构建不带这个 define，`String.fromEnvironment` 取到空串，整段被摇掉，运行时零成本。

## 订阅代理规则（`rules[].hosts`）

TVBox 的代理规则：`rules[].hosts` 列出「要由应用代理出去」的域名（支持 `.*workers.dev`
这类正则，非法的正则退回普通包含匹配）。订阅加载时 `AppState._setConfig` 把规则登记到
`services/relay/proxy_rules.dart` 的 `ProxyRules.current`；`AppHttp` 命中后把地址改写成
本机中继 `/proxy?do=proxy&url=…`（额外请求头走 `h=`），由中继带着应用自己的代理设置去取。
中继没起来时规则自动失效，退化为直连。

覆盖范围：所有走 `AppHttp` 的请求（CMS、Dart 侧蜘蛛、封面、字幕接口…）。**不覆盖**
JVM 里的 jar 蜘蛛（自带 OkHttp）与 JS 蜘蛛的 curl 子进程——这两层吃的是系统代理
（`-Dhttp.proxyHost` / 环境变量），桌面端开着全局代理时行为一致。

## 自定义直播 UA（`LiveUaPolicy`）

设置 → 内容与订阅 → 直播源 → **自定义直播 UA**：一个全局默认 UA + 若干「按接口」的例外规则
（`lib/services/live/live_ua_policy.dart`，存 `kniephos.liveUaPolicy`）。规则匹配语义与
`ProxyRules` 一致：普通片段按地址包含匹配，带正则元字符的按正则匹配，非法正则退回包含匹配。
策略挂在静态 `LiveUaPolicy.current` 上（与 `ProxyRules.current` 同一套做法），因为
`LiveService` 与本机中继都要读，但都不持有 AppState。

**优先级（两条链路都要照此实现，不能各写一份）**：

| 环节 | 取 UA 的顺序 |
| --- | --- |
| 取直播单 `LiveService.load` | 命中的接口规则 > 订阅自带 `ua` / `header` > 内置 `hostDefaultUa` > 用户全局默认 > 探测缓存 > `okhttp/3.12.0` |
| 频道流 / 回看 | 命中的接口规则 > 直播单已带的 UA > 用户全局默认 |

三条不能退回的约束：

1. **全局默认 UA 不能盖过 `hostDefaultUa`**。命中的接口规则算「用户点名给这条接口」，
   可以盖；全局默认不算点名。给 `live.ottiptv.cc` 填一个全局 UA 如果把 `qqlive` 换掉，
   列表会直接指向广告流 —— 改动前不可能发生，测试 `live_ua_policy_test.dart` 守着这条。
2. **频道流要按实际取流地址再解一次**（`resolveLiveStreamUa`）。直播单地址与频道流地址
   常常不在同一个 host（CDN 线路），只信列表阶段的结果会漏掉规则命中。
3. **用户的全局默认 UA 不写进 `_hostUa` 探测缓存**。否则清掉设置后，本次会话里该 host
   还会继续用那个 UA。

覆盖范围：普通 TXT / M3U 直播源（列表 + 频道流 + 回看 + 壳经 `/proxy?do=live` 取的直播单）。
**不覆盖**直播蜘蛛（type=3 / 带 `api`）—— 那类源的 UA 由蜘蛛自己决定，应用不替它改。

## 蜘蛛运行时

| 类型 | 实现要点 |
| --- | --- |
| `.js` | QuickJS 在独立 isolate 执行，`req()` 由 curl 子进程提供同步语义；脚本落盘缓存 6 小时，断网回退旧缓存。超时**不能**用 `Isolate.immediate` 强杀（会把原生 runtime 拆掉，之后 native 代码访问已释放内存 → `quickjs_c_bridge.dll` 里 c0000409 闪退），要用 `beforeNextEvent` 等当前原生调用回到事件循环后再终止 |
| `.py` | 首次使用按需下载 Python 3.11 嵌入式运行时；`assets/python_runner/runner.py` 是桥 |
| `jar` / DEX | 下载 jar → 若含 `classes.dex` 用 dex2jar 转换 → 反射调用 `stubs.jar` 里的 `SpiderRunner`；dex2jar 对 R8「去掉构造器」的 `NEW` 误译由 `DexJarRepair` 修正 |
| 加固壳 | 首次用 unidbg ARM 桥解包，缓存到 `jvm_cache/payloads/<jar>/`；之后用 shell-shim（纯 Java 影子 `DexNative`）加载缓存，不再启动模拟器 |

jar 系蜘蛛**不读 `ext` 里的网盘凭据**，必须由应用主动落盘到固定位置
（`.quarkcookie`、prefs 种子、Pizazz、`Cloud-drive.txt`、`TVBox/*.txt`），缺一个就会显示「还没有配置夸克 Cookie」。

## 网盘 / 站点凭据（`driveAccounts`）

五家凭据统一存在 `kniephos.driveAccounts`，`AppState._syncDriveTokens` 把 Cookie 注入
`driveTokens`（provider 名即蜘蛛 `ext` 键名），`SpiderEnv.sync` 再落盘成各蜘蛛家族期望的文件：

| provider | 登录方式 | 落盘通道 | 缺凭据的后果 |
| --- | --- | --- | --- |
| `quark` / `uc` / `baidu` | 网页扫码（WebView2） | 四条通道全写 | 蜘蛛报「还没有配置 XX Cookie」，取不到流 |
| `115` | 手动粘贴 `UID` / `CID` / `SEID` | `.115cookie`、`Wex_115_cookie` 种子、`TVBox/115.txt` | `api.115.com` 判登录失败，播放地址为空 |
| `bili` | 手动粘贴 `SESSDATA` | 仅 `TVBox/bili_cookie.txt`（订阅里 `cookie` 就指向这个中继地址） | **仍可播 360P / 480P**，只是没有高清 / 大会员画质 |

三条容易踩的约束：

1. **`bili` 是可选增强**（`AppState.isOptionalDriveProvider`）。它不能弹登录窗、不能拦播放、
   不能因为 `guest` 标记就被 `_syncDriveTokens` 丢掉 —— 没 Cookie 也能取到低画质 `durl`，
   B 站 CDN 只要求 Referer（中继的 `/play` 已经补了 `https://www.bilibili.com/`）。
2. **`TVBox/*.txt` 解绑时写空文件**，不能删：中继对缺失文件回 404 + 正文「文件不存在」，
   蜘蛛不校验状态码，会把那段中文当 Cookie 拼进请求头，比空 Cookie 更糟。
3. **`115` 与 `quark` / `uc` / `baidu` 一样是硬门槛**：确认访客态后要从 `driveTokens` 里过滤掉，
   否则蜘蛛拿半个会话去取流只回空数据。

## 设置页折叠规范

设置页里的**每个父分类都必须可折叠**：一律用 `_Section(collapsible: true, initiallyExpanded: false, summary: ...)`
（这两个参数默认值已是「可折叠 + 默认收起」），标题栏 `trailing` 放数量或当前值，`summary` 放收起时的一行摘要。

新增父分类时照此办理，不要留常驻展开的区块：设置页是长列表，任何一块展开都会把其他分类挤出屏幕。
没有合适摘要时至少保留 `trailing` 的计数 / 状态。**唯一例外是「关于」**（`collapsible: false`）。

四个分页与分页下的父分类（新增设置项请放进最贴近的那一类，别再往大类里追加）：

| 分页 | 父分类 |
| --- | --- |
| 内容与订阅 | 订阅配置 / 站点 / Kazumi 规则 / 直播源 / 导入诊断 |
| 播放与外观 | 外观 / 界面与首页 / 播放行为 / 缓冲与缓存 / 画面与播放器 / 下载与网盘 / 网络 / 字幕与弹幕 / 运行时组件 / 性能 |
| 网盘与数据 | 网盘账户 / WebDAV / 数据（备份、清理、运行日志） |
| 安全与关于 | 内容过滤 / 隐私与快捷键（老板键） / 关于 |

### 检查更新

启动后 `UpdateGate` 会请求 GitHub 的 `/releases/latest`，只有远端版本高于
`kAppVersion`（`lib/core/app_version.dart`，与 `pubspec.yaml` 的 `version` 保持一致，
有测试守护）才弹窗，三个按钮分别是【下载】（打开 release 里的 Windows zip 资产，
没有资产就打开 release 页面）、【网盘下载】（123 云盘固定地址）、【稍后提醒】
（什么都不持久化，所以下次启动还会再弹）。仓库没有 release 时会退回 release 列表、
再退回 tag，且只认版本形状的 tag（`v0.9.1`）。

要真正触发提示：在 GitHub 上发布一个 tag 高于当前版本的 release（例如 `v0.9.1`）
并填好更新说明即可。调试弹窗可以用
`flutter build windows --release --dart-define=MISA_UPDATE_REPO=microsoft/vscode`
把检查指向别的仓库，不传时用本仓库（常量会被 tree-shake）。

## Windows 渲染与内存

`windows/runner/main.cpp` 关闭了 Impeller（`flutter::ImpellerSwitch::Disabled`，回退 Skia）。
Flutter 3.47 在 Windows 默认走 Impeller OpenGLESSDF 后端，本项目的圆角、渐变与光晕界面在该后端下
会保留大量整窗尺寸的离屏缓冲，空载提交内存实测 600MB 以上（峰值约 1.4GB）；回退 Skia 后同一界面
空载约 140MB、详情页约 150MB、播放（含 JVM 取流）约 240MB。

图片解码同时收敛：`imageCache` 上限 48MB / 220 张（`main.dart`），海报 `cacheWidth: 320`、
详情背景 960、收藏与直播台标 200 / 128。首页背景只用一层对角渐变，用 `CustomPainter`
（`AppBackdropPainter`）画在内容之下的同一绘制层，不用溢出视口的 `Stack`。

## Windows 关窗退出

关窗分两步：Dart 侧 `window_manager` 拦下关闭消息（`setPreventClose(true)`），先跑
`registerAppShutdown` 注册的收尾（结束常驻取流 JVM），再发 `WM_QUIT`；runner 退出消息循环后
**先销毁窗口**（让 `WM_DESTROY` 在视图还挂着时释放引擎），然后 `TerminateProcess` 直接结束进程。

这两处顺序不能省：窗口晚于 `FlutterViewController` 成员销毁，退出会在 `flutter_windows.dll` 里踩空；
不跳过静态析构 / `DllMain` 卸载，WebView2（`coremessaging.dll`）会 fail-fast。任何一次崩溃都会被
Windows 错误报告留下进程快照克隆，表现为任务管理器里一堆 0 线程的 `MisaTV.exe`，既关不掉也锁住 `build` 目录。

## 便携数据目录：原子写与迁移安全

`lib/core/platform/portable_app_data_io.dart`。「重启后 userdata 全部消失」这个
故障由三个缺陷叠加造成，改动时不要退回任何一条：

1. **写入必须原子**（`PortablePrefsStore._save`）。先写 `shared_preferences.json.tmp`
   再 rename 覆盖。直接 `writeAsString` 覆盖时，进程若在写一半被强杀（关窗最终
   走 `TerminateProcess`，见 runner），文件会被截断成 0 字节，下次启动读到空内容
   → 订阅 / 收藏 / 历史 / 登录态全部"消失"。
2. **读不到主文件时从 `.tmp` 恢复**（`_load`）。进程在 rename 前被杀会留下完整的
   `.tmp`，里面才是最新数据；恢复成功后立刻落成正式文件。注意：主文件**正常**时
   绝不能读 `.tmp`，那可能是上一次的陈旧内容。
3. **迁移不删已有数据的目录**（`_moveInto`）。旧实现里 `to.listSync().isEmpty`
   就 `to.delete(recursive: true)` 再 rename —— 只要迁移中途任一步失败（跨盘、
   杀软锁文件、进程被杀），用户看到的就是整个 userdata 消失。现在只允许 rename
   到**不存在**的目标，已存在则走逐文件合并复制。

## 退出清理不能卡死

「卡死闪退」的根因是退出链路上有**无超时的等待**。日志停在
`[app] 开始退出清理` 之后没有任何输出，就是清理没走完进程就被终止了。

三条约束：

- `SpiderHost.killNow()` / `JarServeHost.killNow()` 里 `StreamSubscription.cancel()`
  **必须带超时**：JVM 被 kill 后管道仍可能挂着未读完的数据，无超时的 cancel 会
  永远等下去。
- `main.dart` 的 `appShutdown` 每一步都独立 `timeout(3s)`，任何一步卡住都不能
  拖住整个退出。
- `registerAppShutdown` 用 `finally` 保证日志一定落盘，并额外写一行
  `退出清理完成`——有这一行才说明退出流程真的走通了，排查时直接看它。

## 数据存储

全部 `shared_preferences`，键前缀 `kniephos.`（键名集中在 `lib/services/local_store.dart`）：

| 键 | 内容 |
| --- | --- |
| `kniephos.profiles` / `activeProfile` / `activeSite` | 订阅档案与当前站点 |
| `kniephos.activeLive` / `activeLiveProfile` / `localLives` | 当前直播源、直播订阅档案、本地导入的 TXT / M3U |
| `kniephos.themeMode` / `accentIndex` / `navBarSize` / `homeColumns` / `homeBrowseMode` | 外观与首页布局 |
| `kniephos.favorites` / `history` / `searchHistory` / `skipSegments` | 收藏、历史、搜索历史、跳过片头片尾 |
| `kniephos.historyTombstones` | 历史墓碑（见「历史墓碑」一节） |
| `kniephos.sourceSpeed` | 源搜索耗时档案（见「搜索耗时档案」一节） |
| `kniephos.playerSettings` / `danmakuSettings` / `contentFilter` | 播放、弹幕、内容过滤设置 |
| `kniephos.driveAccounts` / `xunleiAccount` / `davServers` / `proxy` | 网盘 Cookie（DPAPI 加密）、迅雷、WebDAV 与代理 |
| `kniephos.assrtToken` | assrt 字幕 token（DPAPI 加密） |
| `kniephos.customSubtitleApis` / `liveUaPolicy` / `movieQuotes` / `eulaAccepted` / `windowSize` | 字幕 API、自定义直播 UA、台词缓存、协议标记、窗口尺寸 |

网盘 Cookie、迅雷 Token、WebDAV 密码、代理认证与 assrt token 统一经
`lib/core/platform/credential_vault.dart` 加密后落盘：Windows 走 DPAPI
（`dpapi1:` 前缀，绑定当前 Windows 用户），其他平台 / DPAPI 不可用时退化为
`plain1:` + base64。旧版本明文数据可直接读取，下一次保存自动转为密文。
**DPAPI 密文不能跨电脑 / 跨用户解密**：换机后表现为「未登录」，重新登录即可；
备份导出文件仍是明文，导入后重新加密。

数据目录默认**软件安装目录下的 `userdata`**（`lib/core/platform/portable_app_data_io.dart`，
绿色版可直接搬走），不可写时回落 `%APPDATA%\com.kniephos\MisaTV`。Windows 版自带一个
`shared_preferences` 文件存储实现（`PortablePrefsStore`），因为官方实现固定读 `PathProviderWindows()`，
不跟随 `PathProviderPlatform.instance`。

## 历史墓碑（同步不复活）

观看历史除了正文，还维护一份墓碑（`lib/services/sync/history_sync.dart`）：

- `removeHistory` 写 `<16 位零填充毫秒>|<eventId>` 形式的删除版本；
- `clearHistory` 写全局清空版本，版本早于它的历史一律不再接受；
- 备份导出 / 导入都带上墓碑，导入时与本地墓碑取并集再过滤正文。

没有这层，两个真实问题会冒出来：删除的条目被另一份较旧快照带回来；清空之后再
导入旧备份，历史又满了。多窗口（独立播放器窗口）与未来的局域网同步都要经过
`AppState.mergeExternalHistory`，**不要绕开它直接写 `history`**。

版本号是零填充的字符串，所以字典序 == 时间序；同一毫秒由 eventId 的字典序破平，
各端结果一致。合并前一律按版本升序应用，因此「旧数据后到」与「先到」结果相同。

## 蜘蛛调试口（默认关闭）

`--dart-define=MISA_SPIDER_DEBUG=true` 构建时，中继会挂上 `/debug/spider`：

```text
POST   /debug/spider/session                     → {session}
POST   /debug/spider?session=<id>  {method,args,timeout}
GET    /debug/spider?session=<id>                → 快照
POST   /debug/spider/cancel?session=<id>
DELETE /debug/spider?session=<id>
```

`method` 只接受 `home / category / detail / search / live / play` 白名单；会话
15 分钟空闲过期、最多 8 个；超时由独立 deadline 终结，旧代际的结果会被丢弃。

安全约束（这个口能执行任意蜘蛛脚本，**不要为了图方便默认打开**）：

1. 默认关闭，关闭时一律 403；关闭开关会让已有会话立即失效。
2. 跨站请求会被拒绝，但注意 **HTTPS 页面发往 `127.0.0.1` 的跨站请求拦不住**
   （目标被当作 potentially trustworthy origin，浏览器不发 `Origin` 也不走混合
   内容检查）。真正的边界是「默认关闭 + 只在本机使用」，不能只靠同源校验。
3. 不落盘任何脚本内容，进程退出即失效。

`requests` 只记录走 `AppHttp` 的请求（CMS 与 Dart 侧 JS / PY）；jar 蜘蛛走 JVM 内的
OkHttp、JS 蜘蛛的 `req()` 走 curl 子进程，这两条路径看不到。

## JAR 源启动预热

`lib/services/jar_spider/warmup_plan.dart` + `JarSpiderService.warmUpSite`。

JAR 源的**首次**调用要下载 JRE、做 jar→dex 转换、起 JVM、蜘蛛 `init()` 解挑战，
几十秒起步。用户点搜索才开始，第一批结果注定慢——这是「第一次搜索特别慢」的
主因，耗时档案（见上节）也救不了，因为那时还没有档案。

启动 3 秒后（避开窗口创建 / 配置解析 / 封面加载）串行预热最多 3 个源：

- **只预热 JAR 源**：`.js` / `.py` 走别的运行时，预热没有收益；
- **只预热参与搜索的源**：用户关掉的源不该占启动开销；
- **按实测耗时升序**：先预热快的，收益最直接；
- **串行**：同时拉多只 JVM 会互相抢 CPU 与磁盘，反而更慢；
- **`runtimeReady == false` 时整段跳过**：不静默下载几十 MB 运行时。

`warmUpSite` 的三个契约：绝不抛错（失败让真正搜索时重试）、不写健康度（不代表
用户可见的失败）、按 `key+jar+api` 幂等（同一源只预热一次，失败会解绑以便重试）。

## 蜘蛛失败归因

`lib/services/jar_spider/spider_failure.dart`。

原来所有蜘蛛失败都收敛成 `SourceException(message)`，界面上是一段英文或堆栈，
用户分不清该做什么。现在按文本归到六类并给出下一步：

| 类别 | 典型原因 | 提示方向 |
| --- | --- | --- |
| `runtimeMissing` | 没装 JRE / Python / 加固壳支持 | 去设置安装（装了却报缺失 → 提示重装） |
| `runtimeInstalling` | 运行时正在下载 | 等完成即可 |
| `sourceBroken` | HTTP 4xx/5xx、脚本语法错、蜘蛛抛错 | 换源 |
| `network` | 超时、连接失败、证书 | 检查网络与代理 |
| `needsExt` | 站点缺 ext | 补 ext |
| `unknown` | 无法归因 | 对该源单独体检 |

判定**只看文本、不改控制流**：归因失败退回 `unknown`，绝不因为判定不准改变原有
错误处理。完整原文仍写入日志。判定顺序有意义——「下载运行时超时」会同时命中
运行时与网络两组关键词，必须先判运行时，否则用户会去查网络。

## 沉浸模式的大屏操作（D-pad / 焦点）

`lib/ui/immersive/focus_memory.dart` + `ImmersiveCard.focusNode`。

沉浸观影是给大屏 / TV 用的，但原来整套布局只有 `MouseRegion` + `GestureDetector`，
**没有键盘焦点**，遥控器和方向键完全用不了。现在的做法：

- `ImmersiveCard` 接受 `focusNode` / `onFocus`；不传时仍是纯鼠标卡片
  （沉浸模式里大部分卡片不需要遥控器导航）；
- 卡片被聚焦时复用鼠标悬停的高亮（`_active = _hover || _focused`），
  鼠标与遥控器手感一致；
- `FocusMemory` 记住「上次聚焦的卡片」，从详情页返回时恢复位置，
  而不是跳回第一张。

三个容易踩错的点：

1. **列表刷新要同步 key 集合**（`_syncFocusKeys`）。加载更多 / 换源后卡片数量变化，
   已消失卡片的 `FocusNode` 必须 `dispose`，否则焦点落到一个已移除的节点上，
   方向键会失灵。
2. **恢复焦点要等一帧**。卡片要先进入 widget 树，`requestFocus` 才有效；
   在 `setState` 里直接调用会静默失败。
3. **`restoreTarget` 可能返回 null**，这表示「不要抢焦点」。硬塞焦点到某个
   可能已失效的节点，比不设置更糟。

方向键在货架间的移动交给 Flutter 的焦点树遍历（按几何顺序），而不是自己算网格：
沉浸首页是「横向滚动货架 × 多个分架」的混合布局，手算网格在换行处会跳错。
`GridNavigator` 只用于列数固定的纯网格场景（如分类页），并且明确「行首按左不换行」，
避免遥控器上「按一下左键跳到上一行末尾」这种困惑手感。

## 睡眠定时器

`lib/services/player/sleep_timer.dart` + `lib/ui/widgets/sleep_timer_sheet.dart`。

Windows 端没有系统级「到点暂停」的可靠办法（`SetThreadExecutionState` 只能阻止
休眠，不能暂停播放），所以自己实现。两种模式：

| 模式 | 用途 |
| --- | --- |
| 固定时长（15 分 ~ 2 小时） | 睡前「再看 30 分钟」 |
| 播完当前视频 | 不想被打断，也不想自动连播 |

几个实现要点：

1. **内核不持有播放器**。`SleepTimer` 只在到期时回调 `onExpire`，暂停动作由播放器
   执行；这样它可以被单测，也不会在播放器销毁后留下悬挂引用。
2. **生命周期跟着这一集走**。定时器放在 `_PlayerPageState` 而不是全局 `AppState`：
   关掉播放器就 `dispose()`，避免退出后还在后台倒计时。
3. **`handleVideoEnded()` 必须排在自动连播之前**。否则「播完当前视频后暂停」会被
   自动连播抢走——那正是用户明确不想发生的事。
4. **`checkExpired()` 用于补上休眠期间的到期**。真实 `Timer` 在系统休眠时不走，
   唤醒后可能已远超截止时间；窗口重新获得焦点时调一次即可立即暂停。

## 搜索结果：不做相关性过滤

**不要加「按关键词相关性丢弃结果」的逻辑。** 这一条踩过两次坑，代价都是
「很多源根本搜不到东西」：

1. 第一次用 `searchTitleScore == 0` 过滤 —— 它是**排序**评分器，为排序准确
   刻意严厉（别名 / 译名 / 简写一律 0 分）。实测搜「火影忍者」时 49 个源返回了
   条目、界面却是空。
2. 第二次改成「宽松判定」（短标签丢弃 + 字符重合度）—— 仍然误杀太多。任何
   基于字符串的相关性判定都无法区分「译名」与「噪音」：`NARUTO` 与「火影忍者」
   在字符串层面毫无关系，`ULTRAMAN` 与「奥特曼」同理。

**现行策略**：所有源返回的条目全部保留，相关度只用于**排序**
（`snapshot()` 里按 `searchTitleScore` 降序，让完全命中的排前面）。
用户看到的永远是「源站返回了什么」，而不是「软件替你猜了什么」。

真正会被丢弃的只有两类**用户显式表达**的意图：

| 过滤 | 触发条件 |
| --- | --- |
| 结构化语法 | 用户在搜索框写了 `year:` / `type:` / `area:` / `-排除词` |
| 内容过滤 | 用户在设置里开启的 R18 屏蔽 |

如果以后确实需要「相关性过滤」，正确做法是**做成默认关闭的开关**，让用户自己
决定承担误杀风险，而不是替用户决定。

## 加固壳 payload 缓存（`payloads/<key>/index.json`）

一个 jar key（订阅声明的 md5，否则 jar URL 的 md5）下通常缓存**多个聚合包**，
每只壳只装在其中一个里。实测 D 盘的数据：

```
payloads/c3bb107b/
  index.json:  { "*": "b66f….r2.jar",
                 "…WexNewHuYaGuard": "80dbe….r2.jar", …共 30 个 Wex 壳 }
  b66f….r2.jar  ←  589 个 class，**一个 Wex 都没有**
  80dbe….r2.jar ← 1340 个 class，30 个 Wex 壳都在这里
```

**`*` 绝不能无条件当候选**。它只是「历史上某个壳用过的包」，往往不含当前壳的类。
踩过的坑：无条件塞进候选会占掉一个候选位并可能被优先试跑，表现为
「以前能用的壳突然 ClassNotFound / 原生解密失败」，而且会**存进 index**
变成持久故障 —— 这正是「每修好一个壳，别的壳就坏了」的来源。

三条规则（`payload_selection.dart` 的 `judgePayloadEntry`，有单测）：

| 记录 | 规则 |
| --- | --- |
| `index[className]` 精确记录 | 文件存在即收（它代表本类验证成功过，不被启发式否掉） |
| `index['*']` 默认记录 | **必须**含目标类才收，否则跳过并记日志 |
| 目标类未知（预热） | 只能放行 |

另外 `_dropStaleIndexEntries` 会在读取索引时校验每条精确记录，**包中不含目标类的
记录直接删除并落盘**。有了它，被旧版本污染过的用户不必手动清缓存 ——
下次调用会自动纠正。

## 搜索并发与延迟（性能关键）

`SearchService` 里两组 worker，**都按源数量放开**：

| 池 | 并发 | 说明 |
| --- | --- | --- |
| CMS | 16 | 只是一次 HTTP GET，瓶颈在源站不在本地 |
| 蜘蛛 | 源数量（上限 32） | JS / PY / JAR 混合池 |

**核心判断：蜘蛛源慢是在等源站响应（网络 I/O），不是吃本地 CPU。**
限并发只会让慢源排队，总耗时按 `ceil(N/并发)` 成倍拉长。实测 24 个源、每源
400ms 时：并发 6 需要 1600ms，并发 24 只需 443ms。

真正需要限流的是「每个 JAR 源起几只 JVM」，那一层由
`JarSpiderService._servePoolMax = 3` 独立兜住，多出的请求会自动排队；
JS / PY 也各有自己的执行器池。**不要把这两个层次混为一谈**——早期把它们
当成同一个限制，结果蜘蛛池被卡在 3，整轮搜索被拉长数倍。

另外两条容易踩的坑：

1. **不要给蜘蛛池加「延迟启动」**。曾经有 `_spiderStartDelay = 1200ms`，
   理由是「JVM 冷启动抢 CPU」。但那是早期 3 worker 时代的权衡；现在 CMS 16 worker、
   蜘蛛不设限，这 1.2 秒只是让整轮搜索无条件晚 1.2 秒，用户感受就是「点了没反应」。
2. **蜘蛛超时用 `(timeout + 15).clamp(20, 45)`**。以前是 `timeout + 35`（默认 50s），
   一个卡死源能把整轮搜索拖到 50 秒以上。实测日志里最慢一次 32.5s，45s 上限足够。

## 结构化搜索语法

搜索框支持在关键词后追加过滤条件（`lib/services/matching/search_query.dart`）：

```text
流浪地球 year:2019 type:电影 -解说
剧集 year:2020-2024 area:大陆
```

| 写法 | 含义 |
| --- | --- |
| `year:2024` / `year:2020-2024` / `year:2020..` | 精确年份 / 区间 / 半开区间（`..` `~` `至` `到` 等价） |
| `type:电影` / `type:电影,电视剧` | 类型包含，多个之间是「或」 |
| `area:大陆` | 地区包含 |
| `-解说` | 排除含该词的结果 |

中英文冒号与字段名（`年份` / `类型` / `地区`）都认，大小写不敏感。

三个必须知道的约束：

1. **条件不能下推给源站**。CMS 接口只有 `ac` / `wd` / `t` / `pg` / `f`，蜘蛛源同理，
   所以 `year` / `type` / `area` 是「取回之后就地过滤」。不要指望它减少请求量。
2. **缺失元数据一律放行**。很多源不带年份与类型，严格口径会让用户以为「这个片搜不到」。
   只有明确不匹配的条目才被淘汰。
3. **没有 `site:`**。单源搜索用搜索框的 `@源名`（UI 层收窄 scope，见 `_pinnedSiteKey`）。
   再做一套 `site:` 会出现两个语义不同、互相打架的入口。

`SearchProgress.filterSummary` 是给界面回显的一行摘要（如 `2019 · 电影 · 排除 -解说`），
空串表示没有过滤条件。解析器对**未识别的 `xxx:`** 一律原样留在关键词里，所以搜
`复仇者联盟：终局之战` 或 `http://…` 不会被误吃。

## 本机中继的跨站访问控制

`lib/services/relay/relay_origin.dart` 按请求头分级放行，接入点在 `_handle`：

| 请求形态 | 结果 |
| --- | --- |
| 无 `Origin`（fvp / 外部播放器 / 壳内 JVM） | 放行 |
| `Origin` 与 `Host` 同源 | 放行 |
| 跨站 + `/file` `/pkg` `/proxy` `/ext` 等敏感路由 | 403，且**不回写 CORS 头** |
| 跨站 + `/play` `/img` `/bt/` 媒体路由 | 放行，逐条回显来源而非 `*` |

`/file` 与 `/pkg` 能读应用数据目录（网盘 Cookie 落盘文件在其中），`/proxy` 能借中继
凭据代取任意地址，这两类不能靠 `Access-Control-Allow-Origin: *` 暴露给网页。
注意 **`/proxy?do=ck` 必须继续回 `ok`**：那是加固壳探测宿主代理的握手，破坏它会让
壳拿到端口 `-1` 并导致播放失败（有测试守护）。

## 测试

`flutter test` 覆盖纯逻辑层：配置解析（字段默认值、多仓合并、宽容 JSON、`py_` 过滤）、影片解析
（XML / JSON、多线路、选集、筛选）、直播解析、XMLTV 时间与匹配、直播导出、自定义直播 UA（规则匹配 / 优先级 / 设置页行为）、播放器画面比例与外部播放器探测、
备份格式（原生 / 旧版 Win-Box / `user-config.json`）、合并导出、本地直播源、本地中继（含 WebDAV 鉴权与
`/bt` Range 取流）、m3u8 去广告、VIP 解析、字幕与弹幕（屏蔽词、屏占、排轨）、豆瓣元数据与封面补全、
WebDAV（PROPFIND 解析）、DLNA（SSDP / DIDL-SOAP / 投屏动作链）、磁力（magnet 解析 / 选片 / piece 位序）、
内容过滤（关键词归一 / 多字段匹配 / 密码摘要）、影视台词、本地包路径改写、网盘 Cookie 四通道落盘。

不覆盖：UI 渲染、真实源站网络、JVM / Python 真实调用。

## 已知边界

- 音频源码直通（SPDIF / HDMI 比特流）与超分辨率未实现：libmdk 没有对应接口，不做假开关。
- PUSH 源不支持。
- Web 版仅用于界面预览，播放能力受浏览器编解码与跨域策略限制。
- 端口 9978 被占用时会换端口；壳内生成的地址若硬编码 9978 / `-1`，`SpiderHost` 会统一改写成本 JVM 实际端口。

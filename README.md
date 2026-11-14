<div align=center>

<h1>MisaTV</h1>

<img src="docs/icon/misatv-icon-1024.png" alt="" width="180"></img>

<p>轻量、本地优先的 TVBox 客户端：导入你自备的站源与直播源，即可在电脑上浏览、搜索与播放。
Flutter 重写，单进程、无账号、无遥测，数据只保存在本机。
内置 fvp（libmdk / FFmpeg）播放内核，支持 <code>jar</code> / <code>.js</code> / <code>.py</code> 三类蜘蛛、
网盘取流、磁力 BT、弹幕、外挂字幕、直播 EPG 与 DLNA 投屏。</p>

</div>

注：

- 本仓库是 Electron 版 [Win-box](https://github.com/yagami-hue/Win-box) 的 Flutter 重写（原名 Kniephos，包名与本地存储键沿用旧标识，旧版设置备份可直接导入）。
- 交流 / 反馈请加入 Telegram 频道：[点此加入](https://t.me/MisaTV1)
- 本项目**不内置任何影视源、解析接口或直播源**，全部由你自己导入。

## 支持平台

- Windows 10 及以上（x64，主目标平台）
- Android（可构建，未做重点调优）
- Web（仅界面预览，播放能力受浏览器编解码与跨域策略限制）

## 屏幕截图

<table>
  <tr>
    <td><img alt="home" src="docs/screenshots/home-dark.png" width="520"></td>
    <td><img alt="immersive-spotlight" src="docs/screenshots/immersive-spotlight.png" width="520"></td>
  </tr>
  <tr>
    <td align="center">首页 · 分类与海报流</td>
    <td align="center">沉浸观影 · 首页聚光卡</td>
  </tr>
  <tr>
    <td><img alt="immersive-library" src="docs/screenshots/immersive-library.png" width="520"></td>
    <td><img alt="immersive-detail" src="docs/screenshots/immersive-detail.png" width="520"></td>
  </tr>
  <tr>
    <td align="center">沉浸观影 · 横图分行</td>
    <td align="center">沉浸观影 · 详情与选集</td>
  </tr>
  <tr>
    <td><img alt="detail" src="docs/screenshots/detail-dark.png" width="520"></td>
    <td><img alt="player" src="docs/screenshots/player.png" width="520"></td>
  </tr>
  <tr>
    <td align="center">详情页 · 剧集与演职员</td>
    <td align="center">播放器 · 弹幕与详情悬浮层</td>
  </tr>
  <tr>
    <td><img alt="history" src="docs/screenshots/history.png" width="520"></td>
    <td></td>
  </tr>
  <tr>
    <td align="center">观看历史 · 断点续看</td>
    <td></td>
  </tr>
</table>

> 截图里的影片信息与站点名称来自截图时导入的第三方源，仅用于演示界面；本项目不提供、不推荐、也不内置任何源。

## 功能 / 开发计划

- [X] 订阅导入：TVBox JSON（URL / 粘贴 / 本地 `.json` / 本地 `.py` 蜘蛛 / 本地包目录与 ZIP），多仓自动识别合并
- [X] 订阅维护：启动后台静默回源、手动刷新、墓碑（删掉的源不复活）、本地新增源保留、批量删除、体检后一键删失败源、站点字段编辑
- [X] 本地包改写：`clan://localhost`、`assets://`、`pkg://`、相对 `./` 与 `ext` 内文件
- [X] 点播：CMS type 0（XML）/ type 1、4（JSON），分类、筛选、详情、线路与选集、分页
- [X] 三类蜘蛛：`.js`（QuickJS，内置 ESM→CJS、`pdfh` / cheerio / CryptoJS）、`.py`（按需下载嵌入式 Python 3.11）、`jar` / DEX（按需下载 JRE 17 + dex2jar）
- [X] 加固壳源（Guard / DexNative）：首次用 unidbg ARM 桥解包并缓存，之后走纯 Java shell-shim 快路径
- [X] 聚合搜索：多源并发流式返回，CMS / JS / PY / JAR 各自独立并发，按名称 + 年份去重并标注来源
- [X] 发现与详情：豆瓣元数据补全（封面 / 简介 / 评分 / 演职员 / 相关推荐 / 影评），封面兜底与本地 `/img` 中继
- [X] 播放：进度记忆、自动连播、倍速、全屏、多音轨、6 种画面比例、跳过片头片尾、长按临时倍速、桌面小窗
- [X] 独立播放器窗口：内置播放器可弹到软件主界面之外的独立窗口播放，主界面保持可见（沉浸观影模式下自动不生效）
- [X] 播放增强：弹幕（28 个内置接口 + 自定义）、外挂字幕（SubtitleCat / assrt / 自定义 API）、DLNA 投屏、外部播放器（PotPlayer / VLC / mpv / MPC-HC / 自定义 exe）
- [X] 本地中继 `127.0.0.1:9978`：UA / Referer / Cookie 注入、m3u8 分片与密钥递归改写、可选去广告、网盘直链、WebDAV Basic、BT Range 取流
- [X] 网盘：夸克 / UC / 百度网页扫码登录（WebView2），115 / 哔哩手动粘贴 Cookie，Cookie 注入 jar 系蜘蛛，夸克 `/member` 会话刷新；哔哩 Cookie 为可选增强，不配也能播 360P / 480P
- [X] 磁力（BT）：内置 aria2c sidecar，边下边播、按体积与集名选片、`/bt` piece 门控
- [X] 直播：TXT / M3U / JSON 订阅与 type=3 直播蜘蛛，分组与多线路、EPG（节目单 / 当前下一档 / 直播回看）、导出 TXT / M3U
- [X] 自定义直播 UA：可设全局默认，也可只对某个直播接口生效（按地址片段 / 正则匹配），列表与频道流都带上
- [X] WebDAV 只读直连（OpenList / AList / Nextcloud / 群晖 / 坚果云）
- [X] 内容过滤（R18 屏蔽，关闭需密码）、备份导出 / 导入、收藏 / 历史 / 搜索历史
- [X] 外观：浅色 / 深色 / 跟随系统、5 种主题色、响应式布局、沉浸观影模式
- [X] 桌面细节：自绘无边框标题栏、老板键 / 托盘、播放时阻止休眠、鼠标静止自动隐藏光标与控制栏
- [ ] 音频源码直通（SPDIF / HDMI 比特流）、超分辨率 —— libmdk 未提供对应接口，不做假开关

## 下载

通过本页面 [Releases](https://github.com/yagami-hue/MisaTV/releases/latest) 选项卡下载：

<a href="https://github.com/yagami-hue/MisaTV/releases">
  <img src="https://img.shields.io/badge/Download-Latest_Release-2E9629?style=for-the-badge&logo=github" alt="Get it on Github" height="40"/>
</a>

### Windows

- 解压即用（绿色版）：订阅、历史与运行时会放在软件目录下的 `userdata`，复制整个文件夹即可连数据一起带走；网盘 / 迅雷 / WebDAV 凭据受 Windows DPAPI 保护，换电脑或换用户后需重新登录。
- 安装目录不可写（如 Program Files）时自动回落到 `%APPDATA%\com.kniephos\MisaTV`。
- 首次运行请先阅读并同意使用声明，再到「设置」页导入你自己的站源 / 直播源。

## Q&A

<details>
<summary>使用者 Q&A</summary>

#### Q: 为什么内存占用比别的播放器高？

A: Flutter 桌面端默认走 Impeller，本项目的圆角 / 渐变 / 光晕界面在该后端下会保留大量整窗尺寸的离屏缓冲，空载提交内存实测 600MB 以上。仓库里的 `windows/runner/main.cpp` 已关闭 Impeller 回退 Skia，同一界面空载约 140MB、详情页约 150MB、播放（含 JVM 取流）约 240MB；图片缓存也已收敛（48MB / 220 张，海报按卡片尺寸解码）。

#### Q: 为什么有的源打不开 / 搜不出结果？

A: 多数是源站自身问题：站点失效、需要 `ext` 配置、需要登录或对接口做了加密。设置 → 订阅里对该源点「体检」可查看结果；少数源依赖站点专有加密，属于无解源，换一个源通常即可正常使用。删掉的源会记入墓碑，刷新订阅也不会复活。

#### Q: 第一次进 JAR / 加固壳源为什么要等几分钟？

A: 这类源首次使用要下载运行时（JRE 17 + dex2jar 约 85MB）并做 `jar → dex` 转换；加固壳源还要用 ARM 桥解包一次（约 20–30 秒）。等待期间首页会显示转换 / 解包提示而不是只剩骨架屏，中断的产物下次启动会直接复用，不会重复跑。

#### Q: 为什么网盘播放要求先登录？

A: 夸克 / UC / 百度需要 Cookie 或扫码授权才能取到直链。登录入口在「设置 → 网盘」，走官方网页扫码（内置 WebView2）。凭据只保存在你本机。

#### Q: 为什么弹幕搜不到，或者匹配到了别的集？

A: 弹幕接口普遍较慢且有抖动。程序会优先试同集，未命中时扩大搜索并换候选重试；能识别出集号时只使用该集弹幕，不会静默显示别集。

#### Q: 少数影片里有广告？

A: 本项目未插入任何广告。广告来自你导入的视频源或网盘里的文件本身。设置 → 播放里的「m3u8 去广告」只对点播清单做启发式清洗（默认关闭，删太多或清洗后不可播会自动回退原文）。

</details>

<details>
<summary>开发者 Q&A</summary>

#### Q: 为什么克隆下来直接编译跑不起来？

A: 仓库包含源码与大部分资源，但以下两项因体积或版权原因**不随仓库分发**（见下方「运行前准备」）：`assets/aria2/aria2c.exe` 与 `assets/jvm/shell-real/*.jar`。缺它们的表现是：磁力播放提示引擎缺失；两个内置壳源首次调用改走原生解包（需在设置里装加固壳支持），功能不失效只是变慢。

#### Q: 想改点东西，从哪看起？

A: `lib/core` 是基础设施，`lib/models` 是数据模型，`lib/services` 是业务引擎（蜘蛛、中继、播放解析都在这里），`lib/state/app_state.dart` 是唯一的全局状态，`lib/ui` 是页面与组件。单测在 `test/`。开发约定与踩坑记录见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

#### Q: 为什么不引入状态管理框架 / 数据库？

A: 这个项目的状态只有一份（`AppState : ChangeNotifier` + `InheritedNotifier`），持久化只有 `shared_preferences`。少一层抽象就少一层排查成本，体积与启动也更好控制。

</details>

## 开发

要求 Flutter 3.47+（Dart 3.13+）。

```bash
flutter pub get
flutter analyze
flutter test                 # 纯逻辑单测，不依赖真实源站
flutter run -d windows       # 需要 Visual Studio 的 C++ 桌面开发工具链
flutter run -d android
flutter run -d chrome
```

打包：

```bash
flutter build windows
flutter build apk
flutter build web
```

重新生成图标（源图 `docs/icon/misatv-icon-1024.png` → 各平台尺寸）：

```powershell
powershell -ExecutionPolicy Bypass -File tool/make_icons.ps1
```

## 运行前准备

克隆后直接编译即可运行，但下面两项第三方内容不入库，需要你自己补齐：

| 缺失项 | 影响 | 补齐方式 |
| --- | --- | --- |
| `assets/aria2/aria2c.exe` | 磁力 / BT 播放提示引擎缺失 | 见 [assets/aria2/README.md](assets/aria2/README.md) |
| `assets/jvm/shell-real/*.jar` | 两个内置加固壳源改走原生解包（首次慢 20–30 秒） | 见 [assets/jvm/shell-real/README.md](assets/jvm/shell-real/README.md) |

另外 `mdk-sdk/`（libmdk 上游 SDK 转储）与 `build/`、`.dart_tool/` 已在 `.gitignore` 中排除。

## 目录结构

```text
lib/
  core/       网络（含 DoH、本机代理桥）、GBK 解码、宽容 JSON、日志、主题、桌面窗口
  models/     配置、影片、直播、用户数据模型
  services/   配置解析、CMS、聚合搜索、直播与 EPG、播放解析、JS / PY / JAR 蜘蛛、
              本地中继、网盘登录、WebDAV、DLNA、磁力、字幕、弹幕、豆瓣元数据
  state/      AppState（ChangeNotifier）
  ui/         页面、沉浸页、组件、底部悬浮导航
assets/       JS 支持库、Python 运行时桥、JVM shims 与源码、字体、图标
test/         纯逻辑单测（配置解析、影片解析、中继、去广告、字幕、弹幕、磁力、DLNA…）
```

数据存储键、Windows 渲染与关窗退出、设置页折叠规范等开发约定见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

## 说明

- Fork 二改请注明 GitHub 此项目；参考源码重新开发请标注上游仓库。
- 本仓库只包含本项目源码与自建资源；不含任何第三方私有蜘蛛 jar、JVM 运行时、逆向壳或专有产物。
- 本项目是**个人学习 / 研究性质的开源实现**，与安卓版 TVBox、CatVod 及任何第三方站点、平台无隶属关系。

## 图标

应用图标是同人作品，**不随 GPL-3.0 授权**：

- 原型：抖音「山有井水无月」的**夜神月**Q 版；
- 本版本的**弥海砂**版本由作者使用 GPT 自制；
- 仅用于本项目的应用图标与仓库展示，不改作他用、不用于商业用途。

如权利人对使用方式有异议，请通过 [Issues](https://github.com/yagami-hue/MisaTV/issues) 联系，会及时更换。

## 特别感谢

感谢 [TVBox / CatVod 上游](https://github.com/q215613905/TVBoxOS) —— 本项目的站源协议、蜘蛛接口与解析规则都对齐安卓版。

感谢 [Kazumi](https://github.com/Predidit/Kazumi) —— 界面视觉（浅绿玻璃拟态与海报流）的参考，并支持导入 Kazumi 规则源。

感谢 [QuantumTV](https://github.com/Geon97/QuantumTV) —— 体量与功能边界的参考，成人源判定与过滤思路来自它。

感谢 [fvp](https://pub.dev/packages/fvp) / [mdk-sdk](https://github.com/wang-bin/mdk-sdk)（播放内核）、[mpv-Yaozhi](https://github.com/Yaozhil/mpv-Yaozhi)（可选外部播放器）、[aria2](https://github.com/aria2/aria2)（磁力 BT）、[dex2jar](https://github.com/pxb1988/dex2jar)（jar 蜘蛛运行时转换）、[unidbg](https://github.com/zhkl0228/unidbg)（加固壳 ARM 桥）。

感谢豆瓣（元数据与封面）、[SubtitleCat](https://www.subtitlecat.com/) 与 assrt（字幕）、[Hitokoto](https://hitokoto.cn/)（影视台词）等公开服务。

特别感谢 DeepSeek、GLM、GPT、Claude 等 —— 纯 Vibe coding 项目：作者 0 代码基础，包括开源与发布流程均由 AI 协助完成。

## 免责声明（请务必阅读）

1. **软件性质**：MisaTV 是开源学习项目，本质上只是一个**通用影片播放工具**（播放器外壳）；不含任何盈利行为，不提供服务、**不存储、不推送任何影视资源与内容**。
2. **不提供内容**：本项目**不内置任何资源索引、不运营任何内容服务器**。你自行配置 / 导入的播放源、直播源、解析接口、弹幕与字幕接口、网盘凭据与内容，全部来自**第三方**，与本软件及作者无关；软件内的本地中继（`127.0.0.1`）仅用于你自己设备上的本机播放转发。
3. **无隶属关系**：与任何影视平台、内容站点、网盘服务、TVBox / CatVod 及其发行方**均无隶属、合作、代理或授权关系**；相关名称与商标归各自权利人所有。
4. **使用者责任**：请确保你导入的第三方源与使用行为**符合所在地法律法规**，不得用于传播、观看任何违法或侵权内容；因使用第三方来源引发的一切后果（含版权、侵权、内容合法性）由用户与第三方自行承担，作者免责。
5. **权利通知**：本软件不对任何第三方内容主张权利，也未从第三方内容中获利。若权利人认为本项目某项行为可能侵权，请通过 [Issues](https://github.com/yagami-hue/MisaTV/issues) 联系，作者将及时核实并配合处理。
6. **无担保**：软件按**「现状」**提供，不附带任何明示或默示担保；作者不对使用或无法使用本软件造成的任何直接或间接损失负责。不接受上述约定请立即停止使用并删除本软件。

> 应用内「设置 → 关于」提供同一份声明的完整版；首次启动需同意后才进入主界面。

## 隐私政策

本项目不收集任何用户数据，不使用任何遥测组件。所有配置、历史、凭据与缓存都只保存在你本机（软件目录 `userdata` 或 `%APPDATA%`）。

## 许可

代码采用 **GNU General Public License v3.0**（见 [LICENSE](LICENSE)）。

第三方组件、随包资源与运行期按需下载的内容各自遵循其原许可，详见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)；应用图标不适用 GPL，见上文「图标」。

## Star History

<a href="https://www.star-history.com/?repos=yagami-hue%2FMisaTV&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=yagami-hue/MisaTV&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=yagami-hue/MisaTV&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=yagami-hue/MisaTV&type=date&legend=top-left" />
 </picture>
</a>

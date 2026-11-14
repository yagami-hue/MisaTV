import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app.dart';
import '../../core/app_version.dart';
import '../../core/logging/app_log.dart';
import '../../core/net/proxy_config.dart';
import '../../core/net/proxy_runtime.dart';
import '../../core/platform/player_window.dart';
import '../../core/platform/window_service.dart';
import '../../models/dav.dart';
import '../../models/player_fit.dart';
import '../../models/site_config.dart';
import '../../models/source_health.dart';
import '../../models/user_data.dart';
import '../../services/artwork/artwork_service.dart';
import '../../services/artwork/tmdb_auth.dart';
import '../../services/backup_data.dart';
import '../../services/boss_key/boss_key_service.dart';
import '../../services/content_filter.dart';
import '../../services/update/update_service.dart';
import '../../services/danmaku/danmaku_endpoints.dart';
import '../../services/danmaku/danmaku_models.dart';
import '../../services/danmaku/danmaku_settings.dart';
import '../../services/drive_login_service.dart';
import '../../services/file_dialog_service.dart';
import '../../services/jvm/arm_bridge_runtime.dart';
import '../../services/kazumi/kazumi_rule.dart';
import '../../services/local_import_service.dart';
import '../../services/local_live_service.dart';
import '../../services/live/live_ua_policy.dart';
import '../../services/jvm/jvm_runtime.dart';
import '../../services/mpv_extension.dart';
import '../../services/player/external_players.dart';
import '../../services/py_runtime_service.dart';
import '../../services/relay/local_relay.dart';
import '../../services/runtime_extension.dart';
import '../../state/app_state.dart';
import '../widgets/drive_cookie_dialog.dart';
import '../widgets/drive_web_login_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass.dart';
import '../widgets/import_sheet.dart';
import '../widgets/name_input_dialog.dart';
import '../widgets/uc_tv_login_dialog.dart';
import '../widgets/update_dialog.dart';
import '../widgets/xunlei_login_dialog.dart';
import 'dav_browse_page.dart';
import 'downloads_page.dart';
import 'media_library_page.dart';
import 'sync_page.dart';
import 'video_downloads_page.dart';

part 'settings/common_tiles.dart';
part 'settings/dialogs.dart';
part 'settings/runtime_tiles.dart';
part 'settings/source_widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey<_SectionState> _playSectionKey = GlobalKey<_SectionState>();
  final GlobalKey<_JvmRuntimeTileState> _jvmTileKey =
      GlobalKey<_JvmRuntimeTileState>();
  final GlobalKey<_ArmBridgeTileState> _guardTileKey =
      GlobalKey<_ArmBridgeTileState>();
  final GlobalKey<_PythonRuntimeTileState> _pythonTileKey =
      GlobalKey<_PythonRuntimeTileState>();

  /// 当前父分类（分页）。原有分类都挂在下面四个父分类里。
  int _pageIndex = 0;

  /// 源审计结果是否只看异常项。
  bool _auditOnlyFailed = false;

  static const int _contentPage = 0;
  static const int _playPage = 1;
  static const int _accountPage = 2;
  static const int _safetyPage = 3;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _selectPage(int index) {
    if (index == _pageIndex) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() => _pageIndex = index);
  }

  Future<void> _showProfileHistory(BuildContext context, AppState app) async {
    final snapshots = app.profileHistory;
    final messenger = ScaffoldMessenger.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('订阅历史（${snapshots.length}）'),
        content: SizedBox(
          width: 560,
          child: snapshots.isEmpty
              ? const Text('还没有历史快照。刷新或重新导入订阅时会自动保存上一版本。')
              : SizedBox(
                  height: 360,
                  child: ListView.separated(
                    itemCount: snapshots.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final snapshot = snapshots[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.history_rounded),
                        title: Text(snapshot.name),
                        subtitle: Text(
                          '${_formatSnapshotTime(snapshot.savedAt)} · '
                          '${snapshot.siteCount} 源 / ${snapshot.liveCount} 直播',
                        ),
                        trailing: TextButton(
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            try {
                              await app.restoreProfileSnapshot(snapshot);
                              messenger.showSnackBar(
                                const SnackBar(content: Text('已回滚到该订阅版本')),
                              );
                            } catch (e) {
                              messenger.showSnackBar(
                                SnackBar(content: Text('回滚失败：$e')),
                              );
                            }
                          },
                          child: const Text('回滚'),
                        ),
                      );
                    },
                  ),
                ),
        ),
        actions: [
          if (snapshots.isNotEmpty)
            TextButton(
              onPressed: () async {
                await app.clearProfileHistory();
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('清空历史'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String _formatSnapshotTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  Future<void> _exportSkipSegments(AppState app) async {
    final messenger = ScaffoldMessenger.of(context);
    final path = await FileDialogService.saveText(
      suggestedName: 'misatv-skip-segments.json',
      text: app.skipSegmentsJson(),
    );
    messenger.showSnackBar(
      SnackBar(content: Text(path == null ? '已取消导出' : '已导出：$path')),
    );
  }

  Future<void> _importSkipSegments(AppState app) async {
    final messenger = ScaffoldMessenger.of(context);
    final path = await FileDialogService.pickFile(
      types: [FileDialogService.jsonType],
    );
    if (path == null) return;
    try {
      final text = await FileDialogService.readText(path);
      final count = await app.importSkipSegmentsJson(text);
      messenger.showSnackBar(
        SnackBar(content: Text('已导入 $count 条片头片尾记录')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  Future<void> _exportAuditReport(AppState app) async {
    final text = app.auditReportText();
    final messenger = ScaffoldMessenger.of(context);
    if (kIsWeb) {
      await Clipboard.setData(ClipboardData(text: text));
      messenger.showSnackBar(const SnackBar(content: Text('审计报告已复制到剪贴板')));
      return;
    }
    final path = await FileDialogService.saveText(
      suggestedName: 'misatv-source-audit.txt',
      text: text,
    );
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(path == null ? '已取消导出' : '审计报告已保存：$path'),
      ),
    );
  }

  /// 展开「播放」并滚动到对应扩展卡片，然后开始下载。
  Future<void> revealRuntime(RuntimeExtension kind) async {
    if (_pageIndex != _playPage) {
      _selectPage(_playPage);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    _playSectionKey.currentState?.expand();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final target = switch (kind) {
      RuntimeExtension.jvm => _jvmTileKey.currentContext,
      RuntimeExtension.guard => _guardTileKey.currentContext,
      RuntimeExtension.python => _pythonTileKey.currentContext,
    };
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(
        target,
        alignment: 0.08,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) return;
    switch (kind) {
      case RuntimeExtension.jvm:
        await _jvmTileKey.currentState?.startInstall();
      case RuntimeExtension.guard:
        await _guardTileKey.currentState?.startInstall();
      case RuntimeExtension.python:
        await _pythonTileKey.currentState?.startInstall();
    }
  }

  /// 网盘登录/凭据集中弹窗：设置页只保留入口，避免主页区块被 Cookie 配置挤满。
  Future<void> _openDriveAccounts(BuildContext context) async {
    final app = AppScope.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('网盘账户'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: app,
              builder: (ctx, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final provider in driveProviderNames.keys)
                    _DriveAccountRow(provider: provider, app: app),
                  const SizedBox(height: 6),
                  Text(
                    '凭据经本机系统加密后保存（Windows DPAPI），仅用于蜘蛛源取流；换机备份时请勿泄露。',
                    style: Theme.of(ctx).textTheme.labelSmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.onSurface
                          .withValues(alpha: 0.72),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// WebDAV 服务器管理弹窗（同样从设置页独立出来）。
  Future<void> _openDavServers(BuildContext context) async {
    final app = AppScope.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('WebDAV'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: app,
              builder: (ctx, _) => _DavServerList(app: app),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(
                narrow ? 18 : 28,
                8,
                narrow ? 18 : 28,
                120,
              ),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '设置',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontSize: 26,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '所有数据都只保存在这台设备上',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_pageIndex == _contentPage)
                      FilledButton.tonalIcon(
                        onPressed: () => showImportConfigSheet(context),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('导入源'),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                _SettingsPager(index: _pageIndex, onChanged: _selectPage),
                const SizedBox(height: 16),
                if (_pageIndex == _contentPage) ...[
                  _Section(
                    title: '订阅配置',
                    icon: Icons.playlist_add_check_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '${app.vodProfiles.length} 个',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: _ProfileSummary(app: app),
                    child: app.vodProfiles.isEmpty
                        ? EmptyState(
                            icon: Icons.inbox_outlined,
                            title: '还没有配置',
                            message: '导入 TVBox JSON 订阅开始使用',
                            compact: true,
                            action: FilledButton.tonalIcon(
                              onPressed: () => showImportConfigSheet(context),
                              icon: const Icon(Icons.add_rounded),
                              label: const Text('导入订阅'),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  if (!kIsWeb) ...[
                                    TextButton.icon(
                                      onPressed: () =>
                                          _importLocalJsonFile(context),
                                      icon: const Icon(
                                        Icons.file_open_outlined,
                                        size: 17,
                                      ),
                                      label: const Text('本地 JSON'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () =>
                                          _importLocalPyFiles(context),
                                      icon: const Icon(
                                        Icons.code_rounded,
                                        size: 17,
                                      ),
                                      label: const Text('本地 PY（可多选）'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () =>
                                          _importLocalPackage(context),
                                      icon: const Icon(
                                        Icons.folder_open_rounded,
                                        size: 17,
                                      ),
                                      label: const Text('本地包'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () => _importLocalPackage(
                                        context,
                                        zip: true,
                                      ),
                                      icon: const Icon(
                                        Icons.archive_outlined,
                                        size: 17,
                                      ),
                                      label: const Text('本地包 ZIP'),
                                    ),
                                    TextButton.icon(
                                      onPressed: () => _showProfileHistory(
                                        context,
                                        app,
                                      ),
                                      icon: const Icon(
                                        Icons.history_rounded,
                                        size: 17,
                                      ),
                                      label: Text(
                                        '订阅历史（${app.profileHistory.length}）',
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: app.vodProfiles.length < 2
                                          ? null
                                          : () => _exportMerged(context),
                                      icon: const Icon(
                                        Icons.merge_rounded,
                                        size: 17,
                                      ),
                                      label: const Text('合并导出'),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 8),
                              for (final profile in app.vodProfiles) ...[
                                _ProfileTile(profile: profile, app: app),
                                if (profile != app.vodProfiles.last)
                                  const SizedBox(height: 8),
                              ],
                            ],
                          ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '站点',
                    icon: Icons.dns_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '${app.usableSites.length} / ${app.config?.sites.length ?? 0} 可用',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: _SiteSummary(app: app),
                    child: (app.config?.sites.isEmpty ?? true)
                        ? const EmptyState(
                            icon: Icons.source_outlined,
                            title: '没有站点',
                            message: '导入配置后在这里切换站点',
                            compact: true,
                          )
                        : _SiteList(sites: app.config!.sites, app: app),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: 'Kazumi 规则',
                    icon: Icons.auto_awesome_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '${app.kazumiRules.length} 条',
                      style: theme.textTheme.labelSmall,
                    ),
                    child: app.kazumiRules.isEmpty
                        ? EmptyState(
                            icon: Icons.auto_awesome_outlined,
                            title: '还没有 Kazumi 规则',
                            message: '从官方仓库导入动漫源规则；首页显示每日新番，点开可按片名搜索',
                            compact: true,
                            action: FilledButton.tonalIcon(
                              onPressed: () =>
                                  _importKazumiFromRepo(context, app),
                              icon: const Icon(Icons.cloud_download_outlined),
                              label: const Text('导入官方规则'),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  TextButton.icon(
                                    onPressed: () =>
                                        _importKazumiFromRepo(context, app),
                                    icon: const Icon(
                                      Icons.cloud_download_outlined,
                                      size: 17,
                                    ),
                                    label: const Text('导入官方规则'),
                                  ),
                                  if (!kIsWeb)
                                    TextButton.icon(
                                      onPressed: () =>
                                          _importKazumiFile(context, app),
                                      icon: const Icon(
                                        Icons.file_open_outlined,
                                        size: 17,
                                      ),
                                      label: const Text('本地 JSON'),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              for (final rule in app.kazumiRules)
                                _KazumiRuleRow(
                                  rule: rule,
                                  onDelete: () =>
                                      _deleteKazumiRule(context, app, rule),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '直播源',
                    icon: Icons.live_tv_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '${app.lives.length} 条',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: _LiveSummary(app: app),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (app.liveProfiles.isNotEmpty) ...[
                          Text(
                            '直播订阅',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          for (final profile in app.liveProfiles) ...[
                            _ProfileTile(
                              profile: profile,
                              app: app,
                              asLive: true,
                            ),
                            const SizedBox(height: 8),
                          ],
                          const SizedBox(height: 2),
                        ],
                        if (!kIsWeb) ...[
                          TextButton.icon(
                            onPressed: () => showImportConfigSheet(context),
                            icon: const Icon(Icons.link_rounded, size: 17),
                            label: const Text('导入直播订阅（M3U / TXT 地址）'),
                          ),
                          TextButton.icon(
                            onPressed: () => _importLocalLive(context),
                            icon: const Icon(
                              Icons.playlist_add_rounded,
                              size: 17,
                            ),
                            label: const Text('导入本地直播源（TXT / M3U）'),
                          ),
                          const SizedBox(height: 6),
                        ],
                        if (app.lives.isEmpty)
                          EmptyState(
                            icon: Icons.live_tv_outlined,
                            title: '当前没有直播源',
                            message: '导入 M3U / TXT 直播订阅，或使用含 lives 的 JSON 订阅',
                            compact: true,
                            action: kIsWeb
                                ? null
                                : TextButton.icon(
                                    onPressed: () => _importLocalLive(context),
                                    icon: const Icon(
                                      Icons.playlist_add_rounded,
                                    ),
                                    label: const Text('导入本地直播源'),
                                  ),
                          )
                        else
                          _LiveSourceList(lives: app.lives, app: app),
                        const SizedBox(height: 8),
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.35,
                          ),
                        ),
                        _ActionRow(
                          icon: Icons.badge_outlined,
                          title: '自定义直播 UA',
                          subtitle: _liveUaSubtitle(app),
                          onTap: () => _editLiveUaPolicy(context, app),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_pageIndex == _accountPage && !kIsWeb) ...[
                  // 这两项只弹窗、没有可展开的子内容，但也必须像其他设置分类
                  // 一样落在玻璃卡片里；直接放 ListTile 会变成一条裸露在页面
                  // 背景上的深色长条，和上下卡片之间像被切开。
                  GlassPanel(
                    padding: const EdgeInsets.fromLTRB(18, 4, 18, 4),
                    borderRadius: 24,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ActionRow(
                          icon: Icons.cloud_outlined,
                          title: '网盘账户',
                          subtitle: _driveAccountsSubtitle(app),
                          onTap: () => _openDriveAccounts(context),
                        ),
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.35,
                          ),
                        ),
                        _ActionRow(
                          icon: Icons.folder_shared_outlined,
                          title: 'WebDAV',
                          subtitle: '${app.davService.servers.length} 个服务器',
                          onTap: () => _openDavServers(context),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_pageIndex == _contentPage &&
                    app.activeReport.items.any((e) => e.status != 'OK')) ...[
                  const SizedBox(height: 16),
                  _Section(
                    title: '导入诊断',
                    icon: Icons.healing_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '${app.activeReport.items.where((e) => e.status != 'OK').length} 条',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '有源被降级或跳过（JAR / PUSH 等），点击展开查看原因',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      children: [
                        for (final item in app.activeReport.items.where(
                          (e) => e.status != 'OK',
                        ))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  item.status == 'SKIP'
                                      ? Icons.remove_circle_outline
                                      : Icons.warning_amber_rounded,
                                  size: 18,
                                  color: item.status == 'SKIP'
                                      ? theme.disabledColor
                                      : theme.colorScheme.error,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${item.name} · ${item.reason ?? item.status}',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      Text(
                                        item.message,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: theme.colorScheme.onSurface
                                                  .withValues(alpha: 0.70),
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (_pageIndex == _contentPage) ...[
                  const SizedBox(height: 16),
                  _Section(
                    title: '源审计',
                    icon: Icons.manage_search_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.auditingSources
                          ? '${app.auditDone}/${app.auditTotal}'
                          : app.auditResults.isEmpty
                          ? '${app.usableSites.length} 个可用源'
                          : '${app.auditResults.where((e) => !e.ok).length} 个异常',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '批量访问每个源的主页，检查条目 / 分类 / 耗时；结果可复制或导出',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: app.auditingSources
                                  ? null
                                  : () => app.auditSources(),
                              icon: app.auditingSources
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.play_arrow_rounded),
                              label: Text(
                                app.auditingSources ? '审计中…' : '开始审计',
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: app.auditResults.isEmpty
                                  ? null
                                  : () async {
                                      await Clipboard.setData(
                                        ClipboardData(
                                          text: app.auditReportText(),
                                        ),
                                      );
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('审计报告已复制到剪贴板'),
                                        ),
                                      );
                                    },
                              icon: const Icon(Icons.copy_rounded, size: 18),
                              label: const Text('复制报告'),
                            ),
                            OutlinedButton.icon(
                              onPressed: app.auditResults.isEmpty
                                  ? null
                                  : () => _exportAuditReport(app),
                              icon: const Icon(
                                Icons.file_download_outlined,
                                size: 18,
                              ),
                              label: const Text('导出'),
                            ),
                            if (app.auditResults.isNotEmpty)
                              FilterChip(
                                label: const Text('只看异常'),
                                selected: _auditOnlyFailed,
                                onSelected: (value) =>
                                    setState(() => _auditOnlyFailed = value),
                              ),
                          ],
                        ),
                        if (app.auditingSources) ...[
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            value: app.auditTotal == 0
                                ? null
                                : app.auditDone / app.auditTotal,
                          ),
                        ],
                        if (app.auditResults.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          for (final health in app.auditResults
                              .where((e) => !_auditOnlyFailed || !e.ok)
                              .take(80))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    health.ok
                                        ? Icons.check_circle_outline_rounded
                                        : Icons.error_outline_rounded,
                                    size: 18,
                                    color: health.ok
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.error,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${health.name} · ${health.statusLabel}'
                                          '${health.elapsedMs > 0 ? ' · ${health.elapsedMs}ms' : ''}',
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                        Text(
                                          health.message,
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                color: theme
                                                    .colorScheme
                                                    .onSurface
                                                    .withValues(alpha: 0.68),
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (app.auditResults
                                  .where((e) => !_auditOnlyFailed || !e.ok)
                                  .length >
                              80)
                            Text(
                              '仅显示前 80 条，完整结果请导出报告',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.55,
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
                if (_pageIndex == _contentPage) ...[
                  const SizedBox(height: 16),
                  _Section(
                    title: '源健康',
                    icon: Icons.health_and_safety_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '${app.coolingSources.length} 个冷却中',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '连续失败的源按 15 分钟 / 2 小时 / 24 小时依次冷却；可手动恢复',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: app.coolingSources.isEmpty
                        ? Text(
                            '当前没有冷却中的源',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                            ),
                          )
                        : Column(
                            children: [
                              for (final row in app.coolingSources)
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    Icons.timer_off_outlined,
                                    size: 20,
                                    color: theme.colorScheme.error,
                                  ),
                                  title: Text(row.site.displayName),
                                  subtitle: Text(
                                    '冷却至 ${TimeOfDay.fromDateTime(row.record.cooldownUntil).format(context)}'
                                    '${row.record.lastError.isEmpty ? '' : ' · ${row.record.lastError}'}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: TextButton(
                                    onPressed: () =>
                                        app.resetSourceHealthOf(row.site),
                                    child: const Text('恢复'),
                                  ),
                                ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed: () => app.resetSourceHealth(),
                                  icon: const Icon(
                                    Icons.restart_alt_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('全部恢复'),
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
                if (_pageIndex == _playPage) ...[
                  _Section(
                    title: '外观',
                    icon: Icons.palette_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      _themeModeLabel(app.themeMode),
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: _AppearanceSummary(app: app),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ThemeModeTabs(
                          value: app.themeMode,
                          onChanged: (mode) => app.setThemeMode(mode),
                        ),
                        const SizedBox(height: 18),
                        Text('主题色', style: theme.textTheme.labelMedium),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 12,
                          children: [
                            for (
                              var i = 0;
                              i < AppState.accentPalette.length;
                              i++
                            )
                              _AccentDot(
                                color: AppState.accentPalette[i],
                                selected: app.accentIndex == i,
                                onTap: () => app.setAccentIndex(i),
                              ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Text('底部横条', style: theme.textTheme.labelMedium),
                        const SizedBox(height: 4),
                        Text(
                          '常驻时固定在底部；自动隐藏时只在鼠标靠近窗口底部时滑出，并可遮住上方封面',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final item in const [
                              (false, '常驻'),
                              (true, '自动隐藏'),
                            ])
                              ChoiceChip(
                                label: Text(item.$2),
                                selected: app.navBarAutoHide == item.$1,
                                onSelected: (_) =>
                                    app.setNavBarAutoHide(item.$1),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text('横条大小', style: theme.textTheme.labelMedium),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final item in const [
                              (0, '紧凑'),
                              (1, '标准'),
                              (2, '较大'),
                              (3, '超大'),
                            ])
                              ChoiceChip(
                                label: Text(item.$2),
                                selected: app.navBarSize == item.$1,
                                onSelected: (_) => app.setNavBarSize(item.$1),
                              ),
                          ],
                        ),
                        const Divider(height: 24),
                        const SizedBox(height: 4),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('沉浸观影模式'),
                          subtitle: const Text(
                            '大屏 TV 布局：首页海报轮播、横图卡片、沉浸式详情页（选集自动匹配 B 站/TMDB 剧照）；播放器保持不变',
                          ),
                          value: app.playerSettings.immersiveMode,
                          onChanged: (value) async {
                            await app.setPlayerSettings(
                              app.playerSettings.copyWith(immersiveMode: value),
                            );
                            if (context.mounted) {
                              _settingsSnack(
                                context,
                                value ? '已开启沉浸观影模式' : '已退出沉浸观影模式',
                              );
                            }
                          },
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('首页台词轮换'),
                          subtitle: const Text(
                            '首页顶部每 30 秒轮换一句影视台词，点击可按片名搜索；关闭后连 LOGO 与档案名一起收起，导入按钮下移到「N 个可用站点」那一行',
                          ),
                          value: app.showMovieQuotes,
                          onChanged: (value) => app.setShowMovieQuotes(value),
                        ),
                        // 只有 Windows 能另开窗口；其余平台不给一个按了没反应的开关。
                        if (supportsStandalonePlayerWindow)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('内置播放器独立窗口'),
                            subtitle: Text(
                              '在软件主界面之外打开独立播放器窗口，主界面保持可见；'
                              '关闭则像现在一样在软件主界面内播放'
                              '${app.playerSettings.immersiveMode && app.playerSettings.popOutPlayer ? '（沉浸观影模式下暂停生效，退出后自动恢复）' : ''}',
                            ),
                            value: app.playerSettings.popOutPlayer,
                            onChanged: (value) async {
                              await app.setPlayerSettings(
                                app.playerSettings.copyWith(
                                  popOutPlayer: value,
                                ),
                              );
                              if (!context.mounted) return;
                              final paused =
                                  value && app.playerSettings.immersiveMode;
                              _settingsSnack(
                                context,
                                !value
                                    ? '内置播放器已改为嵌入主界面'
                                    : paused
                                    ? '已开启：沉浸观影模式下暂停生效，退出后自动恢复'
                                    : '内置播放器将以独立窗口打开',
                              );
                            },
                          ),
                        _ActionRow(
                          icon: Icons.image_outlined,
                          title: '横图封面来源',
                          subtitle:
                              '${_artworkSourceLabel(app.playerSettings.artworkPriority)}'
                              '${_tmdbCredentialLabel(app.playerSettings.tmdbApiKey, app.playerSettings.tmdbReadToken)}',
                          onTap: () => _openArtworkSettings(context, app),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '界面与首页',
                    icon: Icons.dashboard_customize_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.playerSettings.immersiveMode ? '沉浸观影' : '标准布局',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '沉浸观影：${app.playerSettings.immersiveMode ? '开' : '关'}'
                      ' · 台词轮换：${app.showMovieQuotes ? '开' : '关'}'
                      ' · 每行 ${app.homeColumns == 0 ? '自动' : '${app.homeColumns} 个'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text('分类浏览方式', style: theme.textTheme.labelMedium),
                        const SizedBox(height: 4),
                        Text(
                          '换页：底部上一页 / 下一页；瀑布：滑到底自动加载下一页',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final item in const [(0, '换页'), (1, '瀑布')])
                              ChoiceChip(
                                label: Text(item.$2),
                                selected: app.homeBrowseMode == item.$1,
                                onSelected: (_) =>
                                    app.setHomeBrowseMode(item.$1),
                              ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Text('首页每行封面', style: theme.textTheme.labelMedium),
                        const SizedBox(height: 4),
                        Text(
                          '默认窗口大小下一行显示几个封面；自动 = 随窗口宽度排列',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.55,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final item in const [
                              (0, '自动'),
                              (4, '4 个'),
                              (5, '5 个'),
                              (6, '6 个'),
                              (7, '7 个'),
                              (8, '8 个'),
                            ])
                              ChoiceChip(
                                label: Text(item.$2),
                                selected: app.homeColumns == item.$1,
                                onSelected: (_) => app.setHomeColumns(item.$1),
                              ),
                          ],
                        ),
                        if (supportsAppWindowSize) ...[
                          const SizedBox(height: 18),
                          Text('窗口尺寸', style: theme.textTheme.labelMedium),
                          const SizedBox(height: 4),
                          Text(
                            app.rememberedWindowSize == null
                                ? '未记忆：启动时按显示器比例自动计算'
                                : '已记忆 ${app.rememberedWindowSize!.width.round()} × '
                                      '${app.rememberedWindowSize!.height.round()}，'
                                      '下次启动使用',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.55,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: () async {
                                  final size = await currentAppWindowSize();
                                  if (size == null) return;
                                  await app.setRememberedWindowSize(size);
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '已记住窗口尺寸 '
                                        '${size.width.round()} × '
                                        '${size.height.round()}',
                                      ),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.aspect_ratio_rounded),
                                label: const Text('记住当前窗口尺寸'),
                              ),
                              if (app.rememberedWindowSize != null)
                                TextButton(
                                  onPressed: () =>
                                      app.setRememberedWindowSize(null),
                                  child: const Text('恢复默认'),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    key: _playSectionKey,
                    title: '播放行为',
                    icon: Icons.play_circle_outline_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      '连播 ${app.playerSettings.autoPlayNext ? '开' : '关'}'
                      ' · 换线 ${app.playerSettings.autoSwitchLine ? '开' : '关'}',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: _PlaySummary(app: app),
                    child: Column(
                      children: [
                        SwitchListTile.adaptive(
                          value: app.playerSettings.autoPlayNext,
                          onChanged: (v) => app.setPlayerSettings(
                            app.playerSettings.copyWith(autoPlayNext: v),
                          ),
                          title: const Text('自动连播下一集'),
                          subtitle: const Text('当前集播放结束后自动切换'),
                          contentPadding: EdgeInsets.zero,
                        ),
                        SwitchListTile.adaptive(
                          value: app.playerSettings.autoSwitchLine,
                          onChanged: (v) => app.setPlayerSettings(
                            app.playerSettings.copyWith(autoSwitchLine: v),
                          ),
                          title: const Text('自动换线路'),
                          subtitle: const Text(
                            '当前线路播放失败时自动尝试下一条线路；'
                            '本源线路都失败后再搜索其他源的相同片名',
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        SwitchListTile.adaptive(
                          value: app.playerSettings.rememberProgress,
                          onChanged: (v) => app.setPlayerSettings(
                            app.playerSettings.copyWith(rememberProgress: v),
                          ),
                          title: const Text('记住播放进度'),
                          subtitle: const Text('退出播放器时保存进度，下次继续'),
                          contentPadding: EdgeInsets.zero,
                        ),
                        SwitchListTile.adaptive(
                          value: app.playerSettings.incognito,
                          onChanged: (v) => app.setPlayerSettings(
                            app.playerSettings.copyWith(incognito: v),
                          ),
                          title: const Text('无痕模式'),
                          subtitle: const Text(
                            '所有播放都不写入观看历史、不保存断点进度；'
                            '播放器内仍可对单次播放临时关闭',
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('历史保留条数'),
                          subtitle: const Text('超出后按更新时间淘汰最旧记录（30–500）'),
                          trailing: DropdownButton<int>(
                            value: app.playerSettings.historyLimit,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final value in ({
                                30,
                                50,
                                100,
                                200,
                                300,
                                500,
                                app.playerSettings.historyLimit,
                              }.toList()..sort()))
                                DropdownMenuItem(
                                  value: value,
                                  child: Text('$value 条'),
                                ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              app.setPlayerSettings(
                                app.playerSettings.copyWith(
                                  historyLimit: value,
                                ),
                              );
                            },
                          ),
                        ),
                        SwitchListTile.adaptive(
                          value: app.playerSettings.m3u8Purify,
                          onChanged: (v) => app.setPlayerSettings(
                            app.playerSettings.copyWith(m3u8Purify: v),
                          ),
                          title: const Text('m3u8 去广告'),
                          subtitle: const Text('点播清单播放前清洗广告分段（启发式，默认关）'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '缓冲与缓存',
                    icon: Icons.speed_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.playerSettings.streamCache ? '边播边缓存' : '不缓存',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '预缓冲 ${app.playerSettings.bufferMinSec.toStringAsFixed(1)}s'
                      ' · 最大 ${app.playerSettings.bufferMaxSec.toStringAsFixed(0)}s'
                      ' · 缓存 ${app.playerSettings.streamCache ? '${app.playerSettings.streamCacheMb}MB' : '关'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.memory_rounded,
                          title: '播放缓冲',
                          subtitle:
                              '起播预缓冲 '
                              '${app.playerSettings.bufferMinSec.toStringAsFixed(1)}s · '
                              '最大缓冲 '
                              '${app.playerSettings.bufferMaxSec.toStringAsFixed(0)}s',
                          onTap: () => _editBufferSettings(context, app),
                        ),
                        SwitchListTile.adaptive(
                          value: app.playerSettings.streamCache,
                          onChanged: (v) => app.setPlayerSettings(
                            app.playerSettings.copyWith(streamCache: v),
                          ),
                          title: const Text('边播边缓存'),
                          subtitle: const Text(
                            '把已下行的分片存到本地：重看、拖回看过的位置直接读盘，不再回源',
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        _ActionRow(
                          icon: Icons.sd_storage_outlined,
                          title: '缓存容量上限',
                          subtitle:
                              '${app.playerSettings.streamCacheMb} MB'
                              '（超出后按最久未使用淘汰）',
                          onTap: () => _pickStreamCacheSize(context, app),
                        ),
                        _ActionRow(
                          icon: Icons.cleaning_services_outlined,
                          title: '清空播放缓存',
                          subtitle: '只清理边播缓存目录，不影响收藏 / 历史 / 订阅',
                          onTap: () => _clearStreamCache(context),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '画面与播放器',
                    icon: Icons.aspect_ratio_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      playerFitLabel(app.playerSettings.fit),
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '${playerFitLabel(app.playerSettings.fit)}'
                      ' · ${_defaultPlayerLabel(app)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.aspect_ratio_rounded,
                          title: '画面比例',
                          subtitle: playerFitLabel(app.playerSettings.fit),
                          onTap: () => _pickPlayerFit(context, app),
                        ),
                        if (!kIsWeb &&
                            defaultTargetPlatform ==
                                TargetPlatform.windows) ...[
                          _ActionRow(
                            icon: Icons.play_circle_outline_rounded,
                            title: '默认播放器',
                            subtitle: _defaultPlayerLabel(app),
                            onTap: () => _pickDefaultPlayer(context, app),
                          ),
                          _ActionRow(
                            icon: Icons.open_in_new_rounded,
                            title: '自定义第三方播放器',
                            subtitle: app.playerSettings.externalPlayers.isEmpty
                                ? '未添加；可直接选择播放器 exe，无需安装识别'
                                : '已添加 ${app.playerSettings.externalPlayers.length} 个播放器',
                            onTap: () => _editExternalPlayers(context),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '下载与网盘',
                    icon: Icons.cloud_download_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.xunleiAccount.loggedIn ? '迅雷已登录' : '只用 aria2',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '迅雷云盘：${app.xunleiAccount.loggedIn ? app.xunleiAccount.displayName : '未登录'}'
                      ' · 下载 ${app.videoDownloads.records.length} 个'
                      ' · 磁力目录：${app.playerSettings.magnetDownloadDir.isEmpty ? '默认' : '自定义'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.download_done_rounded,
                          title: '下载管理',
                          subtitle:
                              '播放器下载的视频与边播缓存；'
                              '支持暂停 / 继续 / 删除，也可只清记录、保留文件',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const VideoDownloadsPage(),
                            ),
                          ),
                        ),
                        _ActionRow(
                          icon: Icons.cloud_download_outlined,
                          title: '迅雷云盘',
                          subtitle: app.xunleiAccount.loggedIn
                              ? '${app.xunleiAccount.displayName} · '
                                    '磁力优先走云端离线下载'
                              : '未登录；支持账号密码（含短信验证）或刷新令牌',
                          onTap: () => _editXunlei(context, app),
                        ),
                        SwitchListTile.adaptive(
                          value: app.xunleiAccount.enabled,
                          onChanged: app.xunleiAccount.loggedIn
                              ? (v) => app.setXunleiEnabled(v)
                              : null,
                          title: const Text('磁力优先使用迅雷云盘'),
                          subtitle: const Text(
                            '先提交到迅雷云盘离线下载，云端完成后播放；'
                            '未登录、关闭或失败时自动回退 aria2',
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        _ActionRow(
                          icon: Icons.folder_open_rounded,
                          title: '磁力下载位置',
                          subtitle: app.playerSettings.magnetDownloadDir.isEmpty
                              ? '默认：应用数据目录/bt（点击自定义）'
                              : app.playerSettings.magnetDownloadDir,
                          onTap: () => _pickMagnetDownloadDir(context, app),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '协同与媒体',
                    icon: Icons.hub_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    summary: Text(
                      '多端同步：${app.syncSettings.lastSyncAt > 0 ? '已同步过' : '未同步'}'
                      ' · 媒体服务器：${app.mediaServers.servers.length} 个'
                      ' · 本地目录：${app.localMedia.dirs.length} 个',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.sync_rounded,
                          title: '多端同步',
                          subtitle: app.lanServer.running
                              ? '局域网服务已开启（端口 ${app.lanServer.port}）'
                              : 'WebDAV / 局域网同步历史、收藏与片头片尾',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const SyncPage(),
                            ),
                          ),
                        ),
                        _ActionRow(
                          icon: Icons.download_outlined,
                          title: '下载管理',
                          subtitle: app.downloadManager.available
                              ? 'aria2 · ${app.downloadManager.tasks.length} 个任务'
                              : '浏览器版不支持 aria2 下载',
                          onTap: app.downloadManager.available
                              ? () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const DownloadsPage(),
                                  ),
                                )
                              : null,
                        ),
                        _ActionRow(
                          icon: Icons.video_library_outlined,
                          title: '媒体库',
                          subtitle:
                              'Emby / Jellyfin · 本地视频'
                              '${app.mediaServers.servers.isEmpty ? '（未配置服务器）' : ''}',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const MediaLibraryPage(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '网络',
                    icon: Icons.vpn_lock_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.proxy.valid
                          ? '手动代理'
                          : (app.proxy.followSystem ? '跟随系统' : '直连'),
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      ProxyRuntime.instance.summary,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.vpn_lock_outlined,
                          title: '网络代理',
                          // 显示实际生效的上游：跟随系统代理时能看到解析到的地址。
                          subtitle: ProxyRuntime.instance.summary,
                          onTap: () => _editProxy(context),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),
                  _Section(
                    title: '字幕与弹幕',
                    icon: Icons.subtitles_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.danmakuSettings.enabled ? '弹幕默认开' : '弹幕默认关',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      '弹幕：${app.danmakuSettings.enabled ? '开' : '关'}'
                      ' · 字号 ${app.danmakuSettings.fontSize.toStringAsFixed(0)}'
                      ' · assrt：${app.assrtToken.isEmpty ? '未配置' : '已配置'}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.subtitles_outlined,
                          title: 'assrt 字幕 token',
                          subtitle: app.assrtToken.isEmpty
                              ? '未配置（SubtitleCat 免 token，仍可在线搜字幕）'
                              : '已配置（在线字幕会同时查 assrt 与 SubtitleCat）',
                          onTap: () => _editAssrtToken(context),
                        ),
                        _ActionRow(
                          icon: Icons.link_rounded,
                          title: '自定义字幕 API',
                          subtitle: app.customSubtitleApis.trim().isEmpty
                              ? '未配置；支持返回 JSON 列表或字幕文件的 URL 模板'
                              : '已配置 ${_customLineCount(app.customSubtitleApis)} 个接口',
                          onTap: () => _editSubtitleApis(context),
                        ),
                        SwitchListTile.adaptive(
                          value: app.danmakuSettings.enabled,
                          onChanged: (v) => app.setDanmakuSettings(
                            app.danmakuSettings.copyWith(enabled: v),
                          ),
                          title: const Text('默认开启弹幕'),
                          subtitle: const Text('优先使用已启用接口；未命中会自动扩大搜索'),
                          contentPadding: EdgeInsets.zero,
                        ),
                        _ActionRow(
                          icon: Icons.chat_bubble_outline_rounded,
                          title: '弹幕样式',
                          subtitle:
                              '字号 ${app.danmakuSettings.fontSize.toStringAsFixed(0)} · '
                              '${(app.danmakuSettings.regionRatio * 100).round()}% 屏 · '
                              '透明度 ${(app.danmakuSettings.opacity * 100).round()}% · '
                              '速度 ${app.danmakuSettings.speed.round()} · '
                              '偏移 ${app.danmakuSettings.offset.toStringAsFixed(1)}s'
                              '${app.danmakuSettings.blockWords.isEmpty ? '' : ' · 屏蔽 ${app.danmakuSettings.blockWords.length} 词'}',
                          onTap: () => _editDanmakuStyle(context),
                        ),
                        _ActionRow(
                          icon: Icons.travel_explore_rounded,
                          title: '弹幕接口',
                          subtitle: _danmakuEndpointsSubtitle(
                            app.danmakuSettings,
                          ),
                          onTap: () => _editDanmakuEndpoints(context),
                        ),
                      ],
                    ),
                  ),
                  if (!kIsWeb &&
                      defaultTargetPlatform == TargetPlatform.windows) ...[
                    const SizedBox(height: 16),
                    _Section(
                      title: '运行时组件',
                      icon: Icons.memory_rounded,
                      collapsible: true,
                      initiallyExpanded: false,
                      trailing: Text(
                        'MPV / Python / JVM / 加固壳',
                        style: theme.textTheme.labelSmall,
                      ),
                      summary: Text(
                        '第三方播放器、蜘蛛运行时与加固壳解包组件按需下载',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.45,
                          ),
                        ),
                      ),
                      child: Column(
                        children: [
                          const _MpvExtensionTile(),
                          const Divider(height: 24),
                          _PythonRuntimeTile(key: _pythonTileKey),
                          const Divider(height: 24),
                          _JvmRuntimeTile(key: _jvmTileKey),
                          const Divider(height: 24),
                          _ArmBridgeTile(key: _guardTileKey),
                          const Divider(height: 24),
                          _ActionRow(
                            icon: Icons.extension_outlined,
                            title: '网盘下载支持库',
                            subtitle: '在浏览器中打开 123 云盘分享页（提取码 Misa）',
                            onTap: () => launchUrl(
                              Uri.parse(
                                'https://1824896562.share.123pan.cn/123pan/syh2jv-j1p6h?pwd=Misa#',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (!kIsWeb) ...[
                    const SizedBox(height: 16),
                    _Section(
                      title: '性能',
                      icon: Icons.speed_rounded,
                      collapsible: true,
                      initiallyExpanded: false,
                      trailing: Text(
                        app.playerSettings.jsWorkerPool ||
                                app.playerSettings.keepSpiderHosts
                            ? '已开启'
                            : '默认',
                        style: theme.textTheme.labelSmall,
                      ),
                      summary: Text(
                        'JS 并行：${app.playerSettings.jsWorkerPool ? '开' : '关'}'
                        ' · JVM 保温：${app.playerSettings.keepSpiderHosts ? '开' : '关'}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.45,
                          ),
                        ),
                      ),
                      child: Column(
                        children: [
                          SwitchListTile.adaptive(
                            value: app.playerSettings.jsWorkerPool,
                            onChanged: (v) => app.setPlayerSettings(
                              app.playerSettings.copyWith(jsWorkerPool: v),
                            ),
                            title: const Text('JS 蜘蛛并行（实验）'),
                            subtitle: const Text(
                              '多 JS 源同时搜索 / 浏览时最多使用 3 个 QuickJS 执行器，'
                              '避免所有请求排在一个 isolate 里；更占内存，默认关闭',
                            ),
                            contentPadding: EdgeInsets.zero,
                          ),
                          Text(
                            '开启后每个执行器使用独立的脚本本地存储文件。'
                            '如果某个 JS 源依赖 local 里的长期状态，切换开关后可能需要重新初始化一次。',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(
                                alpha: 0.5,
                              ),
                              height: 1.5,
                            ),
                          ),
                          const Divider(height: 24),
                          SwitchListTile.adaptive(
                            value: app.playerSettings.keepSpiderHosts,
                            onChanged: (v) => app.setPlayerSettings(
                              app.playerSettings.copyWith(keepSpiderHosts: v),
                            ),
                            title: const Text('常驻 JVM 保温（实验）'),
                            subtitle: const Text(
                              '搜索 / 浏览结束后保留 JVM 取数进程 2 分钟，减少再次冷启动；'
                              '更占内存，默认关闭',
                            ),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
                if (_pageIndex == _safetyPage) ...[
                  _Section(
                    title: '内容过滤',
                    icon: Icons.shield_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      app.contentFilter.enabled ? '已开启' : '已关闭',
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: _ContentFilterSummary(app: app),
                    child: Column(
                      children: [
                        SwitchListTile.adaptive(
                          value: app.contentFilter.enabled,
                          onChanged: (v) =>
                              _toggleContentFilter(context, app, v),
                          title: const Text('屏蔽 R18 / 成人内容'),
                          subtitle: const Text(
                            '开启时设置关闭密码，关闭过滤必须输入该密码，防止儿童误关；命中关键词的条目与分类会从首页、分类与搜索结果里隐藏',
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        _ActionRow(
                          icon: Icons.rule_rounded,
                          title: '屏蔽关键词',
                          subtitle: app.contentFilter.keywords.isEmpty
                              ? '未设置关键词（当前不会过滤任何内容）'
                              : '${app.contentFilter.keywords.join(' · ')}'
                                    '${app.contentFilter.enabled ? '' : '（过滤已关闭，暂不生效）'}',
                          onTap: () => _editContentFilterKeywords(context),
                        ),
                        const Divider(height: 24),
                        Text(
                          '关键词不区分大小写，会匹配片名、备注、类型、地区、标签与来源名称；'
                          '分类名（如「伦理片」）命中时会从分类栏隐藏，其内容也不会出现在搜索结果里。'
                          '过滤只影响浏览与搜索，收藏和历史记录不会被删除；'
                          '关闭过滤需要输入开启时设置的密码。',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.5,
                            ),
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '隐私与快捷键',
                    icon: Icons.keyboard_outlined,
                    collapsible: true,
                    initiallyExpanded: false,
                    trailing: Text(
                      bossKeyLabel(app.playerSettings.bossKey),
                      style: theme.textTheme.labelSmall,
                    ),
                    summary: Text(
                      isBossKeySet(app.playerSettings.bossKey)
                          ? '老板键 ${bossKeyLabel(app.playerSettings.bossKey)}：暂停并收进托盘'
                          : '老板键未设置：不占用全局热键',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.45,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ActionRow(
                          icon: Icons.keyboard_outlined,
                          title: '老板键',
                          subtitle: isBossKeySet(
                            app.playerSettings.bossKey,
                          )
                              ? '${bossKeyLabel(app.playerSettings.bossKey)}'
                                    ' · 暂停视频并收进托盘；沉浸观影模式下不生效'
                              : '未设置 · 默认不占用任何全局热键，点此选择组合',
                          onTap: () => _openBossKeySettings(context, app),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_pageIndex == _accountPage) ...[
                  if (!kIsWeb) const SizedBox(height: 16),
                  _Section(
                    title: '数据',
                    icon: Icons.storage_rounded,
                    collapsible: true,
                    initiallyExpanded: false,
                    summary: _DataSummary(app: app),
                    child: Column(
                      children: [
                        if (!kIsWeb) ...[
                          _ActionRow(
                            icon: Icons.backup_outlined,
                            title: '导出设置备份',
                            subtitle: '订阅、收藏、历史、播放设置与网盘 Cookie（备份文件为明文）',
                            onTap: () => _exportBackup(context),
                          ),
                          _ActionRow(
                            icon: Icons.settings_backup_restore_rounded,
                            title: '导入设置备份',
                            subtitle: '支持 MisaTV 备份与旧版 Win-Box 备份',
                            onTap: () => _restoreBackup(context),
                          ),
                          const Divider(height: 24),
                          _ActionRow(
                            icon: Icons.content_cut_rounded,
                            title: '导出片头片尾',
                            subtitle: '${app.skipSegments.length} 条记录（JSON，可分享给其他设备）',
                            onTap: app.skipSegments.isEmpty
                                ? null
                                : () => _exportSkipSegments(app),
                          ),
                          _ActionRow(
                            icon: Icons.file_download_outlined,
                            title: '导入片头片尾',
                            subtitle: '合并 JSON 记录；同键以导入文件为准',
                            onTap: () => _importSkipSegments(app),
                          ),
                          _ActionRow(
                            icon: Icons.clear_all_rounded,
                            title: '清空片头片尾',
                            subtitle: '${app.skipSegments.length} 条记录',
                            onTap: app.skipSegments.isEmpty
                                ? null
                                : () async {
                                    final ok = await _confirm(
                                      context,
                                      '清空全部片头片尾记录？',
                                      '此操作不可恢复',
                                    );
                                    if (ok == true) {
                                      await app.clearSkipSegments();
                                    }
                                  },
                          ),
                          const Divider(height: 24),
                        ],
                        _ActionRow(
                          icon: Icons.history_rounded,
                          title: '清空观看历史',
                          subtitle: '${app.history.length} 条记录',
                          onTap: app.history.isEmpty
                              ? null
                              : () async {
                                  final ok = await _confirm(
                                    context,
                                    '清空全部观看历史？',
                                    '此操作不可恢复',
                                  );
                                  if (ok == true) await app.clearHistory();
                                },
                        ),
                        _ActionRow(
                          icon: Icons.favorite_border_rounded,
                          title: '清空收藏',
                          subtitle: '${app.favorites.length} 条收藏',
                          onTap: app.favorites.isEmpty
                              ? null
                              : () async {
                                  final ok = await _confirm(
                                    context,
                                    '清空全部收藏？',
                                    '此操作不可恢复',
                                  );
                                  if (ok == true) {
                                    for (final item in List.of(app.favorites)) {
                                      await app.removeFavorite(item.key);
                                    }
                                  }
                                },
                        ),
                        _ActionRow(
                          icon: Icons.search_off_rounded,
                          title: '清空搜索历史',
                          subtitle: '${app.searchHistory.length} 条关键词',
                          onTap: app.searchHistory.isEmpty
                              ? null
                              : app.clearSearchHistory,
                        ),
                        const Divider(height: 24),
                        _ActionRow(
                          icon: Icons.folder_open_rounded,
                          title: '运行日志',
                          subtitle: AppLog.directory.isEmpty
                              ? 'Web 版不写本地日志'
                              : '${AppLog.directory}（按天分文件，保留 14 天）',
                          onTap: AppLog.directory.isEmpty
                              ? null
                              : () => AppLog.openDirectory(),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_pageIndex == _safetyPage) ...[
                  const SizedBox(height: 16),
                  _Section(
                    title: '关于',
                    icon: Icons.info_outline_rounded,
                    // 关于是设置页唯一常驻展开的父分类（其余分类都必须可折叠）。
                    collapsible: false,
                    trailing: Text(
                      'v$kAppVersion',
                      style: theme.textTheme.labelSmall,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: Image.asset(
                                'assets/images/app_icon.png',
                                width: 44,
                                height: 44,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.medium,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'MisaTV',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                  ),
                                ),
                                Text(
                                  'v$kAppVersion · Flutter 轻量重构',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.70),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '基于 TVBox / CatVod 生态的本地优先客户端。不提供、不分发任何影视内容，所有源由用户自行配置。'
                          '请遵守所在地法律法规，仅用于个人学习与研究。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _ActionRow(
                          icon: Icons.system_update_alt_rounded,
                          title: '检查更新',
                          subtitle: '当前 v$kAppVersion · 有新版本会显示更新内容',
                          onTap: () => _checkUpdates(context),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () => launchUrl(
                                Uri.parse(
                                  'https://github.com/yagami-hue/MisaTV',
                                ),
                              ),
                              icon: const Icon(
                                Icons.open_in_new_rounded,
                                size: 16,
                              ),
                              label: const Text('官方网站'),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: () =>
                                  launchUrl(Uri.parse('https://t.me/MisaTV1')),
                              icon: const Icon(Icons.groups_rounded, size: 16),
                              label: const Text('官方群组'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 手动检查更新：没有新版本就给一条提示，有就直接弹更新框。
  Future<void> _checkUpdates(BuildContext context) async {
    _settingsSnack(context, '正在检查更新…');
    final release = await UpdateService().check();
    if (!context.mounted) return;
    if (release == null) {
      _settingsSnack(context, '已经是最新版本（v$kAppVersion）');
      return;
    }
    await showUpdateDialog(context, release);
  }

  Future<bool?> _confirm(BuildContext context, String title, String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }
}

/// 设置页的父分类（分页）。原有的可折叠分类分别挂在这四页下面。
const _settingsPages = <(IconData, String)>[
  (Icons.video_library_outlined, '内容与订阅'),
  (Icons.play_circle_outline_rounded, '播放与外观'),
  (Icons.cloud_outlined, '网盘与数据'),
  (Icons.shield_outlined, '安全与关于'),
];

class _SettingsPager extends StatelessWidget {
  const _SettingsPager({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassPanel(
      padding: const EdgeInsets.all(6),
      borderRadius: 20,
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (var i = 0; i < _settingsPages.length; i++)
            InkWell(
              onTap: () => onChanged(i),
              borderRadius: BorderRadius.circular(14),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: index == i
                      ? theme.colorScheme.primary.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: index == i
                        ? theme.colorScheme.primary.withValues(alpha: 0.35)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _settingsPages[i].$1,
                      size: 16,
                      color: index == i
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface.withValues(alpha: 0.76),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _settingsPages[i].$2,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: index == i
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.75,
                              ),
                        fontWeight: index == i
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Section extends StatefulWidget {
  const _Section({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
    this.collapsible = true,
    this.initiallyExpanded = false,
    this.summary,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  /// 设置页的每个父分类都必须可折叠（默认收起），点标题栏切换。
  final bool collapsible;
  final bool initiallyExpanded;

  /// 折叠时替代内容显示的一行摘要。
  final Widget? summary;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  late bool _expanded = widget.initiallyExpanded;

  /// 供设置页跳转展开使用（折叠态下的 child 不在树里）。
  void expand() {
    if (!widget.collapsible || _expanded) return;
    setState(() => _expanded = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final header = Row(
      children: [
        Icon(widget.icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(widget.title, style: theme.textTheme.titleMedium)),
        ?widget.trailing,
        if (widget.collapsible) ...[
          const SizedBox(width: 4),
          AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: Icon(
              Icons.expand_more_rounded,
              size: 20,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ],
      ],
    );
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      borderRadius: 24,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.collapsible)
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(12),
              child: header,
            )
          else
            header,
          if (!widget.collapsible || _expanded) ...[
            const SizedBox(height: 12),
            widget.child,
          ] else if (widget.summary != null) ...[
            const SizedBox(height: 10),
            widget.summary!,
          ],
        ],
      ),
    );
  }
}


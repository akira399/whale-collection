import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_updates.dart';

class UpdatesScope extends InheritedWidget {
  const UpdatesScope({super.key, required this.updates, required super.child});
  final AppUpdates updates;

  static AppUpdates? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdatesScope>()?.updates;

  @override
  bool updateShouldNotify(UpdatesScope oldWidget) =>
      updates != oldWidget.updates;
}

class UpdateTile extends StatelessWidget {
  const UpdateTile({super.key, this.home = false});
  final bool home;

  @override
  Widget build(BuildContext context) {
    final updates = UpdatesScope.maybeOf(context);
    if (updates == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final version = updates.release?.version;
        if (home && version == null) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.only(top: home ? 0 : 12, bottom: home ? 12 : 0),
          child: Card(
            child: ListTile(
              leading: const Icon(Icons.system_update_rounded),
              title: Text(home ? '发现新版本 $version' : '应用更新'),
              subtitle: Text(
                home
                    ? '查看更新内容并安装'
                    : version != null
                    ? '新版本 $version 可用'
                    : updates.installed == null
                    ? '检查最新版本'
                    : '当前版本 ${updates.installed}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (context) => _UpdatePage(updates: updates),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _UpdatePage extends StatelessWidget {
  const _UpdatePage({required this.updates});
  final AppUpdates updates;

  Future<void> _downloadAndInstall(BuildContext context) async {
    await updates.download();
    if (context.mounted &&
        ModalRoute.isCurrentOf(context) == true &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      await updates.install();
    }
  }

  Future<void> _openRelease(BuildContext context) async {
    try {
      if (await launchUrl(
        ReleaseClient.releasePage,
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } on Exception {
      // The system may have no application for opening web links.
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开发布页')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('应用更新')),
    body: SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListenableBuilder(
            listenable: updates,
            builder: (context, _) {
              final release = updates.release;
              final progress = updates.progress;
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '大肥鱼的收藏箱',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          if (updates.installed case final version?)
                            Text('已安装 $version'),
                          if (release != null)
                            Text(
                              '新版 ${release.version} · ${(release.size / (1024 * 1024)).toStringAsFixed(1)} MiB',
                            ),
                          const SizedBox(height: 14),
                          if (updates.checking) const LinearProgressIndicator(),
                          if (progress != null) ...[
                            LinearProgressIndicator(value: progress),
                            const SizedBox(height: 8),
                            Text(
                              progress >= 1
                                  ? '正在校验安装包…'
                                  : '正在从国内加速线路下载 ${(progress * 100).floor()}%',
                            ),
                          ],
                          if (updates.message case final message?) ...[
                            const SizedBox(height: 8),
                            Semantics(liveRegion: true, child: Text(message)),
                          ],
                          if (updates.downloaded)
                            const Text('安装包已校验，安装时请在系统界面确认。'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              if (release != null)
                                FilledButton.icon(
                                  onPressed: updates.busy
                                      ? null
                                      : updates.downloaded
                                      ? updates.install
                                      : () => _downloadAndInstall(context),
                                  icon: Icon(
                                    updates.downloaded
                                        ? Icons.install_mobile_rounded
                                        : Icons.download_rounded,
                                  ),
                                  label: Text(
                                    updates.downloaded ? '安装更新' : '下载并安装',
                                  ),
                                ),
                              OutlinedButton(
                                onPressed: updates.busy ? null : updates.check,
                                child: Text(updates.checking ? '检查中…' : '检查更新'),
                              ),
                              TextButton(
                                onPressed: () => _openRelease(context),
                                child: const Text('官方发布页'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (release != null && release.notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '更新内容',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            SelectableText(release.notes),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

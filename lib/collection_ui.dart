import 'dart:async';
import 'dart:math' as math;

import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';

import 'appearance.dart';
import 'card_glow.dart';
import 'collection_chrome.dart';
import 'collection_controller.dart';
import 'collection_models.dart';
import 'collection_store.dart';
import 'collection_transfer.dart';
import 'link_services.dart';
import 'mascot_dialogue.dart';
import 'update_page.dart';

const _networkNotice =
    '应用会访问你收藏的链接。原页面资料不足时，优先使用模型服务商的搜索，可能产生费用。其他情况使用 Mwmbl 或 Tavily 补查公开资料。'
    '模型服务会收到用于整理的内容片段或提示词文本。收藏和设置保存在此设备。';

void _message(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

Future<bool> _allowOrganization(
  BuildContext context,
  CollectionController controller,
) async {
  if (!controller.settings.consent) {
    final allow = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.cloud_outlined),
        title: const Text('允许联网整理？'),
        content: const Text(_networkNotice),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('仅保存在本机'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续整理'),
          ),
        ],
      ),
    );
    if (allow != true) return false;
    try {
      await controller.allowNetwork();
    } on Exception {
      if (context.mounted) _message(context, '无法保存联网设置，链接已保存在本机。');
      return false;
    }
  }
  return true;
}

Future<void> _start(
  BuildContext context,
  CollectionController controller,
  int id,
) async {
  if (controller.batchRunning) {
    _message(context, '当前正在批量整理，可在整理结束后处理这条收藏。');
    return;
  }
  if (await _allowOrganization(context, controller)) {
    unawaited(controller.run(id));
  }
}

typedef _Intake = ({
  List<Uri> links,
  String? prompt,
  int? existing,
  bool organize,
});

class CollectionPage extends StatefulWidget {
  const CollectionPage({
    super.key,
    required this.controller,
    this.acceptShares = false,
  });
  final CollectionController controller;
  final bool acceptShares;

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage>
    with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  late final _tabMotion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 230),
    value: 1,
  );
  late final _tabFade = _tabMotion.drive(
    CurveTween(curve: Curves.easeOutCubic),
  );
  late final _tabOffset = _tabFade.drive(
    Tween(begin: const Offset(0, .012), end: Offset.zero),
  );
  static const _shares = MethodChannel('app.toolcollection/share');
  bool _adding = false;
  bool _draining = false;
  int _heardBatch = 0;

  final _random = math.Random();
  int? _heardTool;
  int? _lastLine;
  String _petLine = mascotGreeting(DateTime.now().hour);
  CollectionController get controller => widget.controller;

  void _chatWithMascot() {
    final previous = _lastLine;
    var index = _random.nextInt(
      mascotChatter.length - (previous == null ? 0 : 1),
    );
    if (previous != null && index >= previous) index++;
    setState(() {
      _heardTool = controller.latestOrganizedTool?.id;
      _heardBatch = controller.batchVersion;
      _lastLine = index;
      _petLine = mascotChatter[index];
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.acceptShares) {
      _shares.setMethodCallHandler((call) async {
        if (call.method == 'available') unawaited(_drainShares());
      });
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_drainShares()),
      );
    }
  }

  Future<void> _drainShares() async {
    if (!mounted || !widget.acceptShares || _adding || _draining) return;
    _draining = true;
    try {
      while (mounted && !_adding) {
        final text = await _shares.invokeMethod<String>('take');
        if (!mounted || text == null) break;
        await _add(shared: text);
      }
    } on PlatformException {
      if (mounted) _message(context, '暂时无法读取分享的内容。');
    } finally {
      _draining = false;
    }
  }

  @override
  void dispose() {
    if (widget.acceptShares) _shares.setMethodCallHandler(null);
    _search.dispose();
    _scroll.dispose();
    _tabMotion.dispose();
    super.dispose();
  }

  Future<void> _add({String? shared}) async {
    if (_adding) return;
    _adding = true;
    try {
      ModalRoute<_Intake>? route;
      final value = await showModalBottomSheet<_Intake>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
            ? AnimationStyle.noAnimation
            : const AnimationStyle(
                duration: Duration(milliseconds: 310),
                reverseDuration: Duration(milliseconds: 220),
              ),
        builder: (context) {
          route = ModalRoute.of<_Intake>(context);
          return _LinkSheet(
            controller: controller,
            initialText: shared,
            isPrompt: shared == null
                ? controller.prompts
                : parseLinkText(shared).urls.isEmpty,
          );
        },
      );
      if (value == null) return;
      await route?.completed;
      if (!mounted) return;
      if (value.existing case final existing?) {
        _detail(existing);
        return;
      }
      if (value.prompt case final prompt?) {
        final id = await controller.addPrompt(prompt);
        if (!mounted) return;
        if (value.organize) await _start(context, controller, id);
        if (mounted) _detail(id);
        return;
      }
      final results = await controller.addLinks(value.links);
      if (!mounted) return;
      final fresh = [
        for (final item in results)
          if (item.added) item.id,
      ];
      if (results.length == 1) {
        final result = results.single;
        if (result.added && value.organize) {
          await _start(context, controller, result.id);
        }
        if (!mounted) return;
        if (!result.added) _message(context, '这条链接已收藏');
        _detail(result.id);
        return;
      }
      _message(
        context,
        '已收藏 ${fresh.length} 条，跳过 ${results.length - fresh.length} 条重复链接。',
      );
      if (value.organize && controller.batchRunning) {
        _message(context, '链接已保存，可在当前批次结束后整理。');
      } else if (value.organize &&
          fresh.isNotEmpty &&
          await _allowOrganization(context, controller)) {
        unawaited(controller.runBatch(fresh));
      }
    } on Exception {
      if (mounted) _message(context, '无法保存收藏，请重试。');
    } finally {
      _adding = false;
      unawaited(_drainShares());
    }
  }

  void _detail(int id, {Entry? initialEntry}) {
    FocusScope.of(context).unfocus();
    if (MediaQuery.disableAnimationsOf(context)) {
      Navigator.of(context).push<void>(
        PageRouteBuilder(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (context, _, _) => _DetailPage(
            controller: controller,
            id: id,
            initialEntry: initialEntry,
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => _DetailPage(controller: controller, id: id),
      ),
    );
  }

  void _selectCollection(int index) {
    final prompts = index == 1;
    if (controller.prompts == prompts) return;
    FocusScope.of(context).unfocus();
    _search.clear();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    controller.selectPage(prompts);
    if (!MediaQuery.disableAnimationsOf(context)) {
      unawaited(_tabMotion.forward(from: 0));
    }
  }

  void _selectEntries({required bool export}) {
    FocusScope.of(context).unfocus();
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => _SelectionPage(
          controller: controller,
          exporting: export,
          prompts: controller.prompts,
          visibleIds: export
              ? controller.entries.map((entry) => entry.id).toSet()
              : null,
        ),
      ),
    );
  }

  Widget _collectionCard(BuildContext context, Entry entry) {
    final theme = Theme.of(context);
    final progress = controller.progress(entry.id);
    if (MediaQuery.disableAnimationsOf(context)) {
      return Card(
        child: _EntryCard(
          entry: entry,
          progress: progress,
          onOpen: () => _detail(entry.id, initialEntry: entry),
          onPin: () => _togglePin(context, controller, entry),
        ),
      );
    }
    return OpenContainer<void>(
      tappable: false,
      closedElevation: 0,
      openElevation: 0,
      closedColor:
          theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLowest,
      openColor: theme.scaffoldBackgroundColor,
      middleColor: theme.scaffoldBackgroundColor,
      closedShape: theme.cardTheme.shape ?? const RoundedRectangleBorder(),
      transitionDuration: const Duration(milliseconds: 330),
      transitionType: ContainerTransitionType.fadeThrough,
      closedBuilder: (context, open) => Material(
        type: MaterialType.transparency,
        child: _EntryCard(
          entry: entry,
          progress: progress,
          onPin: () => _togglePin(context, controller, entry),
          onOpen: () {
            FocusScope.of(context).unfocus();
            open();
          },
        ),
      ),
      openBuilder: (context, _) => _DetailPage(
        controller: controller,
        id: entry.id,
        initialEntry: entry,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Scaffold(
        extendBody: true,
        bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom > 0
            ? null
            : CollectionDock(
                selected: controller.prompts ? 1 : 0,
                onSelect: _selectCollection,
              ),
        appBar: AppBar(
          title: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Image.asset(
                  'assets/images/whale_avatar.png',
                  width: 36,
                  height: 36,
                  excludeFromSemantics: true,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FittedBox(
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '大肥鱼的收藏箱',
                    maxLines: 1,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              onPressed: controller.entries.isEmpty
                  ? null
                  : () => _selectEntries(export: true),
              tooltip: '导出收藏清单',
              icon: const Icon(Icons.ios_share_rounded),
            ),
            IconButton(
              onPressed: controller.loading
                  ? null
                  : () => _settings(context, controller),
              tooltip: '设置',
              icon: const Icon(Icons.tune_rounded),
            ),
            const SizedBox(width: 10),
          ],
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: _ReadingWidth(
            child: Builder(
              builder: (context) {
                final entries = controller.entries;
                final loading = controller.loading;
                final error = controller.loadError;
                final list = ListView.builder(
                  controller: _scroll,
                  findChildIndexCallback: (key) {
                    if (key is! ValueKey<int>) return null;
                    final index = entries.indexWhere(
                      (entry) => entry.id == key.value,
                    );
                    return index < 0 ? null : index + 1;
                  },
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(
                    16,
                    10,
                    16,
                    24 + MediaQuery.paddingOf(context).bottom,
                  ),
                  itemCount:
                      1 +
                      (entries.isEmpty || error != null ? 1 : entries.length),
                  itemBuilder: (context, index) {
                    if (index == 0) return _header(context);
                    if (error != null) {
                      return _Empty(
                        icon: Icons.sync_problem_rounded,
                        title: error,
                        action: TextButton(
                          onPressed: controller.refresh,
                          child: const Text('重试'),
                        ),
                      );
                    }
                    if (entries.isEmpty) {
                      return _CollectionSwap(
                        child: loading
                            ? const Padding(
                                padding: EdgeInsets.all(24),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            : _Empty(
                                key: ValueKey(controller.filtered),
                                icon: controller.filtered
                                    ? Icons.search_off_rounded
                                    : Icons.layers_outlined,
                                title: controller.filtered
                                    ? '没有匹配的收藏'
                                    : '收藏库还是空的',
                                description: controller.filtered
                                    ? '试试其他关键词，或清除当前筛选。'
                                    : controller.prompts
                                    ? '粘贴提示词，自动整理用途与标签。'
                                    : '把想留存的工具、开源项目、文章或视频加进来。',
                                action: controller.filtered
                                    ? TextButton(
                                        onPressed: () {
                                          _search.clear();
                                          controller.clearFilters();
                                        },
                                        child: const Text('清除筛选'),
                                      )
                                    : null,
                              ),
                      );
                    }
                    final entry = entries[index - 1];
                    return Padding(
                      key: ValueKey(entry.id),
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _collectionCard(context, entry),
                    );
                  },
                );
                if (MediaQuery.disableAnimationsOf(context)) return list;
                return FadeTransition(
                  opacity: _tabFade,
                  child: SlideTransition(position: _tabOffset, child: list),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tool = controller.latestOrganizedTool;
    final batch = controller.batch;
    final speech =
        batch != null &&
            !batch.running &&
            controller.batchVersion != _heardBatch
        ? '这批宝贝整理好了 ${batch.ready} 条，失败 ${batch.failed} 条，还有 ${batch.remaining} 条等着进箱。'
        : tool != null && tool.id != _heardTool
        ? '「${clip(tool.title, 18)}」进箱啦！${mascotQuip(tool.category)}'
        : _petLine;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: collectionPanel(scheme),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final largeText = MediaQuery.textScalerOf(context).scale(14) > 23;
              final stacked = constraints.maxWidth < 250 || largeText;
              final mascotSize = (constraints.maxWidth * .42).clamp(
                100.0,
                154.0,
              );
              final content = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    controller.prompts ? '提示词库' : '我的收藏',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                      height: 1.12,
                    ),
                  ),
                ],
              );
              final add = FilledButton.icon(
                onPressed: controller.loading ? null : _add,
                icon: const Icon(Icons.add_rounded),
                label: Text(controller.prompts ? '添加提示词' : '添加链接'),
              );
              if (stacked) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    content,
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: add,
                          ),
                        ),
                        const SizedBox(width: 8),
                        CollectionMascot(
                          size: (constraints.maxWidth * .26).clamp(60.0, 90.0),
                          onTap: _chatWithMascot,
                        ),
                      ],
                    ),
                    const SizedBox(height: 9),
                    _CollectionSwap(
                      child: _PetSpeech(key: ValueKey(speech), text: speech),
                    ),
                  ],
                );
              }
              return Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [content, const SizedBox(height: 16), add],
                        ),
                      ),
                      const SizedBox(width: 6),
                      CollectionMascot(
                        size: mascotSize,
                        onTap: _chatWithMascot,
                      ),
                    ],
                  ),
                  const SizedBox(height: 9),
                  _CollectionSwap(
                    child: _PetSpeech(key: ValueKey(speech), text: speech),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        const UpdateTile(home: true),
        TextField(
          controller: _search,
          onChanged: controller.search,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: controller.prompts ? '搜索提示词' : '搜索收藏',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    onPressed: () {
                      _search.clear();
                      controller.search('');
                    },
                    tooltip: '清空搜索',
                    icon: const Icon(Icons.clear_rounded),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        _FilterStrip(
          label: '分类',
          options: [
            '全部分类',
            for (final category in CollectionCategory.values) category.label,
          ],
          selected: controller.category == null
              ? 0
              : controller.category!.index + 1,
          onSelect: (index) => controller.selectCategory(
            index == 0 ? null : CollectionCategory.values[index - 1],
          ),
        ),
        if (controller.tags.isNotEmpty)
          _FilterStrip(
            label: '标签',
            options: ['全部标签', ...controller.tags],
            selected: controller.tag == null
                ? 0
                : controller.tags.indexOf(controller.tag!) + 1,
            onSelect: (index) => controller.selectTag(
              index == 0 ? null : controller.tags[index - 1],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(3, 6, 3, 8),
          child: SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  controller.filtered
                      ? '筛选结果 · ${controller.entries.length} 条'
                      : '最近收藏 · ${controller.entries.length} 条',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilterChip(
                      label: const Text('待整理与补全'),
                      selected: controller.needsOrganization,
                      onSelected: controller.loading
                          ? null
                          : controller.showUnfinished,
                    ),
                    if (controller.needsOrganization || batch != null)
                      TextButton(
                        onPressed: () => _selectEntries(export: false),
                        child: const Text('批量整理'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (batch != null) _BatchStatus(batch),
      ],
    );
  }
}

class _ReadingWidth extends StatelessWidget {
  const _ReadingWidth({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 700),
      child: child,
    ),
  );
}

class _CollectionSwap extends StatelessWidget {
  const _CollectionSwap({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = collectionMotion(context, 180);
    if (duration == Duration.zero) return child;
    return SizedBox(
      width: double.infinity,
      child: AnimatedSize(
        duration: duration,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topLeft,
        child: AnimatedSwitcher(
          duration: duration,
          reverseDuration: collectionMotion(context, 110),
          switchInCurve: Curves.easeOutCubic,
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topLeft,
            clipBehavior: Clip.none,
            children: [
              for (final old in previous)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: IgnorePointer(child: ExcludeSemantics(child: old)),
                ),
              ?current,
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _PetSpeech extends StatelessWidget {
  const _PetSpeech({super.key, required this.text, this.review = false});

  final String text;
  final bool review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLowest.withValues(alpha: .88),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipOval(
              child: Image.asset(
                'assets/images/whale_avatar.png',
                width: 28,
                height: 28,
                excludeFromSemantics: true,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (review)
                    Text(
                      '鲸鱼娘点评',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  Text(
                    text,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterStrip extends StatelessWidget {
  const _FilterStrip({
    required this.label,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  final String label;
  final List<String> options;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: label,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (index, text) in options.indexed)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(text),
                selected: index == selected,
                onSelected: (_) => onSelect(index),
              ),
            ),
        ],
      ),
    ),
  );
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.entry,
    required this.progress,
    required this.onOpen,
    required this.onPin,
  });
  final Entry entry;
  final String? progress;
  final VoidCallback onOpen;
  final VoidCallback onPin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return CardGlow(
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _SourceIcon(entry.kind),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          entry.kind == SourceKind.prompt
                              ? entry.kind.label
                              : '${entry.kind.label} · ${entry.domain}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (entry.pinnedAt != null)
                    Icon(
                      Icons.push_pin_rounded,
                      size: 16,
                      color: scheme.primary,
                      semanticLabel: '已置顶',
                    ),
                  PopupMenuButton<bool>(
                    tooltip: '卡片操作',
                    onSelected: (_) => onPin(),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: true,
                        child: Text(entry.pinnedAt == null ? '置顶收藏' : '取消置顶'),
                      ),
                    ],
                  ),
                ],
              ),
              if (entry.preview.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  entry.preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                ),
              ],
              if (entry.kind == SourceKind.prompt)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _copyPrompt(context, entry.promptText),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('复制提示词'),
                  ),
                ),
              if (entry.category != null || entry.tags.isNotEmpty) ...[
                const SizedBox(height: 10),
                _Tags(category: entry.category, tags: entry.tags),
              ],
              _CollectionSwap(
                child: entry.status == EntryStatus.ready && progress == null
                    ? const SizedBox.shrink()
                    : Padding(
                        key: ValueKey(progress ?? entry.status.name),
                        padding: const EdgeInsets.only(top: 10),
                        child: _Status(entry: entry, progress: progress),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceIcon extends StatelessWidget {
  const _SourceIcon(this.kind);
  final SourceKind kind;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, background, foreground) = switch (kind) {
      SourceKind.repository => (
        Icons.code_rounded,
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      SourceKind.video => (
        Icons.play_circle_outline_rounded,
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      SourceKind.web => (
        Icons.language_rounded,
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
      SourceKind.prompt => (
        Icons.chat_bubble_outline_rounded,
        colors.primaryContainer,
        colors.onPrimaryContainer,
      ),
    };
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(15),
      ),
      child: Icon(icon, color: foreground, size: 22),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.entry, this.progress, this.explain = false});
  final Entry entry;
  final String? progress;
  final bool explain;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label =
        progress ?? (entry.status == EntryStatus.pending ? '待整理' : '待补全');
    return Semantics(
      liveRegion: explain,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (progress != null && !MediaQuery.disableAnimationsOf(context))
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Icon(
              Icons.info_outline_rounded,
              size: 18,
              color: theme.colorScheme.primary,
            ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              explain && progress == null
                  ? '$label · ${entry.reason ?? '链接已保存，可以联网整理或手动补全。'}'
                  : label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tags extends StatelessWidget {
  const _Tags({required this.category, required this.tags});
  final CollectionCategory? category;
  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (category != null)
          _Pill(
            category!.label,
            colors.primaryContainer,
            colors.onPrimaryContainer,
          ),
        for (final tag in tags)
          _Pill(tag, colors.surfaceContainer, colors.onSurface),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, this.background, this.foreground);
  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: foreground),
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(icon, size: 32, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              if (description != null) ...[
                const SizedBox(height: 8),
                Text(description!, textAlign: TextAlign.center),
              ],
              ?action,
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkSheet extends StatefulWidget {
  const _LinkSheet({
    required this.controller,
    required this.isPrompt,
    this.initialText,
  });
  final CollectionController controller;
  final bool isPrompt;
  final String? initialText;

  @override
  State<_LinkSheet> createState() => _LinkSheetState();
}

class _LinkSheetState extends State<_LinkSheet> {
  late final _value = TextEditingController(text: widget.initialText);
  late bool _prompt = widget.isPrompt;
  String? _error;
  bool _checking = false;
  ({List<Uri> urls, int duplicates, int unrecognized, int excess})? _preview;
  Map<String, int> _existing = {};
  final _selected = <Uri>{};

  @override
  void initState() {
    super.initState();
    if (widget.initialText != null && !_prompt) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_prompt) unawaited(_submit(false, previewOnly: true));
      });
    }
  }

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  void _reset() {
    _preview = null;
    _selected.clear();
    _error = null;
  }

  Future<void> _submit(bool organize, {bool previewOnly = false}) async {
    if (_checking) return;
    if (_prompt) {
      if (_value.text.trim().isEmpty) {
        setState(() => _error = '请输入提示词。');
        return;
      }
      Navigator.pop(context, (
        links: <Uri>[],
        prompt: _value.text,
        existing: null as int?,
        organize: organize,
      ));
      return;
    }
    if (_preview != null) {
      if (_selected.isEmpty) return;
      Navigator.pop(context, (
        links: _preview!.urls.where(_selected.contains).toList(),
        prompt: null as String?,
        existing: null as int?,
        organize: organize,
      ));
      return;
    }
    final input = parseLinkText(_value.text);
    if (input.urls.isEmpty) {
      setState(() => _error = '请输入一个完整的 HTTP 或 HTTPS 链接。');
      return;
    }
    if (!previewOnly &&
        widget.initialText == null &&
        input.urls.length == 1 &&
        input.duplicates == 0 &&
        input.unrecognized == 0 &&
        input.urls.single == webUri(_value.text)) {
      Navigator.pop(context, (
        links: input.urls,
        prompt: null as String?,
        existing: null as int?,
        organize: organize,
      ));
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _checking = true);
    try {
      final existing = await widget.controller.store.existingLinks(
        input.urls.map((url) => LinkIdentity(url).key),
      );
      if (!mounted) return;
      setState(() {
        _existing = existing;
        _preview = input;
        _selected.addAll(
          input.urls.where(
            (url) => !existing.containsKey(LinkIdentity(url).key),
          ),
        );
      });
    } on Exception {
      if (mounted) setState(() => _error = '无法检查重复链接，请重试。');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _paste() async {
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final text = clip?.text;
      if (text == null || text.trim().isEmpty) {
        setState(() => _error = '剪贴板里没有可粘贴的文字。');
        return;
      }
      _value.text = _prompt ? text : text.trim();
      setState(_reset);
    } on PlatformException {
      if (mounted) setState(() => _error = '无法读取剪贴板，可直接输入。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final canSave = !_checking && (preview == null || _selected.isNotEmpty);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          22,
          0,
          22,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: _ReadingWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _prompt ? '收藏提示词' : '收藏新链接',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              if (widget.initialText != null)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final kind in [false, true])
                      ChoiceChip(
                        label: Text(kind ? '存为提示词' : '存为工具链接'),
                        selected: kind == _prompt,
                        onSelected: _checking
                            ? null
                            : (_) => setState(() {
                                _prompt = kind;
                                _reset();
                              }),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _value,
                enabled: !_checking,
                keyboardType: TextInputType.multiline,
                minLines: _prompt ? 4 : 1,
                maxLines: _prompt ? 8 : 4,
                autocorrect: false,
                onChanged: (_) => setState(_reset),
                decoration: InputDecoration(
                  labelText: _prompt ? '提示词原文' : '链接',
                  hintText: _prompt ? '在此粘贴提示词' : '可粘贴多条链接或分享文案',
                  errorText: _error,
                  errorMaxLines: 3,
                  suffixIcon: IconButton(
                    onPressed: _checking ? null : _paste,
                    tooltip: _prompt ? '粘贴提示词' : '粘贴链接',
                    icon: const Icon(Icons.content_paste_rounded),
                  ),
                ),
              ),
              if (_checking) const LinearProgressIndicator(),
              if (preview != null) ...[
                const SizedBox(height: 12),
                Text(
                  '已选 ${_selected.length} 条 · 重复 ${preview.duplicates + _existing.length} 条 · 未识别 ${preview.unrecognized} 条',
                ),
                if (preview.excess > 0)
                  Text('每次最多 $maxBatchLinks 条，另有 ${preview.excess} 条未列出。'),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView(
                    shrinkWrap: true,
                    primary: false,
                    children: [
                      for (final url in preview.urls)
                        if (_existing[LinkIdentity(url).key] case final id?)
                          ListTile(
                            title: Text(
                              url.toString(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: const Text('已收藏'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.pop(context, (
                              links: <Uri>[],
                              prompt: null as String?,
                              existing: id,
                              organize: false,
                            )),
                          )
                        else
                          CheckboxListTile(
                            title: Text(
                              url.toString(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            value: _selected.contains(url),
                            onChanged: (checked) => setState(() {
                              if (checked == true) {
                                _selected.add(url);
                              } else {
                                _selected.remove(url);
                              }
                            }),
                          ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: canSave ? () => _submit(true) : null,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(
                  _prompt || preview != null || widget.initialText == null
                      ? '收藏并整理'
                      : '检查链接',
                ),
              ),
              TextButton(
                onPressed: canSave ? () => _submit(false) : null,
                child: const Text('仅保存在本机'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _settings(BuildContext context, CollectionController controller) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('设置')),
          body: SafeArea(
            child: _ReadingWidth(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.palette_outlined),
                      title: const Text('界面外观'),
                      subtitle: const Text('字号、主题与背景'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const _AppearancePage(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.backup_outlined),
                      title: const Text('备份与恢复'),
                      subtitle: const Text('导出或导入收藏与提示词'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              _BackupPage(controller: controller),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.tune_rounded),
                      title: const Text('AI 服务'),
                      subtitle: const Text('模型与搜索服务'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              _SettingsPage(controller: controller),
                        ),
                      ),
                    ),
                  ),
                  const UpdateTile(),
                ],
              ),
            ),
          ),
        ),
      ),
    );

class _BatchStatus extends StatelessWidget {
  const _BatchStatus(this.batch);
  final BatchProgress batch;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: _Section(
      title: batch.running
          ? '正在整理'
          : batch.pause == null
          ? '本批整理结束'
          : '批量整理已暂停',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (batch.running) ...[
            LinearProgressIndicator(
              value: (batch.total - batch.remaining) / batch.total,
            ),
            const SizedBox(height: 8),
          ],
          Text(
            '已完成 ${batch.ready} · 待补全 ${batch.failed} · 剩余 ${batch.remaining}'
            '${batch.skipped == 0 ? '' : ' · 跳过 ${batch.skipped}'}',
          ),
          if (batch.pause case final reason?) Text(reason),
        ],
      ),
    ),
  );
}

class _SelectionPage extends StatefulWidget {
  const _SelectionPage({
    required this.controller,
    required this.exporting,
    required this.prompts,
    this.visibleIds,
  });
  final CollectionController controller;
  final bool exporting;
  final bool prompts;
  final Set<int>? visibleIds;

  @override
  State<_SelectionPage> createState() => _SelectionPageState();
}

class _SelectionPageState extends State<_SelectionPage> {
  static const _channel = MethodChannel('app.toolcollection/backup');
  List<Entry> _rows = const [];
  final _selected = <int>{};
  bool _includeNotes = false;
  bool _includePrompt = false;
  bool _busy = false;
  bool _loading = true;
  bool _failed = false;
  late int _batchVersion;

  CollectionController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _batchVersion = _controller.batchVersion;
    if (!widget.exporting) _controller.addListener(_refreshAfterBatch);
    unawaited(_load());
  }

  @override
  void dispose() {
    if (!widget.exporting) _controller.removeListener(_refreshAfterBatch);
    super.dispose();
  }

  void _refreshAfterBatch() {
    if (_batchVersion == _controller.batchVersion) return;
    _batchVersion = _controller.batchVersion;
    if (!_busy) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final rows = await _controller.store.list(
        prompts: widget.prompts,
        needsOrganization: !widget.exporting,
        ids: widget.visibleIds,
      );
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _selected.retainAll(rows.map((entry) => entry.id));
        _failed = false;
      });
    } on Exception {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (widget.exporting) {
        final entries = await _controller.store.list(
          prompts: widget.prompts,
          ids: _selected,
        );
        if (!mounted) return;
        if (entries.isEmpty) {
          _message(context, '选中的收藏已删除。');
          await _load();
          return;
        }
        final data = collectionMarkdown(
          entries,
          notes: _includeNotes,
          promptText: _includePrompt,
        );
        final saved = await _channel.invokeMethod<bool>('exportMarkdown', {
          'data': data,
        });
        if (mounted && saved == true) _message(context, 'Markdown 清单已导出。');
      } else if (await _allowOrganization(context, _controller)) {
        await _controller.runBatch(
          _rows
              .where((entry) => _selected.contains(entry.id))
              .map((entry) => entry.id),
        );
        await _load();
      }
    } on Exception {
      if (mounted) {
        _message(context, widget.exporting ? '无法导出清单，请重试。' : '无法开始整理，请重试。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final batch = _controller.batch;
      final locked = _busy || (!widget.exporting && _controller.batchRunning);
      final all = _rows.isNotEmpty && _selected.length == _rows.length;
      return Scaffold(
        appBar: AppBar(title: Text(widget.exporting ? '导出收藏清单' : '批量整理')),
        body: SafeArea(
          top: false,
          child: _ReadingWidth(
            child: Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: _rows.length + 1,
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (!widget.exporting && batch != null)
                              _BatchStatus(batch),
                            if (_loading) const LinearProgressIndicator(),
                            if (_failed)
                              TextButton(
                                onPressed: _load,
                                child: const Text('无法读取收藏，点击重试'),
                              ),
                            if (!_loading && !_failed && _rows.isEmpty)
                              Text(
                                widget.exporting
                                    ? '当前没有可导出的收藏。'
                                    : '当前没有待整理的收藏。',
                              ),
                            if (_rows.isNotEmpty)
                              TextButton(
                                onPressed: locked
                                    ? null
                                    : () => setState(() {
                                        _selected.clear();
                                        if (!all) {
                                          _selected.addAll(
                                            _rows.map((entry) => entry.id),
                                          );
                                        }
                                      }),
                                child: Text(all ? '取消全选' : '全选'),
                              ),
                            if (widget.exporting && _rows.isNotEmpty) ...[
                              CheckboxListTile(
                                title: const Text('包含个人备注'),
                                value: _includeNotes,
                                onChanged: locked
                                    ? null
                                    : (value) => setState(
                                        () => _includeNotes = value == true,
                                      ),
                              ),
                              if (widget.prompts)
                                CheckboxListTile(
                                  title: const Text('包含提示词原文'),
                                  value: _includePrompt,
                                  onChanged: locked
                                      ? null
                                      : (value) => setState(
                                          () => _includePrompt = value == true,
                                        ),
                                ),
                            ],
                          ],
                        );
                      }
                      final entry = _rows[index - 1];
                      final progress = _controller.progress(entry.id);
                      return CheckboxListTile(
                        title: Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: widget.exporting
                            ? Text(entry.kind.label)
                            : _Status(entry: entry, progress: progress),
                        value: _selected.contains(entry.id),
                        onChanged: locked
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  _selected.add(entry.id);
                                } else {
                                  _selected.remove(entry.id);
                                }
                              }),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: locked || _selected.isEmpty ? null : _submit,
                      child: Text(
                        '${widget.exporting ? '导出 Markdown' : '整理所选'}（${_selected.length} 条）',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _BackupPage extends StatefulWidget {
  const _BackupPage({required this.controller});
  final CollectionController controller;
  @override
  State<_BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<_BackupPage> {
  static const _channel = MethodChannel('app.toolcollection/backup');
  bool _busy = false;

  Future<void> _backup(bool exporting) async {
    setState(() => _busy = true);
    try {
      if (exporting) {
        final data = await widget.controller.store.exportBackup();
        final saved = await _channel.invokeMethod<bool>('export', {
          'data': data,
        });
        if (saved == true && mounted) _message(context, '备份已导出。');
      } else {
        final data = await _channel.invokeMethod<String>('import');
        if (data != null && mounted) {
          final preview = await widget.controller.store.previewBackup(data);
          if (!mounted) return;
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('预览恢复'),
              content: Text(
                '可导入 ${preview.added} 条收藏，跳过 ${preview.skipped} 条已有或重复收藏。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('确认导入'),
                ),
              ],
            ),
          );
          if (confirmed != true || !mounted) return;
          final result = await widget.controller.store.importBackup(data);
          await widget.controller.refresh();
          if (mounted) {
            _message(
              context,
              '已导入 ${result.added} 条，跳过 ${result.skipped} 条已有收藏。',
            );
          }
        }
      }
    } on FormatException catch (error) {
      if (mounted) _message(context, error.message);
    } on Exception {
      if (mounted) _message(context, '备份操作失败，请检查文件后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('备份与恢复')),
    body: SafeArea(
      child: _ReadingWidth(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              '备份包含收藏、提示词、标签、置顶和个人备注。导入时先预览，已有条目保留本机版本。API 密钥和外观设置保存在本机。',
            ),
            const SizedBox(height: 20),
            Card(
              child: ListTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: const Text('导出备份'),
                subtitle: const Text('保存到设备或云盘'),
                onTap: _busy ? null : () => _backup(true),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: const Text('导入备份'),
                subtitle: const Text('从备份文件合并收藏'),
                onTap: _busy ? null : () => _backup(false),
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    ),
  );
}

class _AppearancePage extends StatelessWidget {
  const _AppearancePage();

  Future<void> _save(BuildContext context, Future<void> operation) async {
    try {
      await operation;
    } on Exception catch (error) {
      if (context.mounted) {
        _message(
          context,
          error is FormatException ? error.message : '无法保存外观设置，请重试。',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppearanceScope.of(context);
    final value = controller.value;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('界面外观')),
      body: SafeArea(
        child: _ReadingWidth(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _Section(
                title: '字号',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前 ${(value.fontScale * 100).round()}%',
                      style: theme.textTheme.bodyLarge,
                    ),
                    Slider(
                      value: value.fontScale,
                      min: 1,
                      max: 1.4,
                      divisions: 8,
                      label: '${(value.fontScale * 100).round()}%',
                      onChanged: (v) =>
                          controller.preview(value.copyWith(fontScale: v)),
                      onChangeEnd: (v) => _save(
                        context,
                        controller.save(
                          controller.value.copyWith(fontScale: v),
                        ),
                      ),
                    ),
                    const Text('在系统字体大小的基础上调整。'),
                  ],
                ),
              ),
              _Section(
                title: '显示模式',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in [
                      (ThemeMode.system, '跟随系统'),
                      (ThemeMode.light, '浅色'),
                      (ThemeMode.dark, '深色'),
                    ])
                      ChoiceChip(
                        label: Text(option.$2),
                        selected: value.mode == option.$1,
                        onSelected: (_) => _save(
                          context,
                          controller.save(value.copyWith(mode: option.$1)),
                        ),
                      ),
                  ],
                ),
              ),
              _Section(
                title: '主题色',
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < appearanceColors.length; i++)
                      ChoiceChip(
                        avatar: CircleAvatar(
                          backgroundColor: appearanceColors[i],
                          radius: 10,
                        ),
                        label: Text(appearanceColorNames[i]),
                        selected: value.colorIndex == i,
                        onSelected: (_) => _save(
                          context,
                          controller.save(value.copyWith(colorIndex: i)),
                        ),
                      ),
                  ],
                ),
              ),
              _Section(
                title: '图片背景',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('从相册选择图片，图片保存在本机。'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: () =>
                              _save(context, controller.chooseImage()),
                          icon: const Icon(Icons.photo_outlined),
                          label: Text(
                            value.backgroundPath == null ? '选择图片' : '更换图片',
                          ),
                        ),
                        if (value.backgroundPath != null)
                          TextButton(
                            onPressed: () =>
                                _save(context, controller.removeImage()),
                            child: const Text('移除背景'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('虚化程度  ${value.blur.round()}'),
                    Slider(
                      value: value.blur,
                      min: 0,
                      max: 20,
                      divisions: 20,
                      onChanged: value.backgroundPath == null
                          ? null
                          : (v) => controller.preview(value.copyWith(blur: v)),
                      onChangeEnd: (v) => _save(
                        context,
                        controller.save(controller.value.copyWith(blur: v)),
                      ),
                    ),
                    Text('遮罩浓度  ${(value.overlay * 100).round()}%'),
                    Slider(
                      value: value.overlay,
                      min: .35,
                      max: .9,
                      divisions: 11,
                      onChanged: value.backgroundPath == null
                          ? null
                          : (v) =>
                                controller.preview(value.copyWith(overlay: v)),
                      onChangeEnd: (v) => _save(
                        context,
                        controller.save(controller.value.copyWith(overlay: v)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _EntryAction { copy, pin, delete }

Future<void> _togglePin(
  BuildContext context,
  CollectionController controller,
  Entry entry,
) async {
  try {
    await controller.setPinned(entry);
  } on Exception {
    if (context.mounted) _message(context, '无法更新置顶，请重试。');
  }
}

class _DetailPage extends StatelessWidget {
  const _DetailPage({
    required this.controller,
    required this.id,
    this.initialEntry,
  });
  final CollectionController controller;
  final int id;
  final Entry? initialEntry;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('收藏详情'),
      actions: [
        IconButton(
          onPressed: () => _settings(context, controller),
          tooltip: '设置',
          icon: const Icon(Icons.tune_rounded),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: SafeArea(
      top: false,
      child: _ReadingWidth(
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => FutureBuilder<Entry?>(
            future: controller.store.find(id),
            initialData: initialEntry,
            builder: (context, snapshot) {
              final entry = snapshot.data;
              if (entry == null) {
                return Center(
                  child: snapshot.connectionState == ConnectionState.waiting
                      ? const CircularProgressIndicator()
                      : const Text('无法读取这条收藏'),
                );
              }
              return _content(context, entry);
            },
          ),
        ),
      ),
    ),
  );

  Widget _content(BuildContext context, Entry entry) {
    final theme = Theme.of(context);
    final progress = controller.progress(id);
    final colors = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: collectionPanel(colors),
          child: CardGlow(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _SourceIcon(entry.kind),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          entry.kind == SourceKind.prompt
                              ? entry.kind.label
                              : '${entry.kind.label} · ${entry.domain}',
                          style: TextStyle(
                            color: colors.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      PopupMenuButton<_EntryAction>(
                        tooltip: '收藏操作',
                        onSelected: (action) {
                          switch (action) {
                            case _EntryAction.copy:
                              unawaited(_copy(context, entry));
                            case _EntryAction.pin:
                              unawaited(_togglePin(context, controller, entry));
                            case _EntryAction.delete:
                              unawaited(_delete(context, entry));
                          }
                        },
                        itemBuilder: (context) => [
                          if (entry.kind != SourceKind.prompt)
                            const PopupMenuItem(
                              value: _EntryAction.copy,
                              child: Text('复制原链接'),
                            ),
                          PopupMenuItem(
                            value: _EntryAction.pin,
                            child: Text(
                              entry.pinnedAt == null ? '置顶收藏' : '取消置顶',
                            ),
                          ),
                          PopupMenuItem(
                            value: _EntryAction.delete,
                            enabled: progress == null,
                            child: const Text('删除收藏'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    entry.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: theme.textTheme.headlineSmall?.fontSize,
                      color: colors.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (entry.toolLink case final link?)
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.icon(
                          onPressed: () => _openExternal(context, link.url),
                          icon: const Icon(Icons.open_in_new_rounded, size: 18),
                          label: Text(link.label),
                        ),
                        if (link.url != entry.original)
                          TextButton(
                            onPressed: () =>
                                _openExternal(context, entry.original),
                            child: const Text('打开原链接'),
                          ),
                      ],
                    )
                  else
                    _promptActions(context, entry.promptText),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (entry.kind != SourceKind.prompt) ...[
          _CollectionSwap(
            child: _PetSpeech(
              key: ValueKey((entry.status, progress != null)),
              review: entry.status == EntryStatus.ready,
              text: entry.status == EntryStatus.ready
                  ? mascotReview(entry)
                  : progress != null
                  ? '让我翻翻资料，读完就来点评！'
                  : entry.status == EntryStatus.attention
                  ? '链接我先收好，等资料齐了再来点评！'
                  : '宝贝先放这儿，想听点评时就点整理。',
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (entry.kind == SourceKind.prompt)
          _Section(
            title: '提示词原文',
            child: SelectableText(
              entry.promptText,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
            ),
          ),
        _CollectionSwap(
          child: entry.status == EntryStatus.ready && progress == null
              ? const SizedBox.shrink()
              : _Section(
                  title: '整理状态',
                  child: _CollectionSwap(
                    child: Column(
                      key: ValueKey(progress ?? entry.status.name),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Status(
                          entry: entry,
                          progress: progress,
                          explain: true,
                        ),
                        if (progress == null) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: controller.batchRunning
                                    ? null
                                    : () => _start(context, controller, id),
                                icon: const Icon(Icons.refresh_rounded),
                                label: Text(
                                  entry.status == EntryStatus.pending
                                      ? '联网整理'
                                      : '重试整理',
                                ),
                              ),
                              TextButton(
                                onPressed: () => _edit(context, entry),
                                child: const Text('手动补全'),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
        ),
        _Section(
          title: entry.summary.isEmpty && entry.description.isNotEmpty
              ? '来源简介'
              : '简介',
          action: entry.status == EntryStatus.ready
              ? IconButton(
                  onPressed: () => _edit(context, entry),
                  tooltip: '编辑收藏',
                  icon: const Icon(Icons.edit_outlined),
                )
              : null,
          child: SelectableText(
            entry.preview.isEmpty ? '暂无简介' : entry.preview,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
          ),
        ),
        _Section(
          title: '核心功能',
          child: entry.features.isEmpty
              ? const Text('暂无核心功能')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final feature in entry.features)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 4, right: 8),
                              child: Icon(
                                Icons.check_circle_outline_rounded,
                                size: 15,
                                color: colors.primary,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                feature,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        _Section(
          title: '分类与标签',
          child: entry.category == null && entry.tags.isEmpty
              ? const Text('待分类')
              : _Tags(category: entry.category, tags: entry.tags),
        ),
        _Section(
          title: '个人备注',
          action: IconButton(
            onPressed: () async {
              final note = await showDialog<String>(
                context: context,
                builder: (context) => _NoteDialog(entry.note),
              );
              if (note == null || !context.mounted) return;
              try {
                await controller.setNote(entry.id, note);
              } on Exception {
                if (context.mounted) _message(context, '无法保存备注，请重试。');
              }
            },
            tooltip: '编辑个人备注',
            icon: const Icon(Icons.edit_note_rounded),
          ),
          child: entry.note.isEmpty
              ? const Text('暂无备注')
              : SelectableText(entry.note),
        ),
        if (entry.links.isNotEmpty || entry.sources.isNotEmpty)
          _Section(
            title: '来源与入口',
            child: Column(
              children: [
                for (final link in entry.links) _LinkRow(link),
                if (entry.links.isNotEmpty && entry.sources.isNotEmpty)
                  const Divider(),
                for (final source in entry.sources)
                  if (source.label == '手动录入')
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('简介与分类由用户录入'),
                    )
                  else
                    _LinkRow(source),
              ],
            ),
          ),
      ],
    );
  }

  void _edit(BuildContext context, Entry entry) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (context) => _EditPage(controller: controller, entry: entry),
        ),
      );

  Future<void> _copy(BuildContext context, Entry entry) async {
    try {
      await Clipboard.setData(ClipboardData(text: entry.original.toString()));
      if (context.mounted) _message(context, '已复制原链接');
    } on PlatformException {
      if (context.mounted) _message(context, '无法复制原链接');
    }
  }

  Future<void> _delete(BuildContext context, Entry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除收藏？'),
        content: Text('「${entry.title}」及其本地整理内容将被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final removed = await controller.remove(entry.id);
      if (!context.mounted) return;
      if (removed) {
        final messenger = ScaffoldMessenger.of(context);
        if (ModalRoute.isCurrentOf(context) == true) Navigator.pop(context);
        messenger.showSnackBar(const SnackBar(content: Text('已删除收藏')));
      } else {
        _message(context, '整理结束后可以删除这条收藏。');
      }
    } on Exception {
      if (context.mounted) _message(context, '无法删除收藏，请重试。');
    }
  }
}

Widget _promptActions(BuildContext context, String text) {
  final variables = promptVariables(text);
  return Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      if (variables.isNotEmpty)
        FilledButton.icon(
          onPressed: () async {
            final copied = await Navigator.push<bool>(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    _PromptFillPage(text: text, variables: variables),
              ),
            );
            if (copied == true && context.mounted) {
              _message(context, '已复制填写后的提示词');
            }
          },
          icon: const Icon(Icons.edit_rounded, size: 18),
          label: const Text('填变量并复制'),
        ),
      FilledButton.tonalIcon(
        onPressed: () => _copyPrompt(context, text),
        icon: const Icon(Icons.copy_rounded, size: 18),
        label: Text(variables.isEmpty ? '复制提示词' : '复制原文'),
      ),
    ],
  );
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog(this.note);
  final String note;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final _note = TextEditingController(text: widget.note);

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('个人备注'),
    content: TextField(
      controller: _note,
      autofocus: true,
      minLines: 3,
      maxLines: 6,
      decoration: const InputDecoration(labelText: '备注'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _note.text),
        child: const Text('保存'),
      ),
    ],
  );
}

class _PromptFillPage extends StatefulWidget {
  const _PromptFillPage({required this.text, required this.variables});
  final String text;
  final List<String> variables;

  @override
  State<_PromptFillPage> createState() => _PromptFillPageState();
}

class _PromptFillPageState extends State<_PromptFillPage> {
  final _form = GlobalKey<FormState>();
  final _values = <String, String>{};

  Future<void> _copy() async {
    if (!_form.currentState!.validate() ||
        widget.variables.any(
          (name) => _values[name]?.trim().isNotEmpty != true,
        )) {
      _message(context, '请填写所有提示词变量。');
      return;
    }
    try {
      await Clipboard.setData(
        ClipboardData(text: fillPrompt(widget.text, _values)),
      );
      if (mounted) Navigator.pop(context, true);
    } on PlatformException {
      if (mounted) _message(context, '无法复制提示词');
    }
  }

  @override
  Widget build(BuildContext context) => _FormPage(
    title: '填写提示词变量',
    form: _form,
    children: [
      for (final name in widget.variables)
        TextFormField(
          decoration: InputDecoration(labelText: name),
          initialValue: _values[name],
          minLines: 1,
          maxLines: 4,
          keyboardType: TextInputType.multiline,
          onChanged: (value) => setState(() {
            if (value.isEmpty) {
              _values.remove(name);
            } else {
              _values[name] = value;
            }
          }),
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入内容' : null,
        ),
      _Section(
        title: '预览',
        child: SelectableText(fillPrompt(widget.text, _values)),
      ),
      FilledButton.icon(
        onPressed: _copy,
        icon: const Icon(Icons.copy_rounded),
        label: const Text('复制填写结果'),
      ),
    ],
  );
}

Future<void> _copyPrompt(BuildContext context, String value) async {
  try {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) _message(context, '已复制提示词');
  } on PlatformException {
    if (context.mounted) _message(context, '无法复制提示词');
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.action});
  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: CardGlow(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(17, 12, 17, 15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: text.titleLarge?.copyWith(
                          fontSize: text.titleMedium?.fontSize,
                        ),
                      ),
                    ),
                    ?action,
                  ],
                ),
                const SizedBox(height: 9),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _openExternal(BuildContext context, Uri url) async {
  try {
    if (webUri(url.toString()) != null &&
        await launchUrl(url, mode: LaunchMode.externalApplication)) {
      return;
    }
  } on Exception {
    // The device may lack a handler for the address.
  }
  if (context.mounted) _message(context, '无法打开链接');
}

class _LinkRow extends StatelessWidget {
  const _LinkRow(this.link);
  final WebLink link;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(link.label),
    subtitle: Text(link.url.host, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: const Icon(Icons.open_in_new_rounded, size: 18),
    onTap: () => _openExternal(context, link.url),
  );
}

class _EditPage extends StatefulWidget {
  const _EditPage({required this.controller, required this.entry});
  final CollectionController controller;
  final Entry entry;

  @override
  State<_EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<_EditPage> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.entry.title);
  late final _summary = TextEditingController(text: widget.entry.preview);
  late final _tags = TextEditingController(text: widget.entry.tags.join('，'));
  late final _original = TextEditingController(
    text: widget.entry.kind == SourceKind.prompt
        ? widget.entry.promptText
        : widget.entry.original.toString(),
  );
  late final _features = TextEditingController(
    text: widget.entry.features.join('\n'),
  );
  late final _links = TextEditingController(
    text: widget.entry.links
        .map((link) => '${link.label} | ${link.url}')
        .join('\n'),
  );
  late CollectionCategory _category =
      widget.entry.category ?? CollectionCategory.other;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    _summary.dispose();
    _tags.dispose();
    _original.dispose();
    _features.dispose();
    _links.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.controller.completeManually(
        widget.entry,
        title: _title.text,
        summary: _summary.text,
        category: _category,
        tags: _tags.text.split(RegExp(r'[,，、]')),
        promptText: widget.entry.kind == SourceKind.prompt
            ? _original.text
            : null,
        originalUrl: widget.entry.kind == SourceKind.prompt
            ? null
            : _original.text,
        features: _features.text
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toList(),
        links: widget.entry.kind == SourceKind.prompt
            ? null
            : [
                for (final line in _links.text.split('\n'))
                  if (line.trim().isNotEmpty)
                    WebLink(
                      line.contains('|')
                          ? line.split('|').first.trim()
                          : '相关链接',
                      webUri(
                        line.contains('|')
                            ? line.substring(line.indexOf('|') + 1).trim()
                            : line.trim(),
                      )!,
                    ),
              ],
      );
      if (mounted) Navigator.pop(context);
    } on DatabaseException catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      _message(
        context,
        error.isUniqueConstraintError() ? '这个链接已收藏。' : '无法保存编辑，请重试。',
      );
    } on Exception {
      if (!mounted) return;
      setState(() => _saving = false);
      _message(context, '无法保存编辑，请重试。');
    }
  }

  @override
  Widget build(BuildContext context) => _FormPage(
    title: widget.entry.status == EntryStatus.ready ? '编辑收藏' : '手动补全',
    form: _form,
    children: [
      TextFormField(
        controller: _title,
        maxLength: 180,
        decoration: const InputDecoration(labelText: '标题'),
        validator: (value) => value!.trim().isEmpty ? '请输入标题' : null,
      ),
      TextFormField(
        controller: _original,
        minLines: widget.entry.kind == SourceKind.prompt ? 4 : 1,
        maxLines: widget.entry.kind == SourceKind.prompt ? 10 : 2,
        decoration: InputDecoration(
          labelText: widget.entry.kind == SourceKind.prompt ? '提示词原文' : '原链接',
        ),
        validator: (value) {
          if (widget.entry.kind == SourceKind.prompt) {
            return value!.trim().isEmpty ? '请输入提示词。' : null;
          }
          return webUri(value ?? '') == null ? '请输入完整的 HTTP 或 HTTPS 链接。' : null;
        },
      ),
      TextFormField(
        controller: _summary,
        minLines: 3,
        maxLines: 7,
        maxLength: 600,
        decoration: const InputDecoration(labelText: '简介'),
      ),
      DropdownButtonFormField<CollectionCategory>(
        isExpanded: true,
        initialValue: _category,
        decoration: const InputDecoration(labelText: '分类'),
        items: [
          for (final category in CollectionCategory.values)
            DropdownMenuItem(value: category, child: Text(category.label)),
        ],
        onChanged: (value) => _category = value!,
      ),
      TextFormField(
        controller: _features,
        minLines: 2,
        maxLines: 6,
        decoration: const InputDecoration(
          labelText: '核心功能',
          helperText: '每行一项',
        ),
      ),
      if (widget.entry.kind != SourceKind.prompt)
        TextFormField(
          controller: _links,
          minLines: 2,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: '源码与下载链接',
            helperText: '每行一个，可写成「名称 | 链接」',
          ),
          validator: (value) {
            for (final line in (value ?? '').split('\n')) {
              if (line.trim().isEmpty) continue;
              final separator = line.indexOf('|');
              if (separator == 0 ||
                  (separator > 0 &&
                      line.substring(0, separator).trim().isEmpty) ||
                  webUri(
                        separator < 0
                            ? line.trim()
                            : line.substring(separator + 1).trim(),
                      ) ==
                      null) {
                return '请输入有效的 HTTP 或 HTTPS 链接。';
              }
            }
            return null;
          },
        ),
      TextFormField(
        controller: _tags,
        decoration: const InputDecoration(
          labelText: '标签',
          helperText: '自由添加，用逗号分隔',
        ),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: const Text('保存收藏'),
      ),
    ],
  );
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({required this.controller});
  final CollectionController controller;

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  final _form = GlobalKey<FormState>();
  late final _base = TextEditingController(
    text: widget.controller.settings.base,
  );
  late final _model = TextEditingController(
    text: widget.controller.settings.model,
  );
  late final _modelKey = TextEditingController(
    text: widget.controller.settings.modelKey,
  );
  late final _searchKey = TextEditingController(
    text: widget.controller.settings.searchKey,
  );
  late bool _consent = widget.controller.settings.consent;
  bool _saving = false;
  bool _fetching = false;
  List<String> _models = [];
  late bool _deepseek =
      _base.text.trim().isEmpty ||
      Uri.tryParse(_base.text.trim())?.host == 'api.deepseek.com';

  @override
  void initState() {
    super.initState();
    if (_base.text.trim().isEmpty) {
      _base.text = 'https://api.deepseek.com';
      if (_model.text.trim().isEmpty) _model.text = 'deepseek-flash';
    }
  }

  void _provider(bool deepseek) {
    if (_deepseek == deepseek) return;
    setState(() {
      _deepseek = deepseek;
      _models = [];
      if (deepseek) {
        _base.text = 'https://api.deepseek.com';
        _model.text = 'deepseek-flash';
      } else if (Uri.tryParse(_base.text.trim())?.host == 'api.deepseek.com') {
        _base.clear();
        _model.clear();
      }
    });
  }

  Future<void> _fetchModels() async {
    final base = _base.text.trim();
    final key = _modelKey.text.trim();
    if (base.isEmpty || key.isEmpty) {
      _message(context, '请先填写模型地址和 Key。');
      return;
    }
    setState(() => _fetching = true);
    try {
      final models = await widget.controller.services.listModels(
        ServiceSettings(base: base, modelKey: key),
      );
      if (!mounted ||
          base != _base.text.trim() ||
          key != _modelKey.text.trim()) {
        return;
      }
      setState(() {
        _models = models;
        if (_model.text.trim().isEmpty ||
            (_deepseek &&
                _model.text.trim() == 'deepseek-flash' &&
                !models.contains('deepseek-flash'))) {
          _model.text = models.first;
        }
      });
      _message(context, '已获取 ${models.length} 个模型');
    } on ServiceProblem catch (problem) {
      if (mounted) _message(context, problem.message);
    } on FormatException {
      if (mounted) _message(context, '模型列表无法读取，可手动填写模型名称。');
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  @override
  void dispose() {
    _base.dispose();
    _model.dispose();
    _modelKey.dispose();
    _searchKey.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      if (_modelKey.text.trim().isNotEmpty && _base.text.trim().isNotEmpty) {
        await _fetchModels();
        if (!mounted) return;
      }
      await widget.controller.saveSettings(
        ServiceSettings(
          base: _base.text.trim(),
          model: _model.text.trim(),
          modelKey: _modelKey.text.trim(),
          searchKey: _searchKey.text.trim(),
          consent: _consent,
        ),
      );
      if (mounted) Navigator.pop(context);
    } on Exception {
      if (!mounted) return;
      setState(() => _saving = false);
      _message(context, '无法保存服务设置，请重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    return _FormPage(
      title: '服务设置',
      form: _form,
      children: [
        if (widget.controller.settingsUnavailable) const Text('无法读取旧配置，请重新填写。'),
        Text('AI 模型', style: title),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('DeepSeek 推荐'),
              selected: _deepseek,
              onSelected: (_) => _provider(true),
            ),
            ChoiceChip(
              label: const Text('其他服务'),
              selected: !_deepseek,
              onSelected: (_) => _provider(false),
            ),
          ],
        ),
        if (!_deepseek)
          TextFormField(
            controller: _base,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'HTTPS 模型基地址',
              hintText: 'https://api.example.com/v1',
              errorMaxLines: 3,
            ),
            validator: (value) {
              final base = value!.trim();
              if (base.isNotEmpty &&
                  (ServiceSettings(base: base).modelEndpoint == null ||
                      base.endsWith('/chat/completions') ||
                      base.endsWith('/chat/completions/'))) {
                return '请输入 HTTPS 基地址，省略 chat/completions、查询参数和片段。';
              }
              return null;
            },
          ),
        _keyField(_modelKey, '模型 Key'),
        TextFormField(
          controller: _model,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: '模型名称',
            suffixIcon: _models.isEmpty
                ? null
                : PopupMenuButton<String>(
                    tooltip: '选择模型',
                    icon: const Icon(Icons.arrow_drop_down),
                    onSelected: (value) => setState(() => _model.text = value),
                    itemBuilder: (context) => [
                      for (final model in _models)
                        PopupMenuItem(value: model, child: Text(model)),
                    ],
                  ),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _fetching ? null : _fetchModels,
          icon: const Icon(Icons.refresh),
          label: Text(_fetching ? '正在获取模型' : '获取可用模型'),
        ),
        Text('全网补查', style: title),
        const Text('优先使用支持的模型服务商搜索。其他情况使用免费的 Mwmbl，填写 Tavily Key 后使用 Tavily。'),
        _keyField(_searchKey, 'Tavily Key'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('允许联网整理'),
          subtitle: const Text(_networkNotice),
          value: _consent,
          onChanged: (value) => setState(() => _consent = value),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('保存设置'),
        ),
      ],
    );
  }

  Widget _keyField(TextEditingController controller, String label) =>
      TextFormField(
        controller: controller,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        decoration: InputDecoration(labelText: label),
      );
}

class _FormPage extends StatelessWidget {
  const _FormPage({
    required this.title,
    required this.form,
    required this.children,
  });
  final String title;
  final GlobalKey<FormState> form;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: SafeArea(
      top: false,
      child: _ReadingWidth(
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
            children: [
              for (final child in children)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: child,
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

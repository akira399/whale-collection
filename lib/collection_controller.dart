import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'collection_models.dart';
import 'collection_store.dart';
import 'link_services.dart';

typedef BatchProgress = ({
  int total,
  int ready,
  int failed,
  int skipped,
  int remaining,
  bool running,
  String? pause,
});

final class CollectionController extends ChangeNotifier {
  CollectionController(this.store, this.settingsStore, this.services);

  final CollectionStore store;
  final SettingsStore settingsStore;
  final LinkServices services;

  ServiceSettings settings = const ServiceSettings();
  bool settingsUnavailable = false;
  List<Entry> entries = const [];
  List<String> tags = const [];
  ({int id, String title, CollectionCategory category})? latestOrganizedTool;
  BatchProgress? batch;
  int batchVersion = 0;
  bool get batchRunning => batch?.running == true;
  String query = '';
  CollectionCategory? category;
  String? tag;
  bool needsOrganization = false;
  bool prompts = false;
  bool loading = true;
  String? loadError;
  final _active = <int, String>{};
  int _load = 0;
  bool _disposed = false;

  String? progress(int id) => _active[id];
  bool get filtered =>
      query.trim().isNotEmpty ||
      category != null ||
      tag != null ||
      needsOrganization;

  Future<void> initialize() async {
    try {
      settings = await settingsStore.load();
    } on Exception {
      settingsUnavailable = true;
    }
    await refresh();
  }

  Future<void> saveSettings(ServiceSettings value) async {
    await settingsStore.save(value);
    settings = value;
    settingsUnavailable = false;
    _notify();
  }

  Future<void> allowNetwork() => saveSettings(
    ServiceSettings(
      base: settings.base,
      model: settings.model,
      modelKey: settings.modelKey,
      searchKey: settings.searchKey,
      consent: true,
    ),
  );

  void search(String value) {
    query = value;
    unawaited(refresh());
  }

  void selectCategory(CollectionCategory? value) {
    category = value;
    _notify();
    unawaited(refresh());
  }

  void selectTag(String? value) {
    tag = value;
    _notify();
    unawaited(refresh());
  }

  void showUnfinished(bool value) {
    needsOrganization = value;
    _notify();
    unawaited(refresh());
  }

  void selectPage(bool value) {
    if (prompts == value) return;
    prompts = value;
    entries = const [];
    tags = const [];
    loadError = null;
    loading = true;
    clearFilters();
  }

  void clearFilters() {
    query = '';
    category = null;
    tag = null;
    needsOrganization = false;
    _notify();
    unawaited(refresh());
  }

  Future<void> refresh() async {
    final revision = ++_load;
    try {
      final availableTags = await store.tags(prompts: prompts);
      if (_load != revision) return;
      if (tag != null && !availableTags.contains(tag)) tag = null;
      final matches = await store.list(
        query: query,
        category: category,
        tag: tag,
        needsOrganization: needsOrganization,
        prompts: prompts,
      );
      if (_load != revision) return;
      tags = List.unmodifiable(availableTags);
      entries = List.unmodifiable(matches);
      loadError = null;
    } on Exception {
      if (_load != revision) return;
      loadError = '无法读取收藏，请重试。';
    }
    loading = false;
    _notify();
  }

  Future<({int id, bool added})> add(String value) async {
    final uri = webUri(value);
    if (uri == null) throw const FormatException();
    final result = await store.add(value, LinkIdentity(uri));
    unawaited(refresh());
    return result;
  }

  Future<int> addPrompt(String text) async {
    if (text.trim().isEmpty) throw const FormatException();
    final id = await store.addPrompt(text);
    unawaited(refresh());
    return id;
  }

  Future<bool> remove(int id) async {
    if (_active.containsKey(id)) return false;
    await store.remove(id);
    if (latestOrganizedTool?.id == id) latestOrganizedTool = null;
    await refresh();
    return true;
  }

  Future<List<({int id, bool added})>> addLinks(List<Uri> urls) async {
    final result = await store.addLinks(urls);
    await refresh();
    return result;
  }

  Future<void> setPinned(Entry entry) async {
    await store.update(entry.id, {
      'pinned_at': entry.pinnedAt == null
          ? DateTime.now().millisecondsSinceEpoch
          : null,
    });
    await refresh();
  }

  Future<void> setNote(int id, String note) async {
    await store.update(id, {'note': note.trim()});
    await refresh();
  }

  Future<void> run(int id) async {
    if (batchRunning) return;
    batch = null;
    await _run(id);
  }

  Future<void> runBatch(Iterable<int> ids) async {
    if (!settings.consent || batchRunning) return;
    final pending = ids.toSet().toList();
    if (pending.isEmpty) return;
    var ready = 0;
    var failed = 0;
    var skipped = 0;
    var remaining = pending.length;
    String? pause;
    void publish(bool running) {
      batch = (
        total: pending.length,
        ready: ready,
        failed: failed,
        skipped: skipped,
        remaining: remaining,
        running: running,
        pause: pause,
      );
      _notify();
    }

    publish(true);
    try {
      for (final id in pending) {
        if (_disposed) break;
        final entry = await store.find(id);
        if (entry == null ||
            entry.status == EntryStatus.ready ||
            _active.containsKey(id)) {
          skipped++;
        } else {
          pause = await _run(id, reportPet: false);
          final result = await store.find(id);
          if (result?.status == EntryStatus.ready) {
            ready++;
          } else {
            failed++;
          }
        }
        remaining--;
        if (pause != null) break;
        publish(true);
      }
    } on Exception {
      pause = '暂时无法读取收藏，剩余条目可稍后继续整理。';
    } finally {
      batchVersion++;
      publish(false);
    }
  }

  Future<String?> _run(int id, {bool reportPet = true}) async {
    if (!settings.consent || _active.containsKey(id)) return null;
    _stage(id, '读取链接');
    try {
      final entry = await store.find(id);
      if (entry == null || entry.status == EntryStatus.ready) return null;
      final config = settings;
      if (entry.kind == SourceKind.prompt) {
        if (!config.hasModel) {
          const reason = '请在设置中填写模型地址、模型名称和 Key，再重试整理。';
          await _needsAttention(id, reason);
          return reason;
        }
        _stage(id, '整理提示词');
        try {
          final result = await services.organize(
            settings: config,
            evidence: LinkEvidence(
              url: Uri(),
              kind: SourceKind.prompt,
              title: entry.title,
              body: clip(entry.promptText, 7000),
            ),
            search: const [],
            knownTags: await store.tags(limit: 30),
          );
          await store.update(id, {
            'status': EntryStatus.ready.name,
            'reason': null,
            'summary': result.summary,
            'features': jsonEncode(result.features),
            'category': result.category.name,
          }, tags: result.tags);
        } on ServiceProblem catch (problem) {
          await _needsAttention(id, problem.message);
          if (problem.connection || problem.pauseBatch) return problem.message;
        } on FormatException {
          await _needsAttention(id, '模型未返回可用的整理结果，可重试或手动补全。');
        }
        return null;
      }
      final identity = LinkIdentity(entry.original);
      LinkEvidence? evidence;
      String? failure;
      var sourceOffline = false;
      String? batchPause;
      try {
        evidence = await services.extract(identity);
      } on ServiceProblem catch (problem) {
        failure = problem.message;
        sourceOffline = problem.connection;
      } on FormatException {
        failure = '原链接返回的资料无法读取。';
      }
      if (evidence != null) {
        await _saveEvidence(entry, evidence);
      }
      if ((evidence?.description.isEmpty ?? true) &&
          (evidence?.body.isEmpty ?? true) &&
          entry.description.isNotEmpty) {
        evidence = LinkEvidence(
          url: entry.resolved ?? entry.original,
          kind: entry.kind,
          title: entry.title,
          description: entry.description,
          links: entry.links,
          sources: entry.sources,
        );
      }

      var excerpts = <SearchExcerpt>[];
      if (evidence?.needsSearch ?? true) {
        _stage(id, '补查公开资料');
        try {
          excerpts = await services.search(
            identity,
            evidence,
            config.searchKey,
            settings: config,
          );
        } on ServiceProblem catch (problem) {
          failure ??= problem.message;
          if (problem.pauseBatch || (sourceOffline && problem.connection)) {
            batchPause = problem.message;
          }
        } on FormatException {
          failure ??= '搜索服务返回的结果无法读取。';
        }
      }
      if (excerpts.isNotEmpty) {
        await _saveSearch(
          id,
          evidence,
          excerpts,
          preserveTitle: identity.repository != null,
        );
      }

      final hasEvidence =
          excerpts.isNotEmpty ||
          (evidence != null &&
              (evidence.description.isNotEmpty || evidence.body.isNotEmpty));
      if (!hasEvidence) {
        await _needsAttention(id, failure ?? '缺少可用于整理的资料，可手动补全。');
        return batchPause;
      } else if (!config.hasModel) {
        const reason = '请在设置中填写模型地址、模型名称和 Key，再重试整理。';
        await _needsAttention(id, reason);
        return reason;
      } else {
        _stage(id, '生成简介与标签');
        try {
          final candidates = services.toolLinks(
            entry.original,
            evidence,
            excerpts,
          );
          final result = await services.organize(
            settings: config,
            evidence:
                evidence ??
                LinkEvidence(
                  url: identity.uri,
                  kind: identity.kind,
                  title: identity.repository ?? excerpts.first.title,
                ),
            search: excerpts,
            knownTags: await store.tags(limit: 30),
            candidates: candidates,
          );
          final selected = result.linkIndex;
          if (identity.kind != SourceKind.repository &&
              selected != null &&
              selected >= 0 &&
              selected < candidates.length) {
            final link = candidates.removeAt(selected);
            candidates.insert(0, link);
          }
          if (candidates.isEmpty && result.toolName.isNotEmpty) {
            _stage(id, '查找工具入口');
            try {
              final destination = await services.findTool(
                result.toolName,
                config,
              );
              if (destination != null) candidates.add(destination);
            } on ServiceProblem {
              // The summary is usable even if the lookup fails.
            } on FormatException {
              // The summary is usable even if the lookup fails.
            }
          }
          await store.update(id, {
            'status': EntryStatus.ready.name,
            'reason': null,
            'summary': result.summary,
            'features': jsonEncode(result.features),
            'category': result.category.name,
            if (candidates.isNotEmpty) 'links': _encodeLinks(candidates),
          }, tags: result.tags);
          if (reportPet) {
            latestOrganizedTool = (
              id: id,
              title: evidence?.title.isNotEmpty == true
                  ? evidence!.title
                  : identity.repository ??
                        excerpts.firstOrNull?.title ??
                        entry.title,
              category: result.category,
            );
          }
        } on ServiceProblem catch (problem) {
          await _needsAttention(id, problem.message);
          if (problem.connection || problem.pauseBatch) return problem.message;
        } on FormatException {
          await _needsAttention(id, '模型未返回可用的整理结果，可重试或手动补全。');
        }
      }
    } on Exception {
      try {
        await _needsAttention(id, '整理过程中出现问题，请稍后重试。');
      } on Exception {
        // The saved entry remains available for retry when storage is accessible.
      }
    } finally {
      _active.remove(id);
      _notify();
      await refresh();
    }
    return null;
  }

  Future<void> completeManually(
    Entry entry, {
    required String title,
    required String summary,
    required CollectionCategory category,
    required List<String> tags,
    String? promptText,
    String? originalUrl,
    List<String>? features,
    List<WebLink>? links,
  }) async {
    if (_active.containsKey(entry.id)) return;
    await store.update(entry.id, {
      'title': title.trim(),
      'summary': summary.trim(),
      'prompt_text': ?promptText,
      if (features != null) 'features': jsonEncode(features),
      if (links != null) 'links': _encodeLinks(links),
      if (originalUrl != null &&
          originalUrl.trim() != entry.original.toString()) ...{
        'original_url': originalUrl.trim(),
        'url_key': LinkIdentity(webUri(originalUrl)!).key,
        'resolved_url': null,
        'domain': webUri(originalUrl)!.host,
        'kind': LinkIdentity(webUri(originalUrl)!).kind.name,
      },
      'category': category.name,
      'status': EntryStatus.ready.name,
      'reason': null,
      'sources': _encodeLinks([
        ...entry.sources.where((source) => source.label != '手动录入'),
        if (entry.kind != SourceKind.prompt) WebLink('手动录入', entry.original),
      ]),
    }, tags: tags);
    await refresh();
  }

  Future<void> _saveEvidence(Entry entry, LinkEvidence evidence) {
    final preview = evidence.description.isNotEmpty
        ? evidence.description
        : clip(evidence.body, 500);
    return store.update(entry.id, {
      'resolved_url': evidence.url.toString(),
      'domain': evidence.url.host,
      'kind': evidence.kind.name,
      if (evidence.title.isNotEmpty) 'title': evidence.title,
      if (preview.isNotEmpty) 'description': preview,
      if (evidence.sources.isNotEmpty)
        'sources': _encodeLinks(evidence.sources),
      if (evidence.links.isNotEmpty) 'links': _encodeLinks(evidence.links),
    });
  }

  Future<void> _saveSearch(
    int id,
    LinkEvidence? evidence,
    List<SearchExcerpt> excerpts, {
    required bool preserveTitle,
  }) => store.update(id, {
    if (!preserveTitle &&
        (evidence?.title ?? '').isEmpty &&
        excerpts.first.title.isNotEmpty)
      'title': excerpts.first.title,
    if ((evidence?.description ?? '').isEmpty && (evidence?.body ?? '').isEmpty)
      'description': clip(excerpts.first.text, 500),
    'sources': _encodeLinks([
      ...?evidence?.sources,
      for (final excerpt in excerpts) excerpt.source,
    ]),
  });

  String _encodeLinks(List<WebLink> links) =>
      jsonEncode([for (final link in links) link.toJson()]);

  Future<void> _needsAttention(int id, String reason) => store.update(id, {
    'status': EntryStatus.attention.name,
    'reason': reason,
  });

  void _stage(int id, String label) {
    _active[id] = label;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

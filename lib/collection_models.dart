import 'dart:convert';

enum CollectionCategory {
  development('开发'),
  writing('写作与知识'),
  design('图像与设计'),
  media('音视频'),
  research('搜索与研究'),
  productivity('效率与自动化'),
  platforms('模型与平台'),
  other('其他');

  const CollectionCategory(this.label);
  final String label;
}

String defaultPromptTitle(String text) {
  final preview = compact(text);
  return '${clip(preview, 80)}${preview.length > 80 ? '…' : ''}';
}

enum SourceKind {
  web('网页'),
  repository('GitHub'),
  video('视频'),
  prompt('提示词');

  const SourceKind(this.label);
  final String label;
}

enum EntryStatus { pending, attention, ready }

Uri? webUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !const {'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      RegExp(r'\s').hasMatch(value.trim())) {
    return null;
  }
  return uri;
}

final class LinkIdentity {
  LinkIdentity(this.uri);

  final Uri uri;

  String? get repository {
    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (!const {'github.com', 'www.github.com'}.contains(uri.host) ||
        parts.length < 2 ||
        !parts.take(2).every((part) => RegExp(r'^[\w.-]+$').hasMatch(part)) ||
        const {
          'topics',
          'orgs',
          'settings',
          'marketplace',
          'sponsors',
          'users',
        }.contains(parts.first)) {
      return null;
    }
    return '${parts.first}/${parts[1].replaceFirst(RegExp(r'\.git$', caseSensitive: false), '')}';
  }

  String? get youtubeId {
    final parts = uri.pathSegments;
    String? id;
    if (uri.host == 'youtu.be' && parts.isNotEmpty) {
      id = parts.first;
    } else if (const {
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
    }.contains(uri.host)) {
      if (uri.path == '/watch') {
        id = uri.queryParameters['v'];
      } else if (parts.length >= 2 &&
          const {'shorts', 'live', 'embed'}.contains(parts.first)) {
        id = parts[1];
      }
    }
    return id != null && RegExp(r'^[\w-]{11}$').hasMatch(id) ? id : null;
  }

  String? get bilibiliId {
    final parts = uri.pathSegments;
    if (const {
          'bilibili.com',
          'www.bilibili.com',
          'm.bilibili.com',
        }.contains(uri.host) &&
        parts.length >= 2 &&
        parts.first == 'video' &&
        RegExp(r'^(BV[0-9A-Za-z]+|av[0-9]+)$').hasMatch(parts[1])) {
      return parts[1];
    }
    return null;
  }

  SourceKind get kind {
    if (repository != null) return SourceKind.repository;
    if (youtubeId != null || bilibiliId != null || uri.host == 'b23.tv') {
      return SourceKind.video;
    }
    return SourceKind.web;
  }

  String get key {
    final fragment = uri.fragment;
    final route = fragment.startsWith('/') || fragment.startsWith('!/');
    final query = uri.query
        .split('&')
        .where((pair) {
          final name = pair.split('=').first.toLowerCase();
          return name.isNotEmpty &&
              !name.startsWith('utm_') &&
              !const {'fbclid', 'gclid', 'msclkid', 'igshid'}.contains(name);
        })
        .join('&');
    final id = youtubeId;
    if (id != null) return 'https://www.youtube.com/watch?v=$id';
    final repo = repository;
    if (repo != null &&
        uri.pathSegments.where((part) => part.isNotEmpty).length == 2 &&
        query.isEmpty &&
        !route) {
      return 'https://github.com/${repo.toLowerCase()}';
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path.isEmpty ? '/' : uri.path,
      query: query.isEmpty ? null : query,
      fragment: route ? fragment : null,
    ).toString();
  }
}

String compact(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

String clip(String text, int length) => text.length <= length
    ? text
    : String.fromCharCodes(text.runes.take(length));

List<String> cleanTags(Iterable<String> values) {
  final tags = <String, String>{};
  for (final value in values) {
    final tag = compact(value);
    if (tag.isNotEmpty) tags.putIfAbsent(tag.toLowerCase(), () => tag);
  }
  return tags.values.toList();
}

final class WebLink {
  const WebLink(this.label, this.url);

  final String label;
  final Uri url;

  Map<String, String> toJson() => {'label': label, 'url': url.toString()};

  static List<WebLink> decode(String json) => [
    for (final link
        in (jsonDecode(json) as List<Object?>).cast<Map<String, Object?>>())
      WebLink(link['label']! as String, Uri.parse(link['url']! as String)),
  ];
}

final class Entry {
  Entry.fromRow(Map<String, Object?> row, this.tags)
    : id = row['id']! as int,
      original = Uri.parse(row['original_url']! as String),
      resolved = row['resolved_url'] == null
          ? null
          : Uri.parse(row['resolved_url']! as String),
      kind = SourceKind.values.byName(row['kind']! as String),
      title = row['title']! as String,
      promptText = row['prompt_text'] as String? ?? '',
      note = row['note'] as String? ?? '',
      pinnedAt = row['pinned_at'] as int?,
      description = row['description']! as String,
      summary = row['summary']! as String,
      features = (jsonDecode(row['features']! as String) as List<Object?>)
          .cast<String>(),
      category = row['category'] == null
          ? null
          : CollectionCategory.values.byName(row['category']! as String),
      status = EntryStatus.values.byName(row['status']! as String),
      reason = row['reason'] as String?,
      sources = WebLink.decode(row['sources']! as String),
      links = WebLink.decode(row['links']! as String),
      createdAt = DateTime.fromMillisecondsSinceEpoch(
        row['created_at']! as int,
        isUtc: true,
      );

  final int id;
  final Uri original;
  final Uri? resolved;
  final SourceKind kind;
  final String title;
  final String promptText;
  final String note;
  final int? pinnedAt;
  final String description;
  final String summary;
  final List<String> features;
  final CollectionCategory? category;
  final EntryStatus status;
  final String? reason;
  final List<String> tags;
  final List<WebLink> sources;
  final List<WebLink> links;
  final DateTime createdAt;

  String get preview => summary.isEmpty ? description : summary;
  String get domain => resolved?.host ?? original.host;

  WebLink? get toolLink {
    if (kind == SourceKind.prompt) return null;
    final main = links.firstOrNull;
    if (main != null) {
      if (kind == SourceKind.repository && main.label.startsWith('查看源码')) {
        return links
            .skip(1)
            .firstWhere(
              (link) => link.label.contains('下载') || link.label.contains('官网'),
              orElse: () => main,
            );
      }
      return main;
    }
    return WebLink('打开来源页面', resolved ?? original);
  }
}

final class Organization {
  const Organization({
    required this.summary,
    required this.features,
    required this.category,
    required this.tags,
    this.toolName = '',
    this.linkIndex,
  });

  final String summary;
  final List<String> features;
  final CollectionCategory category;
  final List<String> tags;
  final String toolName;
  final int? linkIndex;

  factory Organization.fromJson(Object? json) {
    if (json is! Map<String, Object?>) throw const FormatException();
    final summary = json['summary'];
    final category = json['category'];
    List<String> strings(String key, int maxLength, {int? maxItems}) {
      final items = json[key];
      if (items is! List<Object?>) return [];
      final values = items
          .whereType<String>()
          .map(compact)
          .where((s) => s.isNotEmpty);
      return (maxItems == null ? values : values.take(maxItems))
          .map((s) => clip(s, maxLength))
          .toList();
    }

    final name = category is String ? category.trim().toLowerCase() : '';
    if (summary is! String || summary.trim().isEmpty) {
      throw const FormatException();
    }
    return Organization(
      summary: clip(compact(summary), 600),
      features: strings('features', 180, maxItems: 5),
      category: CollectionCategory.values.firstWhere(
        (item) => item.name == name || item.label == name,
        orElse: () => CollectionCategory.other,
      ),
      tags: cleanTags(strings('tags', 80)),
      toolName: json['tool_name'] is String
          ? clip(compact(json['tool_name']! as String), 80)
          : '',
      linkIndex: json['link_index'] is int ? json['link_index']! as int : null,
    );
  }
}

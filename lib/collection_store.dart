import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

import 'collection_models.dart';

final class ServiceSettings {
  const ServiceSettings({
    this.base = '',
    this.model = '',
    this.modelKey = '',
    this.searchKey = '',
    this.consent = false,
  });

  final String base;
  final String model;
  final String modelKey;
  final String searchKey;
  final bool consent;

  Uri? get modelEndpoint {
    final uri = webUri(base);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(path: '$path/chat/completions');
  }

  bool get hasModel =>
      modelEndpoint != null && model.isNotEmpty && modelKey.isNotEmpty;
}

final class SettingsStore {
  const SettingsStore(this.storage);

  final FlutterSecureStorage storage;
  static const _key = 'service_settings';

  Future<ServiceSettings> load() async {
    final raw = await storage.read(key: _key);
    if (raw == null) return const ServiceSettings();
    final json = jsonDecode(raw) as Map<String, Object?>;
    return ServiceSettings(
      base: json['base'] as String? ?? '',
      model: json['model'] as String? ?? '',
      modelKey: json['modelKey'] as String? ?? '',
      searchKey: json['searchKey'] as String? ?? '',
      consent: json['consent'] == true && json['searchConsentV2'] == true,
    );
  }

  Future<void> save(ServiceSettings settings) => storage.write(
    key: _key,
    value: jsonEncode({
      'base': settings.base,
      'model': settings.model,
      'modelKey': settings.modelKey,
      'searchKey': settings.searchKey,
      'consent': settings.consent,
      'searchConsentV2': settings.consent,
    }),
  );
}

final class CollectionStore {
  CollectionStore(this.database);

  final Database database;

  static OpenDatabaseOptions get options => OpenDatabaseOptions(
    version: 3,
    onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE entries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          original_url TEXT NOT NULL,
          url_key TEXT NOT NULL UNIQUE,
          resolved_url TEXT,
          domain TEXT NOT NULL,
          kind TEXT NOT NULL,
          title TEXT NOT NULL,
          prompt_text TEXT NOT NULL DEFAULT '',
          note TEXT NOT NULL DEFAULT '',
          pinned_at INTEGER,
          description TEXT NOT NULL DEFAULT '',
          summary TEXT NOT NULL DEFAULT '',
          features TEXT NOT NULL DEFAULT '[]',
          category TEXT,
          status TEXT NOT NULL,
          reason TEXT,
          sources TEXT NOT NULL DEFAULT '[]',
          links TEXT NOT NULL DEFAULT '[]',
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE tags (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          normalized TEXT NOT NULL UNIQUE
        )
      ''');
      await db.execute('''
        CREATE TABLE entry_tags (
          entry_id INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
          tag_id INTEGER NOT NULL REFERENCES tags(id),
          PRIMARY KEY (entry_id, tag_id)
        )
      ''');
      await db.execute(
        'CREATE INDEX entry_tags_tag ON entry_tags(tag_id, entry_id)',
      );
    },
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) {
        await db.execute(
          "ALTER TABLE entries ADD COLUMN prompt_text TEXT NOT NULL DEFAULT ''",
        );
      }
      if (oldVersion < 3) {
        await db.execute(
          "ALTER TABLE entries ADD COLUMN note TEXT NOT NULL DEFAULT ''",
        );
        await db.execute('ALTER TABLE entries ADD COLUMN pinned_at INTEGER');
      }
    },
  );

  Future<({int id, bool added})> add(String input, LinkIdentity link) =>
      database.transaction((tx) => _add(tx, input, link));

  Future<List<({int id, bool added})>> addLinks(List<Uri> urls) =>
      database.transaction(
        (tx) async => [
          for (final url in urls)
            await _add(tx, url.toString(), LinkIdentity(url)),
        ],
      );

  Future<({int id, bool added})> _add(
    Transaction tx,
    String input,
    LinkIdentity link,
  ) async {
    final existing = await tx.query(
      'entries',
      columns: ['id'],
      where: 'url_key = ?',
      whereArgs: [link.key],
    );
    if (existing.isNotEmpty) {
      return (id: existing.single['id']! as int, added: false);
    }
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final id = await tx.insert('entries', {
      'original_url': input.trim(),
      'url_key': link.key,
      'domain': link.uri.host,
      'kind': link.kind.name,
      'title': link.repository ?? link.uri.host,
      'status': EntryStatus.pending.name,
      'created_at': now,
      'updated_at': now,
    });
    return (id: id, added: true);
  }

  Future<int> addPrompt(String text) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    return database.transaction((tx) async {
      await tx.rawInsert(
        """INSERT INTO entries (original_url, url_key, domain, kind, title, prompt_text, status, created_at, updated_at)
        VALUES ('', 'prompt:' || lower(hex(randomblob(16))), '', ?, ?, ?, ?, ?, ?)""",
        [
          SourceKind.prompt.name,
          defaultPromptTitle(text),
          text,
          EntryStatus.pending.name,
          now,
          now,
        ],
      );
      final row = await tx.rawQuery('SELECT last_insert_rowid() AS id');
      return row.single['id']! as int;
    });
  }

  Future<Map<String, int>> existingLinks(Iterable<String> keys) async {
    final values = keys.toSet().toList();
    final matches = <String, int>{};
    for (var offset = 0; offset < values.length; offset += 500) {
      final group = values.skip(offset).take(500).toList();
      final rows = await database.query(
        'entries',
        columns: ['url_key', 'id'],
        where: 'url_key IN (${List.filled(group.length, '?').join(',')})',
        whereArgs: group,
      );
      for (final row in rows) {
        matches[row['url_key']! as String] = row['id']! as int;
      }
    }
    return matches;
  }

  Future<List<Entry>> list({
    String query = '',
    CollectionCategory? category,
    String? tag,
    bool needsOrganization = false,
    bool? prompts,
    int? id,
    Set<int>? ids,
  }) async {
    if (ids?.isEmpty == true) return [];
    final where = <String>[];
    if (ids != null) {
      where.add('e.id IN (${ids.map((id) => id.toString()).join(',')})');
    }
    final args = <Object>[];
    if (prompts != null) {
      where.add(prompts ? 'e.kind = ?' : 'e.kind != ?');
      args.add(SourceKind.prompt.name);
    }
    if (id != null) {
      where.add('e.id = ?');
      args.add(id);
    }
    if (category != null) {
      where.add('e.category = ?');
      args.add(category.name);
    }
    if (tag != null) {
      where.add('''EXISTS (
        SELECT 1 FROM entry_tags et JOIN tags t ON t.id = et.tag_id
        WHERE et.entry_id = e.id AND t.normalized = ?
      )''');
      args.add(tag.toLowerCase());
    }
    if (needsOrganization) {
      where.add('e.status IN (?, ?)');
      args.addAll([EntryStatus.pending.name, EntryStatus.attention.name]);
    }
    final needle = query.trim().toLowerCase();
    if (needle.isNotEmpty) {
      where.add('''(
        instr(lower(e.title), ?) > 0 OR instr(lower(e.summary), ?) > 0
        OR instr(lower(e.description), ?) > 0
        OR instr(lower(e.prompt_text), ?) > 0
        OR instr(lower(e.note), ?) > 0
        OR instr(lower(e.original_url), ?) > 0
        OR instr(lower(e.resolved_url), ?) > 0
        OR EXISTS (
          SELECT 1 FROM entry_tags et JOIN tags t ON t.id = et.tag_id
          WHERE et.entry_id = e.id AND instr(t.normalized, ?) > 0
        )
      )''');
      args.addAll(List.filled(8, needle));
    }
    final rows = await database.rawQuery('''
      SELECT e.*, t.name AS tag_name
      FROM entries e
      LEFT JOIN entry_tags et ON et.entry_id = e.id
      LEFT JOIN tags t ON t.id = et.tag_id
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY e.pinned_at DESC, e.created_at DESC, e.id DESC, t.normalized
    ''', args);
    final entries = <int, Map<String, Object?>>{};
    final tags = <int, List<String>>{};
    for (final row in rows) {
      final id = row['id']! as int;
      entries[id] = row;
      final tag = row['tag_name'] as String?;
      if (tag != null) (tags[id] ??= []).add(tag);
    }
    return [
      for (final row in entries.entries)
        Entry.fromRow(row.value, List.unmodifiable(tags[row.key] ?? const [])),
    ];
  }

  Future<Entry?> find(int id) async => (await list(id: id)).firstOrNull;

  Future<String> exportBackup() => database.transaction((tx) async {
    final rows = await tx.query('entries', orderBy: 'created_at');
    final items = <Map<String, Object?>>[];
    for (final row in rows) {
      final tags = await tx.rawQuery(
        'SELECT t.name FROM tags t JOIN entry_tags et ON et.tag_id = t.id WHERE et.entry_id = ?',
        [row['id']],
      );
      items.add(
        {...row}
          ..remove('id')
          ..['tags'] = [for (final tag in tags) tag['name']],
      );
    }
    return jsonEncode({
      'format': 'whale_collection',
      'version': 2,
      'entries': items,
    });
  });

  List<({Map<String, Object?> fields, List<String> tags})> _parseBackup(
    String data,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      throw const FormatException('备份文件不是有效的 JSON。');
    }
    if (decoded is! Map<String, Object?> ||
        decoded['format'] != 'whale_collection' ||
        !const {1, 2}.contains(decoded['version']) ||
        decoded['entries'] is! List) {
      throw const FormatException('备份格式或版本不受支持。');
    }
    final items = <({Map<String, Object?> fields, List<String> tags})>[];
    try {
      final legacy = decoded['version'] == 1;
      for (final item in decoded['entries'] as List) {
        final row = Map<String, Object?>.from(item as Map);
        final rawTags = row.remove('tags') as List;
        if (legacy) {
          if (row.containsKey('note') || row.containsKey('pinned_at')) {
            throw const FormatException();
          }
          row['note'] = '';
          row['pinned_at'] = null;
        }
        if (row['pinned_at'] != null && row['pinned_at'] is! int) {
          throw const FormatException();
        }
        final tags = rawTags.cast<String>();
        const requiredStrings = [
          'original_url',
          'url_key',
          'domain',
          'kind',
          'title',
          'prompt_text',
          'description',
          'summary',
          'features',
          'status',
          'sources',
          'links',
          'note',
        ];
        const optionalStrings = ['resolved_url', 'category', 'reason'];
        const integers = ['created_at', 'updated_at'];
        if (row.length !=
                requiredStrings.length +
                    optionalStrings.length +
                    integers.length +
                    1 ||
            !row.containsKey('pinned_at') ||
            requiredStrings.any((key) => row[key] is! String) ||
            optionalStrings.any(
              (key) =>
                  !row.containsKey(key) ||
                  (row[key] != null && row[key] is! String),
            ) ||
            integers.any((key) => row[key] is! int) ||
            (row['url_key'] as String).isEmpty) {
          throw const FormatException();
        }
        for (final key in integers) {
          DateTime.fromMillisecondsSinceEpoch(row[key]! as int, isUtc: true);
        }
        final kind = SourceKind.values.byName(row['kind'] as String);
        EntryStatus.values.byName(row['status'] as String);
        if (row['category'] != null) {
          CollectionCategory.values.byName(row['category'] as String);
        }
        if (kind == SourceKind.prompt) {
          if (!(row['url_key'] as String).startsWith('prompt:') ||
              (row['prompt_text'] as String).trim().isEmpty) {
            throw const FormatException();
          }
        } else {
          final uri = webUri(row['original_url'] as String);
          if (uri == null || LinkIdentity(uri).key != row['url_key']) {
            throw const FormatException();
          }
        }
        if (row['resolved_url'] != null &&
            webUri(row['resolved_url'] as String) == null) {
          throw const FormatException();
        }
        (jsonDecode(row['features'] as String) as List).cast<String>().toList();
        for (final key in ['sources', 'links']) {
          for (final link in WebLink.decode(row[key] as String)) {
            if (webUri(link.url.toString()) == null) {
              throw const FormatException();
            }
          }
        }
        items.add((fields: row, tags: cleanTags(tags)));
      }
    } on Object {
      throw const FormatException('备份内容无效，未导入任何数据。');
    }
    return items;
  }

  Future<({int added, int skipped})> previewBackup(String data) async {
    final items = _parseBackup(data);
    final keys = items.map((item) => item.fields['url_key']! as String).toSet();
    final existing = await existingLinks(keys);
    final added = keys.length - existing.length;
    return (added: added, skipped: items.length - added);
  }

  Future<({int added, int skipped})> importBackup(String data) async {
    final items = _parseBackup(data);
    return database.transaction((tx) async {
      var added = 0;
      for (final item in items) {
        final exists = await tx.query(
          'entries',
          columns: ['id'],
          where: 'url_key = ?',
          whereArgs: [item.fields['url_key']],
          limit: 1,
        );
        if (exists.isNotEmpty) continue;
        final id = await tx.insert('entries', item.fields);
        for (final tag in item.tags) {
          final normalized = tag.toLowerCase();
          await tx.insert('tags', {
            'name': tag,
            'normalized': normalized,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          final rows = await tx.query(
            'tags',
            columns: ['id'],
            where: 'normalized = ?',
            whereArgs: [normalized],
          );
          await tx.insert('entry_tags', {
            'entry_id': id,
            'tag_id': rows.single['id'],
          });
        }
        added++;
      }
      return (added: added, skipped: items.length - added);
    });
  }

  Future<void> remove(int id) async {
    await database.delete('entries', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<String>> tags({int? limit, bool? prompts}) async {
    final rows = await database.rawQuery(
      '''
      SELECT t.name FROM tags t JOIN entry_tags et ON et.tag_id = t.id
      JOIN entries e ON e.id = et.entry_id
      ${prompts == null
          ? ''
          : prompts
          ? 'WHERE e.kind = ?'
          : 'WHERE e.kind != ?'}
      GROUP BY t.id ORDER BY COUNT(*) DESC, t.normalized
      ${limit == null ? '' : 'LIMIT ?'}
    ''',
      [if (prompts != null) SourceKind.prompt.name, ?limit],
    );
    return [for (final row in rows) row['name']! as String];
  }

  Future<void> update(
    int id,
    Map<String, Object?> fields, {
    List<String>? tags,
  }) => database.transaction((tx) async {
    final count = await tx.update(
      'entries',
      {...fields, 'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (count == 0 || tags == null) return;
    await tx.delete('entry_tags', where: 'entry_id = ?', whereArgs: [id]);
    for (final tag in cleanTags(tags)) {
      final key = tag.toLowerCase();
      await tx.insert('tags', {
        'name': tag,
        'normalized': key,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final row = await tx.query(
        'tags',
        columns: ['id'],
        where: 'normalized = ?',
        whereArgs: [key],
      );
      await tx.insert('entry_tags', {
        'entry_id': id,
        'tag_id': row.single['id'],
      });
    }
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:ai_tool_collection/collection_controller.dart';
import 'package:ai_tool_collection/collection_models.dart';
import 'package:ai_tool_collection/collection_store.dart';
import 'package:ai_tool_collection/collection_transfer.dart';
import 'package:ai_tool_collection/link_services.dart';
import 'package:ai_tool_collection/mascot_dialogue.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _settings = ServiceSettings(
  base: 'https://model.example/v1',
  model: 'test-model',
  modelKey: 'test-model-key',
  searchKey: 'test-search-key',
  consent: true,
);

const _longDescription =
    '这个工具可以从文档提取主要内容、整理素材并生成草稿，支持按标签组织资料和关键词搜索。'
    '用户可以在一个工作区管理大量文档、快速检索段落和查看原始来源。';

http.Response _json(Object value) => http.Response.bytes(
  utf8.encode(jsonEncode(value)),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _html(String value) => http.Response.bytes(
  utf8.encode(value),
  200,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

http.Response _model() => _json({
  'choices': [
    {
      'finish_reason': 'stop',
      'message': {
        'content': jsonEncode({
          'summary': '支持整理资料并提取内容。',
          'features': ['关键词搜索'],
          'category': 'writing',
          'tags': ['检索', ' AI ', 'ai'],
        }),
      },
    },
  ],
});

LinkIdentity _link(String url) => LinkIdentity(Uri.parse(url));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('batch parsing normalizes duplicates and limits unique links', () {
    final result = parseLinkText(
      [
        '两个链接 https://github.com/flutter/flutter.git，https://youtu.be/abcdefghijk',
        'https://github.com/Flutter/Flutter/?utm_source=share',
        'https://www.youtube.com/shorts/abcdefghijk',
        '没有链接',
        'https://example.com/view?q=a%2Fb#heading,https://example.com/other',
        for (var i = 0; i < 28; i++) 'https://example.org/tools/$i',
      ].join('\n'),
    );
    expect(result.urls, hasLength(30));
    expect(result.urls[2].query, 'q=a%2Fb');
    expect(result.urls[2].fragment, 'heading');
    expect(result.urls[3].path, '/other');
    expect(result.duplicates, 2);
    expect(result.unrecognized, 1);
    expect(result.excess, 2);
  });

  test(
    'prompt variables reuse multiline values without recursive expansion',
    () {
      const template = '{{ 主题 }}\n{{正文}}\n{{主题}}\n{{ }}';
      expect(promptVariables(template), ['主题', '正文']);
      expect(
        fillPrompt(template, {'主题': '标题', '正文': '第一行\n{{主题}}'}),
        '标题\n第一行\n{{主题}}\n标题\n{{ }}',
      );
    },
  );

  test('link keys preserve meaningful queries and routes', () {
    expect(
      _link('https://EXAMPLE.com/read?q=a%2Fb&q=b&utm_source=share#heading')
          .key,
      'https://example.com/read?q=a%2Fb&q=b',
    );
    expect(
      _link('https://example.com/#/tools?q=one').key,
      isNot(_link('https://example.com/#/tools?q=two').key),
    );
    expect(
      _link('https://www.github.com/Owner/Project.git/').key,
      _link('https://github.com/owner/project').key,
    );
    expect(
      _link('https://youtu.be/aqz-KE-bpKQ?si=share').key,
      _link('https://www.youtube.com/shorts/aqz-KE-bpKQ').key,
    );
    expect(webUri('file:///secret'), isNull);
    expect(webUri('https://user:password@example.com'), isNull);
  });

  test('AI may create more than five free-form tags', () {
    final result = Organization.fromJson({
      'summary': '摘要',
      'features': <String>[],
      'category': 'other',
      'tags': ['写作', '总结', '翻译', '邮件', '教学', '编程', '创意'],
    });
    expect(result.tags, hasLength(7));
  });

  test('version 1 collections migrate without losing existing links', () async {
    final directory = await Directory.systemTemp.createTemp('shilu_upgrade');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}legacy.db';
    final old = await databaseFactoryFfiNoIsolate.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute("""CREATE TABLE entries (
          id INTEGER PRIMARY KEY, original_url TEXT NOT NULL, url_key TEXT NOT NULL UNIQUE,
          resolved_url TEXT, domain TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
          description TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '',
          features TEXT NOT NULL DEFAULT '[]', category TEXT, status TEXT NOT NULL,
          reason TEXT, sources TEXT NOT NULL DEFAULT '[]', links TEXT NOT NULL DEFAULT '[]',
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)""");
          await db.execute(
            'CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL, normalized TEXT NOT NULL UNIQUE)',
          );
          await db.execute(
            'CREATE TABLE entry_tags (entry_id INTEGER NOT NULL, tag_id INTEGER NOT NULL, PRIMARY KEY (entry_id, tag_id))',
          );
          await db.insert('entries', {
            'original_url': 'https://example.com/',
            'url_key': 'https://example.com/',
            'domain': 'example.com',
            'kind': 'web',
            'title': '已有收藏',
            'status': 'ready',
            'created_at': 1,
            'updated_at': 1,
          });
        },
      ),
    );
    await old.close();
    final db = await databaseFactoryFfiNoIsolate.openDatabase(
      path,
      options: CollectionStore.options,
    );
    addTearDown(db.close);
    final store = CollectionStore(db);
    final migrated = (await store.list(prompts: false)).single;
    expect(migrated.title, '已有收藏');
    expect(migrated.note, isEmpty);
    expect(migrated.pinnedAt, isNull);
    final id = await store.addPrompt('新提示词\n第二行');
    expect((await store.find(id))!.promptText, '新提示词\n第二行');
  });

  test(
    'existing users see the new search notice when no Tavily key is set',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'service_settings': jsonEncode({'consent': true}),
      });
      const store = SettingsStore(FlutterSecureStorage());
      expect((await store.load()).consent, isFalse);
      await store.save(const ServiceSettings(consent: true));
      expect((await store.load()).consent, isTrue);
    },
  );

  test(
    'GitHub uses repo, raw README and latest release without model URLs',
    () async {
      final acceptHeaders = <String, String?>{};
      final service = LinkServices(
        MockClient((request) async {
          final path = request.url.path;
          acceptHeaders[path] = request.headers['accept'];
          expect(request.headers['authorization'], isNull);
          return switch (path) {
            '/repos/owner/tool' => _json({
              'full_name': 'owner/tool',
              'description': 'An AI utility',
              'html_url': 'https://github.com/owner/tool',
              'license': {'spdx_id': 'NOASSERTION'},
            }),
            '/repos/owner/tool/readme' => http.Response(
              '# Tool\nExtract readable text',
              200,
            ),
            '/repos/owner/tool/releases/latest' => _json({
              'html_url': 'https://github.com/owner/tool/releases/tag/v1',
              'draft': false,
              'prerelease': false,
            }),
            _ => http.Response('', 404),
          };
        }),
      );
      final evidence = await service.extract(
        _link('https://github.com/owner/tool'),
      );
      expect(evidence.kind, SourceKind.repository);
      expect(evidence.body, contains('Extract readable text'));
      expect(evidence.links.map((link) => link.label), [
        '下载入口 · GitHub Release',
        '查看源码',
      ]);
      expect(
        acceptHeaders['/repos/owner/tool/readme'],
        'application/vnd.github.raw+json',
      );
    },
  );

  test(
    'article reader extracts paragraphs and validated download entries',
    () async {
      final service = LinkServices(
        MockClient(
          (request) async => _html('''
      <title>资料归档工具</title>
      <nav>网站导航</nav>
      <article><h1>资料归档工具</h1>
      <p>$_longDescription $_longDescription</p><p>$_longDescription</p></article>
      <a href="/get">下载</a><a href="javascript:alert(1)">Download</a>
    '''),
        ),
      );
      final evidence = await service.extract(
        _link('https://example.org/guide'),
      );
      expect(evidence.body, contains('文档提取'));
      expect(evidence.body, isNot(contains('网站导航')));
      expect(evidence.links.single.url, Uri.parse('https://example.org/get'));
      expect(evidence.needsSearch, isFalse);
    },
  );

  test(
    'public GitHub page supplies README and homepage without REST quota',
    () async {
      final service = LinkServices(
        MockClient((request) async {
          expect(request.url, Uri.parse('https://github.com/owner/tool'));
          return _html('''
        <meta name="octolytics-dimension-repository_nwo" content="owner/tool">
        <script type="application/json" data-target="react-app.embeddedData">
        {"payload":{"sidebarAboutData":{"website":"https://tool.example/","description":"工具简介"}}}
        </script>
        <article class="markdown-body">用于整理内容的 README</article>
        <a href="/owner/tool/releases/tag/v1">v1</a>
      ''');
        }),
      );
      final result = await service.extract(
        _link('https://github.com/owner/tool'),
      );
      expect(result.body, contains('README'));
      expect(result.description, '工具简介');
      expect(
        result.links.map((link) => link.url.toString()),
        containsAll([
          'https://tool.example/',
          'https://github.com/owner/tool/releases',
        ]),
      );
    },
  );

  test(
    'YouTube uses oEmbed after generic title and Bilibili follows short link',
    () async {
      final service = LinkServices(
        MockClient((request) async {
          if (request.url.host == 'b23.tv') {
            return http.Response(
              '',
              302,
              headers: {
                'location': 'https://www.bilibili.com/video/BV1MW421X7gM/',
              },
            );
          }
          if (request.url.path == '/oembed') {
            expect(
              request.url.queryParameters['url'],
              contains('v=aqz-KE-bpKQ'),
            );
            return _json({'title': 'AI 视频标题'});
          }
          if (request.url.host.endsWith('bilibili.com')) {
            return _html('''
          <meta property="og:title" content="B 站视频">
          <meta name="description" content="工具的视频介绍">
          <article>与摘要无关的页面正文</article>
        ''');
          }
          return _html(
            '<title>YouTube</title><meta name="description" content="Generic website">',
          );
        }),
      );
      final youtube = await service.extract(
        _link('https://www.youtube.com/watch?v=aqz-KE-bpKQ'),
      );
      expect(youtube.title, 'AI 视频标题');
      expect(youtube.description, isEmpty);
      expect(youtube.needsSearch, isTrue);
      final bili = await service.extract(_link('https://b23.tv/example'));
      expect(bili.kind, SourceKind.video);
      expect(bili.url.host, 'www.bilibili.com');
      expect(bili.description, '工具的视频介绍');
      expect(bili.body, isEmpty);
    },
  );

  test(
    'duplicate concurrent inserts share an ID and persist through reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp('shilu_db_test');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}collection.db';
      final database = await databaseFactoryFfiNoIsolate.openDatabase(
        path,
        options: CollectionStore.options,
      );
      final store = CollectionStore(database);
      const plain = 'https://example.com/tool';
      const tracked = '$plain?utm_source=share#section';
      final inserts = await Future.wait([
        store.add(plain, _link(plain)),
        store.add(tracked, _link(tracked)),
      ]);
      expect(inserts.map((item) => item.id).toSet(), hasLength(1));
      expect(inserts.where((item) => item.added), hasLength(1));
      await database.close();
      final reopened = await databaseFactoryFfiNoIsolate.openDatabase(
        path,
        options: CollectionStore.options,
      );
      addTearDown(reopened.close);
      final entry = (await CollectionStore(reopened).list()).single;
      expect(entry.original.toString(), plain);
      expect(entry.status, EntryStatus.pending);
      expect(entry.resolved, isNull);
    },
  );

  test(
    'backup restores links, prompts and tags without overwriting duplicates',
    () async {
      final directory = await Directory.systemTemp.createTemp('backup_test');
      addTearDown(() => directory.delete(recursive: true));
      final first = await databaseFactoryFfiNoIsolate.openDatabase(
        '${directory.path}/first.db',
        options: CollectionStore.options,
      );
      final second = await databaseFactoryFfiNoIsolate.openDatabase(
        '${directory.path}/second.db',
        options: CollectionStore.options,
      );
      addTearDown(first.close);
      addTearDown(second.close);
      final source = CollectionStore(first);
      final target = CollectionStore(second);
      const url = 'https://example.com/backup';
      final link = await source.add(url, _link(url));
      await source.update(
        link.id,
        {'summary': '原收藏', 'note': '工具的个人备注', 'pinned_at': 500},
        tags: ['工具', 'AI'],
      );
      final prompt = await source.addPrompt('原始提示词\n第二行');
      await source.update(prompt, {'summary': '提示词简介'}, tags: ['AI']);
      final backup = await source.exportBackup();
      expect(await target.previewBackup(backup), (added: 2, skipped: 0));
      expect(await target.list(), isEmpty);
      final result = await target.importBackup(backup);
      expect(result.added, 2);
      expect(result.skipped, 0);
      expect(
        (await target.list(prompts: true)).single.promptText,
        '原始提示词\n第二行',
      );
      expect((await target.list(tag: '工具')).single.summary, '原收藏');
      final restored = (await target.list(prompts: false)).single;
      expect(restored.pinnedAt, 500);
      expect(restored.note, '工具的个人备注');
      expect((await target.list()).first.id, restored.id);
      expect(
        (await target.list(query: '个人备注', tag: '工具')).single.id,
        restored.id,
      );
      await target.update(restored.id, {'summary': '本机修改'});
      expect(await target.previewBackup(backup), (added: 0, skipped: 2));
      final again = await target.importBackup(backup);
      expect(again.added, 0);
      expect(again.skipped, 2);
      expect((await target.find(restored.id))!.summary, '本机修改');
      final damaged = jsonDecode(backup) as Map<String, dynamic>;
      (damaged['entries'] as List).last['kind'] = 'invalid';
      await expectLater(
        target.importBackup(jsonEncode(damaged)),
        throwsFormatException,
      );
      expect(await target.list(), hasLength(2));

      final legacy = jsonDecode(backup) as Map<String, dynamic>;
      legacy['version'] = 1;
      for (final row in legacy['entries'] as List) {
        (row as Map).remove('note');
        row.remove('pinned_at');
      }
      await second.delete('entry_tags');
      await second.delete('entries');
      final legacyData = jsonEncode(legacy);
      expect(await target.previewBackup(legacyData), (added: 2, skipped: 0));
      expect(await target.importBackup(legacyData), (added: 2, skipped: 0));
      expect((await target.list(prompts: false)).single.pinnedAt, isNull);
      expect((await target.list(prompts: false)).single.note, isEmpty);
    },
  );

  group('end-to-end collection pipeline', () {
    late Database db;
    late CollectionStore store;
    late SettingsStore settingsStore;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      settingsStore = const SettingsStore(FlutterSecureStorage());
      db = await databaseFactoryFfiNoIsolate.openDatabase(
        inMemoryDatabasePath,
        options: CollectionStore.options,
      );
      store = CollectionStore(db);
    });
    tearDown(() => db.close());

    Future<CollectionController> controller(
      MockClient client,
      ServiceSettings settings,
    ) async {
      final result = CollectionController(
        store,
        settingsStore,
        LinkServices(client),
      );
      addTearDown(result.dispose);
      await settingsStore.save(settings);
      await result.initialize();
      return result;
    }

    test('batch saves all items and continues past one source failure', () async {
      var modelCalls = 0;
      final vm = await controller(
        MockClient((request) async {
          if (request.url.host == 'model.example') {
            modelCalls++;
            return _model();
          }
          if (request.url.host == 'api.tavily.com') {
            return _json({'results': []});
          }
          if (request.url.path == '/missing') return http.Response('', 404);
          return _html(
            '<title>工具资料</title><meta name="description" content="$_longDescription$_longDescription">',
          );
        }),
        _settings,
      );
      final links = [
        for (var i = 0; i < 29; i++) Uri.parse('https://site.example/tool-$i'),
        Uri.parse('https://site.example/missing'),
      ];
      final saved = await vm.addLinks([links.last, ...links.take(29)]);
      expect(await store.list(needsOrganization: true), hasLength(30));
      expect((await vm.addLinks([links.first])).single.added, isFalse);
      await vm.runBatch(saved.map((entry) => entry.id));
      expect(modelCalls, 29);
      expect(vm.batch, (
        total: 30,
        ready: 29,
        failed: 1,
        skipped: 0,
        remaining: 0,
        running: false,
        pause: null,
      ));
      expect(
        (await store.list(needsOrganization: true)).single.id,
        saved.first.id,
      );
      expect(vm.latestOrganizedTool, isNull);
    });

    test('offline or model authentication pauses a batch and saved items can retry', () async {
      var offline = true;
      var modelAuthorized = false;
      final vm = await controller(
        MockClient((request) async {
          if (offline) throw http.ClientException('offline');
          if (request.url.host == 'model.example') {
            return modelAuthorized ? _model() : http.Response('', 401);
          }
          return _html(
            '<title>工具资料</title><meta name="description" content="$_longDescription$_longDescription">',
          );
        }),
        _settings,
      );
      final saved = await vm.addLinks([
        Uri.parse('https://site.example/batch-1'),
        Uri.parse('https://site.example/batch-2'),
      ]);
      final ids = saved.map((item) => item.id);
      await vm.runBatch(ids);
      expect(vm.batch?.pause, contains('检查网络'));
      expect(vm.batch?.remaining, 1);
      expect((await store.find(saved.last.id))!.status, EntryStatus.pending);

      offline = false;
      await vm.runBatch(ids);
      expect(vm.batch?.pause, contains('认证失败'));
      expect(vm.batch?.remaining, 1);
      expect((await store.find(saved.first.id))!.description, isNotEmpty);

      modelAuthorized = true;
      final pending = await store.list(needsOrganization: true);
      await vm.runBatch(pending.map((entry) => entry.id));
      expect(vm.batch?.ready, 2);
      expect(await store.list(needsOrganization: true), isEmpty);
    });

    test(
      'Markdown exports tool links and keeps notes and prompt text opt-in',
      () async {
        final tool = await store.add(
          'https://site.example/tool',
          _link('https://site.example/tool'),
        );
        await store.update(tool.id, {'summary': '工具简介'}, tags: ['工具']);
        final prompt = await store.addPrompt('私有提示词正文\n{{主题}}');
        await store.update(prompt, {'note': '私有备注'});
        final entries = await store.list();
        final shared = collectionMarkdown(entries);
        expect(shared, contains('https://site.example/tool'));
        expect(shared, contains('标签：工具'));
        expect(shared, isNot(contains('私有')));
        final full = collectionMarkdown(entries, notes: true, promptText: true);
        expect(full, contains('    私有提示词正文\n    {{主题}}'));
        expect(full, contains('个人备注：私有备注'));
      },
    );

    test(
      'video import retries blank JSON and persists the selected source link',
      () async {
        var modelCalls = 0;
        final vm = await controller(
          MockClient((request) async {
            if (request.url.host == 'www.bilibili.com') {
              expect(request.headers['user-agent'], contains('Mobile'));
              return _html('''
            <meta property="og:title" content="工具介绍">
            <meta property="og:description" content="$_longDescription 官网：https://tool.example/ 下载：https://tool.example/download">
          ''');
            }
            expect(request.url.host, 'api.deepseek.com');
            final requestData = jsonDecode(utf8.decode(request.bodyBytes));
            expect(requestData['thinking']['type'], 'disabled');
            expect(request.body, contains('https://tool.example/download'));
            modelCalls++;
            return _json({
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {
                    'content': modelCalls == 1
                        ? '  '
                        : '''```json
          {"summary":"工具简介","features":[],"category":"开发","tags":["工具"],"link_index":1,"url":"https://fake.example/"}
          ```''',
                  },
                },
              ],
            });
          }),
          const ServiceSettings(
            base: 'https://api.deepseek.com',
            model: 'deepseek-flash',
            modelKey: 'test',
            consent: true,
          ),
        );
        final entry = await vm.add('https://www.bilibili.com/video/BV123456/');
        await vm.run(entry.id);
        final saved = (await store.find(entry.id))!;
        expect(modelCalls, 2);
        expect(saved.status, EntryStatus.ready);
        expect(saved.category, CollectionCategory.development);
        expect(saved.toolLink?.url.toString(), 'https://tool.example/download');
        expect(
          saved.links.map((link) => link.url.host),
          everyElement('tool.example'),
        );
      },
    );

    test(
      'Mwmbl is used without a key and excludes unrelated results',
      () async {
        final service = LinkServices(
          MockClient((request) async {
            expect(request.url.host, 'api.mwmbl.org');
            expect(request.url.queryParameters['q'], '公开工具');
            expect(request.headers['authorization'], isNull);
            return _json({
              'results': [
                {
                  'title': '其他工具',
                  'url': 'https://other.example/',
                  'content': '无关结果',
                },
                {
                  'title': '公开工具评测',
                  'url': 'https://review.example/',
                  'content': '公开工具支持检索',
                },
              ],
            });
          }),
        );
        final url = Uri.parse('https://site.example/tool?secret=abc');
        final result = await service.search(
          LinkIdentity(url),
          LinkEvidence(url: url, kind: SourceKind.web, title: '公开工具'),
          '',
        );
        expect(result.single.text, '公开工具支持检索');
      },
    );

    test('DeepSeek search takes precedence and parses its summaries', () async {
      final service = LinkServices(
        MockClient((request) async {
          expect(
            request.url.toString(),
            'https://api.deepseek.com/v1/tools/search',
          );
          expect(request.headers['authorization'], 'Bearer model-key');
          expect(jsonDecode(request.body)['count'], 3);
          return _json({
            'results': [
              {
                'title': '公开工具评测',
                'url': 'https://review.example/',
                'summary': '工具资料',
                'content': '',
              },
            ],
          });
        }),
      );
      final url = Uri.parse('https://site.example/tool');
      final result = await service.search(
        LinkIdentity(url),
        LinkEvidence(url: url, kind: SourceKind.web, title: '公开工具'),
        'tavily-key',
        settings: const ServiceSettings(
          base: 'https://api.deepseek.com/v1',
          modelKey: 'model-key',
        ),
      );
      expect(result.single.text, '工具资料');
    });

    test(
      'DeepSeek authentication errors do not fall back to another provider',
      () async {
        final contacted = <String>[];
        final service = LinkServices(
          MockClient((request) async {
            contacted.add(request.url.host);
            return http.Response('', 401);
          }),
        );
        final url = Uri.parse('https://site.example/tool');
        await expectLater(
          service.search(
            LinkIdentity(url),
            LinkEvidence(url: url, kind: SourceKind.web, title: '公开工具'),
            '',
            settings: const ServiceSettings(
              base: 'https://api.deepseek.com',
              modelKey: 'invalid',
            ),
          ),
          throwsA(isA<ServiceProblem>()),
        );
        expect(contacted, ['api.deepseek.com']);
      },
    );

    test('fetches and deduplicates provider models', () async {
      final service = LinkServices(
        MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.toString(), 'https://api.deepseek.com/models');
          expect(request.headers['authorization'], 'Bearer model-key');
          return _json({
            'data': [
              {'id': 'deepseek-flash'},
              {'id': 'deepseek-v4-pro'},
              {'id': 'deepseek-flash'},
            ],
          });
        }),
      );
      expect(
        await service.listModels(
          const ServiceSettings(
            base: 'https://api.deepseek.com',
            modelKey: 'model-key',
          ),
        ),
        ['deepseek-flash', 'deepseek-v4-pro'],
      );
    });

    test(
      'prompt text is preserved, organized, editable and searchable',
      () async {
        final vm = await controller(
          MockClient((request) async {
            expect(request.url.host, 'model.example');
            expect(utf8.decode(request.bodyBytes), contains('第一行'));
            return _model();
          }),
          _settings,
        );
        const original = '第一行\n  第二行\n';
        final id = await vm.addPrompt(original);
        expect((await store.find(id))!.promptText, original);
        await vm.run(id);
        final entry = (await store.find(id))!;
        expect(entry.status, EntryStatus.ready);
        expect(entry.tags, contains('检索'));
        expect((await store.list(prompts: true, query: '第二行')).single.id, id);
        expect(await store.list(prompts: false), isEmpty);
        await vm.completeManually(
          entry,
          title: '自定义提示词',
          summary: '摘要',
          category: CollectionCategory.writing,
          promptText: '编辑后\n  原文',
          features: ['手动功能'],
          tags: ['一', '二', '三', '四', '五', '六', '七'],
        );
        final updated = (await store.find(id))!;
        expect(updated.promptText, '编辑后\n  原文');
        expect(updated.features, ['手动功能']);
        expect(updated.tags, hasLength(7));
        expect(await store.tags(prompts: true), hasLength(7));
        expect(await store.tags(prompts: false), isEmpty);
        expect((await store.list(prompts: true, tag: '七')).single.id, id);
      },
    );

    test('unfinished filter, link search and removal work together', () async {
      final vm = await controller(
        MockClient((_) async => throw StateError('unexpected network request')),
        const ServiceSettings(),
      );
      final pending = await vm.add('https://site.example/original-path');
      final failed = await vm.add('https://site.example/failed');
      final complete = await vm.add('https://site.example/complete');
      await store.update(
        failed.id,
        {
          'status': EntryStatus.attention.name,
          'resolved_url': 'https://mirror.example/redirected-path',
        },
        tags: ['资料'],
      );
      await store.update(
        complete.id,
        {'status': EntryStatus.ready.name},
        tags: ['资料'],
      );

      vm.showUnfinished(true);
      await vm.refresh();
      expect(
        vm.entries.map((entry) => entry.id),
        unorderedEquals([pending.id, failed.id]),
      );
      expect(
        (await store.list(
          query: 'REDIRECTED-PATH',
          needsOrganization: true,
          tag: '资料',
        )).single.id,
        failed.id,
      );
      expect((await store.list(query: 'original-path')).single.id, pending.id);

      expect(await vm.remove(failed.id), isTrue);
      expect(await store.find(failed.id), isNull);
      expect((await store.list(tag: '资料')).single.id, complete.id);
      expect(vm.entries.single.id, pending.id);
      vm.clearFilters();
      await vm.refresh();
      expect(vm.filtered, isFalse);
      expect(vm.entries, hasLength(2));
    });

    test(
      'switching tabs clears stale entries and filters before loading',
      () async {
        final vm = await controller(
          MockClient(
            (_) async => throw StateError('unexpected network request'),
          ),
          const ServiceSettings(),
        );
        final link = await vm.add('https://site.example/tool');
        await store.update(link.id, {}, tags: ['工具']);
        final prompt = await vm.addPrompt('写一段介绍');
        vm.selectTag('工具');
        await vm.refresh();
        expect(vm.entries.single.id, link.id);

        vm.selectPage(true);
        expect(vm.entries, isEmpty);
        expect(vm.tags, isEmpty);
        expect(vm.filtered, isFalse);
        await vm.refresh();
        expect(vm.entries.single.id, prompt);
      },
    );

    test(
      'unreachable homepage uses matching first-party download evidence',
      () async {
        final vm = await controller(
          MockClient((request) async {
            if (request.url.host == 'writer.example') {
              throw http.ClientException('connection failed');
            }
            if (request.url.host == 'model.example') return _model();
            expect(request.url.host, 'api.tavily.com');
            return _json({
              'results': [
                {
                  'title': 'Writer Review',
                  'url': 'https://writer.example.review.example/download',
                  'content': '无关下载',
                },
                {
                  'title': 'Writer 下载',
                  'url': 'https://writer.example/download',
                  'content': '提供适用多个平台的安装程序。',
                },
              ],
            });
          }),
          _settings,
        );
        final result = await vm.add('https://writer.example/');
        await vm.run(result.id);
        final entry = (await store.find(result.id))!;
        expect(entry.status, EntryStatus.ready);
        expect(
          entry.toolLink?.url.toString(),
          'https://writer.example/download',
        );
        expect(entry.sources.single.url.host, 'writer.example');
      },
    );

    test(
      'incomplete link triggers search and rejects unrelated excerpts',
      () async {
        var searchCalls = 0;
        var modelCalls = 0;
        final client = MockClient((request) async {
          if (request.url.host == 'api.tavily.com') {
            searchCalls++;
            expect(request.headers['authorization'], 'Bearer test-search-key');
            final input = jsonDecode(request.body) as Map<String, Object?>;
            expect(input['query'], '公开工具');
            expect(input['max_results'], 3);
            return _json({
              'results': [
                {
                  'title': '其他工具',
                  'url': 'https://other.example/unrelated',
                  'content': '无关结果',
                },
                {
                  'title': '公开工具评测',
                  'url': 'https://review.example/article',
                  'content': '公开工具支持检索功能',
                },
              ],
            });
          }
          if (request.url.host == 'model.example') {
            modelCalls++;
            expect(request.url.path, '/v1/chat/completions');
            expect(request.headers['authorization'], 'Bearer test-model-key');
            expect(utf8.decode(request.bodyBytes), contains('公开工具支持检索功能'));
            expect(utf8.decode(request.bodyBytes), isNot(contains('无关结果')));
            return _model();
          }
          expect(request.headers['authorization'], isNull);
          return _html(
            '<title>公开工具</title><meta name="description" content="短介绍">',
          );
        });
        final vm = await controller(client, _settings);
        final saved = await vm.add(
          'https://site.example/tool?private=abc#test',
        );
        await Future.wait([vm.run(saved.id), vm.run(saved.id)]);
        final entry = (await store.find(saved.id))!;
        expect(entry.status, EntryStatus.ready);
        expect(entry.sources.map((source) => source.url.host), [
          'site.example',
          'review.example',
        ]);
        expect(entry.links, isEmpty);
        expect(searchCalls, 1);
        expect(modelCalls, 1);
        expect(
          await store.list(
            query: '整理资料',
            tag: '检索',
            category: CollectionCategory.writing,
          ),
          hasLength(1),
        );
        expect(
          await store.list(
            query: '检索',
            tag: 'AI',
            category: CollectionCategory.writing,
          ),
          hasLength(1),
        );
        expect(
          await store.list(
            query: '检索',
            tag: 'AI',
            category: CollectionCategory.design,
          ),
          isEmpty,
        );
        expect(await store.tags(), hasLength(2));
      },
    );

    test('offline save remains readable and retry reaches ready', () async {
      var offline = true;
      final vm = await controller(
        MockClient((request) async {
          if (offline) throw http.ClientException('offline');
          if (request.url.host == 'model.example') return _model();
          return _html(
            '<title>可重试</title><meta name="description" content="$_longDescription$_longDescription">',
          );
        }),
        const ServiceSettings(
          base: 'https://model.example/v1',
          model: 'test-model',
          modelKey: 'test-model-key',
          consent: true,
        ),
      );
      final saved = await vm.add('https://site.example/offline');
      await vm.run(saved.id);
      expect((await store.find(saved.id))!.status, EntryStatus.attention);
      expect((await store.find(saved.id))!.reason, contains('检查网络'));
      expect(vm.latestOrganizedTool, isNull);
      offline = false;
      await vm.run(saved.id);
      final entry = (await store.find(saved.id))!;
      expect(entry.status, EntryStatus.ready);
      expect(vm.latestOrganizedTool?.id, saved.id);
      expect(mascotReview(entry), contains('关键词搜索'));
      expect((await store.list()).single.id, saved.id);
    });

    test('invalid model output preserves extracted data and allows manual completion', () async {
      final vm = await controller(
        MockClient((request) async {
          if (request.url.host == 'model.example') {
            return _json({
              'choices': [
                {
                  'message': {'content': '{invalid'},
                },
              ],
            });
          }
          return _html(
            '<title>保留标题</title><meta name="description" content="$_longDescription$_longDescription">',
          );
        }),
        _settings,
      );
      final saved = await vm.add('https://site.example/model-failure');
      await vm.run(saved.id);
      final failed = (await store.find(saved.id))!;
      expect(failed.status, EntryStatus.attention);
      expect(failed.title, '保留标题');
      expect(failed.description, isNotEmpty);
      expect(failed.reason, contains('未返回可用'));
      await vm.completeManually(
        failed,
        title: '我的资料',
        summary: '手动整理',
        category: CollectionCategory.other,
        tags: ['资料'],
      );
      expect((await store.find(saved.id))!.sources.last.label, '手动录入');
      expect(
        (await store.list(
          query: '手动',
          category: CollectionCategory.other,
          tag: '资料',
        )).single.title,
        '我的资料',
      );
    });

    test('search error still permits model processing with a short source description', () async {
      final vm = await controller(
        MockClient((request) async {
          if (request.url.host == 'api.tavily.com') {
            return http.Response('', 429);
          }
          if (request.url.host == 'model.example') return _model();
          return _html(
            '<title>简短描述</title><meta name="description" content="工具简介">',
          );
        }),
        _settings,
      );
      final saved = await vm.add('https://site.example/partial');
      await vm.run(saved.id);
      expect((await store.find(saved.id))!.status, EntryStatus.ready);
    });

    test('credentials are not forwarded to a redirected API endpoint', () async {
      final contacted = <String>[];
      final vm = await controller(
        MockClient((request) async {
          contacted.add(request.url.host);
          if (request.url.host == 'model.example') {
            return http.Response(
              '',
              307,
              headers: {'location': 'https://elsewhere.example/'},
            );
          }
          return _html(
            '<title>服务跳转</title><meta name="description" content="$_longDescription$_longDescription">',
          );
        }),
        _settings,
      );
      final saved = await vm.add('https://site.example/redirect');
      await vm.run(saved.id);
      expect(contacted, ['site.example', 'model.example']);
      expect((await store.find(saved.id))!.status, EntryStatus.attention);
    });
  });
}

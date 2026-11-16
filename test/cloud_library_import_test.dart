import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/article_service.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/backend/ws_server.dart';
import 'package:storm_teleprompter_plus/frontend/ws_client.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/cloud_library_snapshot.dart';
import 'package:storm_teleprompter_plus/services/app_preferences.dart';
import 'package:storm_teleprompter_plus/services/system/app_data_directory.dart';
import 'package:storm_teleprompter_plus/utils/constants.dart';

const libraryId = '09d1e0f2-d4c0-49c9-b3f8-b35837f5b997';
const otherLibraryId = '19d1e0f2-d4c0-49c9-b3f8-b35837f5b997';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late ArticleService service;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('storm-cloud-library-');
    appDataDirectoryOverride = temp;
    service = ArticleService();
    await service.init();
  });
  tearDownAll(() async {
    appDataDirectoryOverride = null;
    if (await temp.exists()) await temp.delete(recursive: true);
  });
  setUp(() async {
    await service.replaceArticles([]);
    await service.replaceFolders([]);
  });

  test('协议注册云稿库导入，重复同步幂等且无时间抖动', () async {
    final snapshot = _snapshot([_script('S-001', '第一句\n第二句')]);
    final first = await service.importCloudLibrary(snapshot);
    expect(first.toJson(), {
      'created': 1,
      'updated': 0,
      'unchanged': 0,
      'total': 1,
    });
    final saved = (await service.loadArticles()).single;
    expect(saved.id, 'cloud:$libraryId:S-001');
    expect(saved.title, 'S-001');
    expect(saved.content, '<p>第一句</p>\n<p>第二句</p>');
    expect(saved.folderId, isNull);
    final before = jsonEncode(saved.toJson());
    final second = await service.importCloudLibrary(snapshot);
    expect(second.toJson(), {
      'created': 0,
      'updated': 0,
      'unchanged': 1,
      'total': 1,
    });
    expect(jsonEncode((await service.loadArticles()).single.toJson()), before);
    expect(
      WsMessageType.fromString('article:cloud_import'),
      WsMessageType.articleCloudImport,
    );
    expect(
      WsMessageType.fromString('article:cloud_import_response'),
      WsMessageType.articleCloudImportResponse,
    );
  });

  test('相同标题的本地稿件不会被云编号覆盖，云稿库之间也不碰撞', () async {
    final local = await service.createArticle(
      title: 'S-001',
      content: '<p>本地自写</p>',
    );
    await service.importCloudLibrary(_snapshot([_script('S-001', '云端一')]));
    await service.importCloudLibrary(
      _snapshot([_script('S-001', '云端二')], id: otherLibraryId),
    );
    final articles = await service.loadArticles();
    expect(articles, hasLength(3));
    expect(
      articles.singleWhere((article) => article.id == local.id).content,
      '<p>本地自写</p>',
    );
    expect(
      articles
          .singleWhere((article) => article.id == 'cloud:$libraryId:S-001')
          .content,
      '<p>云端一</p>',
    );
    expect(
      articles
          .singleWhere((article) => article.id == 'cloud:$otherLibraryId:S-001')
          .content,
      '<p>云端二</p>',
    );
  });

  test('同编号更新正文并保留本机文件夹、创建时间、排序和提词设置', () async {
    final prefs = await AppPreferences.getInstance();
    await prefs.setString(StorageConstants.settingsKey, '{"fontSize":91}');
    final folder = await service.createFolder(name: '我的拍摄目录');
    final createdAt = DateTime.utc(2020, 1, 2);
    final original = Article(
      id: 'cloud:$libraryId:S-001',
      title: 'S-001',
      content: '<p>旧稿</p>',
      createdAt: createdAt,
      updatedAt: createdAt,
      sortOrder: 19,
      folderId: folder.id,
      teleprompterSettings: {'fontSize': 82, 'mirrorMode': true},
    );
    await service.replaceArticles([original]);
    final result = await service.importCloudLibrary(
      _snapshot([_script('S-001', '更新正文')]),
    );
    expect(result.updated, 1);
    final updated = (await service.loadArticles()).single;
    expect(updated.content, '<p>更新正文</p>');
    expect(updated.createdAt, createdAt);
    expect(updated.updatedAt, DateTime.utc(2026, 11, 16, 2));
    expect(updated.sortOrder, 19);
    expect(updated.folderId, folder.id);
    expect(updated.teleprompterSettings, original.teleprompterSettings);
    expect((await service.loadFolders()).single.id, folder.id);
    expect(prefs.getString(StorageConstants.settingsKey), '{"fontSize":91}');
  });

  test('快照未包含的云稿和本地稿保留，本机改过的云正文以云版本恢复', () async {
    await service.importCloudLibrary(
      _snapshot([_script('S-001', '稿一'), _script('S-002', '稿二')]),
    );
    final local = await service.createArticle(title: '本地', content: '自写');
    await service.updateArticle(
      'cloud:$libraryId:S-001',
      content: '<p>本机改写</p>',
    );
    final result = await service.importCloudLibrary(
      _snapshot([_script('S-001', '稿一')]),
    );
    expect(result.toJson(), {
      'created': 0,
      'updated': 1,
      'unchanged': 0,
      'total': 1,
    });
    final articles = await service.loadArticles();
    expect(articles, hasLength(3));
    expect(
      articles.singleWhere((a) => a.id == 'cloud:$libraryId:S-001').content,
      '<p>稿一</p>',
    );
    expect(articles.any((a) => a.id == 'cloud:$libraryId:S-002'), isTrue);
    expect(articles.any((a) => a.id == local.id), isTrue);
  });

  test('无效后项不会造成前项部分写入', () async {
    await service.createArticle(title: '原有本地稿', content: '保持不变');
    final before = jsonEncode(
      (await service.loadArticles()).map((a) => a.toJson()).toList(),
    );
    final invalid = _script('S-002', '第二项')
      ..['updatedAt'] = '2026-02-30T00:00:00Z';
    await expectLater(
      service.importCloudLibrary(
        _snapshot([_script('S-001', '本应新增'), invalid]),
      ),
      throwsFormatException,
    );
    expect(
      jsonEncode(
        (await service.loadArticles()).map((a) => a.toJson()).toList(),
      ),
      before,
    );
  });

  test('只从纯文本正文生成安全HTML，不信远端content', () async {
    final script = _script('S-001', '一行 <script>&\r\n下一行 >')
      ..['content'] =
          '<script>危险内容</script><a href="https://example.test">链接</a>';
    await service.importCloudLibrary(_snapshot([script]));
    expect(
      (await service.loadArticles()).single.content,
      '<p>一行 &lt;script&gt;&amp;</p>\n<p>下一行 &gt;</p>',
    );
  });

  test('本地库已损坏时拒绝同步，不把空列表写回覆盖原始数据', () async {
    final prefs = await AppPreferences.getInstance();
    await prefs.setString(StorageConstants.articlesKey, 'damaged-local-data');
    await expectLater(
      service.importCloudLibrary(_snapshot([_script('S-001', '新正文')])),
      throwsFormatException,
    );
    expect(prefs.getString(StorageConstants.articlesKey), 'damaged-local-data');
  });

  test('完整结构、编号、版本、UTC日历时间和长度都在导入前验证', () {
    final cases = <Map<String, dynamic>>[
      _snapshot([])..['format'] = 'other',
      _snapshot([])..['version'] = 99,
      _snapshot([])..['libraryId'] = 'not-a-uuid',
      _snapshot([])..['revision'] = double.nan,
      _snapshot([_script('S-001', '正文'), _script('S-001', '重复')]),
      _snapshot([_script('../S-001', '正文')]),
      _snapshot([_script('S-001', '正文')..['title'] = '其他标题']),
      _snapshot([_script('S-001', '')]),
      _snapshot([_script('S-001', '正文')..['body'] = 10]),
      _snapshot([_script('S-001', '正文')..['content'] = null]),
      _snapshot([
        _script('S-001', '正文')..['createdAt'] = '2026-13-01T00:00:00Z',
      ]),
      _snapshot([
        _script('S-001', '正文')..['createdAt'] = '2026-11-16T00:00:00',
      ]),
      _snapshot([
        _script('S-001', '正文')..['updatedAt'] = '2026-11-15T00:00:00Z',
      ]),
      _snapshot([_script('S-001', '正文')..['revision'] = 0]),
      _snapshot([_script('S-001', '正文')..['revision'] = 2]),
      _snapshot([_script('S-001', 'x' * 50001)]),
      _snapshot([_script('S-001', '正文')..['content'] = 'x' * 400001]),
      _snapshot(List.generate(1001, (i) => _script('S-$i', '正文'))),
    ];
    for (var index = 0; index < cases.length; index++) {
      expect(
        () => CloudLibrarySnapshot.fromJson(cases[index]),
        throwsFormatException,
        reason: 'case $index',
      );
    }
    final valid = CloudLibrarySnapshot.fromJson(
      _snapshot([_script('S-001', 'x' * 50000)]),
    );
    expect(valid.scripts.single.body.length, 50000);
    expect(CloudLibrarySnapshot.fromJson(valid.toJson()).libraryId, libraryId);
  });

  test('稿库总正文和总HTML超过限制时拒绝', () {
    expect(
      () => CloudLibrarySnapshot.fromJson(
        _snapshot(List.generate(161, (i) => _script('S-$i', 'x' * 50000))),
      ),
      throwsFormatException,
    );
    expect(
      () => CloudLibrarySnapshot.fromJson(
        _snapshot(
          List.generate(
            61,
            (i) => _script('S-$i', '正文')..['content'] = 'x' * 400000,
          ),
        ),
      ),
      throwsFormatException,
    );
    // The server content field can be short while plain-text newlines expand
    // into many local paragraphs. Budget the actual locally generated HTML.
    expect(
      () => CloudLibrarySnapshot.fromJson(
        _snapshot(
          List.generate(
            61,
            (i) => _script('S-$i', '\n' * 49999 + 'x')..['content'] = '',
          ),
        ),
      ),
      throwsFormatException,
    );
  });

  test('WebSocket导入返回计数，坏快照返回错误并保持本地库', () async {
    final server = WsServer();
    service.registerHandlers(server);
    final port = await server.start();
    final client = WsClient();
    addTearDown(() async {
      await client.disconnect();
      client.dispose();
      await server.stop();
      server.dispose();
    });
    await client.connect(port: port);
    final response = await client.request(
      WsMessageType.articleCloudImport,
      data: _snapshot([_script('S-001', '正文')]),
    );
    expect(response.type, WsMessageType.articleCloudImportResponse);
    expect(response.data, {
      'created': 1,
      'updated': 0,
      'unchanged': 0,
      'total': 1,
    });
    final invalid = await client.request(
      WsMessageType.articleCloudImport,
      data: _snapshot([_script('bad/id', '坏编号')]),
    );
    expect(invalid.type, WsMessageType.error);
    expect((await service.loadArticles()).single.title, 'S-001');
  });
}

Map<String, dynamic> _snapshot(
  List<Map<String, dynamic>> scripts, {
  String id = libraryId,
}) => {
  'format': 'storm-cloud-library',
  'version': 1,
  'libraryId': id,
  'revision': 1,
  'scripts': scripts,
};

Map<String, dynamic> _script(String id, String body) => {
  'scriptId': id,
  'title': id,
  'body': body,
  'content': '<p>服务器生成的内容</p>',
  'createdAt': '2026-11-16T00:00:00Z',
  'updatedAt': '2026-11-16T02:00:00Z',
  'revision': 1,
};

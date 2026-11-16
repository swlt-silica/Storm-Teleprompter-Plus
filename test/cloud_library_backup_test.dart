import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/article_service.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/backend/ws_server.dart';
import 'package:storm_teleprompter_plus/frontend/ws_client.dart';
import 'package:storm_teleprompter_plus/models/cloud_library_backup.dart';
import 'package:storm_teleprompter_plus/services/app_preferences.dart';
import 'package:storm_teleprompter_plus/services/system/app_data_directory.dart';
import 'package:storm_teleprompter_plus/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ArticleService service;
  late AppPreferences prefs;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('storm-full-cloud-');
    appDataDirectoryOverride = directory;
    prefs = await AppPreferences.getInstance();
    service = ArticleService();
    await service.init();
  });
  tearDownAll(() async {
    appDataDirectoryOverride = null;
    await directory.delete(recursive: true);
  });
  setUp(() async {
    await service.replaceArticles([]);
    await service.replaceFolders([]);
  });

  test('完整往返保留任意中文标题、旧云ID、富文本和文件夹，并排除本机设置', () async {
    await service.restoreCloudBackup(_backup());
    await service.updateArticle(
      'cloud:library:S-001',
      teleprompterSettings: {'fontSize': 91},
    );
    await prefs.setString(StorageConstants.settingsKey, '{"mirrorMode":true}');
    await prefs.setString('cloud_connection', 'test-device-token');
    final json = (await service.exportCloudBackup()).toJson();
    final serialized = jsonEncode(json);
    expect(serialized, isNot(contains('teleprompterSettings')));
    expect(serialized, isNot(contains('mirrorMode')));
    expect(serialized, isNot(contains('test-device-token')));
    final model = CloudLibraryBackup.fromJson(json);
    expect(model.articles.single.id, 'cloud:library:S-001');
    expect(model.articles.single.title, '任意中文标题：第 01 集 🎬');
    expect(
      model.articles.single.content,
      '<p><strong>富文本</strong> &amp; 第二行</p>',
    );
    expect(model.articles.single.folderId, 'child');
    expect(model.folders.last.parentId, 'parent');
    expect(model.articles.single.teleprompterSettings, isNull);
  });

  test('恢复替换所有稿件及文件夹，保留相同ID本机提词设置和连接配置', () async {
    await service.restoreCloudBackup(_backup());
    await service.updateArticle(
      'cloud:library:S-001',
      teleprompterSettings: {'fontSize': 82},
    );
    await service.createArticle(title: '仅本机', content: '将被替换');
    await service.createFolder(name: '仅本机文件夹');
    await prefs.setString(StorageConstants.settingsKey, 'local-settings');
    await prefs.setString('cloud_connection', 'local-credentials');
    final backup = _backup();
    (backup['articles'] as List).add(_article('new-id')..['title'] = '新稿');
    expect(await service.restoreCloudBackup(backup), {
      'success': true,
      'articles': 2,
      'folders': 2,
    });
    final articles = await service.loadArticles();
    expect(articles, hasLength(2));
    expect(
      articles
          .singleWhere((a) => a.id == 'cloud:library:S-001')
          .teleprompterSettings,
      {'fontSize': 82},
    );
    expect(
      articles.singleWhere((a) => a.id == 'new-id').teleprompterSettings,
      isNull,
    );
    expect(await service.loadFolders(), hasLength(2));
    expect(prefs.getString(StorageConstants.settingsKey), 'local-settings');
    expect(prefs.getString('cloud_connection'), 'local-credentials');
  });

  test('坏快照不部分写入：重复、孤立引用、循环、日历和字段注入均拒绝', () async {
    await service.restoreCloudBackup(_backup());
    final beforeArticles = prefs.getString(StorageConstants.articlesKey);
    final beforeFolders = prefs.getString(StorageConstants.foldersKey);
    final cases = <Map<String, dynamic>>[
      _backup()..['settings'] = {'fontSize': 91},
      _backup()..['version'] = 99,
      _backup()..['version'] = 1.0,
      _backup()..['articles'] = [_article(' \t\n')],
      _backup()
        ..['folders'] = [
          _folder('parent', null)..['name'] = ' \t\n',
          _folder('child', 'parent'),
        ],
      _backup()..['createdAt'] = '2026-02-30T00:00:00Z',
      _backup()..['articles'] = [_article('dup'), _article('dup')],
      _backup()..['articles'] = [_article('x')..['folderId'] = 'missing'],
      _backup()
        ..['articles'] = [
          _article('x')..['teleprompterSettings'] = {'fontSize': 1},
        ],
      _backup()
        ..['articles'] = [
          _article('x')..['updatedAt'] = '2020-01-01T00:00:00Z',
        ],
      _backup()..['articles'] = [_article('x')..['sortOrder'] = 1.5],
      _backup()..['articles'] = [_article('x')..['content'] = 'x' * 400001],
      _backup()..['articles'] = List.generate(1001, (i) => _article('$i')),
      _backup()
        ..['folders'] = [_folder('parent', 'missing'), _folder('child', null)],
      _backup()
        ..['folders'] = [
          _folder('parent', 'child'),
          _folder('child', 'parent'),
        ],
      _backup()
        ..['folders'] = [_folder('parent', null), _folder('parent', null)],
      _backup()
        ..['folders'] = [
          _folder('parent', null)..['name'] = '',
          _folder('child', null),
        ],
    ];
    for (var i = 0; i < cases.length; i++) {
      await expectLater(
        service.restoreCloudBackup(cases[i]),
        throwsFormatException,
        reason: 'case $i',
      );
      expect(prefs.getString(StorageConstants.articlesKey), beforeArticles);
      expect(prefs.getString(StorageConstants.foldersKey), beforeFolders);
    }
  });

  test('总正文和UTF8备份体积限制均验证', () {
    final aggregate = _backup()
      ..['articles'] = List.generate(
        61,
        (i) => _article('$i')..['content'] = 'x' * 400000,
      );
    expect(() => CloudLibraryBackup.fromJson(aggregate), throwsFormatException);
    final utf8Overflow = _backup()
      ..['articles'] = List.generate(
        30,
        (i) => _article('$i')..['content'] = '中' * 400000,
      );
    expect(
      () => CloudLibraryBackup.fromJson(utf8Overflow),
      throwsFormatException,
    );
    final maximum = _backup()
      ..['articles'] = [_article('x' * 256)..['sortOrder'] = 9007199254740991];
    expect(CloudLibraryBackup.fromJson(maximum).articles.single.id.length, 256);
  });

  test('真实磁盘写失败时两个库都保持原样且队列恢复', () async {
    await service.restoreCloudBackup(_backup());
    final file = File(
      '${directory.path}/${StorageConstants.desktopPreferencesFileName}',
    );
    final beforeDisk = await file.readAsString();
    final beforeArticles = prefs.getString(StorageConstants.articlesKey);
    final beforeFolders = prefs.getString(StorageConstants.foldersKey);
    final blocked = Directory('${file.path}.tmp');
    await blocked.create();
    try {
      await expectLater(
        service.restoreCloudBackup(
          _backup()..['articles'] = [_article('replacement')],
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), beforeDisk);
      expect(prefs.getString(StorageConstants.articlesKey), beforeArticles);
      expect(prefs.getString(StorageConstants.foldersKey), beforeFolders);
    } finally {
      await blocked.delete();
    }
    await service.restoreCloudBackup(_backup()..['articles'] = []);
    expect(await service.loadArticles(), isEmpty);
  });

  test('根目录稿件恢复后可用空备份同时清空稿件和文件夹', () async {
    final rootBackup = _backup()..['folders'] = [];
    (rootBackup['articles'] as List).single.remove('folderId');
    await service.restoreCloudBackup(rootBackup);
    expect((await service.loadArticles()).single.folderId, isNull);
    expect(await service.loadFolders(), isEmpty);
    expect(
      await service.restoreCloudBackup({
        'format': 'storm-cloud-backup',
        'version': 1,
        'createdAt': '2026-11-16T00:00:00Z',
        'articles': [],
        'folders': [],
      }),
      {'success': true, 'articles': 0, 'folders': 0},
    );
    final exported = await service.exportCloudBackup();
    expect(exported.articles, isEmpty);
    expect(exported.folders, isEmpty);
  });

  test('全量恢复与本机编辑按调用顺序串行，不死锁或覆盖后续编辑', () async {
    await Future.wait([
      service.restoreCloudBackup(_backup()),
      service.updateArticle('cloud:library:S-001', content: '恢复后编辑'),
      service.createArticle(title: '恢复后新稿', content: '正文'),
    ]).timeout(const Duration(seconds: 5));
    final articles = await service.loadArticles();
    expect(articles, hasLength(2));
    expect(
      articles.singleWhere((a) => a.id == 'cloud:library:S-001').content,
      '恢复后编辑',
    );
  });

  test('WebSocket完整导出和恢复响应及坏快照错误', () async {
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
    final restored = await client.request(
      WsMessageType.articleCloudRestore,
      data: _backup(),
    );
    expect(restored.type, WsMessageType.articleCloudRestoreResponse);
    expect(restored.data, {'success': true, 'articles': 1, 'folders': 2});
    final exported = await client.request(WsMessageType.articleCloudExport);
    expect(exported.type, WsMessageType.articleCloudExportResponse);
    expect(
      CloudLibraryBackup.fromJson(exported.data).articles.single.title,
      '任意中文标题：第 01 集 🎬',
    );
    final bad = await client.request(
      WsMessageType.articleCloudRestore,
      data: _backup()..['articles'] = [_article('a')..['folderId'] = 'orphan'],
    );
    expect(bad.type, WsMessageType.error);
    expect(await service.loadArticles(), hasLength(1));
  });
}

Map<String, dynamic> _backup() => {
  'format': 'storm-cloud-backup',
  'version': 1,
  'createdAt': '2026-11-16T00:00:00Z',
  'articles': [_article('cloud:library:S-001')],
  'folders': [_folder('parent', null), _folder('child', 'parent')],
};
Map<String, dynamic> _article(String id) => {
  'id': id,
  'title': '任意中文标题：第 01 集 🎬',
  'content': '<p><strong>富文本</strong> &amp; 第二行</p>',
  'createdAt': '2026-11-16T00:00:00Z',
  'updatedAt': '2026-11-16T02:00:00.123456Z',
  'sortOrder': 19,
  'folderId': 'child',
};
Map<String, dynamic> _folder(String id, String? parent) => {
  'id': id,
  'name': '目录 $id',
  'parentId': parent,
  'createdAt': '2026-11-16T00:00:00Z',
  'sortOrder': 1,
};

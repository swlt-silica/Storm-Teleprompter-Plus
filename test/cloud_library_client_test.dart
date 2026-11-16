import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/cloud_library_backup.dart';
import 'package:storm_teleprompter_plus/models/folder.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/teleprompter_provider.dart';
import 'package:storm_teleprompter_plus/services/app_preferences.dart';
import 'package:storm_teleprompter_plus/services/cloud_library_service.dart';
import 'package:storm_teleprompter_plus/services/system/app_data_directory.dart';
import 'package:storm_teleprompter_plus/widgets/settings/cloud_library_settings_section.dart';

const _credentials = CloudLibraryCredentials(
  baseUrl: 'https://example.com/teleprompter/',
  readToken: 'test-download-token',
);

Map<String, dynamic> _snapshot() => {
  'format': 'storm-cloud-library',
  'version': 1,
  'libraryId': '11111111-2222-4333-8444-555555555555',
  'revision': 1,
  'scripts': [
    {
      'scriptId': 'TC-001',
      'title': 'TC-001',
      'body': '欢迎大家。',
      'content': '<p>欢迎大家。</p>',
      'createdAt': '2026-11-16T00:00:00Z',
      'updatedAt': '2026-11-16T00:00:00Z',
      'revision': 1,
    },
  ],
};

Map<String, dynamic> _backup() => {
  'format': 'storm-cloud-backup',
  'version': 1,
  'createdAt': '2026-11-16T00:00:00Z',
  'articles': [
    {
      'id': 'local-001',
      'title': '完整稿件',
      'content': '<p>欢迎大家。</p>',
      'createdAt': '2026-11-16T00:00:00Z',
      'updatedAt': '2026-11-16T00:00:00Z',
      'sortOrder': 0,
      'folderId': 'folder-001',
    },
  ],
  'folders': [
    {
      'id': 'folder-001',
      'name': '第一组',
      'parentId': null,
      'createdAt': '2026-11-16T00:00:00Z',
      'sortOrder': 0,
    },
  ],
};
Map<String, dynamic> _backupEnvelope() => {'revision': 2, 'backup': _backup()};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    appDataDirectoryOverride = await Directory.systemTemp.createTemp(
      'storm-cloud-client-',
    );
    await AppPreferences.getInstance();
  });

  test('HTTPS 地址保留部署路径，拒绝公网 HTTP 和 URL 内凭据', () {
    for (final input in [
      'http://example.com',
      'https://user:pass@example.com',
      'https://example.com/?token=x',
      'https://example.com/#secret',
      'file:///tmp/library',
    ]) {
      expect(
        () => CloudLibraryClient.normalizeBaseUrl(input),
        throwsA(isA<CloudLibraryException>()),
      );
    }
    expect(
      CloudLibraryClient.normalizeBaseUrl('http://127.0.0.1:18431/').toString(),
      'http://127.0.0.1:18431',
    );
    expect(
      CloudLibraryClient.normalizeBaseUrl(_credentials.baseUrl).path,
      '/teleprompter',
    );
  });

  test('令牌放 Authorization，访问部署路径下的 API，不跟随重定向', () async {
    final client = CloudLibraryClient(
      client: MockClient((request) async {
        expect(
          request.url.toString(),
          'https://example.com/teleprompter/api/v1/library',
        );
        expect(request.headers['Authorization'], 'Bearer test-download-token');
        expect(request.followRedirects, isFalse);
        return http.Response(
          jsonEncode(_snapshot()),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    addTearDown(client.close);
    expect(
      (await client.download(_credentials)).scripts.single.scriptId,
      'TC-001',
    );
  });

  test('认证拒绝与跳转不暴露响应正文或令牌', () async {
    for (final status in [401, 403, 302]) {
      final client = CloudLibraryClient(
        client: MockClient(
          (_) async =>
              http.Response('secret-server-body test-download-token', status),
        ),
      );
      try {
        await client.download(_credentials);
        fail('Expected a rejection');
      } on CloudLibraryException catch (error) {
        expect(error.message, isNot(contains('secret-server-body')));
        expect(error.message, isNot(contains('test-download-token')));
        expect(error.message, status == 302 ? contains('跳转') : contains('令牌'));
      } finally {
        client.close();
      }
    }
  });

  test('无效云端快照不会发出本机导入请求', () async {
    final connection = _Connection();
    final service = CloudLibrarySyncService(
      client: CloudLibraryClient(
        client: MockClient(
          (_) async => http.Response('{"format":"wrong"}', 200),
        ),
      ),
    );
    addTearDown(service.close);
    addTearDown(connection.dispose);
    await expectLater(
      service.downloadToLocal(
        credentials: _credentials,
        connection: connection,
      ),
      throwsA(isA<CloudLibraryException>()),
    );
    expect(connection.imports, 0);
  });

  test('响应声明超过上限时取消读取并拒绝导入', () async {
    final connection = _Connection();
    final client = MockClient.streaming((request, body) async {
      return http.StreamedResponse(
        const Stream<List<int>>.empty(),
        200,
        contentLength: CloudLibraryClient.maxResponseBytes + 1,
      );
    });
    final service = CloudLibrarySyncService(
      client: CloudLibraryClient(client: client),
    );
    addTearDown(service.close);
    addTearDown(connection.dispose);
    await expectLater(
      service.downloadToLocal(
        credentials: _credentials,
        connection: connection,
      ),
      throwsA(
        isA<CloudLibraryException>().having(
          (error) => error.message,
          'message',
          contains('过大'),
        ),
      ),
    );
    expect(connection.imports, 0);
  });

  test('非本机或正在提词时不访问云库；返回前连接变化也不会导入', () async {
    final connection = _Connection()..local = false;
    final teleprompter = TeleprompterProvider()..loadScript('local', '本地稿件');
    var calls = 0;
    final service = CloudLibrarySyncService(
      client: CloudLibraryClient(
        client: MockClient((_) async {
          calls++;
          connection.local = false;
          return http.Response(
            jsonEncode(_backupEnvelope()),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    );
    addTearDown(service.close);
    addTearDown(connection.dispose);
    addTearDown(teleprompter.dispose);
    await expectLater(
      service.downloadToLocal(
        credentials: _credentials,
        connection: connection,
      ),
      throwsA(isA<CloudLibraryException>()),
    );
    expect(calls, 0);
    connection.local = true;
    teleprompter.play(const AppSettings());
    await expectLater(
      service.downloadToLocal(
        credentials: _credentials,
        connection: connection,
        teleprompter: teleprompter,
      ),
      throwsA(isA<CloudLibraryException>()),
    );
    expect(calls, 0);
    teleprompter.pause(const AppSettings());
    await expectLater(
      service.downloadToLocal(
        credentials: _credentials,
        connection: connection,
        teleprompter: teleprompter,
      ),
      throwsA(isA<CloudLibraryException>()),
    );
    expect(calls, 1);
    expect(connection.imports, 0);
  });

  test('下载调用本机整库恢复，不切换播放连接且返回准确统计', () async {
    final connection = _Connection();
    final service = CloudLibrarySyncService(
      client: CloudLibraryClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(_backupEnvelope()),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      ),
    );
    addTearDown(service.close);
    addTearDown(connection.dispose);
    final result = await service.downloadToLocal(
      credentials: _credentials,
      connection: connection,
    );
    expect(result.articles, 1);
    expect(result.folders, 1);
    expect(connection.imports, 1);
    expect(connection.local, isTrue);
  });

  test('整库下载优先读令牌，没有读令牌时使用上传令牌', () async {
    for (final hasRead in [true, false]) {
      final client = CloudLibraryClient(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/teleprompter/api/v1/backup');
          expect(
            request.headers['Authorization'],
            hasRead ? 'Bearer read-only' : 'Bearer upload-only',
          );
          expect(request.followRedirects, isFalse);
          return http.Response(
            jsonEncode(_backupEnvelope()),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final result = await client.downloadBackup(
        CloudLibraryCredentials(
          baseUrl: _credentials.baseUrl,
          readToken: hasRead ? 'read-only' : '',
          uploadToken: 'upload-only',
        ),
      );
      expect(result.articles.single.id, 'local-001');
      expect(result.folders.single.name, '第一组');
      client.close();
    }
  });

  test('云端没有整库备份时给出首次上传提示，不恢复本机', () async {
    final connection = _Connection();
    final service = CloudLibrarySyncService(
      client: CloudLibraryClient(
        client: MockClient(
          (_) async => http.Response('private-error-body', 404),
        ),
      ),
    );
    addTearDown(service.close);
    addTearDown(connection.dispose);
    await expectLater(
      service.downloadToLocal(
        credentials: _credentials,
        connection: connection,
      ),
      throwsA(
        isA<CloudLibraryException>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('先在有稿件的设备上传整库'),
            isNot(contains('private-error-body')),
          ),
        ),
      ),
    );
    expect(connection.imports, 0);
  });

  test('上传使用PUT和上传令牌，保留稿件与文件夹且剔除设备设置', () async {
    final data = _backup();
    final localArticle = Article.fromJson(
      Map<String, dynamic>.from((data['articles'] as List).single as Map),
    ).copyWith(teleprompterSettings: {'fontSize': 120});
    // Local export may hold per-device settings, but its whitelist serialization
    // removes them before crossing the strict backup wire boundary.
    final backup = CloudLibraryBackup(
      createdAt: DateTime.parse(data['createdAt'] as String),
      articles: [localArticle],
      folders: [
        Folder.fromJson(
          Map<String, dynamic>.from((data['folders'] as List).single as Map),
        ),
      ],
    );
    expect(localArticle.teleprompterSettings, {'fontSize': 120});
    final client = CloudLibraryClient(
      client: MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/teleprompter/api/v1/backup');
        expect(request.headers['Authorization'], 'Bearer upload-only');
        expect(request.followRedirects, isFalse);
        final sent = jsonDecode(request.body) as Map<String, dynamic>;
        expect(sent['format'], 'storm-cloud-backup');
        expect(
          (sent['articles'] as List).single['teleprompterSettings'],
          isNull,
        );
        expect((sent['folders'] as List).single['id'], 'folder-001');
        return http.Response(
          '{"success":true,"articles":1,"folders":1,"revision":3}',
          200,
        );
      }),
    );
    addTearDown(client.close);
    final result = await client.uploadBackup(
      const CloudLibraryCredentials(
        baseUrl: 'https://example.com/teleprompter',
        readToken: 'read-only',
        uploadToken: 'upload-only',
      ),
      backup,
    );
    expect(result.articles, 1);
    expect(result.folders, 1);
    expect(result.revision, 3);
  });

  test('没有上传令牌或上传被拒绝时不报告成功', () async {
    var calls = 0;
    final client = CloudLibraryClient(
      client: MockClient((request) async {
        calls++;
        return http.Response('secret-body', 403);
      }),
    );
    addTearDown(client.close);
    final backup = CloudLibraryBackup.fromJson(_backup());
    await expectLater(
      client.uploadBackup(_credentials, backup),
      throwsA(isA<CloudLibraryException>()),
    );
    expect(calls, 0);
    await expectLater(
      client.uploadBackup(
        const CloudLibraryCredentials(
          baseUrl: 'https://example.com',
          uploadToken: 'upload-only',
        ),
        backup,
      ),
      throwsA(isA<CloudLibraryException>()),
    );
    expect(calls, 1);
  });

  test('上传先从本机导出完整库再提交，保持本地库和连接模式', () async {
    final connection = _Connection();
    var calls = 0;
    final service = CloudLibrarySyncService(
      client: CloudLibraryClient(
        client: MockClient((request) async {
          calls++;
          expect(request.method, 'PUT');
          return http.Response(
            '{"success":true,"articles":1,"folders":1,"revision":3}',
            200,
          );
        }),
      ),
    );
    addTearDown(service.close);
    addTearDown(connection.dispose);
    final result = await service.uploadFromLocal(
      credentials: const CloudLibraryCredentials(
        baseUrl: 'https://example.com',
        uploadToken: 'upload-only',
      ),
      connection: connection,
    );
    expect(result.articles, 1);
    expect(result.folders, 1);
    expect(calls, 1);
    expect(connection.imports, 0);
    expect(connection.isLocal, isTrue);
  });

  test('连接凭据可单独保存和读取，不进入应用设置备份', () async {
    final store = CloudLibraryCredentialStore();
    await store.save(_credentials);
    final value = await store.load();
    expect(value.baseUrl, 'https://example.com/teleprompter');
    expect(value.readToken, _credentials.readToken);
    await store.save(
      const CloudLibraryCredentials(
        baseUrl: 'https://example.com',
        uploadToken: 'upload-only',
      ),
    );
    expect((await store.load()).uploadToken, 'upload-only');
    expect(
      jsonEncode(const AppSettings().toJson()),
      isNot(contains('test-download-token')),
    );
  });

  for (final width in [390.0, 850.0]) {
    testWidgets('云库设置 $width 宽度不溢出、令牌默认隐藏、远程模式禁用下载', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final connection = _Connection()..local = false;
      addTearDown(connection.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<ConnectionProvider>.value(
          value: connection,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CloudLibrarySettingsSection(store: _Store()),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('cloud-library-token')))
            .obscureText,
        isTrue,
      );
      expect(
        tester
            .widgetList<FilledButton>(find.byType(FilledButton))
            .every((button) => button.onPressed == null),
        isTrue,
      );
      expect(find.textContaining('切回本机服务端'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _Connection extends ConnectionProvider {
  bool local = true;
  int imports = 0;
  @override
  bool get isLocal => local;
  @override
  bool get isConnected => true;
  @override
  Future<WsMessage> request(
    WsMessageType type, {
    Map<String, dynamic> data = const {},
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (type == WsMessageType.articleCloudExport) {
      return WsMessage(
        type: WsMessageType.articleCloudExportResponse,
        data: _backup(),
      );
    }
    expect(type, WsMessageType.articleCloudRestore);
    expect(data['format'], 'storm-cloud-backup');
    imports++;
    return const WsMessage(
      type: WsMessageType.articleCloudRestoreResponse,
      data: {'success': true, 'articles': 1, 'folders': 1},
    );
  }
}

class _Store extends CloudLibraryCredentialStore {
  @override
  Future<CloudLibraryCredentials> load() async => _credentials;
  @override
  Future<void> save(CloudLibraryCredentials value) async {}
}

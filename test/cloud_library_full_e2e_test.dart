import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/article_service.dart';
import 'package:storm_teleprompter_plus/backend/ws_server.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/services/app_preferences.dart';
import 'package:storm_teleprompter_plus/services/cloud_library_service.dart';
import 'package:storm_teleprompter_plus/services/system/app_data_directory.dart';
import 'package:storm_teleprompter_plus/utils/constants.dart';

// Only disposable local directories and fixture credentials are used. This
// exercises the real Python API, Dart HTTP client, provider, WebSocket and disk.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This integration suite intentionally talks to its isolated loopback API.
  HttpOverrides.global = null;

  test(
    '真实服务端双向整库覆盖：A上传、B替换恢复并编辑上传、再次恢复只有新版',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'storm-full-e2e-',
      );
      appDataDirectoryOverride = Directory('${directory.path}/device');
      Process? python;
      StreamSubscription<String>? output;
      StreamSubscription<String>? errors;
      final server = WsServer();
      final connection = ConnectionProvider();
      final sync = CloudLibrarySyncService();
      addTearDown(() async {
        sync.close();
        await connection.client.disconnect();
        connection.dispose();
        await server.stop();
        server.dispose();
        final runningPython = python;
        if (runningPython != null) {
          runningPython.kill();
          await runningPython.exitCode.timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              runningPython.kill(ProcessSignal.sigkill);
              return -1;
            },
          );
        }
        await output?.cancel();
        await errors?.cancel();
        appDataDirectoryOverride = null;
        await directory.delete(recursive: true);
      });

      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      const readToken = 'fixture-read-token-for-e2e-tests-000001';
      const uploadToken = 'fixture-upload-token-for-e2e-tests-0002';
      final ready = Completer<void>();
      final serverErrors = <String>[];
      python = await Process.start(
        'python3',
        [
          'server/cloud_library/app.py',
          '--data-dir',
          '${directory.path}/cloud',
          '--port',
          '$port',
        ],
        workingDirectory: Directory.current.path,
        includeParentEnvironment: false,
        environment: {
          'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
          'PYTHONUNBUFFERED': '1',
          'CLOUD_LIBRARY_READ_TOKEN': readToken,
          'CLOUD_LIBRARY_UPLOAD_TOKEN': uploadToken,
        },
      );
      output = python.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.contains('127.0.0.1:$port') && !ready.isCompleted)
              ready.complete();
          });
      errors = python.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(serverErrors.add);
      unawaited(
        python.exitCode.then((code) {
          if (!ready.isCompleted)
            ready.completeError(
              StateError('测试服务端启动失败 ($code): ${serverErrors.join('\n')}'),
            );
        }),
      );
      await ready.future.timeout(const Duration(seconds: 10));
      final credentials = CloudLibraryCredentials(
        baseUrl: 'http://127.0.0.1:$port',
        readToken: readToken,
        uploadToken: uploadToken,
      );
      final articles = ArticleService();
      await articles.init();
      articles.registerHandlers(server);
      final wsPort = await server.start();
      await connection.connectToLocal(wsPort);
      expect(connection.isConnected && connection.isLocal, isTrue);
      final prefs = await AppPreferences.getInstance();
      final credentialStore = CloudLibraryCredentialStore();

      // Device A: two articles, nested folders, original title and rich HTML.
      final parent = await articles.createFolder(name: '设备A拍摄');
      final child = await articles.createFolder(
        name: '第一组',
        parentId: parent.id,
      );
      const originalHtml =
          '<p><strong>第一句</strong> &amp; 保留格式</p><p>第二句 🎬</p>';
      final keep = await articles.createArticle(
        title: '任意中文标题 01',
        content: originalHtml,
        folderId: child.id,
      );
      final remove = await articles.createArticle(
        title: '第二版将删除',
        content: '<p>旧稿</p>',
        folderId: child.id,
      );
      await articles.updateArticle(
        keep.id,
        teleprompterSettings: {'fontSize': 31, 'mirrorMode': true},
      );
      await prefs.setString(StorageConstants.settingsKey, 'device-A-settings');
      await credentialStore.save(credentials);
      final firstUpload = await sync.uploadFromLocal(
        credentials: credentials,
        connection: connection,
      );
      expect(firstUpload.articles, 2);
      expect(firstUpload.folders, 2);
      final cloudA = await sync.client.downloadBackup(credentials);
      expect(
        cloudA.articles.singleWhere((a) => a.id == keep.id).content,
        originalHtml,
      );
      final cloudJson = jsonEncode(cloudA.toJson());
      for (final excluded in [
        'teleprompterSettings',
        'mirrorMode',
        'device-A-settings',
        readToken,
        uploadToken,
      ]) {
        expect(cloudJson, isNot(contains(excluded)));
      }

      // Model a different device's local library while preserving a same-ID
      // device-specific display preference. The cloud must replace local extras.
      final now = DateTime.now().toUtc();
      await articles.replaceArticles([
        Article(
          id: keep.id,
          title: 'B旧稿',
          content: '<p>B本机改写</p>',
          createdAt: now,
          updatedAt: now,
          teleprompterSettings: {'fontSize': 88},
        ),
        Article(
          id: 'device-B-only',
          title: 'B额外稿',
          content: '<p>仅本机</p>',
          createdAt: now,
          updatedAt: now,
        ),
      ]);
      await articles.replaceFolders([]);
      await articles.createFolder(name: 'B额外目录');
      await prefs.setString(StorageConstants.settingsKey, 'device-B-settings');
      const deviceBToken = 'fixture-device-B-only-token';
      await credentialStore.save(
        CloudLibraryCredentials(
          baseUrl: credentials.baseUrl,
          readToken: deviceBToken,
        ),
      );
      final restored = await sync.downloadToLocal(
        credentials: credentials,
        connection: connection,
      );
      expect(restored.articles, 2);
      expect(restored.folders, 2);
      final onB = await articles.loadArticles();
      expect(onB.map((a) => a.id), unorderedEquals([keep.id, remove.id]));
      expect(onB.singleWhere((a) => a.id == keep.id).content, originalHtml);
      expect(onB.singleWhere((a) => a.id == keep.id).teleprompterSettings, {
        'fontSize': 88,
      });
      expect(
        onB.singleWhere((a) => a.id == remove.id).teleprompterSettings,
        isNull,
      );
      expect(
        (await articles.loadFolders()).map((f) => f.id),
        unorderedEquals([parent.id, child.id]),
      );
      expect(
        (await articles.loadFolders())
            .singleWhere((f) => f.id == child.id)
            .parentId,
        parent.id,
      );
      expect(
        prefs.getString(StorageConstants.settingsKey),
        'device-B-settings',
      );
      expect((await credentialStore.load()).readToken, deviceBToken);
      expect(connection.isLocal, isTrue);

      // B changes the library and replaces the cloud's single backup.
      await articles.deleteArticle(remove.id);
      await articles.updateArticle(keep.id, content: '<p><em>B新版正文</em></p>');
      final newArticle = await articles.createArticle(
        title: 'B新增脚本',
        content: '<p>新增正文</p>',
      );
      final secondUpload = await sync.uploadFromLocal(
        credentials: credentials,
        connection: connection,
      );
      expect(secondUpload.articles, 2);
      expect(secondUpload.revision, greaterThan(firstUpload.revision!));
      final cloudB = await sync.client.downloadBackup(credentials);
      expect(
        cloudB.articles.map((a) => a.id),
        unorderedEquals([keep.id, newArticle.id]),
      );
      expect(cloudB.articles.any((a) => a.id == remove.id), isFalse);

      // A stale device restoring again gets exactly the new cloud contents.
      await articles.replaceArticles([
        Article(
          id: remove.id,
          title: '过期旧稿',
          content: '旧正文',
          createdAt: now,
          updatedAt: now,
        ),
      ]);
      await articles.replaceFolders([]);
      await sync.downloadToLocal(
        credentials: credentials,
        connection: connection,
      );
      final third = await articles.loadArticles();
      expect(third.map((a) => a.id), unorderedEquals([keep.id, newArticle.id]));
      expect(
        third.singleWhere((a) => a.id == keep.id).content,
        '<p><em>B新版正文</em></p>',
      );
      expect(
        prefs.getString(StorageConstants.settingsKey),
        'device-B-settings',
      );
      expect((await credentialStore.load()).readToken, deviceBToken);
      expect(connection.isLocal && connection.isConnected, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}

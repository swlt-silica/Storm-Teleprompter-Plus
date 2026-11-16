import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:storm_teleprompter_plus/providers/article_provider.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/folder_provider.dart';
import 'package:storm_teleprompter_plus/providers/teleprompter_provider.dart';
import 'package:storm_teleprompter_plus/services/cloud_library_service.dart';
import 'package:storm_teleprompter_plus/widgets/settings/cloud_library_settings_section.dart';

const _credentials = CloudLibraryCredentials(
  baseUrl: 'https://example.com/teleprompter',
  readToken: 'read-only-test-token',
  uploadToken: 'upload-test-token',
);

void main() {
  Future<void> showSettings(
    WidgetTester tester, {
    required _Connection connection,
    required _Store store,
    required _Service service,
    _Articles? articles,
    _Folders? folders,
    bool syncAllowed = true,
  }) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ConnectionProvider>.value(value: connection),
          if (articles != null)
            ChangeNotifierProvider<ArticleProvider>.value(value: articles),
          if (folders != null)
            ChangeNotifierProvider<FolderProvider>.value(value: folders),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CloudLibrarySettingsSection(
                store: store,
                syncService: service,
                syncAllowed: syncAllowed,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapAction(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('上传或恢复取消确认时不保存配置、不访问服务', (tester) async {
    final connection = _Connection();
    final store = _Store();
    final service = _Service();
    addTearDown(connection.dispose);
    addTearDown(service.close);
    await showSettings(
      tester,
      connection: connection,
      store: store,
      service: service,
    );

    await tapAction(tester, 'cloud-library-upload');
    expect(find.text('覆盖云端唯一备份？'), findsOneWidget);
    expect(find.textContaining('即使本机没有稿件和文件夹'), findsOneWidget);
    expect(store.saves, 0);
    expect(service.uploads, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tapAction(tester, 'cloud-library-restore');
    expect(find.text('整库恢复到本机？'), findsOneWidget);
    expect(find.textContaining('云端没有的本机稿件和文件夹会被删除'), findsOneWidget);
    expect(find.textContaining('连接令牌等设备设置保留'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.saves, 0);
    expect(service.uploads, 0);
    expect(service.restores, 0);
  });

  testWidgets('上传确认后锁定操作，完成前不显示成功', (tester) async {
    final connection = _Connection();
    final store = _Store();
    final service = _Service()
      ..pendingUpload = Completer<CloudLibraryTransferResult>();
    addTearDown(connection.dispose);
    addTearDown(service.close);
    await showSettings(
      tester,
      connection: connection,
      store: store,
      service: service,
    );

    await tapAction(tester, 'cloud-library-upload');
    await tester.tap(find.byKey(const Key('cloud-library-confirm-overwrite')));
    await tester.pump();
    await tester.pump();
    expect(service.uploads, 1);
    expect(service.lastCredentials?.uploadToken, 'upload-test-token');
    expect(store.saves, 1);
    expect(find.text('正在上传…'), findsOneWidget);
    expect(find.textContaining('上传完成：'), findsNothing);
    for (final key in ['cloud-library-upload', 'cloud-library-restore']) {
      expect(
        tester.widget<FilledButton>(find.byKey(Key(key))).onPressed,
        isNull,
      );
    }
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('cloud-library-save')))
          .onPressed,
      isNull,
    );
    for (final key in [
      'cloud-library-url',
      'cloud-library-token',
      'cloud-library-upload-token',
    ]) {
      expect(tester.widget<TextField>(find.byKey(Key(key))).enabled, isFalse);
    }

    service.pendingUpload!.complete(
      const CloudLibraryTransferResult(articles: 3, folders: 2, revision: 7),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('上传完成：3 篇稿件、2 个文件夹'), findsOneWidget);
    expect(service.restores, 0);
  });

  testWidgets('整库恢复确认成功后刷新两份列表并回到根目录', (tester) async {
    final connection = _Connection();
    final store = _Store();
    final service = _Service();
    final articles = _Articles();
    final folders = _Folders()..setCurrentFolder('deleted-local-folder');
    addTearDown(connection.dispose);
    addTearDown(service.close);
    addTearDown(articles.dispose);
    addTearDown(folders.dispose);
    await showSettings(
      tester,
      connection: connection,
      store: store,
      service: service,
      articles: articles,
      folders: folders,
    );

    await tapAction(tester, 'cloud-library-restore');
    expect(folders.currentFolderId, 'deleted-local-folder');
    await tester.tap(find.byKey(const Key('cloud-library-confirm-overwrite')));
    await tester.pumpAndSettle();
    expect(service.restores, 1);
    expect(service.uploads, 0);
    expect(folders.currentFolderId, isNull);
    expect(folders.loads, 1);
    expect(articles.loads, 1);
    expect(find.textContaining('整库恢复完成：2 篇稿件、1 个文件夹'), findsOneWidget);
    expect(find.textContaining('本机设备设置已保留'), findsOneWidget);
  });

  testWidgets('上传失败不显示完成，操作恢复可用', (tester) async {
    final connection = _Connection();
    final store = _Store();
    final service = _Service()
      ..uploadError = const CloudLibraryException('上传失败，云端原备份未替换');
    addTearDown(connection.dispose);
    addTearDown(service.close);
    await showSettings(
      tester,
      connection: connection,
      store: store,
      service: service,
    );
    await tapAction(tester, 'cloud-library-upload');
    await tester.tap(find.byKey(const Key('cloud-library-confirm-overwrite')));
    await tester.pumpAndSettle();
    expect(find.text('上传失败，云端原备份未替换'), findsOneWidget);
    expect(find.textContaining('上传完成：'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cloud-library-upload')))
          .onPressed,
      isNotNull,
    );
  });

  for (final width in [390.0, 850.0]) {
    testWidgets('云备份设置 $width 宽无溢出，双令牌隐藏，远程模式禁用传输', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final connection = _Connection()..local = false;
      final service = _Service();
      addTearDown(connection.dispose);
      addTearDown(service.close);
      await showSettings(
        tester,
        connection: connection,
        store: _Store(),
        service: service,
      );
      for (final key in ['cloud-library-token', 'cloud-library-upload-token']) {
        expect(
          tester.widget<TextField>(find.byKey(Key(key))).obscureText,
          isTrue,
        );
      }
      for (final key in ['cloud-library-upload', 'cloud-library-restore']) {
        expect(
          tester.widget<FilledButton>(find.byKey(Key(key))).onPressed,
          isNull,
        );
      }
      expect(find.textContaining('切回本机服务端'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('仅下载令牌的设备可以恢复但不能上传', (tester) async {
    final connection = _Connection();
    final service = _Service();
    addTearDown(connection.dispose);
    addTearDown(service.close);
    await showSettings(
      tester,
      connection: connection,
      store: _Store(
        const CloudLibraryCredentials(
          baseUrl: 'https://example.com/teleprompter',
          readToken: 'read-only-test-token',
        ),
      ),
      service: service,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cloud-library-upload')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cloud-library-restore')))
          .onPressed,
      isNotNull,
    );
    expect(service.uploads, 0);
    expect(service.restores, 0);
  });

  testWidgets('提词页禁止上传和整库恢复', (tester) async {
    final connection = _Connection();
    final service = _Service();
    addTearDown(connection.dispose);
    addTearDown(service.close);
    await showSettings(
      tester,
      connection: connection,
      store: _Store(),
      service: service,
      syncAllowed: false,
    );
    for (final key in ['cloud-library-upload', 'cloud-library-restore']) {
      expect(
        tester.widget<FilledButton>(find.byKey(Key(key))).onPressed,
        isNull,
      );
    }
    expect(find.textContaining('先退出提词页面'), findsOneWidget);
  });
}

class _Connection extends ConnectionProvider {
  bool local = true;
  @override
  bool get isLocal => local;
  @override
  bool get isConnected => true;
}

class _Store extends CloudLibraryCredentialStore {
  _Store([this.value = _credentials]);
  final CloudLibraryCredentials value;
  int saves = 0;
  @override
  Future<CloudLibraryCredentials> load() async => value;
  @override
  Future<void> save(CloudLibraryCredentials value) async {
    saves++;
  }
}

class _Service extends CloudLibrarySyncService {
  int uploads = 0;
  int restores = 0;
  Completer<CloudLibraryTransferResult>? pendingUpload;
  CloudLibraryException? uploadError;
  CloudLibraryCredentials? lastCredentials;

  @override
  Future<CloudLibraryTransferResult> uploadFromLocal({
    required CloudLibraryCredentials credentials,
    required ConnectionProvider connection,
    TeleprompterProvider? teleprompter,
    bool allowedFromPage = true,
  }) async {
    uploads++;
    lastCredentials = credentials;
    if (uploadError != null) throw uploadError!;
    return pendingUpload?.future ??
        const CloudLibraryTransferResult(articles: 2, folders: 1, revision: 3);
  }

  @override
  Future<CloudLibraryTransferResult> downloadToLocal({
    required CloudLibraryCredentials credentials,
    required ConnectionProvider connection,
    TeleprompterProvider? teleprompter,
    bool allowedFromPage = true,
  }) async {
    restores++;
    return const CloudLibraryTransferResult(
      articles: 2,
      folders: 1,
      revision: 3,
    );
  }
}

class _Articles extends ArticleProvider {
  int loads = 0;
  @override
  Future<void> loadArticles() async {
    loads++;
  }
}

class _Folders extends FolderProvider {
  int loads = 0;
  @override
  Future<void> loadFolders() async {
    loads++;
  }
}

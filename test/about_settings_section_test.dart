import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/pages/about_page.dart';
import 'package:storm_teleprompter_plus/services/app_release_service.dart';
import 'package:storm_teleprompter_plus/services/app_update_installer.dart';
import 'package:storm_teleprompter_plus/pages/log_viewer_page.dart';
import 'package:storm_teleprompter_plus/widgets/settings/about_settings_section.dart';

void main() {
  test('local development version resolves to the Git commit hash', () async {
    final version = await AppVersionInfo.load();

    expect(version.value, matches(RegExp(r'^[0-9a-f]{8}$')));
  });

  testWidgets('about page exposes project, updates, license, and logs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AboutSettingsSection(
              versionLoader: () async => const AppVersionInfo('1234abcd'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('关于飓风提词器 Plus'), findsOneWidget);
    await tester.tap(find.text('关于飓风提词器 Plus'));
    await tester.pumpAndSettle();

    expect(find.text('飓风提词器 Plus'), findsOneWidget);
    expect(find.text('Storm Teleprompter+'), findsOneWidget);
    expect(find.text('访问 GitHub 项目主页'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('License'), findsOneWidget);
    expect(find.textContaining('版本 1234abcd'), findsNWidgets(2));

    await tester.tap(find.text('License'));
    await tester.pumpAndSettle();

    expect(find.text('MIT License'), findsWidgets);
    expect(find.textContaining('Copyright (c) 2026 Html5syt'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    for (var index = 0; index < 10; index++) {
      await tester.tap(find.byType(Image));
    }
    await tester.pumpAndSettle();
    expect(find.byType(LogViewerPage), findsOneWidget);
  });

  testWidgets('Android about update downloads and starts installation', (
    tester,
  ) async {
    var downloaded = false;
    var installed = false;
    final installer = _FakeUpdateInstaller(
      onDownload: (_, {onProgress}) async {
        downloaded = true;
        onProgress?.call(1, 1);
        final file = File('${Directory.systemTemp.path}/fake-about-update.apk');
        file.writeAsBytesSync([1]);
        return file;
      },
      onInstall: (_) async => installed = true,
    );
    final releaseService = _FakeReleaseService(_releaseWithApk);
    addTearDown(installer.dispose);
    addTearDown(releaseService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AboutPage(
          versionLoader: () async => const AppVersionInfo('v1.0.0'),
          releaseService: releaseService,
          updateInstaller: installer,
          isAndroid: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('立即更新'), findsOneWidget);

    await tester.tap(find.text('立即更新'));
    await tester.pumpAndSettle();

    expect(downloaded, isTrue);
    expect(tester.takeException(), isNull);
    expect(installed, isTrue);
  });

  testWidgets('Android about update without an APK opens the Release page', (
    tester,
  ) async {
    var opened = false;
    final releaseService = _FakeReleaseService(_releaseWithoutApk);
    addTearDown(releaseService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AboutPage(
          versionLoader: () async => const AppVersionInfo('v1.0.0'),
          releaseService: releaseService,
          isAndroid: true,
          releaseLauncher: (_) async => opened = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('前往更新'), findsOneWidget);

    await tester.tap(find.text('前往更新'));
    await tester.pumpAndSettle();

    expect(opened, isTrue);
  });

  testWidgets('Android about update failure shows an error and opens Release', (
    tester,
  ) async {
    var opened = false;
    final installer = _FakeUpdateInstaller(
      onDownload: (_, {onProgress}) async {
        throw StateError('download failed');
      },
    );
    final releaseService = _FakeReleaseService(_releaseWithApk);
    addTearDown(installer.dispose);
    addTearDown(releaseService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AboutPage(
          versionLoader: () async => const AppVersionInfo('v1.0.0'),
          releaseService: releaseService,
          updateInstaller: installer,
          isAndroid: true,
          releaseLauncher: (_) async => opened = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('立即更新'));
    await tester.pumpAndSettle();

    expect(find.textContaining('更新失败：'), findsOneWidget);
    expect(opened, isTrue);
  });
}

const _releaseWithApk = UpdateCheckResult(
  currentVersion: 'v1.0.0',
  latestRelease: GitHubReleaseInfo(
    tagName: 'v2.0.0',
    name: 'Version 2.0.0',
    pageUrl: '$githubRepositoryUrl/releases/tag/v2.0.0',
    notes: '更新内容',
    assets: [
      GitHubReleaseAsset(
        name: 'storm-teleprompter-2.0.0-arm64.apk',
        downloadUrl: 'https://example.test/update.apk',
        size: 1,
        digest: null,
      ),
    ],
  ),
  hasUpdate: true,
  canCompare: true,
);

const _releaseWithoutApk = UpdateCheckResult(
  currentVersion: 'v1.0.0',
  latestRelease: GitHubReleaseInfo(
    tagName: 'v2.0.0',
    name: 'Version 2.0.0',
    pageUrl: '$githubRepositoryUrl/releases/tag/v2.0.0',
    notes: '更新内容',
  ),
  hasUpdate: true,
  canCompare: true,
);

class _FakeReleaseService extends AppReleaseService {
  _FakeReleaseService(this.result);

  final UpdateCheckResult result;

  @override
  Future<UpdateCheckResult> checkForUpdates(String currentVersion) async {
    return result;
  }
}

class _FakeUpdateInstaller extends AppUpdateInstaller {
  _FakeUpdateInstaller({this.onInstall, this.onDownload});

  final Future<void> Function(String path)? onInstall;
  final Future<File> Function(
    GitHubReleaseAsset asset, {
    void Function(int received, int total)? onProgress,
  })?
  onDownload;

  @override
  Future<File> download(
    GitHubReleaseAsset asset, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (onDownload != null) {
      return onDownload!(asset, onProgress: onProgress);
    }
    onProgress?.call(1, 1);
    final file = File('${Directory.systemTemp.path}/fake-about-update.apk');
    file.writeAsBytesSync([1]);
    return file;
  }

  @override
  Future<void> install(File apk) async {
    await onInstall?.call(apk.path);
  }
}

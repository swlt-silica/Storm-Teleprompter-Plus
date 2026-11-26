import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:storm_teleprompter_plus/services/app_release_service.dart';
import 'package:storm_teleprompter_plus/services/app_update_installer.dart';

void main() {
  test('downloads an APK, reports progress, and verifies its digest', () async {
    final bytes = utf8.encode('apk bytes');
    final directory = await Directory.systemTemp.createTemp('update-test-');
    addTearDown(() => directory.delete(recursive: true));
    final digest = sha256.convert(bytes).toString();
    final progress = <(int, int)>[];
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://example.test/update.apk');
      return http.Response.bytes(bytes, 200);
    });
    final installer = AppUpdateInstaller(
      client: client,
      cacheDirectoryLoader: () async => directory,
    );
    addTearDown(installer.dispose);

    final file = await installer.download(
      const GitHubReleaseAsset(
        name: 'storm-teleprompter-2.2.0-arm64.apk',
        downloadUrl: 'https://example.test/update.apk',
        size: 9,
        digest: 'sha256:placeholder',
      ).withDigest(digest),
      onProgress: (received, total) => progress.add((received, total)),
    );

    expect(await file.readAsString(), 'apk bytes');
    expect(progress.last, (9, 9));
  });

  test('rejects a digest mismatch and removes the partial APK', () async {
    final directory = await Directory.systemTemp.createTemp('update-test-');
    addTearDown(() => directory.delete(recursive: true));
    final installer = AppUpdateInstaller(
      client: MockClient((_) async => http.Response('wrong bytes', 200)),
      cacheDirectoryLoader: () async => directory,
    );
    addTearDown(installer.dispose);

    await expectLater(
      installer.download(
        const GitHubReleaseAsset(
          name: 'storm-teleprompter-2.2.0-arm64.apk',
          downloadUrl: 'https://example.test/update.apk',
          size: 11,
          digest: 'sha256:000000',
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      File('${directory.path}/storm-teleprompter-2.2.0-arm64.apk').existsSync(),
      isFalse,
    );
    expect(
      File(
        '${directory.path}/storm-teleprompter-2.2.0-arm64.apk.download',
      ).existsSync(),
      isFalse,
    );
  });

  test('delegates installation to the injected platform launcher', () async {
    String? installedPath;
    final installer = AppUpdateInstaller(
      installLauncher: (path) async => installedPath = path,
    );
    addTearDown(installer.dispose);
    final file = File('${Directory.systemTemp.path}/update.apk');

    await installer.install(file);

    expect(installedPath, file.path);
  });
}

extension on GitHubReleaseAsset {
  GitHubReleaseAsset withDigest(String digest) => GitHubReleaseAsset(
    name: name,
    downloadUrl: downloadUrl,
    size: size,
    digest: digest,
  );
}

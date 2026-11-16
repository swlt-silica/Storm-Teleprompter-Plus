import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/services/app_preferences.dart';
import 'package:storm_teleprompter_plus/services/system/app_data_directory.dart';
import 'package:storm_teleprompter_plus/utils/constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppPreferences preferences;
  late File file;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'storm-prefs-transaction-',
    );
    appDataDirectoryOverride = directory;
    preferences = await AppPreferences.getInstance();
    file = File(
      '${directory.path}/${StorageConstants.desktopPreferencesFileName}',
    );
  });
  tearDownAll(() async {
    appDataDirectoryOverride = null;
    await directory.delete(recursive: true);
  });

  test(
    'failed disk write preserves committed memory and disk; queue can recover',
    () async {
      await preferences.setString('articles', 'original');
      final originalDisk = await file.readAsString();
      final blockedTemporaryFile = Directory('${file.path}.tmp');
      await blockedTemporaryFile.create();
      await expectLater(
        preferences.setString('articles', 'uncommitted'),
        throwsA(isA<FileSystemException>()),
      );
      expect(preferences.getString('articles'), 'original');
      expect(await file.readAsString(), originalDisk);
      await blockedTemporaryFile.delete();
      await preferences.setString('articles', 'recovered');
      expect(preferences.getString('articles'), 'recovered');
      expect(jsonDecode(await file.readAsString())['articles'], 'recovered');
    },
  );

  test(
    'batch commit replaces articles and folders together or preserves both',
    () async {
      await preferences.setValues({
        'articles': 'old-articles',
        'folders': 'old-folders',
      });
      final before = await file.readAsString();
      final blocked = Directory('${file.path}.tmp');
      await blocked.create();
      try {
        await expectLater(
          preferences.setValues({
            'articles': 'new-articles',
            'folders': 'new-folders',
          }),
          throwsA(isA<FileSystemException>()),
        );
        expect(preferences.getString('articles'), 'old-articles');
        expect(preferences.getString('folders'), 'old-folders');
        expect(await file.readAsString(), before);
      } finally {
        await blocked.delete();
      }
      await preferences.setValues({
        'articles': 'new-articles',
        'folders': 'new-folders',
      });
      final saved = jsonDecode(await file.readAsString());
      expect(saved['articles'], 'new-articles');
      expect(saved['folders'], 'new-folders');
    },
  );

  test('concurrent device configuration writes preserve both keys', () async {
    await Future.wait([
      preferences.setString('cloud_connection', 'private-test-token'),
      preferences.setString('settings', 'local-device-settings'),
    ]);
    final saved = jsonDecode(await file.readAsString());
    expect(saved['cloud_connection'], 'private-test-token');
    expect(saved['settings'], 'local-device-settings');
    expect(preferences.getString('settings'), 'local-device-settings');
    if (!Platform.isWindows) expect((await file.stat()).mode & 0x1FF, 0x180);
  });
}

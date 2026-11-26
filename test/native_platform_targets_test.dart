import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// 工程及发布入口只声明原生平台，防止后续脚手架更新重新引入 Web 构建。
void main() {
  test('移除 Web 工程、工作流和图标生成目标，保留五个原生平台', () {
    expect(Directory('web').existsSync(), isFalse);
    final metadata = File('.metadata').readAsStringSync();
    expect(metadata, isNot(contains('platform: web')));
    for (final platform in ['android', 'ios', 'windows', 'macos', 'linux']) {
      expect(Directory(platform).existsSync(), isTrue);
      expect(metadata, contains('platform: $platform'));
    }
    for (final workflow in ['debug', 'release']) {
      final content = File(
        '.github/workflows/$workflow.yml',
      ).readAsStringSync();
      expect(content, isNot(contains('flutter build web')));
      expect(content, isNot(contains('name: Web')));
    }
    expect(
      File('flutter_launcher_icons.yaml').readAsStringSync(),
      isNot(contains('  web:')),
    );
    expect(
      File('tool/generate_icons.ps1').readAsStringSync(),
      isNot(contains('iOS, Web,')),
    );
  });

  test('Android update installer exposes a cache-only FileProvider bridge', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/example/storm_teleprompter_plus/MainActivity.kt',
    ).readAsStringSync();
    final filePaths = File('android/app/src/main/res/xml/file_paths.xml');

    expect(manifest, contains('android.permission.REQUEST_INSTALL_PACKAGES'));
    expect(manifest, contains('androidx.core.content.FileProvider'));
    expect(manifest, contains('\${applicationId}.fileprovider'));
    expect(activity, contains('storm.teleprompter/update'));
    expect(activity, contains('installApk'));
    expect(filePaths.existsSync(), isTrue);
    expect(filePaths.readAsStringSync(), contains('<cache-path'));
  });
}

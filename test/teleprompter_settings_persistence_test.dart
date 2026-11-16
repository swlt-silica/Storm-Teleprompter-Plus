import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/models/app_backup.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/models/folder.dart';
import 'package:storm_teleprompter_plus/providers/settings_provider.dart';

void main() {
  const expectedKeys = {
    'fontSize',
    'lineHeight',
    'scrollMode',
    'wpm',
    'autoScrollMode',
    'pixelsPerSecond',
    'mirrorMode',
    'paddingX',
    'readingLineOffset',
    'highlightCurrentChar',
    'defaultBold',
    'progressInfoSizeRatio',
    'teleprompterFontFamily',
    'grayReadChars',
    'textColor',
    'letterSpacing',
    'teleprompterBgColor',
    'underlineCurrentChar',
    'readingAreaBorderWidth',
    'progressShowTime',
    'progressShowPercentage',
    'progressShowSpeed',
    'progressShowCurrentTime',
  };

  test('all shared teleprompter settings survive map round trip', () {
    final source = const AppSettings().copyWith(
      fontSize: 83,
      lineHeight: 2.1,
      scrollMode: ScrollMode.asr,
      wpm: 237,
      mirrorMode: true,
      paddingX: 17,
      readingLineOffset: 0.63,
      highlightCurrentChar: true,
      defaultBold: false,
      progressInfoSizeRatio: 0.75,
      teleprompterFontFamily: 'Test Font',
      grayReadChars: false,
      textColor: 0xFF123456,
      letterSpacing: 3.5,
      teleprompterBgColor: 0xFF654321,
      underlineCurrentChar: true,
      readingAreaBorderWidth: 5.5,
      progressShowTime: false,
      progressShowPercentage: false,
      progressShowSpeed: false,
      progressShowCurrentTime: false,
    );

    final data = source.toTeleprompterMap();
    final restored = const AppSettings().mergeOverrides(data);

    expect(data.keys.toSet(), expectedKeys);
    expect(restored.toTeleprompterMap(), data);
  });

  test('本机切换稿件沿用共用提词设置', () async {
    final provider = SettingsProvider();
    addTearDown(provider.dispose);
    provider.useSharedTeleprompterSettings();
    await provider.setFontSize(72);
    await provider.setLineHeight(2.1);
    await provider.toggleMirrorMode();
    final shared = provider.settings.toTeleprompterMap();

    provider.useSharedTeleprompterSettings();
    expect(provider.mergedSettings.toTeleprompterMap(), shared);
    expect(provider.mergedSettings.fontSize, 72);
    expect(provider.mergedSettings.lineHeight, 2.1);
    expect(provider.mergedSettings.mirrorMode, isTrue);

    provider.applyRemoteTeleprompterSettings({'fontSize': 28});
    expect(provider.mergedSettings.fontSize, 28);
    expect(provider.settings.fontSize, 72);
    provider.clearRemoteTeleprompterSettings();
    expect(provider.mergedSettings.toTeleprompterMap(), shared);
  });

  test('article JSON export and import retain teleprompter settings', () {
    final now = DateTime(2026, 7, 12);
    final settings = const AppSettings()
        .copyWith(fontSize: 72, paddingX: 12, mirrorMode: true)
        .toTeleprompterMap();
    final article = Article(
      id: 'article-1',
      title: 'Test',
      content: '<p>Content</p>',
      createdAt: now,
      updatedAt: now,
      teleprompterSettings: settings,
    );

    final restored = Article.fromJson(article.toJson());

    expect(restored.teleprompterSettings, settings);
  });

  test('complete backup survives JSON round trip', () {
    final now = DateTime.utc(2026, 7, 12, 8, 30);
    final article = Article(
      id: 'article-1',
      title: 'Test',
      content: '<p>Content</p>',
      createdAt: now,
      updatedAt: now,
      folderId: 'folder-1',
      teleprompterSettings: const AppSettings().toTeleprompterMap(),
    );
    final backup = AppBackup(
      createdAt: now,
      articles: [article],
      folders: [Folder(id: 'folder-1', name: 'Folder', createdAt: now)],
      settings: const AppSettings(fontSize: 76),
    );

    final restored = AppBackup.fromJson(backup.toJson());

    expect(restored.createdAt, now);
    expect(restored.articles.single.toJson(), article.toJson());
    expect(restored.folders.single.id, 'folder-1');
    expect(restored.settings.fontSize, 76);
  });
}

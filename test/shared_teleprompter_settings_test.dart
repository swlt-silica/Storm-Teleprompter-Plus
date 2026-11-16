import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/article_service.dart';
import 'package:storm_teleprompter_plus/backend/settings_service.dart';
import 'package:storm_teleprompter_plus/backend/teleprompter_session.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/backend/ws_server.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/settings_provider.dart';
import 'package:storm_teleprompter_plus/services/system/app_data_directory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('真实存储共用设置：旧稿件不覆盖，换稿和重启保留设置且稿件不被重写', () async {
    final directory = await Directory.systemTemp.createTemp(
      'storm-shared-settings-',
    );
    appDataDirectoryOverride = directory;
    final server = WsServer();
    final connection = ConnectionProvider();
    final provider = SettingsProvider();
    final service = SettingsService();
    final articles = ArticleService();
    final session = TeleprompterSession();
    addTearDown(() async {
      provider.dispose();
      await connection.client.disconnect();
      connection.dispose();
      await server.stop();
      session.dispose();
      server.dispose();
      appDataDirectoryOverride = null;
      await directory.delete(recursive: true);
    });
    await service.init();
    await articles.init();
    service.registerHandlers(server);
    articles.registerHandlers(server);
    session.registerHandlers(server);
    final first = await articles.createArticle(
      title: '第一篇',
      content: '<p>第一篇正文</p>',
    );
    final second = await articles.createArticle(
      title: '第二篇',
      content: '<p>第二篇正文</p>',
    );
    await articles.updateArticle(
      first.id,
      teleprompterSettings: {'fontSize': 19, 'mirrorMode': true},
    );
    await articles.updateArticle(
      second.id,
      teleprompterSettings: {'fontSize': 130, 'mirrorMode': false},
    );
    final before = (await articles.loadArticles())
        .map((a) => a.toJson())
        .toList();
    await connection.connectToLocal(await server.start());
    provider.bindConnection(connection);
    await provider.init();
    provider.useSharedTeleprompterSettings();
    await provider.setFontSize(83);
    await provider.setLineHeight(2.3);
    await provider.setLetterSpacing(3.5);
    await provider.setTextColor(0xFF123456);
    await provider.setTeleprompterBgColor(0xFF456789);
    await provider.toggleMirrorMode();
    await provider.setScrollMode(ScrollMode.asr);
    await provider.setWpm(217);
    await provider.setPaddingX(17);
    await provider.setReadingLineOffset(.63);
    final expected = provider.settings.toTeleprompterMap();

    for (final article in await articles.loadArticles()) {
      // The page uses this same entry point, never the legacy article overrides.
      expect(article.teleprompterSettings, isNotNull);
      provider.useSharedTeleprompterSettings();
      expect(provider.mergedSettings.toTeleprompterMap(), expected);
    }
    final fromDisk = await service.loadSettings();
    expect(fromDisk.toTeleprompterMap(), expected);
    final restarted = SettingsProvider()..bindConnection(connection);
    addTearDown(restarted.dispose);
    await restarted.init();
    expect(restarted.mergedSettings.toTeleprompterMap(), expected);
    expect(
      (await articles.loadArticles()).map((a) => a.toJson()).toList(),
      before,
    );
    // Wait for preceding settings broadcasts with a round-trip on the same socket.
    await connection.request(WsMessageType.settingsGet);
    expect(session.settingsOverride['fontSize'], 83);
    expect(session.settingsOverride['mirrorMode'], isTrue);
  });

  test('远程会话设置和调速不覆盖本机共用设置，回到本机仍为原值', () async {
    final connection = _RemoteConnection();
    final provider = SettingsProvider();
    addTearDown(connection.dispose);
    addTearDown(provider.dispose);
    await provider.setFontSize(83);
    await provider.setWpm(217);
    final local = provider.settings.toTeleprompterMap();
    provider.bindConnection(connection);
    provider.applyRemoteTeleprompterSettings({'fontSize': 27, 'wpm': 97});
    provider.applyRemoteSyncedRuntimeSettings({
      'scrollMode': 'asr',
      'wpm': 104,
    });
    expect(provider.mergedSettings.fontSize, 27);
    expect(provider.mergedSettings.wpm, 104);
    await provider.setFontSize(31);
    expect(provider.mergedSettings.fontSize, 31);
    expect(provider.settings.toTeleprompterMap(), local);
    expect(connection.saves, 0);
    provider.clearRemoteTeleprompterSettings();
    expect(provider.mergedSettings.toTeleprompterMap(), local);
  });
}

class _RemoteConnection extends ConnectionProvider {
  int saves = 0;
  @override
  bool get isRemote => true;
  @override
  bool get isLocal => false;
  @override
  bool get isConnected => true;
  @override
  bool get canRetryRemoteConnection => false;
  @override
  Future<WsMessage> request(
    WsMessageType type, {
    Map<String, dynamic>? data,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (type == WsMessageType.settingsSave) saves++;
    throw StateError('远程会话不应持久化本机设置');
  }
}

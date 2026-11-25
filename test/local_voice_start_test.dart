import 'dart:async';
import 'dart:io';
import 'package:storm_teleprompter_plus/backend/backend_server.dart';
import 'package:storm_teleprompter_plus/services/system/app_data_directory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/ws_protocol.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/teleprompter_provider.dart';

class _Connection extends ConnectionProvider {
  bool online = false;
  bool fail = false;
  final messages = <WsMessageType>[];
  Map<String, dynamic>? session;

  @override
  bool get isLocal => online;
  @override
  bool get isConnected => online;
  @override
  Future<void> connectToBundledLocal() async {
    online = !fail;
  }

  @override
  Future<WsMessage> request(
    WsMessageType type, {
    Map<String, dynamic> data = const {},
    Duration timeout = const Duration(seconds: 10),
  }) async {
    messages.add(type);
    if (type == WsMessageType.teleprompterStartSession) session = data;
    return WsMessage(type: type, data: {'status': 'running', 'success': true});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('本机服务真实掉线后点开始重建会话并保留阅读位置', () async {
    final dir = await Directory.systemTemp.createTemp('storm-reconnect-');
    appDataDirectoryOverride = dir;
    final backend = BackendServer();
    final connection = ConnectionProvider()..bindLocalBackend(backend);
    final prompt = TeleprompterProvider()..bindConnection(connection);
    try {
      await connection.connectToBundledLocal();
      expect(connection.isLocal, true);
      final disconnected = Completer<void>();
      connection.addListener(() {
        if (!connection.isConnected && !disconnected.isCompleted)
          disconnected.complete();
      });
      await backend.stop();
      await disconnected.future.timeout(const Duration(seconds: 3));
      expect(connection.canRetryRemoteConnection, false);
      prompt.loadArticle(
        Article(
          id: 'local',
          title: '本机',
          content: '保留这里的位置',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );
      prompt.setCurrentIndex(3);
      final finished = Completer<void>();
      prompt.addListener(() {
        if (!prompt.isPlaying &&
            prompt.asrStatus == 'error' &&
            !finished.isCompleted)
          finished.complete();
      });
      // No native microphone in the test runner. Reaching model selection proves
      // the ASR request was handled by the restarted backend for this article.
      prompt.play(
        const AppSettings(scrollMode: ScrollMode.asr, autoHideUI: false),
      );
      await finished.future.timeout(const Duration(seconds: 8));
      expect(connection.isLocal, true);
      expect(backend.teleprompterSession.activeArticleId, 'local');
      expect(backend.teleprompterSession.currentIndex, 3);
      expect(prompt.asrError, contains('尚未选择语音识别模型'));
    } finally {
      await connection.disconnect();
      prompt.dispose();
      await backend.stop();
      connection.dispose();
      appDataDirectoryOverride = null;
      await dir.delete(recursive: true);
    }
  });
  for (final fail in [false, true]) {
    testWidgets('本机断开后点开始，恢复结果 fail=$fail', (tester) async {
      final connection = _Connection()..fail = fail;
      final prompt = TeleprompterProvider()..bindConnection(connection);
      addTearDown(prompt.dispose);
      final article = Article(
        id: 'draft',
        title: '临时稿',
        content: '今天讲第二段',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      prompt.loadArticle(article);
      prompt.setCurrentIndex(2);
      prompt.play(
        const AppSettings(scrollMode: ScrollMode.asr, autoHideUI: false),
      );
      await tester.pump();
      if (fail) {
        expect(prompt.isPlaying, false);
        expect(prompt.asrStatus, 'error');
        expect(connection.messages, isEmpty);
      } else {
        expect(connection.session?['article'], article.toJson());
        expect(connection.session?['currentIndex'], 2);
        expect(
          connection.messages,
          containsAllInOrder([
            WsMessageType.teleprompterStartSession,
            WsMessageType.asrStart,
          ]),
        );
        expect(prompt.asrStatus, 'running');
      }
    });
  }
}

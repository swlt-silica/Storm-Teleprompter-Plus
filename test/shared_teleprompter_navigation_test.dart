import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:storm_teleprompter_plus/models/article.dart';
import 'package:storm_teleprompter_plus/pages/editor_page.dart';
import 'package:storm_teleprompter_plus/pages/home_page.dart';
import 'package:storm_teleprompter_plus/pages/teleprompter_page.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/settings_provider.dart';
import 'package:storm_teleprompter_plus/providers/teleprompter_provider.dart';

import 'support/quick_workspace_test_host.dart';

Article _article(String id, double oldFontSize) => Article(
  id: id,
  title: '稿件$id',
  content: '<p>这是$id的提词正文。</p>',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  teleprompterSettings: {'fontSize': oldFontSize, 'mirrorMode': false},
);

class _Articles extends QuickTestArticles {
  int articleSettingsWrites = 0;

  @override
  Future<Article?> updateArticleTeleprompterSettings(
    String id,
    Map<String, dynamic> settings,
  ) async {
    articleSettingsWrites++;
    return articles.firstWhere((article) => article.id == id);
  }
}

Future<void> _openFromHome(WidgetTester tester, String title) async {
  await tester.tap(find.text(title).first);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
  expect(find.byType(TeleprompterPage), findsOneWidget);
}

Future<void> _popPrompt(WidgetTester tester) async {
  Navigator.of(tester.element(find.byType(TeleprompterPage))).pop();
  await tester.pumpAndSettle();
}

class _RemoteConnection extends QuickTestConnection {
  _RemoteConnection({this.retrying = false});
  final bool retrying;
  @override
  bool get isConnected => !retrying;
  @override
  bool get isLocal => false;
  @override
  bool get isRemote => !retrying;
  @override
  bool get canRetryRemoteConnection => retrying;
}

void main() {
  testWidgets('主页切换旧稿沿用共享字号，退出不写每稿设置', (tester) async {
    final articles = _Articles()
      ..upsertArticle(_article('A', 23))
      ..upsertArticle(_article('B', 121));
    final settings = QuickTestSettings();
    await settings.toggleFullScreenMode();
    await settings.setFontSize(79);
    await settings.toggleMirrorMode();
    await mountQuickWorkspace(tester, const HomePage(), articles, settings);

    await _openFromHome(tester, '稿件A');
    expect(settings.mergedSettings.fontSize, 79);
    expect(settings.mergedSettings.mirrorMode, isTrue);
    await settings.setFontSize(93);
    await tester.pump();
    await _popPrompt(tester);

    await _openFromHome(tester, '稿件B');
    expect(settings.mergedSettings.fontSize, 93);
    expect(settings.mergedSettings.mirrorMode, isTrue);
    await _popPrompt(tester);

    await _openFromHome(tester, '稿件A');
    expect(settings.mergedSettings.fontSize, 93);
    await _popPrompt(tester);
    expect(articles.articleSettingsWrites, 0);
    expect(
      articles.articles.firstWhere((a) => a.id == 'A').teleprompterSettings,
      {'fontSize': 23.0, 'mirrorMode': false},
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('编辑器启动提词忽略旧专属设置并使用共享设置', (tester) async {
    final article = _article('编辑器', 21);
    final articles = _Articles()..upsertArticle(article);
    final settings = QuickTestSettings();
    await settings.toggleFullScreenMode();
    await settings.setFontSize(87);
    await mountQuickWorkspace(
      tester,
      EditorPage(article: article),
      articles,
      settings,
    );
    await tester.tap(find.text('开始提词'));
    await tester.pumpAndSettle();
    expect(find.byType(TeleprompterPage), findsOneWidget);
    expect(settings.mergedSettings.fontSize, 87);
    await settings.setFontSize(99);
    await tester.pump();
    await _popPrompt(tester);
    expect(settings.mergedSettings.fontSize, 99);
    expect(articles.articleSettingsWrites, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final retrying in [false, true]) {
    testWidgets('远端${retrying ? '重连' : '在线'}切稿后恢复新会话临时配置', (tester) async {
      final connection = _RemoteConnection(retrying: retrying);
      final settings = QuickTestSettings();
      final teleprompter = TeleprompterProvider();
      await settings.toggleFullScreenMode();
      await settings.setFontSize(61);
      settings.applyRemoteTeleprompterSettings({'fontSize': 112});
      // home 已应用新会话，但退出旧页面会清除临时配置。新页应从
      // sessionArticle（主端消息快照）重新应用，而不退回本机字号。
      settings.clearRemoteTeleprompterSettings();
      expect(settings.mergedSettings.fontSize, 61);
      final article = _article('远端', 112);
      teleprompter.loadScript(article.id, article.content);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ConnectionProvider>.value(value: connection),
            ChangeNotifierProvider<SettingsProvider>.value(value: settings),
            ChangeNotifierProvider<TeleprompterProvider>.value(
              value: teleprompter,
            ),
          ],
          child: MaterialApp(
            localizationsDelegates:
                quill.FlutterQuillLocalizations.localizationsDelegates,
            supportedLocales: quill.FlutterQuillLocalizations.supportedLocales,
            home: TeleprompterPage(article: article),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(settings.mergedSettings.fontSize, 112);
      expect(settings.settings.fontSize, 61);
      await tester.pumpWidget(const SizedBox());
      expect(settings.mergedSettings.fontSize, 61);
      settings.dispose();
      teleprompter.dispose();
      connection.dispose();
    });
  }
}

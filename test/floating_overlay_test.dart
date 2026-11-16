import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:storm_teleprompter_plus/models/app_settings.dart';
import 'package:storm_teleprompter_plus/models/floating_overlay_settings.dart';
import 'package:storm_teleprompter_plus/providers/connection_provider.dart';
import 'package:storm_teleprompter_plus/providers/settings_provider.dart';
import 'package:storm_teleprompter_plus/providers/teleprompter_provider.dart';
import 'package:storm_teleprompter_plus/services/overlay/floating_teleprompter_bridge.dart';
import 'package:storm_teleprompter_plus/services/overlay/floating_teleprompter_controller.dart';
import 'package:storm_teleprompter_plus/services/text_parser.dart';
import 'package:storm_teleprompter_plus/services/app_preferences.dart';
import 'package:storm_teleprompter_plus/services/system/app_data_directory.dart';
import 'package:storm_teleprompter_plus/widgets/teleprompter/floating_overlay_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    appDataDirectoryOverride = await Directory.systemTemp.createTemp(
      'storm-overlay-test-',
    );
    await AppPreferences.getInstance();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('原生未返回成功时不能将悬浮窗视为运行', () async {
    const channel = MethodChannel('storm.overlay.test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => false);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final bridge = FloatingTeleprompterBridge(channel: channel);
    await expectLater(bridge.start({'text': '台词'}), throwsStateError);
  });

  test('设备状态保留真实系统信息，厂商未知状态不被当成已授权', () {
    final status = FloatingOverlayStatus.fromMap({
      'isMiuiDevice': true,
      'deviceManufacturer': 'Xiaomi',
      'deviceModel': '22041216C',
      'androidSdk': 31,
      'batteryOptimizationExempt': false,
    });
    expect(status.isMiuiDevice, isTrue);
    expect(status.deviceModel, '22041216C');
    expect(status.androidSdk, 31);
    expect(status.batteryOptimizationExempt, isFalse);
    final unknown = FloatingOverlayStatus.fromMap({});
    expect(unknown.isMiuiDevice, isFalse);
    expect(unknown.batteryOptimizationExempt, isNull);
    expect(unknown.androidSdk, 0);
  });

  test('厂商权限、自启动和省电策略使用对应的原生入口', () async {
    const channel = MethodChannel('storm.overlay.miui.test');
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final bridge = FloatingTeleprompterBridge(channel: channel);
    await bridge.openVendorPermissions();
    await bridge.openAutoStartSettings();
    await bridge.openBatterySettings();
    expect(methods, [
      'openVendorPermissions',
      'openAutoStartSettings',
      'openBatterySettings',
    ]);
  });

  testWidgets('MIUI 引导不伪报厂商授权且三个入口可操作，不额外阻止启动', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.bridge.permissions = const FloatingOverlayStatus(
      overlayPermission: true,
      microphonePermission: true,
      accessibilityEnabled: true,
      isMiuiDevice: true,
      deviceManufacturer: 'Xiaomi',
      deviceModel: '22041216C',
      androidSdk: 31,
      batteryOptimizationExempt: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FloatingOverlaySheet(
            controller: fixture.controller,
            settings: fixture.settings,
            prepareOrientation: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('MIUI 运行权限'), findsOneWidget);
    expect(find.text('当前设备：Xiaomi 22041216C'), findsOneWidget);
    expect(find.textContaining('应用无法读取这些厂商权限是否已开启'), findsOneWidget);
    expect(find.text('去检查'), findsNWidgets(3));
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    for (final title in ['悬浮窗与后台弹出界面', '自启动', '省电策略']) {
      final row = find.ancestor(
        of: find.text(title),
        matching: find.byType(Row),
      );
      final button = find.descendant(
        of: row,
        matching: find.byType(TextButton),
      );
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }
    expect(fixture.bridge.vendorPermissionCalls, 1);
    expect(fixture.bridge.autoStartCalls, 1);
    expect(fixture.bridge.batterySettingsCalls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final sdk in [31, 33]) {
    testWidgets('Android API $sdk 按真实底层版本显示受限设置提示', (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.settings.setScrollMode(ScrollMode.asr);
      fixture.bridge.permissions = FloatingOverlayStatus(androidSdk: sdk);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingOverlaySheet(
              controller: fixture.controller,
              settings: fixture.settings,
              prepareOrientation: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('MIUI 运行权限'), findsNothing);
      expect(
        find.textContaining('允许受限设置'),
        sdk >= 33 ? findsOneWidget : findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test('富文本换行与 emoji 的游标转换保持 UTF-16 边界并允许回退', () {
    final lines = TextParser.parse('<p>你好😀</p><p>第二句</p>');
    final script = FloatingScriptText.fromLines(lines);
    expect(script.text, '你好😀\n第二句');
    final secondLine = lines.last.characters.first.rawIndex;
    expect(script.offsetForRawIndex(secondLine), 5);
    expect(script.offsetForRawIndex(lines.first.characters[3].rawIndex), 2);
    expect(script.offsetForRawIndex(lines.first.characters.first.rawIndex), 0);
    expect(script.offsetForRawIndex(-1), -1);
  });

  test('悬浮外观随完整设置备份恢复，稿件覆盖不重置悬浮外观', () {
    final original = const AppSettings().copyWith(
      floatingOverlay: const FloatingOverlaySettings(
        fontSize: 42,
        backgroundOpacity: 0.3,
        widthFraction: 0.7,
        heightFraction: 0.6,
        mirror: true,
      ),
    );
    final restored = AppSettings.fromJson(original.toJson());
    expect(
      restored.floatingOverlay.toJson(),
      original.floatingOverlay.toJson(),
    );
    expect(
      restored.mergeOverrides({'fontSize': 80}).floatingOverlay.toJson(),
      original.floatingOverlay.toJson(),
    );
    final safe = FloatingOverlaySettings.fromJson({
      'fontSize': double.nan,
      'backgroundOpacity': 3,
      'widthFraction': -1,
    });
    expect(safe.fontSize, 32);
    expect(safe.backgroundOpacity, 1);
    expect(safe.widthFraction, 0.35);
    expect(AppSettings.fromJson({}).floatingOverlay.fontSize, 32);
  });

  test('未授权、远程模式和像素匀速均不能绕过启动门槛', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.bridge.permissions = const FloatingOverlayStatus();
    await expectLater(fixture.controller.start(), throwsStateError);
    expect(fixture.bridge.startCalls, 0);
    expect(fixture.teleprompter.isPlaying, isFalse);
    fixture.bridge.permissions = _ready;
    fixture.connection.local = false;
    await expectLater(fixture.controller.start(), throwsStateError);
    expect(fixture.bridge.startCalls, 0);
    fixture.connection.local = true;
    await fixture.settings.toggleAutoScrollMode();
    await expectLater(fixture.controller.start(), throwsStateError);
    expect(fixture.bridge.startCalls, 0);
  });

  test('原生启动失败时不打开相机也不开始播放', () async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    fixture.bridge.startError = StateError('悬浮权限已被撤销');
    await expectLater(
      fixture.controller.start(openCamera: true),
      throwsStateError,
    );
    expect(fixture.controller.active, isFalse);
    expect(fixture.controller.starting, isFalse);
    expect(fixture.teleprompter.isPlaying, isFalse);
    expect(fixture.bridge.cameraCalls, 0);
    expect(fixture.controller.lastError, contains('权限已被撤销'));
  });

  testWidgets('后台同步发送前进和回退游标，原生关闭时暂停会话', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.controller.start();
    expect(fixture.controller.active, isTrue);
    expect(fixture.teleprompter.isPlaying, isTrue);
    fixture.teleprompter.setCurrentIndex(4);
    await tester.pump(const Duration(milliseconds: 100));
    expect(fixture.bridge.updates.last['currentIndex'], 4);
    fixture.teleprompter.setCurrentIndex(1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(fixture.bridge.updates.last['currentIndex'], 1);
    await fixture.bridge.onAction?.call({'action': 'close'});
    expect(fixture.controller.active, isFalse);
    expect(fixture.teleprompter.isPlaying, isFalse);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('运行中切为像素匀速会停止并解释原因，保留用户设置', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.controller.start();
    await fixture.settings.toggleAutoScrollMode();
    await tester.pump(const Duration(milliseconds: 100));
    expect(fixture.controller.active, isFalse);
    expect(fixture.teleprompter.isPlaying, isFalse);
    expect(fixture.settings.mergedSettings.isContinuousScroll, isTrue);
    expect(fixture.controller.lastError, contains('像素匀速'));
  });

  testWidgets('语音识别启动失败不打开相机，运行中识别失败停止并释放会话', (tester) async {
    final teleprompter = _ControlledVoice();
    final fixture = _Fixture(teleprompter: teleprompter);
    addTearDown(fixture.dispose);
    await fixture.settings.setScrollMode(ScrollMode.asr);
    await fixture.settings.setAsrModel('test-model', '测试模型');
    teleprompter.status = 'error';
    await expectLater(
      fixture.controller.start(openCamera: true),
      throwsStateError,
    );
    expect(fixture.bridge.cameraCalls, 0);
    expect(fixture.controller.active, isFalse);
    expect(teleprompter.isPlaying, isFalse);
    teleprompter.status = 'running';
    await fixture.controller.start();
    expect(fixture.controller.active, isTrue);
    teleprompter.fail();
    await tester.pump(const Duration(milliseconds: 100));
    expect(fixture.controller.active, isFalse);
    expect(teleprompter.isPlaying, isFalse);
    expect(fixture.controller.lastError, contains('测试识别失败'));
  });

  testWidgets('黑字全屏设置不会让半透明悬浮窗变成黑底黑字', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.settings.setTextColor(0xFF000000);
    await fixture.controller.start();
    expect(fixture.bridge.starts.single['textColor'], 0xFFFFFFFF);
    expect(fixture.bridge.starts.single['backgroundColor'], 0xFF000000);
    await fixture.controller.stop(pause: true);
  });

  testWidgets('麦克风拒绝后给出中文反馈和应用权限恢复入口', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.settings.setScrollMode(ScrollMode.asr);
    fixture.bridge.permissions = const FloatingOverlayStatus(
      overlayPermission: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FloatingOverlaySheet(
            controller: fixture.controller,
            settings: fixture.settings,
            prepareOrientation: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final request = find.text('允许').first;
    await tester.ensureVisible(request);
    await tester.tap(request);
    await tester.pumpAndSettle();
    expect(find.text('麦克风权限未获允许，可在系统应用权限中开启'), findsOneWidget);
    final appSettings = find.text('打开应用权限设置');
    await tester.ensureVisible(appSettings);
    await tester.tap(appSettings);
    await tester.pumpAndSettle();
    expect(fixture.bridge.appSettingsCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('语音模型缺失不会启动窗口或相机', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.settings.setScrollMode(ScrollMode.asr);
    await expectLater(
      fixture.controller.start(openCamera: true),
      throwsStateError,
    );
    expect(fixture.bridge.startCalls, 0);
    expect(fixture.bridge.cameraCalls, 0);
  });

  for (final width in [390.0, 850.0]) {
    testWidgets('中文悬浮设置在宽度 $width 下无溢出，拒绝权限时禁用启动', (tester) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      fixture.bridge.permissions = const FloatingOverlayStatus();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingOverlaySheet(
              controller: fixture.controller,
              settings: fixture.settings,
              prepareOrientation: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('悬浮提词'), findsOneWidget);
      expect(find.text('背景不透明度'), findsOneWidget);
      expect(find.text('左右镜像'), findsOneWidget);
      final start = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(start.onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

const _ready = FloatingOverlayStatus(
  overlayPermission: true,
  accessibilityEnabled: true,
  microphonePermission: true,
  notificationPermission: true,
);

class _Fixture {
  _Fixture({TeleprompterProvider? teleprompter})
    : teleprompter = teleprompter ?? TeleprompterProvider() {
    this.teleprompter.loadScript('article', '第一句内容\n第二句内容');
    controller = FloatingTeleprompterController(
      teleprompter: this.teleprompter,
      settings: settings,
      connection: connection,
      bridge: bridge,
    );
  }
  final bridge = _FakeBridge();
  final TeleprompterProvider teleprompter;
  final settings = SettingsProvider();
  final connection = _LocalConnection();
  late final FloatingTeleprompterController controller;
  void dispose() {
    controller.dispose();
    teleprompter.dispose();
    settings.dispose();
    connection.dispose();
  }
}

class _LocalConnection extends ConnectionProvider {
  bool local = true;
  @override
  bool get isConnected => true;
  @override
  bool get isLocal => local;
  @override
  bool get canRetryRemoteConnection => false;
}

class _FakeBridge extends FloatingTeleprompterBridge {
  FloatingOverlayStatus permissions = _ready;
  int startCalls = 0;
  int cameraCalls = 0;
  int appSettingsCalls = 0;
  int vendorPermissionCalls = 0;
  int autoStartCalls = 0;
  int batterySettingsCalls = 0;
  final starts = <Map<String, dynamic>>[];
  Object? startError;
  final updates = <Map<String, dynamic>>[];
  @override
  void attach() {}
  @override
  void detach() {}
  @override
  Future<FloatingOverlayStatus> status() async => permissions;
  @override
  Future<void> start(Map<String, dynamic> payload) async {
    startCalls++;
    starts.add(payload);
    if (startError != null) throw startError!;
  }

  @override
  Future<void> update(Map<String, dynamic> payload) async =>
      updates.add(payload);
  @override
  Future<void> stop() async {}
  @override
  Future<bool> requestMicrophonePermission() async => false;
  @override
  Future<void> openAppSettings() async {
    appSettingsCalls++;
  }

  @override
  Future<void> openVendorPermissions() async {
    vendorPermissionCalls++;
  }

  @override
  Future<void> openAutoStartSettings() async {
    autoStartCalls++;
  }

  @override
  Future<void> openBatterySettings() async {
    batterySettingsCalls++;
  }

  @override
  Future<void> openCamera() async {
    cameraCalls++;
  }
}

class _ControlledVoice extends TeleprompterProvider {
  String status = 'running';
  @override
  String get asrStatus => status;
  @override
  String? get asrError => status == 'error' ? '测试识别失败' : null;
  void fail() {
    status = 'error';
    notifyListeners();
  }
}

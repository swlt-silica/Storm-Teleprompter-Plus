import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/script_character.dart';

class FloatingOverlayStatus {
  const FloatingOverlayStatus({
    this.overlayPermission = false,
    this.accessibilityEnabled = false,
    this.microphonePermission = false,
    this.notificationPermission = false,
    this.running = false,
    this.isMiuiDevice = false,
    this.deviceManufacturer = '',
    this.deviceModel = '',
    this.androidSdk = 0,
    this.batteryOptimizationExempt,
  });

  factory FloatingOverlayStatus.fromMap(Map<dynamic, dynamic> map) =>
      FloatingOverlayStatus(
        overlayPermission: map['overlayPermission'] == true,
        accessibilityEnabled: map['accessibilityEnabled'] == true,
        microphonePermission: map['microphonePermission'] == true,
        notificationPermission: map['notificationPermission'] == true,
        running: map['running'] == true,
        isMiuiDevice: map['isMiuiDevice'] == true,
        deviceManufacturer: map['deviceManufacturer'] as String? ?? '',
        deviceModel: map['deviceModel'] as String? ?? '',
        androidSdk: (map['androidSdk'] as num?)?.toInt() ?? 0,
        batteryOptimizationExempt: map['batteryOptimizationExempt'] is bool
            ? map['batteryOptimizationExempt'] as bool
            : null,
      );

  final bool overlayPermission;
  final bool accessibilityEnabled;
  final bool microphonePermission;
  final bool notificationPermission;
  final bool running;
  final bool isMiuiDevice;
  final String deviceManufacturer;
  final String deviceModel;
  final int androidSdk;
  final bool? batteryOptimizationExempt;
}

/// 唯一的原生通道边界。窗口启动必须由原生返回成功后才能视为运行。
class FloatingTeleprompterBridge {
  FloatingTeleprompterBridge({
    MethodChannel channel = const MethodChannel('storm.teleprompter/overlay'),
  }) : _channel = channel;

  final MethodChannel _channel;
  Future<void> Function(Map<String, dynamic>)? onAction;

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void attach() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAction' && call.arguments is Map) {
        await onAction?.call(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
  }

  void detach() {
    onAction = null;
    _channel.setMethodCallHandler(null);
  }

  Future<FloatingOverlayStatus> status() async => FloatingOverlayStatus.fromMap(
    await _channel.invokeMapMethod<dynamic, dynamic>('getStatus') ?? {},
  );

  Future<void> requestOverlayPermission() =>
      _channel.invokeMethod<void>('requestOverlayPermission');
  Future<void> openAppSettings() =>
      _channel.invokeMethod<void>('openAppSettings');
  Future<void> openAccessibilitySettings() =>
      _channel.invokeMethod<void>('openAccessibilitySettings');
  Future<void> openVendorPermissions() =>
      _channel.invokeMethod<void>('openVendorPermissions');
  Future<void> openAutoStartSettings() =>
      _channel.invokeMethod<void>('openAutoStartSettings');
  Future<void> openBatterySettings() =>
      _channel.invokeMethod<void>('openBatterySettings');
  Future<bool> requestMicrophonePermission() async =>
      await _channel.invokeMethod<bool>('requestMicrophonePermission') ?? false;
  Future<bool> requestNotificationPermission() async =>
      await _channel.invokeMethod<bool>('requestNotificationPermission') ??
      false;

  Future<void> start(Map<String, dynamic> payload) async {
    final started = await _channel.invokeMethod<bool>('start', payload);
    if (started != true) throw StateError('悬浮窗未能启动，请检查权限后重试');
  }

  Future<void> update(Map<String, dynamic> payload) =>
      _channel.invokeMethod<void>('update', payload);
  Future<void> stop() => _channel.invokeMethod<void>('stop');
  Future<void> openCamera() => _channel.invokeMethod<void>('openCamera');
}

/// 从页面实际使用的解析结果建立映射，不能直接将 HTML 或原稿索引传给 TextView。
/// Android TextView 和 Dart String 都使用 UTF-16；插入的换行也要计入偏移。
class FloatingScriptText {
  FloatingScriptText._(this.text, this._rawIndices, this._offsets);

  factory FloatingScriptText.fromLines(List<ScriptLine> lines) {
    final text = StringBuffer();
    final rawIndices = <int>[];
    final offsets = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) text.write('\n');
      for (final character in lines[i].characters) {
        rawIndices.add(character.rawIndex);
        offsets.add(text.length);
        text.write(character.char);
      }
    }
    return FloatingScriptText._(text.toString(), rawIndices, offsets);
  }

  final String text;
  final List<int> _rawIndices;
  final List<int> _offsets;

  int offsetForRawIndex(int rawIndex) {
    if (rawIndex < 0 || _rawIndices.isEmpty) return -1;
    var low = 0;
    var high = _rawIndices.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_rawIndices[mid] <= rawIndex) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    var offset = _offsets[(low - 1).clamp(0, _offsets.length - 1)];
    // 光标不能落在 emoji 等非 BMP 字符的低代理项上。
    if (offset > 0 &&
        text.codeUnitAt(offset) >= 0xDC00 &&
        text.codeUnitAt(offset) <= 0xDFFF) {
      offset--;
    }
    return offset;
  }
}

String floatingOverlayError(Object error) {
  if (error is PlatformException) return error.message ?? '悬浮窗操作失败，请重试';
  if (error is MissingPluginException) return '当前安装包未包含安卓悬浮窗功能';
  if (error is StateError) return error.message.toString();
  return '悬浮窗操作失败：$error';
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/app_settings.dart';
import '../../models/floating_overlay_settings.dart';
import '../../models/script_character.dart';
import '../../providers/connection_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/teleprompter_provider.dart';
import 'floating_teleprompter_bridge.dart';

/// 将已有会话的游标投影到安卓悬浮窗，不另建一套识别器或播放进度。
class FloatingTeleprompterController extends ChangeNotifier {
  FloatingTeleprompterController({
    required this.teleprompter,
    required this.settings,
    required this.connection,
    FloatingTeleprompterBridge? bridge,
    this.onSettingsRequested,
    this.asrReadyTimeout = const Duration(minutes: 2),
  }) : bridge = bridge ?? FloatingTeleprompterBridge() {
    this.bridge
      ..onAction = _handleAction
      ..attach();
    teleprompter.addListener(_scheduleUpdate);
    settings.addListener(_scheduleUpdate);
    connection.addListener(_scheduleUpdate);
  }

  final TeleprompterProvider teleprompter;
  final SettingsProvider settings;
  final ConnectionProvider connection;
  final FloatingTeleprompterBridge bridge;
  final VoidCallback? onSettingsRequested;
  final Duration asrReadyTimeout;
  bool _active = false;
  bool _starting = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? _updateTimer;
  List<ScriptLine>? _cachedLines;
  FloatingScriptText? _cachedText;
  String? _lastError;
  Completer<void>? _pendingAsrReady;

  bool get active => _active;
  bool get starting => _starting;
  String? get lastError => _lastError;
  bool get controlLocked =>
      !connection.isLocal ||
      !connection.isConnected ||
      connection.canRetryRemoteConnection;

  bool get canStartOnDevice =>
      !controlLocked ||
      (!connection.isConnected && !connection.canRetryRemoteConnection);

  FloatingScriptText get scriptText {
    if (!identical(_cachedLines, teleprompter.lines)) {
      _cachedLines = teleprompter.lines;
      _cachedText = FloatingScriptText.fromLines(teleprompter.lines);
    }
    return _cachedText!;
  }

  Map<String, dynamic> _payload() {
    final appSettings = settings.mergedSettings;
    return {
      ...appSettings.floatingOverlay.toJson(),
      'text': scriptText.text,
      'currentIndex': scriptText.offsetForRawIndex(teleprompter.currentIndex),
      'isPlaying': teleprompter.isPlaying,
      'mode': appSettings.scrollMode.name,
      'lineHeight': appSettings.lineHeight,
      // 默认白字黑底，独立透明度保证相机取景不被全屏底色覆盖。
      'textColor': 0xFFFFFFFF,
      'backgroundColor': 0xFF000000,
      'status': appSettings.scrollMode == ScrollMode.asr
          ? switch (teleprompter.asrStatus) {
              'loading' => '正在准备语音识别',
              'running' => '语音跟读',
              'error' => teleprompter.asrError ?? '语音识别失败',
              _ => '语音已暂停',
            }
          : teleprompter.isPlaying
          ? '自动滚动'
          : '已暂停',
    };
  }

  Future<void> start({bool openCamera = false}) async {
    if (_disposed || _starting) return;
    if (!canStartOnDevice) throw StateError('请在本机服务端模式下启动悬浮提词');
    if (scriptText.text.trim().isEmpty) throw StateError('稿件为空，请先填写台词');
    final current = settings.mergedSettings;
    if (current.isContinuousScroll) {
      throw StateError('悬浮提词支持按字自动滚动和语音跟读，请先切换滚动方式');
    }

    _starting = true;
    _lastError = null;
    final generation = ++_generation;
    final wasPlaying = teleprompter.isPlaying;
    var nativeStarted = false;
    notifyListeners();
    try {
      if (!connection.isConnected) {
        await connection.connectToBundledLocal();
        if (_disposed || generation != _generation) return;
        if (controlLocked) throw StateError(connection.lastError ?? '本机服务启动失败');
      }
      final status = await bridge.status();
      if (_disposed || generation != _generation) return;
      if (!status.overlayPermission) throw StateError('请先允许“显示在其他应用上层”');
      if (current.scrollMode == ScrollMode.asr) {
        if (!status.microphonePermission) throw StateError('请先允许麦克风权限');
        if (!status.accessibilityEnabled) {
          throw StateError('相机录像时语音跟读需要先启用“飓风提词器：相机悬浮跟读”无障碍服务');
        }
      }
      if (current.scrollMode == ScrollMode.asr && current.asrModelId.isEmpty) {
        await settings.prepareVoiceModel();
        if (_disposed || generation != _generation) return;
        if (controlLocked || settings.settings.asrModelId.isEmpty) {
          throw StateError('本机语音模型尚未准备好');
        }
      }
      await bridge.start(_payload());
      nativeStarted = true;
      if (_disposed || generation != _generation) {
        await bridge.stop();
        return;
      }
      _active = true;
      notifyListeners();
      if (!teleprompter.isPlaying) {
        if (teleprompter.state == TeleprompterState.completed)
          teleprompter.reset();
        teleprompter.play(current);
      }
      if (current.scrollMode == ScrollMode.asr) await _waitForAsr(generation);
      if (_disposed || generation != _generation) return;
      await bridge.update(_payload());
      if (openCamera) await bridge.openCamera();
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _lastError = floatingOverlayError(error);
        if ((!wasPlaying || nativeStarted) && teleprompter.isPlaying) {
          teleprompter.pause(current);
        }
        _active = false;
        try {
          await bridge.stop();
        } catch (_) {}
      }
      rethrow;
    } finally {
      if (!_disposed && generation == _generation) {
        _starting = false;
        notifyListeners();
      }
    }
  }

  Future<void> _waitForAsr(int generation) async {
    final ready = Completer<void>();
    _pendingAsrReady = ready;
    void check() {
      if (ready.isCompleted) return;
      if (_disposed || !_active || generation != _generation) {
        ready.completeError(StateError('悬浮提词已停止'));
      } else if (teleprompter.asrStatus == 'error') {
        ready.completeError(StateError(teleprompter.asrError ?? '语音识别启动失败'));
      } else if (teleprompter.asrStatus == 'running') {
        ready.complete();
      }
    }

    teleprompter.addListener(check);
    addListener(check);
    check();
    try {
      await ready.future.timeout(
        asrReadyTimeout,
        onTimeout: () => throw StateError('语音识别准备超时，请检查模型后重试'),
      );
    } finally {
      if (identical(_pendingAsrReady, ready)) _pendingAsrReady = null;
      teleprompter.removeListener(check);
      removeListener(check);
    }
  }

  void _scheduleUpdate() {
    if (_disposed || !_active || _updateTimer != null) return;
    // Timer 在 Flutter 页面停止绘制时仍运行，不能依赖 addPostFrameCallback。
    _updateTimer = Timer(const Duration(milliseconds: 80), () {
      _updateTimer = null;
      if (_disposed || !_active) return;
      if (controlLocked) {
        unawaited(_stopAfterFailure());
        return;
      }
      unawaited(_pushUpdate());
    });
  }

  Future<void> _pushUpdate() async {
    if (settings.mergedSettings.isContinuousScroll) {
      _lastError = '已停止悬浮提词：像素匀速滚动不支持后台悬浮，请改用按字自动滚动或语音跟读';
      await _stopAfterFailure();
      return;
    }
    if (settings.mergedSettings.scrollMode == ScrollMode.asr &&
        teleprompter.asrStatus == 'error') {
      _lastError = teleprompter.asrError ?? '语音识别失败，已停止悬浮提词';
      await _stopAfterFailure();
      return;
    }
    try {
      await bridge.update(_payload());
    } catch (error) {
      if (_disposed || !_active) return;
      _lastError = floatingOverlayError(error);
      await _stopAfterFailure();
    }
  }

  Future<void> _stopAfterFailure() async {
    try {
      await stop(pause: true);
    } catch (error) {
      if (!_disposed) {
        _lastError ??= floatingOverlayError(error);
        notifyListeners();
      }
    }
  }

  Future<void> refreshStatus() async {
    final status = await bridge.status();
    if (_disposed) return;
    if (_active && !status.running) {
      _active = false;
      _generation++;
      _starting = false;
      if (teleprompter.isPlaying) teleprompter.pause(settings.mergedSettings);
      notifyListeners();
    }
  }

  Future<void> stop({bool pause = false}) async {
    final wasActive = _active || _starting;
    _generation++;
    _active = false;
    _starting = false;
    _updateTimer?.cancel();
    _updateTimer = null;
    if (pause && wasActive && teleprompter.isPlaying) {
      teleprompter.pause(settings.mergedSettings);
    }
    if (!_disposed) notifyListeners();
    await bridge.stop();
  }

  Future<void> _handleAction(Map<String, dynamic> data) async {
    if (_disposed) return;
    final action = data['action'];
    if (action == 'error') {
      _lastError = data['message'] as String? ?? '悬浮提词发生错误';
      notifyListeners();
      return;
    }
    if (action == 'close') {
      // 服务已移除窗口，直接暂停会话，避免 stop → close 循环。
      final wasActive = _active || _starting;
      _active = false;
      _starting = false;
      _generation++;
      _updateTimer?.cancel();
      _updateTimer = null;
      if (wasActive && teleprompter.isPlaying) {
        teleprompter.pause(settings.mergedSettings);
      }
      notifyListeners();
      return;
    }
    if (!_active || controlLocked) return;
    switch (action) {
      case 'togglePlay':
        teleprompter.togglePlayPause(settings.mergedSettings);
      case 'rewind':
        _moveLine(-1);
      case 'forward':
        _moveLine(1);
      case 'settings':
        onSettingsRequested?.call();
      case 'updateSettings':
        final merged = FloatingOverlaySettings.fromJson({
          ...settings.settings.floatingOverlay.toJson(),
          ...data,
        });
        await settings.setFloatingOverlay(merged);
    }
  }

  void _moveLine(int delta) {
    final lines = teleprompter.lines
        .where((line) => line.characters.isNotEmpty)
        .toList();
    if (lines.isEmpty) return;
    var current = 0;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].characters.first.rawIndex <= teleprompter.currentIndex)
        current = i;
    }
    final next = (current + delta).clamp(0, lines.length - 1);
    teleprompter.setCurrentIndex(lines[next].characters.first.rawIndex);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    final pending = _pendingAsrReady;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('悬浮提词已停止'));
    }
    _updateTimer?.cancel();
    teleprompter.removeListener(_scheduleUpdate);
    settings.removeListener(_scheduleUpdate);
    connection.removeListener(_scheduleUpdate);
    bridge.detach();
    unawaited(bridge.stop().catchError((Object _) {}));
    super.dispose();
  }
}

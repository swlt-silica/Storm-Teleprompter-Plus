import 'package:flutter/material.dart';
import '../backend/ws_protocol.dart';
import '../models/app_settings.dart';
import '../models/floating_overlay_settings.dart';
import 'connection_provider.dart';

/// 应用设置状态管理（前端）
///
/// 通过 WebSocket 与后端通信，管理应用设置的读取、保存。
/// 本机全部稿件共用提词设置；远程同步播放仅叠加临时会话配置。
class SettingsProvider with ChangeNotifier {
  AppSettings _settings = const AppSettings();
  bool _isLoading = false;

  ConnectionProvider? _connection;

  // ─── 远程播放的临时配置（不写入本机共用设置） ─────────────
  Map<String, dynamic> _remoteOverrides = {};
  bool _remoteOverridesActive = false;

  VoidCallback? _connectionListener;
  AppSettings get settings => _settings;
  bool get isLoading => _isLoading;

  /// 本机使用统一设置；远程播放时使用服务端的临时会话配置。
  AppSettings get mergedSettings => _remoteOverrides.isNotEmpty
      ? _settings.mergeOverrides(_remoteOverrides)
      : _settings;

  /// 绑定连接
  void bindConnection(ConnectionProvider connection) {
    if (_connection != null && _connectionListener != null) {
      _connection!.removeListener(_connectionListener!);
    }
    _connection = connection;
    _connectionListener = () {
      if (!connection.isConnected && !connection.canRetryRemoteConnection) {
        _remoteOverrides = {};
        _remoteOverridesActive = false;
        _isLoading = false;
        notifyListeners();
      }
    };
    connection.addListener(_connectionListener!);
  }

  /// 开始本机稿件时不再载入旧稿件的专属外观，直接沿用设备共用设置。
  void useSharedTeleprompterSettings({bool notify = true}) {
    clearRemoteTeleprompterSettings(notify: notify);
  }

  void applyRemoteTeleprompterSettings(
    Map<String, dynamic> settings, {
    bool notify = true,
  }) {
    final next = _settings.mergeOverrides(settings).toTeleprompterMap();
    final unchanged =
        _remoteOverridesActive && _mapEquals(_remoteOverrides, next);
    _remoteOverridesActive = true;
    if (unchanged) return;
    _remoteOverrides = next;
    if (notify) notifyListeners();
  }

  void applyRemoteSyncedRuntimeSettings(Map<String, dynamic> settings) {
    var changed = false;
    if (settings['scrollMode'] case final String modeName) {
      final mode = ScrollMode.values.firstWhere(
        (value) => value.name == modeName,
        orElse: () => mergedSettings.scrollMode,
      );
      if (_remoteOverrides['scrollMode'] != mode.name) {
        _remoteOverrides['scrollMode'] = mode.name;
        changed = true;
      }
    }
    if (settings.containsKey('wpm')) {
      final value = settings['wpm'];
      if (value is num) {
        final next = value.toInt();
        if (_remoteOverrides['wpm'] != next) {
          _remoteOverrides['wpm'] = next;
          changed = true;
        }
      }
    }
    for (final key in ['autoScrollMode', 'pixelsPerSecond']) {
      if (settings.containsKey(key) && _remoteOverrides[key] != settings[key]) {
        _remoteOverrides[key] = settings[key];
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  bool _mapEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  void clearRemoteTeleprompterSettings({bool notify = true}) {
    if (!_remoteOverridesActive && _remoteOverrides.isEmpty) return;
    _remoteOverridesActive = false;
    _remoteOverrides = {};
    if (notify) notifyListeners();
  }

  /// 所有本机稿件统一写入 AppSettings，切稿及重启后继续生效。
  Future<void> _setAndSave({required Map<String, dynamic> overrideData}) async {
    final connection = _connection;
    if (connection != null &&
        (connection.isRemote || connection.canRetryRemoteConnection)) {
      // 远程显示端不能把播放会话设置保存到服务端全局配置。
      _remoteOverrides = mergedSettings
          .mergeOverrides(overrideData)
          .toTeleprompterMap();
      _remoteOverridesActive = true;
      notifyListeners();
      return;
    }
    _remoteOverrides = {};
    _remoteOverridesActive = false;
    _settings = _settings.mergeOverrides(overrideData);
    notifyListeners();
    await _saveSettings();
    _syncTeleprompterSettingsToBackend();
  }

  void _syncTeleprompterSettingsToBackend() {
    final connection = _connection;
    if (connection == null || !connection.isConnected || !connection.isLocal) {
      return;
    }
    connection.send(
      WsMessage(
        type: WsMessageType.teleprompterSettingsUpdate,
        data: {'settings': mergedSettings.toTeleprompterMap()},
      ),
    );
  }

  /// 初始化并加载设置
  Future<void> init() async {
    await loadSettings();
  }

  /// 从后端加载设置
  Future<void> loadSettings() async {
    _isLoading = true;
    notifyListeners();

    try {
      if (_connection != null && _connection!.isConnected) {
        final response = await _connection!.request(WsMessageType.settingsGet);
        if (response.type == WsMessageType.settingsGetResponse) {
          _settings = AppSettings.fromJson(
            response.data['settings'] as Map<String, dynamic>,
          );
        }
      }
    } catch (e) {
      debugPrint('[SettingsProvider] 加载设置失败: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 保存设置到后端
  Future<void> _saveSettings() async {
    try {
      if (_connection != null && _connection!.isConnected) {
        await _connection!.request(
          WsMessageType.settingsSave,
          data: {'settings': _settings.toJson()},
        );
      }
    } catch (e) {
      debugPrint('[SettingsProvider] 保存设置失败: $e');
    }
  }

  /// 悬浮窗外观与普通提词设置一样，由本设备的全部稿件共用。
  Future<void> setFloatingOverlay(FloatingOverlaySettings value) async {
    _settings = _settings.copyWith(floatingOverlay: value);
    notifyListeners();
    await _saveSettings();
  }

  /// 更新字体大小
  Future<void> setFontSize(double fontSize) async {
    await _setAndSave(overrideData: {'fontSize': fontSize});
  }

  /// 更新行高
  Future<void> setLineHeight(double lineHeight) async {
    await _setAndSave(overrideData: {'lineHeight': lineHeight});
  }

  /// 更新滚动模式
  Future<void> setScrollMode(ScrollMode mode) async {
    await _setAndSave(overrideData: {'scrollMode': mode.name});
  }

  /// 更新 WPM
  Future<void> setWpm(int wpm) async {
    await _setAndSave(overrideData: {'wpm': wpm});
  }

  /// 再次点击自动标签时切换运动方式，各模式保留自己的速度。
  Future<void> toggleAutoScrollMode() async {
    final next = mergedSettings.autoScrollMode == AutoScrollMode.line
        ? AutoScrollMode.continuous
        : AutoScrollMode.line;
    await _setAndSave(overrideData: {'autoScrollMode': next.name});
  }

  /// 更新当前自动模式速度，不把反向速度截断为零。
  Future<void> setAutoSpeed(double speed) async {
    if (!speed.isFinite) return;
    if (mergedSettings.isContinuousScroll) {
      await _setAndSave(overrideData: {'pixelsPerSecond': speed});
    } else {
      await setWpm(speed.round());
    }
  }

  /// 切换镜像模式
  Future<void> toggleMirrorMode() async {
    await _setAndSave(overrideData: {'mirrorMode': !mergedSettings.mirrorMode});
  }

  /// 切换全屏模式
  Future<void> toggleFullScreenMode() async {
    _settings = _settings.copyWith(fullScreenMode: !_settings.fullScreenMode);
    notifyListeners();
    await _saveSettings();
  }

  /// 设置全屏模式
  Future<void> setFullScreenMode(bool value) async {
    _settings = _settings.copyWith(fullScreenMode: value);
    notifyListeners();
    await _saveSettings();
  }

  /// 切换自动隐藏 UI
  Future<void> toggleAutoHideUI() async {
    _settings = _settings.copyWith(autoHideUI: !_settings.autoHideUI);
    notifyListeners();
    await _saveSettings();
  }

  /// 设置自动隐藏延迟
  Future<void> setAutoHideDelay(int seconds) async {
    _settings = _settings.copyWith(autoHideDelaySeconds: seconds);
    notifyListeners();
    await _saveSettings();
  }

  /// 设置 ASR 模型信息
  Future<void> setAsrModel(String id, String name) async {
    _settings = _settings.copyWith(asrModelId: id, asrModelName: name);
    notifyListeners();
    await _saveSettings();
  }

  Future<void> clearAsrModel() => setAsrModel('', '');

  Future<void> setAsrInputDevice(String id, String name) async {
    _settings = _settings.copyWith(
      asrInputDeviceId: id,
      asrInputDeviceName: name,
    );
    notifyListeners();
    await _saveSettings();
  }

  /// 更新主题色
  Future<void> setUiPrimaryColor(int hexColor) async {
    _settings = _settings.copyWith(uiPrimaryColor: hexColor);
    notifyListeners();
    await _saveSettings();
  }

  /// 更新提词器背景色
  Future<void> setTeleprompterBgColor(int hexColor) async {
    await _setAndSave(overrideData: {'teleprompterBgColor': hexColor});
  }

  /// 更新水平边距
  Future<void> setPaddingX(double value) async {
    await _setAndSave(overrideData: {'paddingX': value});
  }

  /// 更新阅读线偏移
  Future<void> setReadingLineOffset(double value) async {
    await _setAndSave(overrideData: {'readingLineOffset': value});
  }

  /// 更新进度条提示字号比例
  Future<void> setProgressInfoSizeRatio(double value) async {
    await _setAndSave(overrideData: {'progressInfoSizeRatio': value});
  }

  /// 更新 ASR 镜像 URL
  Future<void> setAsrMirrorUrl(String url) async {
    _settings = _settings.copyWith(asrMirrorUrl: url);
    notifyListeners();
    await _saveSettings();
  }

  Future<void> setAsrAdvancedParameters({
    required int numThreads,
    required double rule1MinTrailingSilence,
    required double rule2MinTrailingSilence,
    required double rule3MinUtteranceLength,
    required bool useSystemProxy,
  }) async {
    _settings = _settings.copyWith(
      asrNumThreads: numThreads.clamp(0, 64),
      asrRule1MinTrailingSilence: rule1MinTrailingSilence.clamp(0.1, 20),
      asrRule2MinTrailingSilence: rule2MinTrailingSilence.clamp(0.1, 20),
      asrRule3MinUtteranceLength: rule3MinUtteranceLength.clamp(1, 300),
      asrUseSystemProxy: useSystemProxy,
    );
    notifyListeners();
    await _saveSettings();
  }

  /// 更新应用 UI 字体
  Future<void> setAppFontFamily(String fontFamily) async {
    _settings = _settings.copyWith(appFontFamily: fontFamily);
    notifyListeners();
    await _saveSettings();
  }

  /// 更新提词器正文字体
  Future<void> setTeleprompterFontFamily(String fontFamily) async {
    await _setAndSave(overrideData: {'teleprompterFontFamily': fontFamily});
  }

  /// 切换已读字符变灰
  Future<void> toggleGrayReadChars() async {
    await _setAndSave(
      overrideData: {'grayReadChars': !mergedSettings.grayReadChars},
    );
  }

  /// 更新字体颜色
  Future<void> setTextColor(int hexColor) async {
    await _setAndSave(overrideData: {'textColor': hexColor});
  }

  /// 更新字间距
  Future<void> setLetterSpacing(double value) async {
    await _setAndSave(overrideData: {'letterSpacing': value});
  }

  /// 切换当前字高亮
  Future<void> toggleHighlightCurrentChar() async {
    await _setAndSave(
      overrideData: {
        'highlightCurrentChar': !mergedSettings.highlightCurrentChar,
      },
    );
  }

  /// 切换默认加粗
  Future<void> toggleDefaultBold() async {
    await _setAndSave(
      overrideData: {'defaultBold': !mergedSettings.defaultBold},
    );
  }

  /// 切换当前字下划线
  Future<void> toggleUnderlineCurrentChar() async {
    await _setAndSave(
      overrideData: {
        'underlineCurrentChar': !mergedSettings.underlineCurrentChar,
      },
    );
  }

  /// 更新阅读区域框边框粗细
  Future<void> setReadingAreaBorderWidth(double value) async {
    await _setAndSave(overrideData: {'readingAreaBorderWidth': value});
  }

  /// 切换进度条显示 - 已用时间
  Future<void> toggleProgressShowTime() async {
    await _setAndSave(
      overrideData: {'progressShowTime': !mergedSettings.progressShowTime},
    );
  }

  /// 切换进度条显示 - 进度百分比
  Future<void> toggleProgressShowPercentage() async {
    await _setAndSave(
      overrideData: {
        'progressShowPercentage': !mergedSettings.progressShowPercentage,
      },
    );
  }

  /// 切换进度条显示 - 滚动速度
  Future<void> toggleProgressShowSpeed() async {
    await _setAndSave(
      overrideData: {'progressShowSpeed': !mergedSettings.progressShowSpeed},
    );
  }

  /// 切换进度条显示 - 当前时间
  Future<void> toggleProgressShowCurrentTime() async {
    await _setAndSave(
      overrideData: {
        'progressShowCurrentTime': !mergedSettings.progressShowCurrentTime,
      },
    );
  }

  /// 更新设备共用的快速模式设置。
  Future<void> setQuickMode({
    bool? enabled,
    bool? autoSave,
    String? folderId,
  }) async {
    _settings = _settings.copyWith(
      quickModeEnabled: enabled,
      quickModeAutoSave: autoSave,
      quickModeFolderId: folderId,
    );
    notifyListeners();
    await _saveSettings();
  }

  Future<void> setAppBrightnessMode(AppBrightnessMode mode) async {
    _settings = _settings.copyWith(appBrightnessMode: mode);
    notifyListeners();
    await _saveSettings();
  }

  /// 完全重置所有设置为默认值
  Future<void> resetAllSettings() async {
    _settings = const AppSettings();
    notifyListeners();
    try {
      if (_connection != null && _connection!.isConnected) {
        _connection!.request(WsMessageType.settingsReset);
      }
    } catch (e) {
      debugPrint('[SettingsProvider] 重置设置失败: $e');
    }
  }

  /// 批量更新设置
  Future<void> updateSettings(AppSettings newSettings) async {
    _settings = newSettings;
    notifyListeners();
    await _saveSettings();
  }

  @override
  void dispose() {
    if (_connection != null && _connectionListener != null) {
      _connection!.removeListener(_connectionListener!);
    }
    super.dispose();
  }
}

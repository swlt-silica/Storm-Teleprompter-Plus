part of '../teleprompter_page.dart';

/// 提词器页面逻辑 mixin
///
/// 包含全屏控制、滚轮调速、滚动进度和会话退出等页面逻辑。
mixin TeleprompterPageLogic<T extends StatefulWidget>
    on State<T>, WidgetsBindingObserver {
  final ScrollController scrollController = ScrollController();
  final GlobalKey<TeleprompterTextLayerState> textLayerKey =
      GlobalKey<TeleprompterTextLayerState>();
  bool isFullScreen = false;

  TeleprompterProvider? _teleprompterProvider;
  SettingsProvider? _settingsProvider;
  ConnectionProvider? _connectionProvider;
  _WindowEventListener? _windowListener;
  bool _remoteSessionEndSent = false;
  bool _viewportProgressUpdateScheduled = false;
  double? _pendingViewportProgress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _teleprompterProvider = context.read<TeleprompterProvider>();
    _settingsProvider = context.read<SettingsProvider>();
    _connectionProvider = context.read<ConnectionProvider>();
    _setupScrollListener();

    // 本机稿件只用设备共享设置；远端稿件携带主端的会话快照。
    // 远端切稿先退出旧页面，其 dispose 会清掉临时设置，故此处重新应用
    // 新会话快照。连接重试时同样保留这份快照，避免回退本机配置。
    final connection = _connectionProvider!;
    if (!connection.isRemote && !connection.canRetryRemoteConnection) {
      _settingsProvider!.useSharedTeleprompterSettings(notify: false);
    } else {
      final sessionSettings =
          (widget as TeleprompterPage).article.teleprompterSettings;
      if (sessionSettings != null) {
        _settingsProvider!.applyRemoteTeleprompterSettings(
          sessionSettings,
          notify: false,
        );
      }
    }

    // 监听窗口最大化/还原事件，确保标题栏正确显示
    if (_isDesktop) {
      _initWindowListener();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = _settingsProvider!.mergedSettings;
      // 自动进入全屏
      if (settings.fullScreenMode) {
        enterFullScreen();
      }
    });
  }

  /// 初始化窗口事件监听
  void _initWindowListener() async {
    try {
      await windowManager.ensureInitialized();
      _windowListener = _WindowEventListener(this);
      windowManager.addListener(_windowListener!);
    } catch (e) {
      debugPrint('[WindowListener] 初始化失败: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_windowListener != null) {
      windowManager.removeListener(_windowListener!);
    }
    // 退出时若为全屏则退出，但需避免在 dispose 中调用 setState
    if (isFullScreen) {
      unawaited(exitFullScreen(updateState: false));
    }
    _sendRemoteSessionEndIfMaster();
    // 退出只清除远端会话的临时显示配置，不修改本机共享设置。
    _settingsProvider?.clearRemoteTeleprompterSettings(notify: false);
    scrollController.dispose();
    // 退出时停止提词器（不触发 notifyListeners，避免 defunct 异常）
    _teleprompterProvider?.stopAll();
    super.dispose();
  }

  Map<String, dynamic> _sessionEndData() {
    return {'articleId': (widget as TeleprompterPage).article.id};
  }

  bool _canEndRemoteSession(ConnectionProvider connection) {
    return !_remoteSessionEndSent &&
        connection.isLocal &&
        connection.isConnected;
  }

  void _sendRemoteSessionEndIfMaster() {
    final connection = _connectionProvider;
    if (connection == null) return;
    if (!_canEndRemoteSession(connection)) return;
    _remoteSessionEndSent = true;
    connection.send(
      WsMessage(
        type: WsMessageType.teleprompterEndSession,
        data: _sessionEndData(),
      ),
    );
  }

  Future<void> _endRemoteSessionIfMaster() async {
    final connection = _connectionProvider;
    if (connection == null) return;
    if (!_canEndRemoteSession(connection)) return;
    _remoteSessionEndSent = true;
    try {
      await connection.request(
        WsMessageType.teleprompterEndSession,
        data: _sessionEndData(),
        timeout: const Duration(seconds: 2),
      );
    } catch (e) {
      debugPrint('[TeleprompterLogic] 结束远程会话确认失败: $e');
      connection.send(
        WsMessage(
          type: WsMessageType.teleprompterEndSession,
          data: _sessionEndData(),
        ),
      );
    }
  }

  // ─── 全屏控制 ──────────────────────────────────────────

  bool get _isDesktop {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  Future<void> enterFullScreen() async {
    if (isFullScreen) return;
    if (mounted) setState(() => isFullScreen = true);

    if (_isDesktop) {
      try {
        // 先隐藏标题栏，再进入全屏，顺序很重要
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
        await Future.delayed(const Duration(milliseconds: 50));
        await windowManager.setFullScreen(true);
      } catch (e) {
        debugPrint('[FullScreen] 全屏失败，降级处理: $e');
        // 降级：仅隐藏标题栏
        try {
          await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
        } catch (_) {}
        try {
          await windowManager.setFullScreen(true);
        } catch (_) {}
      }
    } else if (!kIsWeb) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  Future<void> exitFullScreen({bool updateState = true}) async {
    if (!isFullScreen && updateState) return;
    if (updateState && mounted) {
      setState(() => isFullScreen = false);
    } else {
      isFullScreen = false;
    }

    if (_isDesktop) {
      try {
        await windowManager.setFullScreen(false);
        await Future.delayed(const Duration(milliseconds: 50));
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      } catch (e) {
        debugPrint('[FullScreen] 退出全屏失败: $e');
      }
    } else if (!kIsWeb) {
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }

  void toggleFullScreen() {
    if (isFullScreen) {
      exitFullScreen();
    } else {
      enterFullScreen();
    }
  }

  // ─── 鼠标滚轮处理 ─────────────────────────────────────

  void handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;

    final teleprompter = context.read<TeleprompterProvider>();
    final settingsProvider = context.read<SettingsProvider>();
    final settings = settingsProvider.mergedSettings;
    if (context.read<ConnectionProvider>().isRemote) return;

    if (settings.scrollMode == ScrollMode.auto &&
        teleprompter.isPlaying &&
        (settings.isContinuousScroll || settings.autoSpeed != 0)) {
      // 自动模式：滚轮只调速，不滚动页面
      teleprompter.adjustSpeedByWheel(
        event.scrollDelta.dy,
        settingsProvider,
        stepMultiplier: _speedStepMultiplier(),
      );
      return;
    }

    if (settings.scrollMode == ScrollMode.auto &&
        teleprompter.isPlaying &&
        settings.autoSpeed == 0) {
      if (_speedModifierPressed()) {
        teleprompter.adjustSpeedByWheel(
          event.scrollDelta.dy,
          settingsProvider,
          stepMultiplier: _speedStepMultiplier(),
        );
        return;
      }

      final direction = event.scrollDelta.dy > 0 ? 1 : -1;
      final visualTarget = textLayerKey.currentState?.rawIndexForVisualLineMove(
        direction,
      );
      if (visualTarget != null) {
        teleprompter.setCurrentIndex(visualTarget);
      }
      return;
    }

    // 手动/ASR 模式：让滚动自然传播
  }

  int _speedStepMultiplier() {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed) return 10;
    if (keyboard.isShiftPressed) return 4;
    return 1;
  }

  bool _speedModifierPressed() {
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isControlPressed || keyboard.isShiftPressed;
  }

  // ─── 手动滚动进度更新 ──────────────────────────────────

  void _setupScrollListener() {
    scrollController.addListener(_onScrollChanged);
  }

  void _onScrollChanged() {
    if (!mounted) return;
    if (!scrollController.hasClients) return;
    final maxScroll = scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) return;
    if (context.read<SettingsProvider>().mergedSettings.isContinuousScroll) {
      _scheduleViewportProgressUpdate(scrollController.offset / maxScroll);
      return;
    }
    // 扣除空气垫计算实际内容进度
    final screenHeight = MediaQuery.of(context).size.height;
    final topPad = screenHeight * (TeleprompterConstants.topPaddingVh / 100);
    final bottomPad =
        screenHeight * (TeleprompterConstants.bottomPaddingVh / 100);
    final contentExtent = maxScroll - topPad - bottomPad;
    if (contentExtent <= 0) {
      _scheduleViewportProgressUpdate(0.0);
      return;
    }
    final contentOffset = (scrollController.offset - topPad).clamp(
      0.0,
      contentExtent,
    );
    final progress = (contentOffset / contentExtent).clamp(0.0, 1.0);
    _scheduleViewportProgressUpdate(progress);
  }

  void _scheduleViewportProgressUpdate(double progress) {
    _pendingViewportProgress = progress;
    if (_viewportProgressUpdateScheduled) return;
    _viewportProgressUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportProgressUpdateScheduled = false;
      if (!mounted) return;
      final value = _pendingViewportProgress;
      _pendingViewportProgress = null;
      if (value == null) return;
      context.read<TeleprompterProvider>().setViewportProgress(value);
    });
  }

  // ─── 格式化工具 ────────────────────────────────────────

  String formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  /// 当前时间格式化 (HH:mm)
  String _formatCurrentTime() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }
}

/// 窗口事件监听器（用于最大化/还原时恢复标题栏）
class _WindowEventListener extends WindowListener {
  final TeleprompterPageLogic state;

  _WindowEventListener(this.state);

  @override
  void onWindowMaximize() {
    if (!state.isFullScreen) {
      windowManager.setTitleBarStyle(TitleBarStyle.normal);
    }
  }

  @override
  void onWindowUnmaximize() {
    if (!state.isFullScreen) {
      windowManager.setTitleBarStyle(TitleBarStyle.normal);
    }
  }
}

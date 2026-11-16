import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/app_settings.dart';
import '../../models/floating_overlay_settings.dart';
import '../../providers/settings_provider.dart';
import '../../services/overlay/floating_teleprompter_bridge.dart';
import '../../services/overlay/floating_teleprompter_controller.dart';

Future<void> showFloatingOverlaySheet(
  BuildContext context, {
  required FloatingTeleprompterController controller,
  required SettingsProvider settings,
  required Future<void> Function() prepareOrientation,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => FloatingOverlaySheet(
    controller: controller,
    settings: settings,
    prepareOrientation: prepareOrientation,
  ),
);

/// 沿用应用现有颜色和 Material 控件，只添加悬浮提词所需的中文配置。
class FloatingOverlaySheet extends StatefulWidget {
  const FloatingOverlaySheet({
    super.key,
    required this.controller,
    required this.settings,
    required this.prepareOrientation,
  });

  final FloatingTeleprompterController controller;
  final SettingsProvider settings;
  final Future<void> Function() prepareOrientation;

  @override
  State<FloatingOverlaySheet> createState() => _FloatingOverlaySheetState();
}

class _FloatingOverlaySheetState extends State<FloatingOverlaySheet>
    with WidgetsBindingObserver {
  late FloatingOverlaySettings _options;
  FloatingOverlayStatus? _status;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _options = widget.settings.settings.floatingOverlay;
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_controllerChanged);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_controllerChanged);
    super.dispose();
  }

  void _controllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final status = await widget.controller.bridge.status();
      if (mounted) setState(() => _status = status);
    } catch (error) {
      if (mounted) setState(() => _error = floatingOverlayError(error));
    }
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = floatingOverlayError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() => widget.settings.setFloatingOverlay(_options);

  Future<void> _start({required bool camera}) => _run(() async {
    await _save();
    await widget.prepareOrientation();
    await widget.controller.start(openCamera: camera);
    if (mounted && widget.controller.active) Navigator.pop(context);
  });

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final appSettings = widget.settings.mergedSettings;
    final voice = appSettings.scrollMode == ScrollMode.asr;
    final continuous = appSettings.isContinuousScroll;
    final permissionReady =
        _status?.overlayPermission == true &&
        (!voice ||
            (_status?.microphonePermission == true &&
                _status?.accessibilityEnabled == true));
    final canStart =
        permissionReady &&
        !_busy &&
        !controller.starting &&
        !controller.controlLocked &&
        !continuous &&
        (!voice || appSettings.asrModelId.isNotEmpty) &&
        controller.scriptText.text.trim().isNotEmpty;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.9,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          20 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '悬浮提词',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '关闭设置',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text('将台词叠在手机相机上，自拍时同时查看人脸和台词。'),
            const SizedBox(height: 20),
            _preview(context),
            const SizedBox(height: 20),
            _slider(
              '悬浮字号',
              '${_options.fontSize.round()}',
              _options.fontSize,
              18,
              100,
              (value) => _options.copyWith(fontSize: value),
            ),
            _slider(
              '背景不透明度',
              '${(_options.backgroundOpacity * 100).round()}%',
              _options.backgroundOpacity,
              0,
              1,
              (value) => _options.copyWith(backgroundOpacity: value),
            ),
            _slider(
              '窗口宽度',
              '${(_options.widthFraction * 100).round()}%',
              _options.widthFraction,
              0.35,
              1,
              (value) => _options.copyWith(widthFraction: value),
            ),
            _slider(
              '窗口高度',
              '${(_options.heightFraction * 100).round()}%',
              _options.heightFraction,
              0.18,
              0.8,
              (value) => _options.copyWith(heightFraction: value),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('左右镜像'),
              subtitle: const Text('使用分光镜提词器时开启'),
              value: _options.mirror,
              onChanged: _busy
                  ? null
                  : (value) {
                      setState(
                        () => _options = _options.copyWith(mirror: value),
                      );
                      unawaited(_save());
                    },
            ),
            const SizedBox(height: 16),
            const Text(
              '使用权限',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            _permission(
              title: '显示在其他应用上层',
              description: '允许台词显示在手机相机上方',
              granted: _status?.overlayPermission,
              button: '去授权',
              onPressed: () =>
                  _run(widget.controller.bridge.requestOverlayPermission),
            ),
            if (voice) ...[
              _permission(
                title: '麦克风',
                description: '仅在语音跟读时采集声音，本地识别台词',
                granted: _status?.microphonePermission,
                button: '允许',
                onPressed: () => _run(() async {
                  final granted = await controller.bridge
                      .requestMicrophonePermission();
                  if (!granted) {
                    throw StateError('麦克风权限未获允许，可在系统应用权限中开启');
                  }
                }),
              ),
              if (_status?.microphonePermission == false)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(controller.bridge.openAppSettings),
                    child: const Text('打开应用权限设置'),
                  ),
                ),
              _permission(
                title: '录像时保持语音跟读',
                description:
                    '请在无障碍设置中启用“飓风提词器：相机悬浮跟读”。服务不读取屏幕内容，用于相机录像时保持语音输入。'
                    '${(_status?.androidSdk ?? 0) >= 33 ? 'Android 13 及以上若开关受限，可在应用信息中查看“允许受限设置”。' : ''}'
                    '不同手机仍需实测兼容性。',
                granted: _status?.accessibilityEnabled,
                button: '去开启',
                onPressed: () =>
                    _run(controller.bridge.openAccessibilitySettings),
              ),
            ],
            _permission(
              title: '悬浮提词通知（可选）',
              description: '显示运行状态，并可从通知中停止提词',
              granted: _status?.notificationPermission,
              button: '允许',
              onPressed: () => _run(() async {
                await controller.bridge.requestNotificationPermission();
              }),
            ),
            if (_status?.isMiuiDevice == true) ..._miuiSettings(controller),
            if (continuous) ...[
              const SizedBox(height: 12),
              const Text('像素匀速滚动依赖页面绘制，暂不用于悬浮窗。可明确切换为按字自动滚动，或返回选择语音模式。'),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await widget.settings.toggleAutoScrollMode();
                          controller.teleprompter.refreshAutoScrollSettings(
                            widget.settings.mergedSettings,
                          );
                          setState(() {});
                        }),
                  child: const Text('切换为按字自动滚动'),
                ),
              ),
            ],
            if (voice && appSettings.asrModelId.isEmpty) ...[
              const SizedBox(height: 12),
              const Text('尚未选择语音模型，请先返回应用设置下载并选择模型。'),
            ],
            if (controller.controlLocked) ...[
              const SizedBox(height: 12),
              const Text('请在本机服务端模式下使用悬浮提词。远程连接中不提供本机播放控制。'),
            ],
            if (_error != null || controller.lastError != null) ...[
              const SizedBox(height: 12),
              Text(
                _error ?? controller.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: canStart ? () => _start(camera: true) : null,
              icon: _busy || controller.starting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.videocam_outlined),
              label: Text(controller.starting ? '正在准备语音跟读…' : '悬浮提词并打开相机'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: canStart ? () => _start(camera: false) : null,
              child: const Text('只显示悬浮窗'),
            ),
            if (controller.active)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => controller.stop(pause: true)),
                child: const Text('停止悬浮提词'),
              ),
            const SizedBox(height: 12),
            const Text(
              '打开相机后可手动切换前置镜头。拖动窗口调整位置，锁定后可穿透操作相机；点击解锁按钮恢复窗口操作。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider(
    String label,
    String value,
    double current,
    double min,
    double max,
    FloatingOverlaySettings Function(double) update,
  ) => Column(
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(value),
        ],
      ),
      Slider(
        label: value,
        value: current.clamp(min, max),
        min: min,
        max: max,
        onChanged: _busy
            ? null
            : (value) => setState(() => _options = update(value)),
        onChangeEnd: _busy ? null : (_) => unawaited(_save()),
      ),
    ],
  );

  List<Widget> _miuiSettings(FloatingTeleprompterController controller) {
    final status = _status!;
    final device = [
      status.deviceManufacturer,
      status.deviceModel,
    ].where((part) => part.trim().isNotEmpty).join(' ');
    return [
      const SizedBox(height: 20),
      const Text(
        'MIUI 运行权限',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      if (device.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text('当前设备：$device', style: const TextStyle(fontSize: 12)),
      ],
      const SizedBox(height: 8),
      const Text(
        '切到相机后台词消失、返回应用按钮无反应或跟读停止时，请检查以下设置。菜单名称可能随系统版本不同；应用无法读取这些厂商权限是否已开启。',
        style: TextStyle(fontSize: 12),
      ),
      _vendorSetting(
        title: '悬浮窗与后台弹出界面',
        description: '在其他权限中允许“显示悬浮窗”和“后台弹出界面”，以便相机上显示台词并返回提词器。',
        action: controller.bridge.openVendorPermissions,
      ),
      _vendorSetting(
        title: '自启动',
        description: '按需允许应用自启动，减少系统限制后台运行。此设置不会让提词器自动开始录音。',
        action: controller.bridge.openAutoStartSettings,
      ),
      _vendorSetting(
        title: '省电策略',
        description: status.batteryOptimizationExempt == true
            ? '系统电池优化已豁免；MIUI 的应用省电策略仍需手动确认“无限制”。'
            : '将本应用的省电策略设为“无限制”，避免切换相机后暂停跟读。',
        action: controller.bridge.openBatterySettings,
      ),
    ];
  }

  Widget _vendorSetting({
    required String title,
    required String description,
    required Future<void> Function() action,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Text(description, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        TextButton(
          onPressed: _busy ? null : () => _run(action),
          child: const Text('去检查'),
        ),
      ],
    ),
  );

  Widget _permission({
    required String title,
    required String description,
    required bool? granted,
    required String button,
    required VoidCallback onPressed,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Text(description, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        if (granted == true)
          const Padding(padding: EdgeInsets.only(top: 10), child: Text('已允许'))
        else
          TextButton(
            onPressed: _busy || granted == null ? null : onPressed,
            child: Text(granted == null ? '检查中' : button),
          ),
      ],
    ),
  );

  Widget _preview(BuildContext context) {
    final text = widget.controller.scriptText.text.trim();
    final display = text.isEmpty ? '请先填写台词' : text;
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('台词效果预览', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.topCenter,
            child: FractionallySizedBox(
              widthFactor: _options.widthFraction,
              child: Container(
                color: Colors.black.withValues(
                  alpha: _options.backgroundOpacity,
                ),
                padding: const EdgeInsets.all(12),
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(0, 0, _options.mirror ? -1.0 : 1.0),
                  child: Text(
                    display,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _options.fontSize,
                      color: Colors.white,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

# 系统入口

| 部分 | 位置与职责 |
| --- | --- |
| 安卓壳 | `android/app/src/main/`：FlutterActivity、权限、原生悬浮窗和运行服务 |
| 提词页面 | `lib/pages/teleprompter_page.dart`：全屏与悬浮入口、页面生命周期 |
| 提词状态 | `lib/providers/teleprompter_provider.dart`：播放、当前位置、前后移动与识别结果 |
| 设置 | `lib/models/app_settings.dart`、`lib/providers/settings_provider.dart`：设置持久化与稿件覆盖 |
| 语音会话 | `lib/backend/asr_session_service.dart`：识别会话与回读位置广播 |
| 音频采集 | `lib/services/asr/asr_service_native.dart`：record PCM 音频流与 sherpa-onnx |
| 自动化验证 | `test/`、`.github/workflows/`：测试与安卓构建 |

新增的安卓跨应用悬浮窗与 Flutter 通道复用现有提词会话，不再建立第二套稿件库或识别器。

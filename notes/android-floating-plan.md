# 安卓悬浮提词实施记录

## 已授权范围

用户要求将 `html5syt/Storm-Teleprompter-Plus` fork 到自己的 GitHub，增加此前讨论的 Suflyor 同类屏幕悬浮功能，相关设置中文化。

目标场景：OPPO 手机打开系统相机自拍时，透过半透明台词窗看见人脸，并继续按朗读进度提词。保留飓风现有全屏、镜像、稿件管理与备份功能。

采用原生 Android 悬浮窗与 Flutter 会话桥接，在 MIT 项目中独立实现，不复制 GPL 的 Suflyor 源码。服务器备份同步未纳入本次请求。

## 阶段与验收

- [x] 读取上游、确认账号与许可证，fork 到 `swlt-silica/Storm-Teleprompter-Plus`。
- [x] 检查已有实现：没有安卓跨应用悬浮服务；已有语音识别、回读定位、设置持久化与备份。
- [x] 实现 Android 悬浮窗、中文控制、透明度/字号/大小/镜像、拖动与锁定穿透。
- [x] 接入 Flutter 会话：显示实际稿件和当前位置，支持播放暂停、前后移动和关闭，正确处理权限与错误。
- [ ] 验证后台运行与退出：静态与模拟会话检查通过；前台通知停止、无障碍无内容读取、任务退出清理已实现，实际安卓行为待验。
- [x] 完成格式、分析、自动化测试与 Android ARM64 构建；记录未能实测的条件。
- [x] 推送修改，交付仓库、可安装 APK 与中文使用说明。

## 验证边界

本机初始无 Flutter/Java/Android SDK。构建工具在任务工作目录或 GitHub Actions 中运行，不切换用户窗口。

OPPO 真机的相机并发麦克风、厂商后台管理策略需要用户安装后验证，不能以编译通过替代。

## 已取得的验证结果

- 本地 Flutter 3.44.1 / Dart 3.12.1，按上游锁文件安装依赖，没有升级依赖。
- `flutter analyze --no-pub` 无问题；完整 `flutter test --no-pub` 126 项通过。
- 中文设置页在 390 和 850 逻辑像素宽度无溢出，使用真实中文字体生成两张 widget 截图并目视检查。
- XML 解析与差异空白检查通过；本地和 GitHub Actions 的 Android Release APK 均构建成功，签名验证通过。
- 已验证源码提交 `21fd25c5107cf912accaef1b6b2197d47d4299d5`：[成功构建](https://github.com/swlt-silica/Storm-Teleprompter-Plus/actions/runs/43791631057)。后续本文件的状态更新不修改应用源码。
- [改动 PR](https://github.com/swlt-silica/Storm-Teleprompter-Plus/pull/1) 提供审阅；APK、签名/校验信息与中文说明交付至任务 `outputs/`。

## 待真机验收

后台窗口和音频会话已实现关闭/错误/任务退出清理，自动化会话测试通过；实际 OPPO 自拍录像时是否持续跟读、视频声音、锁定穿透和系统通知清理仍需用户安装后验证，因此第三项不以编译成功代替勾选。

GitHub CLI 已补充用户授权的 workflow 权限。原生悬浮功能独立实现，没有沿用 Suflyor GPL 代码。签名材料仅存任务 `work/private/` 受限文件及 Fork 的 Actions Secrets，未进入仓库；未经用户许可不清理。

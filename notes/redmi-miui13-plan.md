# Redmi Note 11T Pro / MIUI 13 适配记录

## 请求与边界

用户提供设备 Redmi Note 11T Pro、系统 MIUI 13.0.14，要求再提供可安装版本。已有 ARM64 悬浮版继续作为基础，同包名和同签名更新以保留数据。既有 APK 保留。

本次增加小米/Redmi 的厂商设置入口与中文说明。设备和 Android SDK 从手机运行时读取；不把用户提供的 MIUI 版本当作已经探测到的系统值。MIUI 私有权限不可可靠查询，因此不显示虚假的“已授权”。

## 验收清单

- [x] 检查既有包：支持 ARM64、Android API 24 及以上；已有中文悬浮窗和语音跟读。
- [x] 原生提供 MIUI 权限、自启动和省电设置入口，并处理不存在的页面及授权拒绝。
- [x] 中文设置根据实际厂商显示 MIUI 指引，普通设备保持通用权限引导；Android 12 不套用 Android 13 的受限设置说明。
- [ ] 增加 MIUI 显示与入口调用测试，通过分析、测试及 APK 编译。
- [ ] 提供仅含目标 ARM64 库的签名 APK，检查包名、最低系统、版本号、签名和校验值。
- [ ] 推送源码和更新现有 PR，交付中文 MIUI 使用说明。

## 真机验证

尚未连接用户 Redmi，安装、系统相机录像与麦克风同时采集、MIUI 后台管理行为仍需该设备验收。不会以打包成功宣称已真机适配通过。

## 公开组件协议依据

厂商私有页面可能随 ROM 变动，所有入口均需逐级回退到应用信息或通用设置。以下公开代码仅用于核对组件名与 Intent extra，未复制实现：

- [AnkiDroid AdaptionUtil](https://github.com/ankidroid/Anki-Android/blob/main/anki-common/src/main/kotlin/com/ichi2/anki/common/android/AdaptionUtil.kt)：MIUI 自启动管理页。
- [HelloDaemon IntentWrapper](https://github.com/xingda920813/HelloDaemon/blob/master/hellodaemon/src/main/java/com/xdandroid/hellodaemon/IntentWrapper.java)：MIUI 应用省电页和 package_name/package_label。
- [AutoJs6 XiaomiBackgroundPopupPermission](https://github.com/SuperMonster003/AutoJs6/blob/master/app/src/main/java/org/autojs/autojs/permission/XiaomiBackgroundPopupPermission.kt)：MIUI 权限编辑页候选名。

## 已完成验证

- Flutter 静态分析无问题，完整 131 项测试通过（MIUI 新增 5 项）。
- 真实中文字体、390 逻辑像素设置页截图已目视检查，无溢出；图中的设备状态为测试输入，不是真机读取结果。
- Manifest XML 和差异空白检查通过；下一步为最终签名构建与产物核对。

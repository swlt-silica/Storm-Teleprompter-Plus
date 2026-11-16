# 安卓悬浮提词构建与验收

悬浮提词分支使用 `.github/workflows/overlay-android.yml`，在
`feature/android-floating-prompter` 分支推送或手动运行时执行：

1. 从 Flutter 官方仓库的 `3.44.1` 标签安装 SDK，并安装 Java 17。
2. 使用锁文件记录的包源 `https://pub.flutter-io.cn`，执行
   `flutter pub get --enforce-lockfile`，再运行 `flutter analyze --no-pub`
   和 `flutter test --no-pub`。
3. 使用本 Fork 独立的签名密钥构建 ARM64 Release APK。
4. 验证 APK 签名，保存 SHA-256 校验值和包含提交号的构建信息。

此工作流只上传构建产物，不创建 GitHub Release。可在运行记录的
Artifacts 中下载 `storm-floating-arm64-<完整提交号>`。解压后，安装
`storm-floating-<短提交号>-arm64.apk`；`build.json` 记录构建来源，
`signature.txt` 记录签名证书信息，`SHA256SUMS.txt` 用于校验文件完整性。

## 签名要求

在 Fork 的 Actions Secrets 配置以下四项，工作流不会使用原作者的私钥：

| Secret | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | 本 Fork 的 JKS 密钥库的 Base64 内容 |
| `ANDROID_KEYSTORE_PASSWORD` | 密钥库密码 |
| `ANDROID_KEY_ALIAS` | 签名密钥别名 |
| `ANDROID_KEY_PASSWORD` | 签名密钥密码 |

工作流缺少任一项时会失败，避免误把每次变化的 Debug 签名当成正式签名。
密钥只解码到临时目录，配置文件权限为仅当前用户可读写，运行结束后删除。
密钥不得提交到仓库。请保留密钥库和密码的有效备份；后续覆盖安装需要相同签名。

本 Fork 使用独立应用 ID `work.swlt.stormteleprompter`，可与原作者版本并存，
两者的数据目录独立。需要迁移稿件时，在原版导出完整备份，再在本 Fork 中恢复；
后续本 Fork 的覆盖更新必须保留相同签名。

## 本机构建

需要 Flutter 3.44.1、Java 17、Android SDK。在本地创建不提交到 Git 的
`android/key.properties`，填入本 Fork 密钥库的实际路径和凭据：

```properties
storeFile=/绝对路径/storm-overlay.jks
storePassword=密钥库密码
keyAlias=密钥别名
keyPassword=密钥密码
```

密钥库放在仓库外的私密目录。下载 SDK 时，若版本索引不可用，可直接从官方标签
获取；该方式也是 CI 的安装方式：

```sh
git clone --depth 1 --branch 3.44.1 https://github.com/flutter/flutter.git /你的工具目录/flutter
/你的工具目录/flutter/bin/flutter --version
```

```sh
export PUB_HOSTED_URL=https://pub.flutter-io.cn
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --release --no-pub --split-per-abi --target-platform android-arm64 \
  --dart-define=APP_VERSION=overlay-local
```

本次改动不需要升级依赖。不要通过 `flutter pub upgrade` 或切换到另一包源来
重写 `pubspec.lock`；构建使用 `--no-pub`，防止再次自动解析依赖。

只有在 `android/key.properties` 或对应环境变量配置了有效 Release 签名时，
本地构建才使用该密钥；原有 Gradle 配置在未配置时会退回 Debug 签名，不能将
此类包用于长期更新。CI 已强制检查四项签名配置。

## 真机验收边界

CI 的静态检查、单元测试和 APK 构建不能证明 OPPO 或 Redmi 系统相机与提词器可以同时获取
麦克风。发布前需要在目标手机上验证以下实际操作：

- 允许相应权限后，打开自拍相机，确认人脸和台词同时可见。
- 改变悬浮背景透明度、字号、窗口位置和大小，检查文字不被截断。
- 暂停、继续、前后移动和重读回退都与当前稿件位置一致。
- 锁定后能点击相机录制按钮，且始终有办法解锁或关闭悬浮窗。
- 录像时语音跟读持续工作，并且录制的视频保留声音。
- 停止悬浮、退出提词和清除任务后，窗口及前台通知能够正确关闭。

涉及打开系统设置、相机或切换窗口的真机测试需要用户明确允许，不能在用户当前
操作中自动触发。

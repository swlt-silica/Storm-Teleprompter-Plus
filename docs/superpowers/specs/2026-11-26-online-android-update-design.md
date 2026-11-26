# Android 在线更新设计

## 意图

让 Android 用户在发现 GitHub 新 Release 后，点击“立即更新”即可由应用下载对应 APK，并调起系统安装界面。更新过程需要显示进度，下载失败或设备无法安装时保留 Release 页面入口。

## 目标

- 复用现有启动检查和“关于 → 检查更新”入口。
- 从 GitHub 最新 Release 的附件中选择 ARM64 APK。
- 下载到应用临时目录，显示下载进度并避免把完整 APK 一次性读入内存。
- 使用 Release API 返回的 SHA-256 digest 校验下载文件。
- 通过 Android `FileProvider` 和安装 Intent 调起系统安装界面。
- 安装完成前保留旧版本运行，网络失败时不影响提词器使用。
- 桌面平台继续使用浏览器打开 Release 页面。

## 非目标

- 不在应用内执行静默安装。
- 不绕过 Android 的未知来源安装确认。
- 不实现应用商店分发或后台自动下载。
- 不改变 Release 创建和上传流程。每次发布仍需上传完整安装包和各平台发布物。

## 约束

- 当前应用使用 `APP_VERSION` 作为正式版本比较值。
- 当前 Android 发布物为 ARM64 APK，命名格式包含 `arm64` 并以 `.apk` 结尾。
- GitHub API 的最新 Release 接口返回 Release 页面地址和附件下载地址。
- 应用已有 `http`、`path_provider`、`url_launcher` 和 MethodChannel 使用方式。
- Android 安装包必须沿用既有签名，否则系统无法覆盖安装。

## 方案

### 方案一，应用下载并直接调起 Android 安装器

应用读取 Release 附件，流式下载 APK 到临时目录，使用 SHA-256 校验后，通过原生 Android `ACTION_VIEW` 搭配 `FileProvider` 打开系统安装器。实现跨 Dart 和 Android 原生边界，但更新路径最短，错误可控，符合用户“点更新后直接安装”的目标。本次采用此方案。

### 方案二，下载后交给系统文件管理器

应用只负责下载文件，再用通用文件打开接口交给文件管理器。不同厂商的文件管理器对 APK MIME 类型和权限处理差异较大，用户还需要额外找到并点击安装，体验和可验证性较差。

### 方案三，只打开 Release 页面

复用现有逻辑，改动最小，但用户仍需手动定位附件、下载和安装，不能完成在线更新目标。

## 设计

### Release 数据

扩展 `GitHubReleaseInfo` 保存 APK 附件集合。解析 `browser_download_url`、文件大小和可选 `digest`。选择名称包含 `arm64` 或 `arm64-v8a` 且扩展名为 `.apk` 的附件。没有匹配附件时，更新弹窗显示 Release 页面入口。

### 下载和校验

新增更新下载服务，接收 Release 附件和下载目录。使用 `http.Client.send` 流式写入临时文件，按已接收字节计算进度。下载完成后比较 GitHub digest 中的 SHA-256。校验失败删除临时文件并提示更新失败。下载过程支持取消，取消后删除临时文件。

### Android 安装

新增更新 MethodChannel。Android 原生侧注册 `FileProvider`，通过 `res/xml/file_paths.xml` 只共享应用缓存目录。Dart 传入 APK 文件路径，原生侧生成 content URI，设置 APK MIME 类型和临时读权限，调用安装 Intent。Manifest 增加安装请求权限和 Provider 声明。

### 用户界面

- 启动检查发现新版本后，按钮显示“立即更新”。
- 点击后显示下载进度和当前文件大小。
- 下载成功后立即调起安装器。
- 下载或安装失败时显示错误原因，并提供“打开 Release”入口。
- “关于”页面复用同一更新服务和交互。桌面端直接打开 Release 页面。
- 保留“稍后更新”和“忽略本次更新”。

### 测试

- Release 服务解析 ARM64 APK 附件和 digest。
- 缺少 APK 附件时能够回退到 Release 页面。
- 下载服务正确报告进度，校验成功后返回文件，digest 不匹配时失败并清理文件。
- 更新弹窗在下载期间显示进度，完成后触发安装流程，失败后保留 Release 入口。
- Android Manifest 和 Provider 配置包含必要声明。
- 运行完整 Flutter 测试、静态分析和 Android release 构建。

## 实施决定

- 版本检查继续使用 GitHub `releases/latest`，只处理最新正式 Release。
- APK 下载文件放在缓存目录，避免把临时安装包加入应用备份。
- 下载安装完成后由系统负责安装确认和覆盖升级。
- 更新失败不阻塞启动，不改变稿件、模型和提词状态。

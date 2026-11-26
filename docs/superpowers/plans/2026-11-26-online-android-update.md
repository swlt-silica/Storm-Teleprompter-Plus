# Android Online Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Android 用户从应用内下载 GitHub 最新 ARM64 APK，校验后直接调起系统安装器完成更新。

**Architecture:** 扩展现有 `AppReleaseService` 保存 Release 附件信息，并新增独立的 `AppUpdateInstaller` 负责流式下载、SHA-256 校验和安装入口。Flutter 通过 `MethodChannel` 把缓存目录中的 APK 交给 Android `FileProvider` 和安装 Intent，启动检查与“关于”页面共享同一套更新流程。

**Tech Stack:** Flutter/Dart、`http`、`crypto`、`path_provider`、Android Kotlin、Android `FileProvider`、GitHub Releases API。

**Spec:** `docs/superpowers/specs/2026-11-26-online-android-update-design.md`

## Global Constraints

- 只处理 GitHub `releases/latest` 返回的最新正式 Release。
- 选择名称包含 `arm64` 或 `arm64-v8a` 且以 `.apk` 结尾的附件。
- APK 下载到应用缓存目录，并以流式方式处理。
- 下载完成后比较 GitHub 返回的 SHA-256 digest。
- Android 通过 `FileProvider` 和安装 Intent 调起系统安装器。
- 更新失败不阻塞启动，不修改稿件、模型和提词状态。
- 每次 GitHub 发布必须上传完整安装包和需要交付的各平台发布物，并核对附件状态、大小和 SHA-256 后再公开 Release。

## Review Focus

- 最新 Release 没有 ARM64 APK 时，弹窗仍能打开 Release 页面。
- GitHub digest 缺失时，更新流程仍能使用 HTTPS 下载并安装，digest 存在且不匹配时必须拒绝安装。
- 下载过程中网络中断时，临时文件被删除，下一次更新可以重新开始。
- APK 安装 Intent 只能读取应用缓存目录中的目标文件。
- 开发版本、桌面端和 Android 设备无法安装时，现有检查更新行为继续可用。

### Task 1: Release asset model and update downloader

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/services/app_release_service.dart`
- Create: `lib/services/app_update_installer.dart`
- Test: `test/app_release_service_test.dart`
- Create: `test/app_update_installer_test.dart`

**Interfaces:**
- `GitHubReleaseAsset` exposes `name`, `downloadUrl`, `size`, `digest` and `isArm64Apk`.
- `GitHubReleaseInfo.assets` contains parsed assets, and `androidApk` returns the preferred ARM64 APK or `null`.
- `AppUpdateInstaller.download(GitHubReleaseAsset asset, {void Function(int received, int total)? onProgress})` returns a verified `Future<File>`.
- `AppUpdateInstaller.install(File apk)` delegates to the platform installer and can be injected in tests.

- [ ] **Step 1: Write failing tests** for parsing an ARM64 asset, selecting it, digest success, digest mismatch, progress reporting and cleanup after a failed stream.
- [ ] **Step 2: Run focused tests** with `flutter test test/app_release_service_test.dart test/app_update_installer_test.dart` and confirm they fail because the new interfaces and behavior do not exist.
- [ ] **Step 3: Add `crypto` as a direct dependency** and implement the asset model, latest Release parsing, streaming download and SHA-256 verification.
- [ ] **Step 4: Run the focused tests** and confirm all new cases pass.
- [ ] **Step 5: Run the existing Release and update checker tests** to confirm compatibility with current callers.

### Task 2: Android installer bridge and manifest configuration

**Files:**
- Modify: `android/app/src/main/kotlin/com/example/storm_teleprompter_plus/MainActivity.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Create: `android/app/src/main/res/xml/file_paths.xml`
- Modify: `lib/services/app_update_installer.dart`
- Test: `test/native_platform_targets_test.dart`

**Interfaces:**
- Method channel name `storm.teleprompter/update`.
- Method `installApk` accepts `{path: String}` and invokes Android `ACTION_VIEW` with MIME `application/vnd.android.package-archive` and a cache-only `FileProvider` URI.

- [ ] **Step 1: Extend platform configuration tests** to require the update MethodChannel name, `REQUEST_INSTALL_PACKAGES`, `FileProvider`, and cache path declaration.
- [ ] **Step 2: Run the focused platform test** and confirm it fails against the current Android files.
- [ ] **Step 3: Register the MethodChannel in `MainActivity`**, add the provider and permission, and add the cache-only XML path.
- [ ] **Step 4: Implement the Dart platform launcher** with a test-injectable callback and desktop fallback behavior.
- [ ] **Step 5: Run platform configuration and Dart service tests** and confirm they pass.

### Task 3: Shared update interaction in startup and About flows

**Files:**
- Modify: `lib/widgets/common/startup_update_checker.dart`
- Modify: `lib/pages/about_page.dart`
- Modify: `test/startup_update_checker_test.dart`
- Modify: `test/about_settings_section_test.dart`

**Interfaces:**
- Startup and About use `AppUpdateInstaller` for Android APK assets.
- Update dialog actions remain `ignore`, `later`, and update. Android update action downloads, shows progress, verifies and installs. Release page remains available as fallback.

- [ ] **Step 1: Add failing widget tests** for an update with an APK asset, visible download progress, installer invocation and missing-asset fallback.
- [ ] **Step 2: Run the focused widget tests** and confirm the current “前往更新” flow fails the new expectations.
- [ ] **Step 3: Add injectable installer and progress callbacks**, change Android action text to “立即更新”, and keep external Release fallback.
- [ ] **Step 4: Run focused widget tests** and confirm the update flows pass without affecting ignore or later behavior.

### Task 4: Documentation, versioning and release automation checks

**Files:**
- Modify: `README.md`
- Modify: `.github/workflows/release.yml`
- Modify: `notes/docs/android-release-signing.md` if required by the existing release instructions
- Test: `test/native_platform_targets_test.dart`

- [ ] **Step 1: Add release asset naming and online update instructions** to README, including the ARM64 APK naming convention.
- [ ] **Step 2: Add a release workflow check** that fails when a prepared Android release has no APK asset, while retaining the existing platform artifacts.
- [ ] **Step 3: Run documentation/workflow text checks** and inspect the diff for unrelated changes.

### Task 5: Full verification and GitHub publication

**Files:**
- Modify: version metadata only if the next release version is selected during packaging.

- [ ] **Step 1: Run `flutter analyze` and the complete `flutter test` suite.**
- [ ] **Step 2: Build a signed ARM64 Android release APK using the existing signing configuration and verify package name, version, ABI and signature continuity.
- [ ] **Step 3: Commit the implementation and push the release branch to GitHub, using the repository API fallback if direct Git transport times out.
- [ ] **Step 4: Create the next version Release as a draft, upload the complete APK and any required platform artifacts, then verify asset state, size and SHA-256.
- [ ] **Step 5: Publish the Release and verify the tag target, `browser_download_url`, digest and download response.
- [ ] **Step 6: Update local project memory and shared memory with the release result and the mandatory complete-asset publication rule.

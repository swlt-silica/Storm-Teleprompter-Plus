# ASR 发音容错与旗舰模型实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让普通提词和 Android 悬浮窗在同音字、前后鼻音、平翘舌差异下保持跟随，并提供适合高性能手机的中英旗舰流式模型。

**Architecture:** 在现有 `TeleprompterAlignment` 内加入独立的中文发音等价比较层，保留精确字符优先和原有窗口、锚点策略。扩展 `AsrModels` 提供官方 `x-ASR` 中英流式 Zipformer 标准精度与 INT8 选项，模型加载器通过元数据传递 `modelType`，设置页沿用现有下载、选择和删除入口。

**Tech Stack:** Flutter/Dart、`sherpa_onnx`、ONNX 流式 Transducer、Flutter widget tests、GitHub Releases。

**Spec:** `docs/superpowers/specs/2026-11-26-asr-phonetic-tolerance-design.md`

## Global Constraints

- 保持 `OnlineRecognizer` 流式识别，不改成等待整句的离线识别。
- 显示文本和原稿索引保持原样，发音等价只用于内部匹配。
- 精确字符匹配优先于宽松匹配。
- 短片段和单个相似字不能触发远距离跳转。
- 用户已有模型继续保留，模型切换发生在下一次开始识别前。
- Android ARM64 Release APK、完整发布物、SHA-256 和签名信息必须在公开 Release 前核对。

## Review Focus

- 连续中文句子全部通过宽松匹配时，游标应前进到正确位置，不因权重降低而停住。测试归 Task 1。
- 只有一个同音字或相似声母时，不能跳过几十字寻找后文。测试归 Task 1。
- 原稿包含英文、数字和中文混合内容时，英文大小写和中文宽松匹配应同时工作。测试归 Task 1。
- 新模型目录使用 `encoder.int8.onnx`、`decoder.onnx`、`joiner.int8.onnx` 时，加载器应传递正确的 `modelType`。测试归 Task 2。
- 模型下载或加载失败时，原已选择的模型和下一次启动流程应继续可用。测试归 Task 2。

### Task 1: 中文发音宽松对齐

**Files:**
- Create: `lib/services/asr/chinese_pronunciation_matcher.dart`
- Modify: `lib/services/asr/alignment_engine.dart`
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Test: `test/asr_contract_test.dart`

**Interfaces:**
- Produces `ChinesePronunciationMatcher.equivalent(String left, String right) -> bool` and `ChinesePronunciationMatcher.similarity(String left, String right) -> double` for use by `TeleprompterAlignment`.
- `TeleprompterAlignment` continues exposing `AlignmentResult consumeTranscript(String text, bool isFinal)`.

- [ ] **Step 1: Write failing alignment tests** for same-sound substitutions, `n/ng`, `z/zh`, `c/ch`, `s/sh`, `an/ang`, mixed Chinese-English text, short false positives, and sequential duplicate sentences.
- [ ] **Step 2: Run focused tests and verify failure**

  Run `PATH="/Users/letu/Documents/Codex/2026-11-16/t/work/toolchains/flutter/bin:$PATH" flutter test test/asr_contract_test.dart --no-pub`.

  Expected result is failure because the alignment engine has no pronunciation equivalence layer.

- [ ] **Step 3: Implement `ChinesePronunciationMatcher`** with normalized pronunciation classes for supported Chinese characters and explicit confusion groups. Exact character equality returns full similarity. Supported pronunciation classes must cover the spec's same-sound, nasal ending, retroflex, and final confusion cases. Unknown Chinese characters return no equivalence so unrelated text remains conservative.
- [ ] **Step 4: Integrate weighted matching** in `_charLevelMatch` and `_isBetterMatch`. Exact matches score higher than pronunciation matches. A pronunciation match counts toward continuity, while `_hasEnoughConfidence` requires at least three Chinese characters or an equivalent mixed-language span before a distant resync.
- [ ] **Step 5: Run focused tests and verify pass**

  Run `PATH="/Users/letu/Documents/Codex/2026-11-16/t/work/toolchains/flutter/bin:$PATH" flutter test test/asr_contract_test.dart --no-pub`.

  Expected result is all tests in the file passing.

- [ ] **Step 6: Commit**

  `git add lib/services/asr/chinese_pronunciation_matcher.dart lib/services/asr/alignment_engine.dart pubspec.yaml pubspec.lock test/asr_contract_test.dart && git commit -m "feat: tolerate Mandarin pronunciation differences"`

### Task 2: 旗舰流式模型和模型加载元数据

**Files:**
- Modify: `lib/services/asr_service.dart`
- Modify: `lib/services/asr/asr_service_stub.dart`
- Modify: `lib/services/asr/asr_service_native.dart`
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Test: `test/asr_model_management_test.dart`
- Test: `test/asr_contract_test.dart`

**Interfaces:**
- `AsrModelInfo` gains `modelType` and `tier` metadata while retaining existing constructor compatibility.
- `AsrService.recommendModel()` returns the 960ms standard precision flagship model.
- `AsrService.loadModel()` passes `modelInfo.modelType` to `sherpa.OnlineModelConfig` when available.

- [ ] **Step 1: Write failing model metadata tests** for the 960ms standard model, 480ms standard model, INT8 variants, model type, URLs, size metadata, and flagship recommendation.
- [ ] **Step 2: Run focused model tests and verify failure**

  Run `PATH="/Users/letu/Documents/Codex/2026-11-16/t/work/toolchains/flutter/bin:$PATH" flutter test test/asr_model_management_test.dart test/asr_contract_test.dart --no-pub`.

  Expected result is failure because the new models and metadata do not exist.

- [ ] **Step 3: Update `sherpa_onnx` and add model definitions**

  Use the current stable plugin line that supports the official x-ASR model type and set the dependency floor to `2.0.3`. Add standard precision and INT8 entries for official x-ASR 960ms and 480ms archives. Keep existing models and imported model behavior.

- [ ] **Step 4: Persist model metadata and pass `modelType`**

  Save `modelType` and tier metadata in `.model.json` for downloaded and imported models where available. During load, set `OnlineModelConfig.modelType` from metadata, defaulting to the existing auto-detection behavior for old models.

- [ ] **Step 5: Preserve fallback behavior**

  If a new model cannot be downloaded or loaded, leave the selected model setting and existing installed model untouched. Keep the error surfaced through the current download and startup UI.

- [ ] **Step 6: Run focused tests and verify pass**

  Run `PATH="/Users/letu/Documents/Codex/2026-11-16/t/work/toolchains/flutter/bin:$PATH" flutter test test/asr_model_management_test.dart test/asr_contract_test.dart --no-pub`.

  Expected result is all focused tests passing.

- [ ] **Step 7: Commit**

  `git add lib/services/asr_service.dart lib/services/asr/asr_service_stub.dart lib/services/asr/asr_service_native.dart pubspec.yaml pubspec.lock test/asr_model_management_test.dart test/asr_contract_test.dart && git commit -m "feat: add flagship streaming ASR models"`

### Task 3: 模型设置体验和版本说明

**Files:**
- Modify: `lib/pages/settings_page.dart`
- Modify: `README.md`
- Test: `test/settings_asr_dialog_test.dart`

**Interfaces:**
- Consumes `AsrModelInfo.tier`, `modelType`, `recommendedMemoryMB`, `accuracy`, and `latency` from Task 2.
- Existing model download, select, delete, and progress callbacks remain the entry points.

- [ ] **Step 1: Write failing settings tests** for flagship labels, recommended model text, standard versus INT8 metadata, and selection without changing the current running session.
- [ ] **Step 2: Run the settings test and verify failure**

  Run `PATH="/Users/letu/Documents/Codex/2026-11-16/t/work/toolchains/flutter/bin:$PATH" flutter test test/settings_asr_dialog_test.dart --no-pub`.

  Expected result is failure because the settings UI does not render model tiers.

- [ ] **Step 3: Update model cards and recommendation copy**

  Show tier, accuracy, latency, package size, recommended memory, and whether the model is standard precision or INT8. Mark the 960ms standard model as the flagship recommendation while retaining the existing download and selection actions.

- [ ] **Step 4: Update README model guidance**

  Document the new flagship choices, the expected memory and latency tradeoff, and the fact that model download remains user initiated.

- [ ] **Step 5: Run focused settings tests and verify pass**

  Run `PATH="/Users/letu/Documents/Codex/2026-11-16/t/work/toolchains/flutter/bin:$PATH" flutter test test/settings_asr_dialog_test.dart --no-pub`.

  Expected result is all settings tests passing.

- [ ] **Step 6: Commit**

  `git add lib/pages/settings_page.dart README.md test/settings_asr_dialog_test.dart && git commit -m "feat: expose ASR model tiers in settings"`

### Task 4: 全量验证、构建和 GitHub Release

**Files:**
- Modify: `pubspec.yaml` version metadata if needed for the next release.
- Create: `artifacts/storm-teleprompter-<version>-arm64.apk`
- Create: `artifacts/SHA256SUMS.txt`
- Create: `artifacts/signature.txt`

**Interfaces:**
- Consumes all implementation commits from Tasks 1–3.
- Produces a pushed branch, release tag, complete GitHub Release assets, and a verified Android ARM64 APK download link.

- [ ] **Step 1: Run static analysis and the full Flutter suite**

  Run `PATH="/Users/letu/Documents/Codex/2026-11-16/t/work/toolchains/flutter/bin:/Users/letu/Documents/Codex/2026-11-16/t/work/toolchains/flutter/bin/cache/dart-sdk/bin:$PATH" dart analyze --format=machine` and `PATH="/Users/letu/Documents/Codex/2026-11-16/t/work/toolchains/flutter/bin:$PATH" flutter test --no-pub`.

  Expected result is zero analysis diagnostics and zero test failures.

- [ ] **Step 2: Build Android ARM64 Release APK**

  Use the existing signing configuration and increment the version. Verify package name `work.swlt.stormteleprompter`, version metadata, ABI `arm64-v8a`, and signing certificate continuity.

- [ ] **Step 3: Commit release metadata and push code**

  Push the implementation branch and release tag to GitHub after local verification.

- [ ] **Step 4: Create the next GitHub Release and upload complete assets**

  Upload the Android ARM64 APK, desktop/mobile release packages generated by the existing release workflow, `SHA256SUMS.txt`, and `signature.txt`. Keep the release draft until every asset is present and marked `uploaded`.

- [ ] **Step 5: Publish and verify**

  Verify tag target, asset names, sizes, GitHub digests, release state, and the Android ARM64 direct download URL. If network download validation times out, record the server-side asset state and exact failed command.

- [ ] **Step 6: Update project memory**

  Record the release version, commit, APK digest, model changes, and the standing rule that every GitHub code update needs a complete versioned Release.

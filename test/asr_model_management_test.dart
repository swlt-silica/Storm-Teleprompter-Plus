import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/services/system/app_data_directory.dart';
import 'package:storm_teleprompter_plus/services/asr_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'imported models ignore archive symlinks and can be listed and deleted',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'storm_asr_model_test_',
      );
      final archiveFile = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}android-cache-file',
      );
      final modelId =
          'test-imported-model-${DateTime.now().microsecondsSinceEpoch}';
      appDataDirectoryOverride = Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}app_data',
      );
      final service = AsrService.instance;

      addTearDown(() async {
        await service.deleteModel(modelId);
        appDataDirectoryOverride = null;
        if (await temporaryDirectory.exists()) {
          await temporaryDirectory.delete(recursive: true);
        }
      });

      final archive = Archive()
        ..addFile(ArchiveFile.string('fixture/tokens.txt', 'a 0'))
        ..addFile(ArchiveFile('fixture/encoder.onnx', 1, [0]))
        ..addFile(ArchiveFile('fixture/decoder.onnx', 1, [0]))
        ..addFile(ArchiveFile.symlink('fixture/test_wavs', '*'));
      final tarBytes = TarEncoder().encodeBytes(archive);
      await archiveFile.writeAsBytes(BZip2Encoder().encodeBytes(tarBytes));

      expect(
        await service.importModelArchive(
          archiveFile.path,
          modelId: modelId,
          archiveName: 'fixture.tar.bz2',
        ),
        modelId,
      );
      expect(await service.isModelDownloaded(modelId), isTrue);

      final importedModel = (await service.listAvailableModels()).singleWhere(
        (model) => model.id == modelId,
      );
      expect(importedModel.isImported, isTrue);
      expect(importedModel.name, 'fixture');
      final installedModelRoot =
          '${appDataDirectoryOverride!.path}${Platform.pathSeparator}'
          'asr_models${Platform.pathSeparator}$modelId';
      expect(
        await File(
          '$installedModelRoot${Platform.pathSeparator}encoder.onnx',
        ).exists(),
        isTrue,
      );
      expect(
        await FileSystemEntity.type(
          '$installedModelRoot${Platform.pathSeparator}fixture',
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );

      final nestedDirectory = Directory(
        '$installedModelRoot${Platform.pathSeparator}legacy-layout',
      );
      await nestedDirectory.create();
      final rootEncoder = File(
        '$installedModelRoot${Platform.pathSeparator}encoder.onnx',
      );
      final nestedEncoder = await rootEncoder.rename(
        '${nestedDirectory.path}${Platform.pathSeparator}encoder.onnx',
      );
      expect(await nestedEncoder.exists(), isTrue);
      expect(await service.isModelDownloaded(modelId), isTrue);
      expect(await rootEncoder.exists(), isTrue);
      expect(await nestedEncoder.exists(), isFalse);

      await service.deleteModel(modelId);
      expect(await service.isModelDownloaded(modelId), isFalse);
      expect(
        (await service.listAvailableModels()).any(
          (model) => model.id == modelId,
        ),
        isFalse,
      );
    },
  );

  test('failed model load preserves the previously loaded model state', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'storm_asr_load_fallback_test_',
    );
    appDataDirectoryOverride = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}app_data',
    );
    final service = AsrService.instance;
    const previousModelId = 'previous-model';
    const brokenModelId = 'broken-model';

    addTearDown(() async {
      service.setLoadedModelForTesting(null);
      appDataDirectoryOverride = null;
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    AsrService.markBindingsInitializedForTesting();
    final brokenModelDirectory = Directory(
      '${appDataDirectoryOverride!.path}${Platform.pathSeparator}'
      'asr_models${Platform.pathSeparator}$brokenModelId',
    );
    await brokenModelDirectory.create(recursive: true);
    service.setLoadedModelForTesting(previousModelId);

    await expectLater(
      service.loadModel(brokenModelId),
      throwsA(isA<Exception>()),
    );

    expect(service.isModelLoaded, isTrue);
    expect(service.currentModelId, previousModelId);
  });

  test('imported x-ASR archives persist the zipformer2 model type', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'storm_asr_x_asr_import_test_',
    );
    final archiveFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}x-asr.tar.bz2',
    );
    const modelId = 'x-asr-imported';
    appDataDirectoryOverride = Directory(
      '${temporaryDirectory.path}${Platform.pathSeparator}app_data',
    );
    final service = AsrService.instance;

    addTearDown(() async {
      await service.deleteModel(modelId);
      appDataDirectoryOverride = null;
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    final archive = Archive()
      ..addFile(ArchiveFile.string('fixture/tokens.txt', 'a 0'))
      ..addFile(ArchiveFile('fixture/encoder.onnx', 1, [0]))
      ..addFile(ArchiveFile('fixture/decoder.onnx', 1, [0]))
      ..addFile(ArchiveFile('fixture/joiner.onnx', 1, [0]));
    final tarBytes = TarEncoder().encodeBytes(archive);
    await archiveFile.writeAsBytes(BZip2Encoder().encodeBytes(tarBytes));

    await service.importModelArchive(
      archiveFile.path,
      modelId: modelId,
      archiveName:
          'sherpa-onnx-x-asr-960ms-streaming-zipformer-transducer-zh-en-punct.tar.bz2',
    );

    final importedModel = (await service.listAvailableModels()).singleWhere(
      (model) => model.id == modelId,
    );
    expect(importedModel.modelType, 'zipformer2');
  });
}

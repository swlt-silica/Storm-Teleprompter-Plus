import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_release_service.dart';

typedef UpdateCacheDirectoryLoader = Future<Directory> Function();
typedef ApkInstallLauncher = Future<void> Function(String path);

const _updateChannel = MethodChannel('storm.teleprompter/update');

class AppUpdateInstaller {
  AppUpdateInstaller({
    http.Client? client,
    UpdateCacheDirectoryLoader? cacheDirectoryLoader,
    ApkInstallLauncher? installLauncher,
  }) : _client = client ?? http.Client(),
       _cacheDirectoryLoader = cacheDirectoryLoader ?? getTemporaryDirectory,
       _installLauncher = installLauncher ?? _installWithPlatform;

  final http.Client _client;
  final UpdateCacheDirectoryLoader _cacheDirectoryLoader;
  final ApkInstallLauncher _installLauncher;

  Future<File> download(
    GitHubReleaseAsset asset, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (asset.downloadUrl.isEmpty) {
      throw StateError('更新附件没有下载地址');
    }

    final directory = await _cacheDirectoryLoader();
    await directory.create(recursive: true);
    final fileName = _safeFileName(asset.name);
    final temporaryFile = File('${directory.path}/$fileName.download');
    final targetFile = File('${directory.path}/$fileName');
    if (temporaryFile.existsSync()) await temporaryFile.delete();

    try {
      final response = await _client.send(
        http.Request('GET', Uri.parse(asset.downloadUrl)),
      );
      if (response.statusCode != 200) {
        throw StateError('更新下载失败：HTTP ${response.statusCode}');
      }

      final total = asset.size ?? response.contentLength ?? -1;
      var received = 0;
      final digestSink = _DigestSink();
      final digestInput = sha256.startChunkedConversion(digestSink);
      final output = temporaryFile.openWrite();
      try {
        await for (final chunk in response.stream) {
          output.add(chunk);
          digestInput.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await output.close();
        digestInput.close();
      }

      final expectedDigest = _sha256Digest(asset.digest);
      final actualDigest = digestSink.value!.toString();
      if (expectedDigest != null && actualDigest != expectedDigest) {
        throw StateError('更新文件校验失败');
      }

      if (targetFile.existsSync()) await targetFile.delete();
      return temporaryFile.rename(targetFile.path);
    } catch (_) {
      if (temporaryFile.existsSync()) await temporaryFile.delete();
      rethrow;
    }
  }

  Future<void> install(File apk) => _installLauncher(apk.path);

  void dispose() => _client.close();
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest event) => value = event;

  @override
  void close() {}
}

String _safeFileName(String name) {
  final normalized = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (normalized.isEmpty || normalized == '.' || normalized == '..') {
    return 'storm-teleprompter-update.apk';
  }
  return normalized;
}

String? _sha256Digest(String? value) {
  if (value == null) return null;
  final normalized = value.toLowerCase().trim();
  if (normalized.startsWith('sha256:')) {
    return normalized.substring('sha256:'.length);
  }
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized) ? normalized : null;
}

Future<void> _installWithPlatform(String path) async {
  if (defaultTargetPlatform != TargetPlatform.android) {
    throw UnsupportedError('当前平台不支持直接安装 APK');
  }
  await _updateChannel.invokeMethod<void>('installApk', {'path': path});
}

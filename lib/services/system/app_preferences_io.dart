import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/constants.dart';
import 'app_data_directory.dart';

class AppPreferences {
  AppPreferences._shared(this._sharedPreferences)
    : _file = null,
      _values = null;

  AppPreferences._file(this._file, this._values) : _sharedPreferences = null;

  final SharedPreferences? _sharedPreferences;
  final File? _file;
  final Map<String, String>? _values;
  Future<void> _pendingWrite = Future<void>.value();

  static Future<AppPreferences>? _instance;

  static Future<AppPreferences> getInstance() {
    return _instance ??= _create();
  }

  static Future<AppPreferences> _create() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return AppPreferences._shared(await SharedPreferences.getInstance());
    }

    final dataDirectory = await getAppDataDirectory();
    final file = File(
      p.join(dataDirectory.path, StorageConstants.desktopPreferencesFileName),
    );
    final values = <String, String>{};
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.key is String && entry.value is String) {
              values[entry.key as String] = entry.value as String;
            }
          }
        }
      } catch (error) {
        // Decoder exceptions can quote private connection tokens from the file.
        debugPrint('[AppPreferences] 读取应用数据失败: ${error.runtimeType}');
      }
    }
    return AppPreferences._file(file, values);
  }

  String? getString(String key) {
    return _sharedPreferences?.getString(key) ?? _values?[key];
  }

  Future<bool> setString(String key, String value) async {
    final sharedPreferences = _sharedPreferences;
    if (sharedPreferences != null) {
      return sharedPreferences.setString(key, value);
    }

    final write = _pendingWrite.then((_) async {
      final snapshot = Map<String, String>.from(_values!);
      snapshot[key] = value;
      await _writeSnapshot(snapshot);
      // Publish only the committed snapshot; a failed disk write must leave
      // readers on the previous data, and the next queued write can retry.
      _values
        ..clear()
        ..addAll(snapshot);
    });
    _pendingWrite = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await write;
    return true;
  }

  Future<void> _writeSnapshot(Map<String, String> snapshot) async {
    final file = _file!;
    await file.parent.create(recursive: true);
    final temporaryFile = File('${file.path}.tmp');
    await temporaryFile.writeAsString(jsonEncode(snapshot), flush: true);
    // Connection tokens now live in these device-local preferences. Keep the
    // portable Unix file private before it replaces the previous snapshot.
    if (!Platform.isWindows) {
      final result = await Process.run('/bin/chmod', [
        '600',
        temporaryFile.path,
      ]);
      if (result.exitCode != 0) {
        throw const FileSystemException('无法限制本机连接配置文件的读取权限');
      }
    }
    // File.rename replaces an existing file. Do not delete the original first:
    // if replacement fails, the previous snapshot must remain recoverable.
    await temporaryFile.rename(file.path);
  }
}

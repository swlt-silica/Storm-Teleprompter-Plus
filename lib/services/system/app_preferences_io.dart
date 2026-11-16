import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/constants.dart';
import 'app_data_directory.dart';

class AppPreferences {
  AppPreferences._shared(this._sharedPreferences, this._values) : _file = null;

  AppPreferences._file(this._file, this._values) : _sharedPreferences = null;

  final SharedPreferences? _sharedPreferences;
  final File? _file;
  final Map<String, String> _values;
  static const _sharedSnapshotKey = '__storm_committed_strings_v1';
  Future<void> _pendingWrite = Future<void>.value();

  static Future<AppPreferences>? _instance;

  static Future<AppPreferences> getInstance() {
    return _instance ??= _create();
  }

  static Future<AppPreferences> _create() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      final preferences = await SharedPreferences.getInstance();
      final values = <String, String>{
        for (final key in preferences.getKeys())
          if (key != _sharedSnapshotKey && preferences.get(key) is String)
            key: preferences.getString(key)!,
      };
      final committed = preferences.getString(_sharedSnapshotKey);
      if (committed != null) {
        final decoded = jsonDecode(committed);
        if (decoded is! Map ||
            decoded.entries.any(
              (entry) => entry.key is! String || entry.value is! String,
            )) {
          throw const FormatException('本机配置快照损坏，请先恢复有效备份');
        }
        values.addAll(Map<String, String>.from(decoded));
      }
      return AppPreferences._shared(preferences, values);
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
    return _values[key];
  }

  Future<bool> setString(String key, String value) => setValues({key: value});

  /// One durable commit for all keys. Mobile preferences use a single JSON
  /// envelope, because several SharedPreferences.setString calls are not a
  /// transaction. Old individual string keys are migrated on the first write.
  Future<bool> setValues(Map<String, String> values) {
    if (values.containsKey(_sharedSnapshotKey)) {
      throw ArgumentError('保留的配置键不可直接写入');
    }
    final changes = Map<String, String>.from(values);
    final result = _pendingWrite.then((_) async {
      final snapshot = Map<String, String>.from(_values)..addAll(changes);
      final shared = _sharedPreferences;
      if (shared != null) {
        if (!await shared.setString(_sharedSnapshotKey, jsonEncode(snapshot)))
          return false;
      } else {
        await _writeSnapshot(snapshot);
      }
      // Readers see the complete batch only after its durable write succeeds.
      _values
        ..clear()
        ..addAll(snapshot);
      return true;
    });
    _pendingWrite = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
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

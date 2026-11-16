import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class AppPreferences {
  AppPreferences._(this._preferences, this._values);

  final SharedPreferences _preferences;
  final Map<String, String> _values;
  Future<void> _pendingWrite = Future<void>.value();
  static const _snapshotKey = '__storm_committed_strings_v1';
  static Future<AppPreferences>? _instance;

  static Future<AppPreferences> getInstance() => _instance ??= _create();

  static Future<AppPreferences> _create() async {
    final preferences = await SharedPreferences.getInstance();
    final values = <String, String>{
      for (final key in preferences.getKeys())
        if (key != _snapshotKey && preferences.get(key) is String)
          key: preferences.getString(key)!,
    };
    final committed = preferences.getString(_snapshotKey);
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
    return AppPreferences._(preferences, values);
  }

  String? getString(String key) => _values[key];

  Future<bool> setString(String key, String value) => setValues({key: value});

  Future<bool> setValues(Map<String, String> values) {
    if (values.containsKey(_snapshotKey)) throw ArgumentError('保留的配置键不可直接写入');
    final changes = Map<String, String>.from(values);
    final result = _pendingWrite.then((_) async {
      final snapshot = Map<String, String>.from(_values)..addAll(changes);
      if (!await _preferences.setString(_snapshotKey, jsonEncode(snapshot)))
        return false;
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
}

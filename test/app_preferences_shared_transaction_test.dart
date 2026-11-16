import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise the same single-key mobile transaction without an Android runtime.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:storm_teleprompter_plus/services/system/app_preferences_shared.dart';

class _FailingStore extends InMemorySharedPreferencesStore {
  _FailingStore() : super.empty();
  bool fail = false;
  int writes = 0;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes++;
    if (fail) return false;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'mobile envelope migrates legacy keys and failed writes expose no partial state',
    () async {
      SharedPreferences.setMockInitialValues({
        'articles': 'legacy-articles',
        'folders': 'legacy-folders',
        'settings': 'device-settings',
        'cloud_connection': 'private-test-token',
        '__storm_committed_strings_v1': jsonEncode({
          'articles': 'committed-articles',
          'folders': 'committed-folders',
        }),
      });
      final preferences = await AppPreferences.getInstance();
      expect(preferences.getString('articles'), 'committed-articles');
      expect(preferences.getString('folders'), 'committed-folders');
      expect(preferences.getString('settings'), 'device-settings');
      final store = _FailingStore();
      SharedPreferencesStorePlatform.instance = store;
      expect(
        await preferences.setValues({
          'articles': 'new-articles',
          'folders': 'new-folders',
        }),
        isTrue,
      );
      expect(store.writes, 1);
      final envelope = jsonDecode(
        (await store.getAll())['flutter.__storm_committed_strings_v1']
            as String,
      );
      expect(envelope['articles'], 'new-articles');
      expect(envelope['folders'], 'new-folders');
      expect(envelope['settings'], 'device-settings');
      expect(envelope['cloud_connection'], 'private-test-token');
      store.fail = true;
      expect(
        await preferences.setValues({
          'articles': 'bad-articles',
          'folders': 'bad-folders',
        }),
        isFalse,
      );
      expect(preferences.getString('articles'), 'new-articles');
      expect(preferences.getString('folders'), 'new-folders');
      expect(
        jsonDecode(
          (await store.getAll())['flutter.__storm_committed_strings_v1']
              as String,
        ),
        envelope,
      );
      store.fail = false;
      await Future.wait([
        preferences.setString('articles', 'recovered'),
        preferences.setString('settings', 'new-settings'),
      ]);
      expect(preferences.getString('articles'), 'recovered');
      expect(preferences.getString('folders'), 'new-folders');
      expect(preferences.getString('settings'), 'new-settings');
    },
  );
}

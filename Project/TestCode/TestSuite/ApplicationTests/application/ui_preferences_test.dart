import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/application/ui_preferences.dart';

void main() {
  test('interface preferences round-trip through the atomic store', () async {
    final temporary = await Directory.systemTemp.createTemp('ui-prefs-');
    addTearDown(() => temporary.delete(recursive: true));
    final store = UiPreferencesStore(
      File(p.join(temporary.path, 'settings', 'interface.json')),
    );

    expect(await store.load(), isNull);
    await store.save(
      const UiPreferences(highContrast: true, textSize: AppTextSize.extraLarge),
    );
    final restored = await store.load();

    expect(restored?.highContrast, isTrue);
    expect(restored?.textSize, AppTextSize.extraLarge);
    expect(File('${store.file.path}.tmp').existsSync(), isFalse);
  });

  test('unsupported settings version is rejected', () {
    expect(
      () => UiPreferences.fromJson(const {'version': 99}),
      throwsFormatException,
    );
  });
}

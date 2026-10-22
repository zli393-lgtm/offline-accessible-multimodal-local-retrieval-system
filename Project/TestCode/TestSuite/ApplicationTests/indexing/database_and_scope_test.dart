import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/indexing/database_storage.dart';
import 'package:retrieval/indexing/index_scope.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('database-scope-test-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('prepares user-selected storage and dynamically protects it', () async {
    final root = p.join(temporary.path, 'chosen-drive-folder');
    final result = await const DatabaseStorageManager().prepare(root);

    expect(result.writable, isTrue);
    expect(await Directory(result.profile.chromaDirectory).exists(), isTrue);
    expect(await Directory(result.profile.registryDirectory).exists(), isTrue);
    expect(result.profile.containsRuntimePath(result.profile.dataRoot), isTrue);
    expect(
      result.profile.containsRuntimePath(
        p.join(result.profile.chromaDirectory, 'database.sqlite'),
      ),
      isTrue,
    );
    expect(
      result.profile.containsRuntimePath(p.join(root, 'user.txt')),
      isFalse,
    );
  });

  test(
    'does not silently turn an empty database setting into current directory',
    () {
      expect(() => DatabaseStorageProfile.forRoot('  '), throwsArgumentError);
    },
  );

  test(
    'moves a database by copy and verification without deleting source',
    () async {
      final manager = const DatabaseStorageManager();
      final source = (await manager.prepare(p.join(temporary.path, 'source')))
          .profile;
      final sourceFile = File(p.join(source.chromaDirectory, 'vectors.bin'));
      await sourceFile.writeAsBytes([1, 2, 3, 4]);

      final result = await manager.migrate(
        source: source,
        destinationRootPath: p.join(temporary.path, 'destination'),
      );

      expect(result.verified, isTrue);
      expect(result.filesCopied, 1);
      expect(result.bytesCopied, 4);
      expect(await sourceFile.exists(), isTrue);
      expect(
        await File(p.join(result.destination.chromaDirectory, 'vectors.bin'))
            .readAsBytes(),
        [1, 2, 3, 4],
      );
    },
  );

  test('persists the selected database location', () async {
    final profile = DatabaseStorageProfile.forRoot(
      p.join(temporary.path, 'db'),
    );
    final store = DatabaseSettingsStore(
      File(p.join(temporary.path, 'settings', 'database.json')),
    );
    await store.save(profile);
    final loaded = await store.load();
    expect(loaded!.selectedRootPath, profile.selectedRootPath);
    expect(loaded.profileId, profile.profileId);
  });

  test(
    'deleting saved scope removes both committed and temporary files',
    () async {
      final scopeFile = File(
        p.join(temporary.path, 'scope', 'index-scope.json'),
      );
      final store = IndexScopeStore(scopeFile);
      await store.save(
        IndexScope(
          mode: IndexScopeMode.allDevices,
          includedPaths: [p.join(temporary.path, 'selected')],
          excludedPaths: [p.join(temporary.path, 'excluded')],
        ),
      );
      final temporaryScopeFile = File('${scopeFile.path}.tmp');
      await temporaryScopeFile.writeAsString('incomplete');

      await store.delete();

      expect(await scopeFile.exists(), isFalse);
      expect(await temporaryScopeFile.exists(), isFalse);
      expect(await store.load(), isNull);
    },
  );

  test(
    'clears every generated index artifact but preserves scan scope',
    () async {
      final manager = const DatabaseStorageManager();
      final profile = (await manager.prepare(
        p.join(temporary.path, 'clear-target'),
      )).profile;
      final scopeFile = File(
        p.join(profile.indexStateDirectory, 'index-scope.json'),
      );
      await scopeFile.writeAsString('{"scope":"keep"}');
      final generatedFiles = [
        File(p.join(profile.chromaDirectory, 'vectors.bin')),
        File(p.join(profile.registryDirectory, 'file-registry.json')),
        File(p.join(profile.indexStateDirectory, 'index-coverage.json')),
        File(p.join(profile.failureLogDirectory, 'failures.log')),
        File(p.join(profile.temporaryDirectory, 'working.tmp')),
      ];
      for (final file in generatedFiles) {
        await file.parent.create(recursive: true);
        await file.writeAsString('generated');
      }

      await manager.clearAllIndexes(profile);

      expect(await scopeFile.readAsString(), '{"scope":"keep"}');
      for (final file in generatedFiles) {
        expect(await file.exists(), isFalse, reason: file.path);
      }
      expect(await Directory(profile.chromaDirectory).exists(), isTrue);
      expect(await Directory(profile.registryDirectory).exists(), isTrue);
    },
  );

  test(
    'scope supports add, remove, update, all-device mode and exclusions',
    () async {
      final first = p.join(temporary.path, 'first');
      final second = p.join(temporary.path, 'second');
      final excluded = p.join(second, 'ignore');
      var scope = IndexScope(mode: IndexScopeMode.selectedPaths).addPath(first);
      scope = scope.replacePath(first, second).exclude(excluded);

      expect(scope.includedPaths, [PathRules.canonical(second)]);
      expect(scope.excludes(p.join(excluded, 'inside.txt')), isTrue);
      expect(scope.excludes(p.join(second, 'keep.txt')), isFalse);

      final store = IndexScopeStore(File(p.join(temporary.path, 'scope.json')));
      await store.save(scope);
      final loaded = await store.load();
      expect(loaded!.toJson(), scope.toJson());
      expect(
        IndexScope(mode: IndexScopeMode.allDevices).mode,
        IndexScopeMode.allDevices,
      );
    },
  );
}

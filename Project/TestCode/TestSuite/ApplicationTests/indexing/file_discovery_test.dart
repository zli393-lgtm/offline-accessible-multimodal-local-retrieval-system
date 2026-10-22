import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/indexing/database_storage.dart';
import 'package:retrieval/indexing/file_discovery.dart';
import 'package:retrieval/indexing/index_scope.dart';

class _FakeVolumes implements VolumeDiscovery {
  final List<String> values;

  const _FakeVolumes(this.values);

  @override
  Future<List<String>> roots() async => values;
}

void main() {
  late Directory temporary;
  late DatabaseStorageProfile storage;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('discovery-test-');
    storage = DatabaseStorageProfile.forRoot(temporary.path);
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'finds every regular file and excludes runtime DB and retry logs',
    () async {
      final selected = Directory(p.join(temporary.path, 'selected'));
      await selected.create();
      await File(p.join(selected.path, 'one.txt')).writeAsString('one');
      await File(p.join(selected.path, 'two.png')).writeAsBytes([1]);
      await File(p.join(selected.path, 'unsupported.bin')).writeAsBytes([1]);
      await File(p.join(selected.path, 'fail.retrieval-failures.log'))
          .writeAsString('do not scan');
      await Directory(storage.chromaDirectory).create(recursive: true);
      await File(p.join(storage.chromaDirectory, 'inside.txt'))
          .writeAsString('x');

      final events = await const FileDiscoveryService()
          .discover(
            scope: IndexScope(
              mode: IndexScopeMode.selectedPaths,
              includedPaths: [selected.path, storage.dataRoot],
            ),
            storage: storage,
          )
          .toList();

      final paths = events.whereType<DiscoveredFile>().map(
        (event) => event.path,
      );
      expect(
        paths,
        contains(PathRules.canonical(p.join(selected.path, 'one.txt'))),
      );
      expect(
        paths,
        contains(PathRules.canonical(p.join(selected.path, 'two.png'))),
      );
      expect(
        paths,
        contains(PathRules.canonical(p.join(selected.path, 'unsupported.bin'))),
      );
      expect(paths, hasLength(3));
    },
  );

  test(
    'reports missing selected paths instead of aborting discovery',
    () async {
      final missing = p.join(temporary.path, 'missing');
      final existing = File(p.join(temporary.path, 'existing.md'));
      await existing.writeAsString('ok');
      final events = await const FileDiscoveryService()
          .discover(
            scope: IndexScope(
              mode: IndexScopeMode.selectedPaths,
              includedPaths: [missing, existing.path],
            ),
            storage: storage,
          )
          .toList();

      expect(events.whereType<DiscoveredFile>(), hasLength(1));
      expect(
        events.whereType<DiscoveryFailure>().single.code,
        'PATH_NOT_FOUND',
      );
    },
  );

  test('all-device mode uses discovered roots', () async {
    final file = File(p.join(temporary.path, 'device.txt'));
    await file.writeAsString('ok');
    final service = FileDiscoveryService(
      volumeDiscovery: _FakeVolumes([file.path]),
    );
    final events = await service
        .discover(
          scope: IndexScope(mode: IndexScopeMode.allDevices),
          storage: storage,
        )
        .toList();
    expect(
      events.whereType<DiscoveredFile>().single.path,
      PathRules.canonical(file.path),
    );
  });
}

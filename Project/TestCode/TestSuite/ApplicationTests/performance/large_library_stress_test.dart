import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/indexing/database_storage.dart';
import 'package:retrieval/indexing/index_job.dart';
import 'package:retrieval/indexing/index_scope.dart';

import '../support/fakes.dart';

void main() {
  test(
    'scans and indexes a fixed 1000-file library without losing objects',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'large-library-stress-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final source = await Directory(p.join(temporary.path, 'source')).create();
      for (var index = 0; index < 1000; index++) {
        await File(
          p.join(
            source.path,
            'document-${index.toString().padLeft(4, '0')}.txt',
          ),
        ).writeAsString('fixed stress record $index');
      }
      final storage = (await const DatabaseStorageManager().prepare(
        p.join(temporary.path, 'database-root'),
      )).profile;
      final vectors = FakeVectorStore();
      final runner = IndexJobRunner(
        parser: FakeParser(),
        embeddingEngine: fakeMultimodalEngine(),
        vectorStore: vectors,
        storage: storage,
        registryCheckpointSize: 100,
      );
      final initialMemory = ProcessInfo.currentRss;
      final stopwatch = Stopwatch()..start();

      final state = await runner.run(
        scope: IndexScope(
          mode: IndexScopeMode.selectedPaths,
          includedPaths: [source.path],
        ),
      );
      stopwatch.stop();
      final memoryGrowth = ProcessInfo.currentRss - initialMemory;

      expect(state.discovered, 1000);
      expect(state.processed, 1000);
      expect(state.succeeded, 1000);
      expect(state.failed, 0);
      expect(vectors.replaced, hasLength(1000));
      expect(memoryGrowth, lessThan(256 * 1024 * 1024));
      // ignore: avoid_print
      print(
        'LARGE LIBRARY STRESS | files=1000 '
        'elapsed_ms=${stopwatch.elapsedMilliseconds} '
        'files_per_second='
        '${(1000 / stopwatch.elapsedMilliseconds * 1000).toStringAsFixed(2)} '
        'rss_growth_bytes=$memoryGrowth',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

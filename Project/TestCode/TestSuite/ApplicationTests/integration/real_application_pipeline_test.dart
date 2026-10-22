import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/application/application_controller.dart';
import 'package:retrieval/application/runtime_configuration.dart';
import 'package:retrieval/application/ui_preferences.dart';
import 'package:retrieval/indexing/index_scope.dart';
import 'package:retrieval/query/query_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('real text parser, BERT, Chroma, indexing and attachment query work together', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'real-application-pipeline-',
    );
    final input = await Directory(p.join(temporary.path, 'input'))
        .create(recursive: true);
    final textFile = await File(p.join(input.path, 'offline-search-note.txt'))
        .writeAsString(
          'A sapphire lighthouse is the distinctive phrase used by this '
          'offline retrieval integration test.',
        );
    // This text-only integration test must not depend on GhostPDL being
    // installed on the test host. Runtime validation only needs the two
    // command entry points; this pipeline never executes either command.
    final ghostPdl = await Directory(p.join(temporary.path, 'ghostpdl'))
        .create(recursive: true);
    await File(p.join(ghostPdl.path, 'gswin64c.exe')).writeAsBytes(const []);
    await File(p.join(ghostPdl.path, 'gxpswin64c.exe')).writeAsBytes(const []);

    final controller = ApplicationController(
      configurationStore: RuntimeConfigurationStore(
        File(p.join(temporary.path, 'settings', 'runtime.json')),
      ),
      uiPreferencesStore: UiPreferencesStore(
        File(p.join(temporary.path, 'settings', 'interface.json')),
      ),
    );
    addTearDown(() async {
      await controller.localVectorService.stop();
      controller.dispose();
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });

    final stopwatch = Stopwatch()..start();
    await controller.initialize();
    final modelRoot = p.normalize(
      p.join(
        Directory.current.path,
        '..',
        '..',
        'Dependencies',
        'Packageable',
        'Models',
      ),
    );
    await controller.saveConfigurationAndStart(
      databaseRoot: p.join(temporary.path, 'database-root'),
      applicationDirectory: Directory.current.path,
      pythonExecutable: RuntimeConfiguration.pythonDirectoryForDisplay(
        Platform.environment['SXSX_PYTHON'] ?? '',
      ),
      logDirectory: p.join(temporary.path, 'logs'),
      dependencyPaths: {
        'ghostPdl': ghostPdl.path,
        'modelRoot': modelRoot,
      },
    );
    // ignore: avoid_print
    print('REAL PIPELINE | runtime_ready_ms=${stopwatch.elapsedMilliseconds}');
    await controller.setScopeMode(IndexScopeMode.selectedPaths);
    await controller.addIndexPath(input.path);
    await controller.runIndex();
    // ignore: avoid_print
    print('REAL PIPELINE | indexed_ms=${stopwatch.elapsedMilliseconds}');

    expect(controller.indexState?.succeeded, 1);
    expect(controller.indexState?.failed, 0);

    await controller.search(
      QueryRequest(attachmentPaths: [textFile.path], resultLimit: 10),
    );
    // ignore: avoid_print
    print('REAL PIPELINE | queried_ms=${stopwatch.elapsedMilliseconds}');
    final units = controller.queryResponse!.units;
    expect(units, hasLength(1));
    expect(units.single.status, QueryUnitStatus.completed);
    expect(
      units.single.textResults.map(
        (hit) => p.normalize(hit.sourcePath).toLowerCase(),
      ),
      contains(p.normalize(textFile.path).toLowerCase()),
    );
    expect(units.single.imageResults, isEmpty);
    expect(units.single.audioResults, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

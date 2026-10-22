import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/parsing/opaque_file_parser.dart';
import 'package:retrieval/core/parsing/parser.dart';
import 'package:retrieval/domain/file_object.dart';
import 'package:retrieval/indexing/database_storage.dart';
import 'package:retrieval/indexing/failure_log.dart';
import 'package:retrieval/indexing/file_registry.dart';
import 'package:retrieval/indexing/index_job.dart';
import 'package:retrieval/indexing/index_comparison.dart';
import 'package:retrieval/indexing/index_file_state.dart';
import 'package:retrieval/indexing/index_scope.dart';

import '../support/fakes.dart';

void main() {
  late Directory temporary;
  late Directory selected;
  late DatabaseStorageProfile storage;
  late FakeParser parser;
  late FakeVectorStore vectors;
  late IndexJobRunner runner;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('index-job-test-');
    selected = Directory(p.join(temporary.path, 'selected'));
    await selected.create();
    storage = (await const DatabaseStorageManager().prepare(
      p.join(temporary.path, 'database-root'),
    )).profile;
    parser = FakeParser();
    vectors = FakeVectorStore();
    runner = IndexJobRunner(
      parser: parser,
      embeddingEngine: fakeMultimodalEngine(),
      vectorStore: vectors,
      storage: storage,
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  IndexScope scope() => IndexScope(
    mode: IndexScopeMode.selectedPaths,
    includedPaths: [selected.path],
  );

  test('file status vocabulary contains the required atomic states', () {
    expect(IndexFileStatus.values, [
      IndexFileStatus.discovered,
      IndexFileStatus.unchanged,
      IndexFileStatus.queued,
      IndexFileStatus.processing,
      IndexFileStatus.indexed,
      IndexFileStatus.failed,
      IndexFileStatus.cancelled,
      IndexFileStatus.removed,
    ]);
  });

  test('unknown suffix becomes a successful file-name-only object', () async {
    final file = File(p.join(selected.path, 'private-format.myappdata'));
    await file.writeAsBytes([0, 255, 12, 34]);
    final opaqueRunner = IndexJobRunner(
      parser: const OpaqueFileParser(),
      embeddingEngine: fakeMultimodalEngine(),
      vectorStore: vectors,
      storage: storage,
    );

    final state = await opaqueRunner.run(scope: scope());
    final registry = await FileRegistryStore(
      File(p.join(storage.registryDirectory, 'file-registry.json')),
    ).load();

    expect(state.succeeded, 1);
    expect(state.failed, 0);
    expect(registry, hasLength(1));
    expect(registry.values.single.path, PathRules.canonical(file.path));
    expect(
      vectors.replaced.single.content.textInformation.single.text,
      'private-format.myappdata',
    );
    expect(
      vectors.replaced.single.content.textInformation.single.informationKind,
      TextInformationKind.fileName,
    );
  });

  test(
    'indexes files independently, logs failures, and retries exact records',
    () async {
      final good = File(p.join(selected.path, 'good.txt'));
      final bad = File(p.join(selected.path, 'bad.txt'));
      await good.writeAsString('good');
      await bad.writeAsString('bad');
      parser.failures[PathRules.canonical(bad.path)] = const FormatException(
        'broken',
      );

      final state = await runner.run(scope: scope());

      expect(state.status, IndexJobStatus.partial);
      expect(state.processed, 2);
      expect(state.succeeded, 1);
      expect(state.failed, 1);
      expect(vectors.replaced, hasLength(1));
      expect(state.failureLogPath, isNotNull);
      expect(await File(state.failureLogPath!).exists(), isTrue);

      parser.failures.remove(PathRules.canonical(bad.path));
      final plan = await runner.retryFromLog(state.failureLogPath!);
      expect(plan.accepted, hasLength(1));
      expect(plan.rejected, isEmpty);
      expect(vectors.replaced, hasLength(2));
      expect(
        await FailureRecordStore(
          File(p.join(storage.indexStateDirectory, 'failures.json')),
        ).load(),
        isEmpty,
      );
    },
  );

  test(
    'skips unchanged files, updates changed files, and removes deleted files',
    () async {
      final file = File(p.join(selected.path, 'tracked.txt'));
      await file.writeAsString('version one');

      final fileStates = <IndexFileState>[];
      final first = await runner.run(
        scope: scope(),
        onFileProgress: fileStates.add,
      );
      expect(first.succeeded, 1);
      expect(vectors.replaced, hasLength(1));
      expect(
        fileStates.map((state) => state.status),
        containsAllInOrder([
          IndexFileStatus.discovered,
          IndexFileStatus.queued,
          IndexFileStatus.processing,
          IndexFileStatus.indexed,
        ]),
      );
      final savedJob = await IndexJobStateStore(storage.indexStateDirectory)
          .load(first.jobId);
      expect(savedJob?.endedTime, isNotNull);
      expect(savedJob?.scopeSnapshot?['mode'], 'selectedPaths');
      expect(savedJob?.comparisonSnapshot?['hash'], isTrue);
      expect(savedJob?.fileStateLogPath, isNotNull);

      fileStates.clear();
      final second = await runner.run(
        scope: scope(),
        onFileProgress: fileStates.add,
      );
      expect(second.skipped, 1);
      expect(vectors.replaced, hasLength(1));
      expect(fileStates.last.status, IndexFileStatus.unchanged);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await file.writeAsString('version two is longer');
      final third = await runner.run(scope: scope());
      expect(third.succeeded, 1);
      expect(vectors.replaced, hasLength(2));
      expect(vectors.replaced.last.objectVersion, 2);

      final id = FileObjectIds.fromPath(PathRules.canonical(file.path));
      await file.delete();
      fileStates.clear();
      final fourth = await runner.run(
        scope: scope(),
        onFileProgress: fileStates.add,
      );
      expect(fourth.failed, 0);
      expect(vectors.removed, [id]);
      expect(fileStates.last.status, IndexFileStatus.removed);
      expect(
        await FileRegistryStore(
          File(p.join(storage.registryDirectory, 'file-registry.json')),
        ).load(),
        isEmpty,
      );
    },
  );

  test(
    'records internal stages and unit progress for one file object',
    () async {
      final file = File(p.join(selected.path, 'multimodal.txt'));
      await file.writeAsString('content');
      final canonical = PathRules.canonical(file.path);
      parser.contentByPath[canonical] = fakeContent(
        canonical,
        withImage: true,
        withAudio: true,
      );
      final fileStates = <IndexFileState>[];

      final result = await runner.run(
        scope: scope(),
        onFileProgress: fileStates.add,
      );

      expect(result.succeeded, 1);
      final stages = fileStates.map((state) => state.stage).toList();
      expect(
        stages,
        containsAllInOrder([
          FileProcessingStage.reading.name,
          FileProcessingStage.textEmbedding.name,
          FileProcessingStage.imageEmbedding.name,
          FileProcessingStage.audioEmbedding.name,
          FileProcessingStage.indexStaging.name,
          FileProcessingStage.indexValidation.name,
          FileProcessingStage.indexCommit.name,
          'committed',
        ]),
      );
      expect(
        fileStates.any(
          (state) =>
              state.stage == FileProcessingStage.textEmbedding.name &&
              state.completedUnits == 1 &&
              state.totalUnits == 1,
        ),
        isTrue,
      );

      final replayed = await IndexFileStateStore(storage.indexStateDirectory)
          .loadLatest(result.jobId);
      expect(replayed.values.single.status, IndexFileStatus.indexed);
      final persistedLines = await IndexFileStateStore(
        storage.indexStateDirectory,
      ).fileFor(result.jobId).readAsLines();
      expect(persistedLines, hasLength(1));
    },
  );

  test('cancels safely inside a file before its index is committed', () async {
    final file = File(p.join(selected.path, 'cancel-inside.txt'));
    await file.writeAsString('content');
    final control = IndexJobControl();
    final fileStates = <IndexFileState>[];

    final result = await runner.run(
      scope: scope(),
      control: control,
      onFileProgress: (state) {
        fileStates.add(state);
        if (state.stage == FileProcessingStage.textEmbedding.name) {
          control.cancel();
        }
      },
    );

    expect(result.status, IndexJobStatus.cancelled);
    expect(fileStates.last.status, IndexFileStatus.failed);
    expect(fileStates.last.stage, 'cancelled');
    expect(result.failed, 1);
    final persisted = await IndexFileStateStore(storage.indexStateDirectory)
        .loadLatest(result.jobId);
    expect(persisted.values.single.status, IndexFileStatus.failed);
    expect(persisted.values.single.stage, 'cancelled');
    expect(vectors.replaced, isEmpty);
    expect(
      await FileRegistryStore(
        File(p.join(storage.registryDirectory, 'file-registry.json')),
      ).load(),
      isEmpty,
    );
  });

  test('pauses and resumes at an internal file processing boundary', () async {
    final file = File(p.join(selected.path, 'pause-inside.txt'));
    await file.writeAsString('content');
    final control = IndexJobControl();
    final jobStates = <IndexJobStatus>[];
    var requestedPause = false;

    final result = await runner.run(
      scope: scope(),
      control: control,
      onProgress: (state) => jobStates.add(state.status),
      onFileProgress: (state) {
        if (!requestedPause &&
            state.stage == FileProcessingStage.textEmbedding.name) {
          requestedPause = true;
          control.pause();
          Timer(const Duration(milliseconds: 20), control.resume);
        }
      },
    );

    expect(result.status, IndexJobStatus.completed);
    expect(jobStates, contains(IndexJobStatus.paused));
    expect(vectors.replaced, hasLength(1));
  });

  test(
    'detects changed bytes even when file size and modified time are unchanged',
    () async {
      final file = File(p.join(selected.path, 'same-metadata.txt'));
      await file.writeAsString('first value');

      final first = await runner.run(scope: scope());
      expect(first.succeeded, 1);
      expect(vectors.replaced, hasLength(1));
      final originalModified = (await file.stat()).modified;

      await file.writeAsString('other value');
      await file.setLastModified(originalModified);

      final second = await runner.run(scope: scope());
      expect(second.succeeded, 1);
      expect(second.skipped, 0);
      expect(vectors.replaced, hasLength(2));
      expect(vectors.replaced.last.objectVersion, 2);
    },
  );

  test(
    'indexes equal content at different paths as separate objects',
    () async {
      final firstFile = File(p.join(selected.path, 'first.txt'));
      final secondFile = File(p.join(selected.path, 'second.txt'));
      await firstFile.writeAsString('identical content');
      await secondFile.writeAsString('identical content');

      final state = await runner.run(scope: scope());

      expect(state.succeeded, 2);
      expect(vectors.replaced, hasLength(2));
      expect(
        vectors.replaced.map((object) => object.fileObjectId).toSet(),
        hasLength(2),
      );
    },
  );

  test('renamed paths remove the old object and create a new object', () async {
    final oldFile = File(p.join(selected.path, 'before.txt'));
    await oldFile.writeAsString('content');
    await runner.run(scope: scope());
    final oldId = FileObjectIds.fromPath(PathRules.canonical(oldFile.path));

    final newPath = p.join(selected.path, 'after.txt');
    final newFile = await oldFile.rename(newPath);
    final second = await runner.run(scope: scope());
    final newId = FileObjectIds.fromPath(PathRules.canonical(newFile.path));

    expect(second.succeeded, 1);
    expect(oldId, isNot(newId));
    expect(vectors.removed, contains(oldId));
    expect(vectors.replaced.last.fileObjectId, newId);
  });

  test('no comparison keeps stale entries and skips existing files', () async {
    final file = File(p.join(selected.path, 'kept.txt'));
    await file.writeAsString('original');
    await runner.run(scope: scope());
    final id = FileObjectIds.fromPath(PathRules.canonical(file.path));

    await file.delete();
    final state = await runner.run(
      scope: scope(),
      comparison: const IndexComparisonOptions.none(),
    );

    expect(state.succeeded, 0);
    expect(vectors.removed, isEmpty);
    expect(
      await FileRegistryStore(
        File(p.join(storage.registryDirectory, 'file-registry.json')),
      ).load(),
      contains(id),
    );
  });

  test('quick comparison removes paths missing from the scan', () async {
    final file = File(p.join(selected.path, 'removed.txt'));
    await file.writeAsString('original');
    await runner.run(scope: scope());
    final id = FileObjectIds.fromPath(PathRules.canonical(file.path));

    await file.delete();
    await runner.run(
      scope: scope(),
      comparison: const IndexComparisonOptions.quick(),
    );

    expect(vectors.removed, [id]);
  });

  test('standard comparison trusts unchanged size and modified time', () async {
    final file = File(p.join(selected.path, 'standard.txt'));
    await file.writeAsString('first value');
    await runner.run(scope: scope());
    final modified = (await file.stat()).modified;

    await file.writeAsString('other value');
    await file.setLastModified(modified);
    final state = await runner.run(
      scope: scope(),
      comparison: const IndexComparisonOptions.standard(),
    );

    expect(state.skipped, 1);
    expect(vectors.replaced, hasLength(1));
  });

  test(
    'advanced comparison recalculates hash and detects changed bytes',
    () async {
      final file = File(p.join(selected.path, 'advanced.txt'));
      await file.writeAsString('first value');
      await runner.run(scope: scope());
      final modified = (await file.stat()).modified;

      await file.writeAsString('other value');
      await file.setLastModified(modified);
      final state = await runner.run(
        scope: scope(),
        comparison: const IndexComparisonOptions.advanced(),
      );

      expect(state.succeeded, 1);
      expect(state.skipped, 0);
      expect(vectors.replaced, hasLength(2));
    },
  );

  test(
    'custom size-only comparison detects size changes without cleanup',
    () async {
      final changed = File(p.join(selected.path, 'changed.txt'));
      final removed = File(p.join(selected.path, 'stale.txt'));
      await changed.writeAsString('one');
      await removed.writeAsString('stale');
      await runner.run(scope: scope());
      final removedId = FileObjectIds.fromPath(
        PathRules.canonical(removed.path),
      );

      await changed.writeAsString('a longer value');
      await removed.delete();
      final state = await runner.run(
        scope: scope(),
        comparison: const IndexComparisonOptions(
          path: false,
          size: true,
          modifiedTime: false,
          hash: false,
        ),
      );

      expect(state.succeeded, 1);
      expect(vectors.removed, isEmpty);
      expect(
        await FileRegistryStore(
          File(p.join(storage.registryDirectory, 'file-registry.json')),
        ).load(),
        contains(removedId),
      );
    },
  );

  test('cancelled jobs preserve progress and stop before later work', () async {
    await File(p.join(selected.path, 'first.txt')).writeAsString('one');
    await File(p.join(selected.path, 'second.txt')).writeAsString('two');
    final control = IndexJobControl();
    var cancelled = false;
    final state = await runner.run(
      scope: scope(),
      control: control,
      onProgress: (progress) {
        if (!cancelled && progress.processed == 1) {
          cancelled = true;
          control.cancel();
        }
      },
    );
    expect(state.status, IndexJobStatus.cancelled);
    expect(state.processed, 1);
    expect(vectors.replaced, hasLength(1));
  });

  test('cancelling a queued file does not create a file result', () async {
    final file = File(p.join(selected.path, 'cancelled.txt'));
    await file.writeAsString('cancel me');
    final control = IndexJobControl();
    final fileStates = <IndexFileState>[];

    final state = await runner.run(
      scope: scope(),
      control: control,
      onFileProgress: (fileState) {
        fileStates.add(fileState);
        if (fileState.status == IndexFileStatus.queued) control.cancel();
      },
    );

    expect(state.status, IndexJobStatus.cancelled);
    expect(
      fileStates.map((fileState) => fileState.status),
      containsAllInOrder([IndexFileStatus.discovered, IndexFileStatus.queued]),
    );
    expect(state.failed, 0);
    expect(
      await IndexFileStateStore(storage.indexStateDirectory)
          .loadLatest(state.jobId),
      isEmpty,
    );
    expect(vectors.replaced, isEmpty);
  });

  test('partial extraction fails the object and commits no index', () async {
    final file = File(p.join(selected.path, 'partial.txt'));
    await file.writeAsString('usable text');
    final canonical = PathRules.canonical(file.path);
    parser.contentByPath[canonical] = fakeContent(
      canonical,
      status: ExtractionStatus.partial,
      issues: const [
        ExtractionIssue(
          stage: 'ocr',
          message: 'one image failed',
          severity: ExtractionIssueSeverity.warning,
        ),
      ],
    );
    final fileStates = <IndexFileState>[];

    final state = await runner.run(
      scope: scope(),
      onFileProgress: fileStates.add,
    );

    expect(state.succeeded, 0);
    expect(state.failed, 1);
    expect(state.status, IndexJobStatus.partial);
    expect(fileStates.last.status, IndexFileStatus.failed);
    expect(vectors.replaced, isEmpty);
    final registry = await FileRegistryStore(
      File(p.join(storage.registryDirectory, 'file-registry.json')),
    ).load();
    expect(registry, isEmpty);
  });

  test('failed replacement keeps the previous usable index', () async {
    final file = File(p.join(selected.path, 'keep-old.txt'));
    await file.writeAsString('old usable content');
    await runner.run(scope: scope());
    final canonical = PathRules.canonical(file.path);
    final id = FileObjectIds.fromPath(canonical);
    final registryStore = FileRegistryStore(
      File(p.join(storage.registryDirectory, 'file-registry.json')),
    );
    final previous = (await registryStore.load())[id]!;

    await file.writeAsString('changed content that fails');
    parser.failures[canonical] = const FormatException('processing failed');
    final fileStates = <IndexFileState>[];
    final state = await runner.run(
      scope: scope(),
      onFileProgress: fileStates.add,
    );

    expect(state.failed, 1);
    expect(fileStates.last.status, IndexFileStatus.failed);
    expect(vectors.replaced, hasLength(1));
    final retained = (await registryStore.load())[id]!;
    expect(retained.objectVersion, previous.objectVersion);
    expect(retained.fingerprint, previous.fingerprint);
  });

  test('paused jobs report the safe paused state before resuming', () async {
    await File(p.join(selected.path, 'paused.txt')).writeAsString('one');
    final control = IndexJobControl()..pause();
    final statuses = <IndexJobStatus>[];

    final state = await runner.run(
      scope: scope(),
      control: control,
      onProgress: (progress) {
        statuses.add(progress.status);
        if (progress.status == IndexJobStatus.paused) control.resume();
      },
    );

    expect(statuses, contains(IndexJobStatus.paused));
    expect(state.status, IndexJobStatus.completed);
  });

  test('records a failed state when the job itself cannot continue', () async {
    final corruptRegistry = File(
      p.join(storage.registryDirectory, 'corrupt-registry.json'),
    );
    await corruptRegistry.parent.create(recursive: true);
    await corruptRegistry.writeAsString('{not-json');
    final failedRunner = IndexJobRunner(
      parser: parser,
      embeddingEngine: fakeMultimodalEngine(),
      vectorStore: vectors,
      storage: storage,
      registryStore: FileRegistryStore(corruptRegistry),
    );
    IndexJobState? lastState;

    await expectLater(
      failedRunner.run(
        scope: scope(),
        onProgress: (state) => lastState = state,
      ),
      throwsA(isA<FormatException>()),
    );

    expect(lastState, isNotNull);
    expect(lastState!.status, IndexJobStatus.failed);
    expect(lastState!.currentPath, isNull);
    final saved = await IndexJobStateStore(storage.indexStateDirectory)
        .load(lastState!.jobId);
    expect(saved?.status, IndexJobStatus.failed);
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/models/extracted_file_content.dart';
import '../core/models/parsing_result.dart';
import '../core/parsing/parser.dart';
import '../domain/file_object.dart';
import '../embedding/multimodal_embedding_engine.dart';
import '../storage/multimodal_vector_store.dart';
import 'database_storage.dart';
import 'failure_log.dart';
import 'file_discovery.dart';
import 'file_fingerprint.dart';
import 'index_comparison.dart';
import 'file_registry.dart';
import 'index_file_state.dart';
import 'index_scope.dart';

enum IndexJobStatus {
  queued,
  running,
  pausing,
  paused,
  cancelling,
  cancelled,
  completed,
  partial,
  failed,
}

class IndexJobState {
  final String jobId;
  final IndexJobStatus status;
  final DateTime startedTime;
  final DateTime updatedTime;
  final DateTime? endedTime;
  final int discovered;
  final int processed;
  final int succeeded;
  final int skipped;
  final int failed;
  final String? currentPath;
  final String? failureLogPath;
  final String? fileStateLogPath;
  final Set<String> completedPaths;
  final Map<String, Object?>? scopeSnapshot;
  final Map<String, Object?>? comparisonSnapshot;

  const IndexJobState({
    required this.jobId,
    required this.status,
    required this.startedTime,
    required this.updatedTime,
    this.endedTime,
    required this.discovered,
    required this.processed,
    required this.succeeded,
    required this.skipped,
    required this.failed,
    required this.completedPaths,
    this.currentPath,
    this.failureLogPath,
    this.fileStateLogPath,
    this.scopeSnapshot,
    this.comparisonSnapshot,
  });

  factory IndexJobState.start(
    String jobId, {
    IndexScope? scope,
    IndexComparisonOptions? comparison,
    String? fileStateLogPath,
  }) {
    final now = DateTime.now().toUtc();
    return IndexJobState(
      jobId: jobId,
      status: IndexJobStatus.queued,
      startedTime: now,
      updatedTime: now,
      discovered: 0,
      processed: 0,
      succeeded: 0,
      skipped: 0,
      failed: 0,
      completedPaths: const {},
      fileStateLogPath: fileStateLogPath,
      scopeSnapshot: scope?.toJson(),
      comparisonSnapshot: comparison?.toJson(),
    );
  }

  IndexJobState copyWith({
    IndexJobStatus? status,
    DateTime? endedTime,
    int? discovered,
    int? processed,
    int? succeeded,
    int? skipped,
    int? failed,
    String? currentPath,
    bool clearCurrentPath = false,
    String? failureLogPath,
    String? fileStateLogPath,
    Set<String>? completedPaths,
  }) => IndexJobState(
    jobId: jobId,
    status: status ?? this.status,
    startedTime: startedTime,
    updatedTime: DateTime.now().toUtc(),
    discovered: discovered ?? this.discovered,
    processed: processed ?? this.processed,
    succeeded: succeeded ?? this.succeeded,
    skipped: skipped ?? this.skipped,
    failed: failed ?? this.failed,
    currentPath: clearCurrentPath ? null : currentPath ?? this.currentPath,
    failureLogPath: failureLogPath ?? this.failureLogPath,
    fileStateLogPath: fileStateLogPath ?? this.fileStateLogPath,
    completedPaths: completedPaths ?? this.completedPaths,
    scopeSnapshot: scopeSnapshot,
    comparisonSnapshot: comparisonSnapshot,
    endedTime: endedTime ?? this.endedTime,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'jobId': jobId,
    'status': status.name,
    'startedTime': startedTime.toIso8601String(),
    'updatedTime': updatedTime.toIso8601String(),
    'endedTime': endedTime?.toIso8601String(),
    'scope': scopeSnapshot,
    'comparison': comparisonSnapshot,
    'discovered': discovered,
    'processed': processed,
    'succeeded': succeeded,
    'skipped': skipped,
    'failed': failed,
    'currentPath': currentPath,
    'failureLogPath': failureLogPath,
    'fileStateLogPath': fileStateLogPath,
    // Full paths live in an append-only checkpoint journal. Keeping them out
    // of this frequently-written JSON avoids quadratic rewrites on large
    // all-device scans.
    'completedPathCount': completedPaths.length,
  };

  factory IndexJobState.fromJson(Map<String, dynamic> json) => IndexJobState(
    jobId: json['jobId'] as String,
    status: IndexJobStatus.values.byName(json['status'] as String),
    startedTime: DateTime.parse(json['startedTime'] as String).toUtc(),
    updatedTime: DateTime.parse(json['updatedTime'] as String).toUtc(),
    endedTime: json['endedTime'] == null
        ? null
        : DateTime.parse(json['endedTime'] as String).toUtc(),
    discovered: (json['discovered'] as num).toInt(),
    processed: (json['processed'] as num).toInt(),
    succeeded: (json['succeeded'] as num).toInt(),
    skipped: (json['skipped'] as num).toInt(),
    failed: (json['failed'] as num).toInt(),
    currentPath: json['currentPath'] as String?,
    failureLogPath: json['failureLogPath'] as String?,
    fileStateLogPath: json['fileStateLogPath'] as String?,
    scopeSnapshot: (json['scope'] as Map?)?.cast<String, Object?>(),
    comparisonSnapshot: (json['comparison'] as Map?)?.cast<String, Object?>(),
    completedPaths: (json['completedPaths'] as List? ?? const [])
        .cast<String>()
        .toSet(),
  );
}

class IndexJobStateStore {
  final String directory;

  const IndexJobStateStore(this.directory);

  File fileFor(String jobId) => File(p.join(directory, 'job-$jobId.json'));

  Future<void> save(IndexJobState state) async {
    final file = fileFor(state.jobId);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<IndexJobState?> load(String jobId) async {
    final file = fileFor(jobId);
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString());
    return IndexJobState.fromJson(Map<String, dynamic>.from(value as Map));
  }
}

class IndexJobCheckpointStore {
  final String directory;

  const IndexJobCheckpointStore(this.directory);

  File fileFor(String jobId) =>
      File(p.join(directory, 'job-$jobId-completed.jsonl'));

  Future<void> append(String jobId, String path) async {
    final file = fileFor(jobId);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode(PathRules.canonical(path))}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<Set<String>> load(String jobId) async {
    final file = fileFor(jobId);
    if (!await file.exists()) return {};
    final result = <String>{};
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final value = jsonDecode(line);
      if (value is! String) {
        throw const FormatException('Invalid index checkpoint entry.');
      }
      result.add(PathRules.canonical(value));
    }
    return result;
  }
}

class IndexJobControl {
  bool _paused = false;
  bool _cancelled = false;
  Completer<void>? _resume;

  bool get isPaused => _paused;
  bool get isCancelled => _cancelled;

  void pause() {
    if (_cancelled || _paused) return;
    _paused = true;
    _resume = Completer<void>();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    _resume?.complete();
    _resume = null;
  }

  void cancel() {
    _cancelled = true;
    resume();
  }

  Future<void> waitIfPaused() async {
    if (_paused) await _resume!.future;
  }
}

class IndexJobRunner {
  final Parser parser;
  final MultimodalEmbeddingEngine embeddingEngine;
  final MultimodalVectorStore vectorStore;
  final FileDiscoveryService discovery;
  final DatabaseStorageProfile storage;
  final FileRegistryStore registryStore;
  final FailureRecordStore failureStore;
  final FailureLogFile failureLog;
  final IndexJobStateStore jobStore;
  final IndexJobCheckpointStore checkpointStore;
  final IndexFileStateStore fileStateStore;
  final String logDirectory;
  final int registryCheckpointSize;

  IndexJobRunner({
    required this.parser,
    required this.embeddingEngine,
    required this.vectorStore,
    required this.storage,
    FileDiscoveryService? discovery,
    FileRegistryStore? registryStore,
    FailureRecordStore? failureStore,
    FailureLogFile? failureLog,
    IndexJobStateStore? jobStore,
    IndexJobCheckpointStore? checkpointStore,
    IndexFileStateStore? fileStateStore,
    String? logDirectory,
    this.registryCheckpointSize = 25,
  }) : discovery = discovery ?? const FileDiscoveryService(),
       registryStore =
           registryStore ??
           FileRegistryStore(
             File(p.join(storage.registryDirectory, 'file-registry.json')),
           ),
       failureStore =
           failureStore ??
           FailureRecordStore(
             File(p.join(storage.indexStateDirectory, 'failures.json')),
           ),
       failureLog = failureLog ?? const FailureLogFile(),
       jobStore = jobStore ?? IndexJobStateStore(storage.indexStateDirectory),
       checkpointStore =
           checkpointStore ??
           IndexJobCheckpointStore(storage.indexStateDirectory),
       fileStateStore =
           fileStateStore ?? IndexFileStateStore(storage.indexStateDirectory),
       logDirectory = logDirectory ?? storage.failureLogDirectory {
    if (registryCheckpointSize <= 0) {
      throw ArgumentError.value(
        registryCheckpointSize,
        'registryCheckpointSize',
      );
    }
  }

  Future<IndexJobState> run({
    required IndexScope scope,
    IndexComparisonOptions comparison = const IndexComparisonOptions.complete(),
    IndexJobControl? control,
    IndexJobState? resumeState,
    void Function(IndexJobState state)? onProgress,
    void Function(IndexFileState state)? onFileProgress,
  }) async {
    final effectiveControl = control ?? IndexJobControl();
    final jobId =
        resumeState?.jobId ?? DateTime.now().microsecondsSinceEpoch.toString();
    var latestState =
        resumeState ??
        IndexJobState.start(
          jobId,
          scope: scope,
          comparison: comparison,
          fileStateLogPath: fileStateStore.fileFor(jobId).path,
        );
    try {
      await jobStore.save(latestState);
      onProgress?.call(latestState);
      return await _run(
        scope: scope,
        comparison: comparison,
        control: effectiveControl,
        initialState: latestState,
        onProgress: (state) {
          latestState = state;
          onProgress?.call(state);
        },
        onFileProgress: onFileProgress,
      );
    } catch (_) {
      try {
        final finalFileStates = await fileStateStore.loadLatest(jobId);
        final resultLogPath = (await const IndexResultLogFile().write(
          directory: logDirectory,
          jobId: jobId,
          states: finalFileStates.values,
        )).path;
        latestState = latestState.copyWith(fileStateLogPath: resultLogPath);
      } catch (_) {
        // Keep the original indexing failure if even best-effort logging fails.
      }
      latestState = latestState.copyWith(
        status: IndexJobStatus.failed,
        clearCurrentPath: true,
        endedTime: DateTime.now().toUtc(),
      );
      try {
        await jobStore.save(latestState);
      } catch (_) {
        // Keep the original job failure when the state store itself is broken.
      }
      onProgress?.call(latestState);
      rethrow;
    }
  }

  Future<IndexJobState> _run({
    required IndexScope scope,
    required IndexComparisonOptions comparison,
    required IndexJobControl control,
    required IndexJobState initialState,
    required void Function(IndexJobState state) onProgress,
    void Function(IndexFileState state)? onFileProgress,
  }) async {
    var state = initialState;
    final checkpointed = await checkpointStore.load(state.jobId);
    state = state.copyWith(
      completedPaths: {...state.completedPaths, ...checkpointed},
    );
    state = state.copyWith(status: IndexJobStatus.running);
    final registry = await registryStore.load();
    var registryChanges = 0;
    final seen = <String>{};
    final failures = <IndexFailureRecord>[];
    var discoveryFailed = false;
    var failureSequence = 0;
    Future<IndexJobState> cancelJob([String? interruptedPath]) async {
      if (interruptedPath != null) {
        await _recordFileState(
          jobId: state.jobId,
          path: interruptedPath,
          status: IndexFileStatus.failed,
          stage: 'cancelled',
          message: '用户取消任务；该文件尚未完成，因此归入失败。',
          onProgress: onFileProgress,
        );
        state = state.copyWith(
          processed: state.processed + 1,
          failed: state.failed + 1,
          completedPaths: {...state.completedPaths, interruptedPath},
        );
      }
      if (registryChanges > 0) await registryStore.save(registry);
      final finalFileStates = await fileStateStore.loadLatest(state.jobId);
      final resultLogPath = (await const IndexResultLogFile().write(
        directory: logDirectory,
        jobId: state.jobId,
        states: finalFileStates.values,
      )).path;
      state = state.copyWith(
        status: IndexJobStatus.cancelled,
        clearCurrentPath: true,
        fileStateLogPath: resultLogPath,
        endedTime: DateTime.now().toUtc(),
      );
      await jobStore.save(state);
      onProgress(state);
      return state;
    }

    await jobStore.save(state);
    onProgress(state);

    await for (final event in discovery.discover(
      scope: scope,
      storage: storage,
    )) {
      if (control.isPaused) {
        state = state.copyWith(
          status: IndexJobStatus.paused,
          clearCurrentPath: true,
        );
        await jobStore.save(state);
        onProgress(state);
        await control.waitIfPaused();
        if (!control.isCancelled) {
          state = state.copyWith(status: IndexJobStatus.running);
          await jobStore.save(state);
          onProgress(state);
        }
      }
      if (control.isCancelled) {
        return cancelJob();
      }
      state = state.copyWith(discovered: state.discovered + 1);
      if (event is DiscoveryFailure) {
        discoveryFailed = true;
        final failure = _failure(
          state.jobId,
          ++failureSequence,
          event.path,
          'discovery',
          event.code,
          event.message,
        );
        failures.add(failure);
        await failureStore.put(failure);
        await _recordFileState(
          jobId: state.jobId,
          path: event.path,
          status: IndexFileStatus.failed,
          stage: 'discovery',
          message: event.message,
          onProgress: onFileProgress,
        );
        state = state.copyWith(failed: state.failed + 1);
        await jobStore.save(state);
        onProgress(state);
        continue;
      }
      final path = PathRules.canonical(event.path);
      seen.add(path);
      if (state.completedPaths.contains(path) &&
          registry.containsKey(FileObjectIds.fromPath(path))) {
        continue;
      }
      await _recordFileState(
        jobId: state.jobId,
        path: path,
        status: IndexFileStatus.discovered,
        stage: 'discovery',
        onProgress: onFileProgress,
      );
      if (control.isCancelled) return cancelJob();
      state = state.copyWith(currentPath: path);
      await jobStore.save(state);
      onProgress(state);
      try {
        final objectId = FileObjectIds.fromPath(path);
        final previous = registry[objectId];
        await _recordFileState(
          jobId: state.jobId,
          path: path,
          status: IndexFileStatus.discovered,
          stage: 'metadata',
          onProgress: onFileProgress,
        );
        final stat =
            previous == null || comparison.size || comparison.modifiedTime
            ? await File(path).stat()
            : null;
        var fingerprint = previous?.fingerprint ?? '';
        if (previous == null || comparison.hash) {
          await _recordFileState(
            jobId: state.jobId,
            path: path,
            status: IndexFileStatus.discovered,
            stage: 'fingerprinting',
            detail: 'SHA-256',
            onProgress: onFileProgress,
          );
          fingerprint = await _fingerprint(path);
        }
        if (previous != null &&
            !_requiresReindex(
              previous,
              comparison,
              stat: stat,
              fingerprint: fingerprint,
            )) {
          await _recordFileState(
            jobId: state.jobId,
            path: path,
            status: IndexFileStatus.unchanged,
            stage: 'comparison',
            onProgress: onFileProgress,
          );
          state = state.copyWith(
            processed: state.processed + 1,
            skipped: state.skipped + 1,
            completedPaths: {...state.completedPaths, path},
          );
        } else {
          await _recordFileState(
            jobId: state.jobId,
            path: path,
            status: IndexFileStatus.queued,
            stage: 'queued',
            onProgress: onFileProgress,
          );
          if (control.isCancelled) return await cancelJob();
          await _recordFileState(
            jobId: state.jobId,
            path: path,
            status: IndexFileStatus.processing,
            stage: 'processing',
            onProgress: onFileProgress,
          );
          if (control.isCancelled) return await cancelJob(path);
          // Keep the stored content fingerprint aligned with the newly indexed
          // bytes even when metadata, rather than hash comparison, triggered
          // this rebuild.
          if (previous != null && !comparison.hash) {
            fingerprint = await _fingerprint(path);
          }
          final object = await _process(
            path,
            fingerprint: fingerprint,
            objectVersion: (previous?.objectVersion ?? 0) + 1,
            observer: (progress) async {
              await _recordFileState(
                jobId: state.jobId,
                path: path,
                status: IndexFileStatus.processing,
                stage: progress.stage.name,
                completedUnits: progress.completedUnits,
                totalUnits: progress.totalUnits,
                detail: progress.detail,
                onProgress: onFileProgress,
              );
              final commitCompleted =
                  progress.stage == FileProcessingStage.indexCommit &&
                  progress.completedUnits != null &&
                  progress.completedUnits == progress.totalUnits;
              // Once the atomic commit has returned successfully, this object
              // is complete. A concurrent cancellation applies to the next
              // object; it must not roll this committed generation back.
              if (commitCompleted) return;
              if (control.isPaused) {
                state = state.copyWith(status: IndexJobStatus.paused);
                await jobStore.save(state);
                onProgress(state);
                await control.waitIfPaused();
                if (!control.isCancelled) {
                  state = state.copyWith(status: IndexJobStatus.running);
                  await jobStore.save(state);
                  onProgress(state);
                }
              }
              if (control.isCancelled) {
                throw const FileProcessingInterrupted();
              }
            },
          );
          registry[object.fileObjectId] = FileRegistryEntry.fromObject(object);
          registryChanges++;
          if (registryChanges >= registryCheckpointSize) {
            await registryStore.save(registry);
            registryChanges = 0;
          }
          state = state.copyWith(
            processed: state.processed + 1,
            succeeded: state.succeeded + 1,
            completedPaths: {...state.completedPaths, path},
          );
          await _recordFileState(
            jobId: state.jobId,
            path: path,
            status: IndexFileStatus.indexed,
            stage: 'committed',
            onProgress: onFileProgress,
          );
        }
      } catch (error) {
        if (error is FileProcessingInterrupted) return await cancelJob(path);
        final failure = _failure(
          state.jobId,
          ++failureSequence,
          path,
          'index',
          _errorCode(error),
          '$error',
        );
        failures.add(failure);
        await failureStore.put(failure);
        await _recordFileState(
          jobId: state.jobId,
          path: path,
          status: IndexFileStatus.failed,
          stage: 'processing',
          message: '$error',
          onProgress: onFileProgress,
        );
        state = state.copyWith(
          processed: state.processed + 1,
          failed: state.failed + 1,
          completedPaths: {...state.completedPaths, path},
        );
      }
      await checkpointStore.append(state.jobId, path);
      state = state.copyWith(clearCurrentPath: true);
      await jobStore.save(state);
      onProgress(state);
    }

    if (registryChanges > 0) await registryStore.save(registry);
    if (comparison.path && !discoveryFailed && !control.isCancelled) {
      await _removeMissing(
        scope,
        registry,
        seen,
        jobId: state.jobId,
        onFileProgress: onFileProgress,
      );
    }
    String? logPath;
    if (failures.isNotEmpty) {
      logPath = (await failureLog.write(
        directory: logDirectory,
        records: failures,
        name: 'failed-imports-${state.jobId}${FailureLogCodec.fileExtension}',
      )).path;
    }
    final finalFileStates = await fileStateStore.loadLatest(state.jobId);
    final resultLogPath = (await const IndexResultLogFile().write(
      directory: logDirectory,
      jobId: state.jobId,
      states: finalFileStates.values,
    )).path;
    state = state.copyWith(
      status: failures.isEmpty
          ? IndexJobStatus.completed
          : IndexJobStatus.partial,
      clearCurrentPath: true,
      failureLogPath: logPath,
      fileStateLogPath: resultLogPath,
      endedTime: DateTime.now().toUtc(),
    );
    await jobStore.save(state);
    onProgress(state);
    return state;
  }

  Future<FailureRetryPlan> retryFromLog(
    String logPath, {
    void Function(String path, bool success, String? error)? onResult,
  }) async {
    final parsed = await failureLog.read(logPath);
    final known = await failureStore.load();
    final plan = const FailureLogCodec().createRetryPlan(
      log: parsed,
      knownFailures: known,
    );
    final registry = await registryStore.load();
    for (final failure in plan.accepted) {
      try {
        final fingerprint = await _fingerprint(failure.path);
        final previous = registry[failure.fileObjectId];
        final object = await _process(
          failure.path,
          fingerprint: fingerprint,
          objectVersion: (previous?.objectVersion ?? 0) + 1,
        );
        registry[object.fileObjectId] = FileRegistryEntry.fromObject(object);
        await registryStore.save(registry);
        await failureStore.remove(failure.failureId);
        onResult?.call(failure.path, true, null);
      } catch (error) {
        final updated = IndexFailureRecord(
          failureId: failure.failureId,
          fileObjectId: failure.fileObjectId,
          path: failure.path,
          stage: 'retry',
          code: _errorCode(error),
          message: '$error',
          retryable: true,
          attempts: failure.attempts + 1,
          time: DateTime.now().toUtc(),
        );
        await failureStore.put(updated);
        onResult?.call(failure.path, false, '$error');
      }
    }
    return plan;
  }

  Future<FileObject> _process(
    String path, {
    required String fingerprint,
    required int objectVersion,
    FileProcessingObserver? observer,
  }) async {
    final parsed = await parser.parse(path, observer: observer);
    if (parsed.content.status != ExtractionStatus.completed) {
      final details = parsed.content.issues
          .map((issue) => issue.message)
          .where((message) => message.trim().isNotEmpty)
          .join('; ');
      throw StateError(
        details.isEmpty
            ? 'File extraction did not complete.'
            : 'File extraction did not complete: $details',
      );
    }
    final stat = await File(path).stat();
    final metadata = parsed.metadata.copyWith(
      filePath: PathRules.canonical(path),
      fileSize: stat.size,
      modifiedTime: stat.modified,
      accessedTime: stat.accessed,
      changedTime: stat.changed,
      fingerprint: fingerprint,
    );
    var object = FileObject.fromParsingResult(
      ParsingResult(metadata: metadata, content: parsed.content),
      origin: FileObjectOrigin.indexedLibrary,
      objectVersion: objectVersion,
    );
    final embeddings = await embeddingEngine.embedContent(
      object.content,
      observer: observer,
    );
    object = object.withEmbeddings(embeddings);
    if (embeddings.status != EmbeddingStatus.completed) {
      final details = embeddings.issues
          .map((issue) => issue.message)
          .where((message) => message.trim().isNotEmpty)
          .join('; ');
      throw StateError(
        details.isEmpty
            ? 'File embedding did not complete.'
            : 'File embedding did not complete: $details',
      );
    }
    if (object.analysis.isEmpty) {
      throw StateError('The file produced no indexable vectors.');
    }
    final records = await vectorStore.replaceFileObject(
      object,
      observer: observer,
    );
    return object.withIndex(
      FileIndexData(
        databaseProfileId: storage.profileId,
        indexVersion:
            '$objectVersion-${metadata.modifiedTime.microsecondsSinceEpoch}',
        indexedTime: DateTime.now().toUtc(),
        status: FileIndexStatus.indexed,
        textRecordIds: records.textRecordIds,
        imageRecordIds: records.imageRecordIds,
        audioRecordIds: records.audioRecordIds,
      ),
    );
  }

  Future<void> _removeMissing(
    IndexScope scope,
    Map<String, FileRegistryEntry> registry,
    Set<String> seen, {
    required String jobId,
    void Function(IndexFileState state)? onFileProgress,
  }) async {
    final removed = <String>[];
    for (final entry in registry.values) {
      final inScope =
          scope.mode == IndexScopeMode.allDevices ||
          scope.includedPaths.any(
            (root) => PathRules.isSameOrDescendant(entry.path, root),
          );
      if (inScope &&
          !scope.excludes(entry.path, systemPaths: storage.protectedPaths) &&
          !seen.contains(PathRules.canonical(entry.path))) {
        await vectorStore.removeFileObject(entry.fileObjectId);
        removed.add(entry.fileObjectId);
        await _recordFileState(
          jobId: jobId,
          path: entry.path,
          status: IndexFileStatus.removed,
          stage: 'cleanup',
          onProgress: onFileProgress,
        );
      }
    }
    for (final id in removed) {
      registry.remove(id);
    }
    if (removed.isNotEmpty) await registryStore.save(registry);
  }

  Future<String> _fingerprint(String path) async {
    return FileFingerprint.compute(path);
  }

  Future<void> _recordFileState({
    required String jobId,
    required String path,
    required IndexFileStatus status,
    required String stage,
    int? completedUnits,
    int? totalUnits,
    String? detail,
    String? message,
    void Function(IndexFileState state)? onProgress,
  }) async {
    final state = IndexFileState.forPath(
      jobId: jobId,
      path: path,
      status: status,
      stage: stage,
      completedUnits: completedUnits,
      totalUnits: totalUnits,
      detail: detail,
      message: message,
    );
    // The per-job result log stores one final outcome per handled file.
    // Intermediate states remain live UI events and are not persisted as
    // separate result rows.
    if (_isFinalFileResult(status)) await fileStateStore.append(state);
    onProgress?.call(state);
  }

  bool _isFinalFileResult(IndexFileStatus status) => switch (status) {
    IndexFileStatus.unchanged ||
    IndexFileStatus.indexed ||
    IndexFileStatus.failed ||
    IndexFileStatus.removed => true,
    IndexFileStatus.discovered ||
    IndexFileStatus.queued ||
    IndexFileStatus.processing ||
    IndexFileStatus.cancelled => false,
  };

  bool _requiresReindex(
    FileRegistryEntry previous,
    IndexComparisonOptions comparison, {
    required FileStat? stat,
    required String fingerprint,
  }) {
    if (!comparison.checksExistingFile) return false;
    if (previous.schemaVersion < FileRegistryEntry.currentSchemaVersion) {
      return true;
    }
    // Legacy partial/failed entries are never accepted as completed objects.
    if (previous.status != FileIndexStatus.indexed) return true;
    if (comparison.size && previous.fileSize != stat!.size) return true;
    if (comparison.modifiedTime &&
        previous.modifiedTime?.microsecondsSinceEpoch !=
            stat!.modified.toUtc().microsecondsSinceEpoch) {
      return true;
    }
    if (comparison.hash && previous.fingerprint != fingerprint) return true;
    return false;
  }

  IndexFailureRecord _failure(
    String jobId,
    int sequence,
    String path,
    String stage,
    String code,
    String message,
  ) => IndexFailureRecord(
    failureId: '$jobId-${sequence.toString().padLeft(6, '0')}',
    fileObjectId: FileObjectIds.fromPath(path),
    path: PathRules.canonical(path),
    stage: stage,
    code: code,
    message: message,
    retryable: code != 'UNSUPPORTED_FORMAT',
    attempts: 1,
    time: DateTime.now().toUtc(),
  );

  String _errorCode(Object error) {
    if (error is UnsupportedError) return 'UNSUPPORTED_FORMAT';
    if (error is FileSystemException) {
      final code = error.osError?.errorCode;
      if (code == 5 || code == 13) return 'PERMISSION_DENIED';
      if (code == 2 || code == 3) return 'PATH_NOT_FOUND';
      return 'FILE_SYSTEM_ERROR';
    }
    if (error is FormatException) return 'DAMAGED_FILE';
    return 'PROCESSING_FAILED';
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/parsing/file_parser_router.dart';
import '../embedding/multimodal_embedding_engine.dart';
import '../indexing/database_storage.dart';
import '../indexing/index_job.dart';
import '../indexing/index_comparison.dart';
import '../indexing/index_file_state.dart';
import '../indexing/index_scope.dart';
import '../indexing/index_coverage.dart';
import '../indexing/file_registry.dart';
import '../query/query_attachment_coordinator.dart';
import '../query/query_models.dart';
import '../storage/chroma_client.dart';
import '../storage/multimodal_vector_store.dart';
import 'local_chroma_service.dart';
import 'dependency_check.dart';
import 'runtime_configuration.dart';
import 'pdfium_runtime.dart';
import 'runtime_dependencies.dart';
import 'system_file_launcher.dart';
import 'ui_preferences.dart';

class ApplicationController extends ChangeNotifier {
  final RuntimeConfigurationStore configurationStore;
  final DatabaseStorageManager storageManager;
  final LocalChromaService localVectorService;
  final UiPreferencesStore uiPreferencesStore;
  final SystemFileLauncher fileLauncher;
  final bool onboardingEnabled;
  final AppLanguage? systemLanguage;

  RuntimeConfiguration? configuration;
  DatabaseStorageProfile? storage;
  IndexScope scope = IndexScope(mode: IndexScopeMode.selectedPaths);
  IndexJobState? indexState;
  final Map<String, IndexFileState> indexFileStates = {};
  IndexComparisonOptions indexComparison =
      const IndexComparisonOptions.standard();
  QueryResponse? queryResponse;
  UiPreferences uiPreferences = const UiPreferences();
  IndexCoverage indexCoverage = IndexCoverage();
  String statusMessage = '请先在“设置”中选择数据库存储位置。';
  bool busy = false;
  bool _runtimeStarting = false;

  ChromaClient? _vectorClient;
  MultimodalEmbeddingEngine? _embeddingEngine;
  IndexJobRunner? _indexRunner;
  QueryAttachmentCoordinator? _queryCoordinator;
  IndexJobControl? _jobControl;
  Future<void>? _uiPreferenceWrite;

  ApplicationController({
    RuntimeConfigurationStore? configurationStore,
    this.storageManager = const DatabaseStorageManager(),
    LocalChromaService? localVectorService,
    UiPreferencesStore? uiPreferencesStore,
    SystemFileLauncher? fileLauncher,
    this.onboardingEnabled = true,
    this.systemLanguage,
  }) : configurationStore =
           configurationStore ?? RuntimeConfigurationStore.platformDefault(),
       localVectorService = localVectorService ?? LocalChromaService(),
       uiPreferencesStore =
           uiPreferencesStore ?? UiPreferencesStore.platformDefault(),
       fileLauncher = fileLauncher ?? SystemFileLauncher.platformDefault();

  bool get ready => _indexRunner != null && _queryCoordinator != null;
  bool get runtimeStarting => _runtimeStarting;
  String get logDirectory =>
      configuration?.logDirectory ??
      RuntimeConfiguration.suggestedLogDirectory(storage?.selectedRootPath);
  bool get shouldShowOnboarding =>
      onboardingEnabled && !uiPreferences.onboardingCompleted;
  String _l(String chinese, String english) =>
      uiPreferences.language == AppLanguage.english ? english : chinese;
  bool get indexing =>
      indexState?.status == IndexJobStatus.queued ||
      indexState?.status == IndexJobStatus.running ||
      indexState?.status == IndexJobStatus.pausing ||
      indexState?.status == IndexJobStatus.paused ||
      indexState?.status == IndexJobStatus.cancelling;

  Future<void> initialize() async {
    try {
      final savedPreferences = await uiPreferencesStore.load();
      if (savedPreferences == null) {
        final detectedLanguage =
            systemLanguage ??
            (PlatformDispatcher.instance.locale.languageCode.toLowerCase() ==
                    'zh'
                ? AppLanguage.simplifiedChinese
                : AppLanguage.english);
        uiPreferences = UiPreferences(language: detectedLanguage);
        await uiPreferencesStore.save(uiPreferences);
      } else {
        uiPreferences = savedPreferences;
      }
      configuration = await configurationStore.load();
      final current = configuration;
      if (current == null) {
        statusMessage = _l(
          '尚未完成初始设置，请前往“设置”选择索引数据的保存位置',
          'Initial setup is incomplete. Open Settings and choose where to store the index.',
        );
        return;
      }
      final prepared = await storageManager.prepare(current.databaseRoot);
      if (!prepared.writable) {
        statusMessage = _l(
          '已保存的数据库位置不可写：${prepared.issues.join('；')}',
          'The saved database location is not writable: ${prepared.issues.join('; ')}',
        );
        return;
      }
      storage = prepared.profile;
      await _loadScope();
      await _loadIndexCoverage();
      statusMessage = _l(
        '配置已读取。需要使用时请在设置中启动本地服务。',
        'Configuration loaded. Start the local service in Settings when needed.',
      );
    } catch (error) {
      statusMessage = _l(
        '读取配置失败：$error',
        'Failed to load configuration: $error',
      );
    } finally {
      notifyListeners();
    }
  }

  Future<void> saveConfigurationAndStart({
    required String databaseRoot,
    required String applicationDirectory,
    required String pythonExecutable,
    required String logDirectory,
    Map<String, String> dependencyPaths = const {},
  }) async {
    await _runBusy(() async {
      _updateStatus('正在准备数据库目录…', 'Preparing the database folder…');
      final prepared = await storageManager.prepare(databaseRoot.trim());
      if (!prepared.writable) {
        throw FileSystemException(
          '数据库位置不可写：${prepared.issues.join('；')}',
          databaseRoot,
        );
      }
      final selectedLogDirectory = Directory(logDirectory.trim());
      if (selectedLogDirectory.path.isEmpty) {
        throw ArgumentError(
          _l('日志存储位置不能为空。', 'The log folder cannot be empty.'),
        );
      }
      await selectedLogDirectory.create(recursive: true);
      final logProbe = File(
        p.join(
          selectedLogDirectory.path,
          '.write-probe-$pid-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await logProbe.writeAsString('log-write-check', flush: true);
      await logProbe.delete();
      final next = RuntimeConfiguration(
        databaseRoot: prepared.profile.selectedRootPath,
        applicationDirectory: PathRules.canonical(applicationDirectory.trim()),
        pythonExecutable: PathRules.canonical(pythonExecutable.trim()),
        logDirectory: PathRules.canonical(selectedLogDirectory.path),
        dependencyPaths: dependencyPaths,
      );
      if (ready && _sameRuntimeConfiguration(configuration, next)) {
        await configurationStore.save(next);
        configuration = next;
        storage = prepared.profile;
        _updateStatus(
          '配置没有变化，本地服务继续运行。',
          'The configuration is unchanged. The local service remains running.',
        );
        return;
      }
      _updateStatus('正在校验本地运行环境…', 'Validating the local runtime…');
      await _validateRuntime(next);
      _updateStatus('正在停止旧的本地服务…', 'Stopping the previous local service…');
      await _stopRuntime();
      _updateStatus('正在保存配置…', 'Saving configuration…');
      await configurationStore.save(next);
      configuration = next;
      storage = prepared.profile;
      _updateStatus('正在读取索引状态…', 'Loading index state…');
      await _loadScope();
      await _loadIndexCoverage();
      await _startRuntime(validate: false);
      statusMessage = _l(
        '数据库、文件读取和三类向量服务均已就绪。',
        'The database, file reader, and all three vector services are ready.',
      );
    });
  }

  Future<DependencyCheckReport> checkDependencies({
    required String applicationDirectory,
    required String pythonDirectory,
    required Map<String, String> dependencyPaths,
  }) async {
    if (busy) {
      throw StateError(_l('当前已有任务正在执行。', 'Another task is already running.'));
    }
    busy = true;
    _updateStatus('正在检查全部本地依赖…', 'Checking all local dependencies…');
    try {
      final report = await DependencyCheck.run(
        applicationDirectory: applicationDirectory,
        pythonExecutable: RuntimeConfiguration.resolvePythonExecutable(
          applicationDirectory: applicationDirectory,
          configuredPath: pythonDirectory,
        ),
        dependencyPaths: dependencyPaths,
      );
      statusMessage = report.complete
          ? _l('全部依赖均已准备完成。', 'All dependencies are ready.')
          : _l(
              '依赖尚未完整：${report.allMissing.join('、')}',
              'Dependencies are incomplete: ${report.allMissing.join(', ')}',
            );
      return report;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<DependencyCheckReport> installLowerDependencies({
    required String applicationDirectory,
    required String pythonDirectory,
    required Map<String, String> dependencyPaths,
    required bool installToProgram,
  }) async {
    if (busy) {
      throw StateError(_l('当前已有任务正在执行。', 'Another task is already running.'));
    }
    busy = true;
    _updateStatus(
      '正在通过网络安装 Python 组件和模型，请勿关闭程序…',
      'Installing Python components and models from the network. Do not close the app…',
    );
    try {
      final python = RuntimeConfiguration.resolvePythonExecutable(
        applicationDirectory: applicationDirectory,
        configuredPath: pythonDirectory,
      );
      if (python.isEmpty) {
        throw FileSystemException(
          _l('必须先配置 Python。', 'Python must be configured first.'),
        );
      }
      final script = p.join(
        applicationDirectory,
        'services',
        'dependencies',
        'install_runtime.py',
      );
      final process = await Process.run(python, [
        script,
        '--mode',
        installToProgram ? 'program' : 'python',
        '--program-root',
        applicationDirectory,
      ], workingDirectory: applicationDirectory);
      if (process.exitCode != 0) {
        throw ProcessException(
          python,
          [script],
          '${process.stderr}',
          process.exitCode,
        );
      }
      final output = '${process.stdout}'.trim().split('\n').last;
      final installed = jsonDecode(output) as Map<String, dynamic>;
      final installedPython = '${installed['python']}';
      final installedModels = '${installed['models']}';
      final nextPaths = {...dependencyPaths, 'modelRoot': installedModels};
      final current = configuration;
      if (current != null) {
        final next = RuntimeConfiguration(
          databaseRoot: current.databaseRoot,
          applicationDirectory: applicationDirectory,
          pythonExecutable: File(installedPython).parent.path,
          logDirectory: current.logDirectory,
          dependencyPaths: nextPaths,
        );
        await configurationStore.save(next);
        configuration = next;
      }
      final report = await DependencyCheck.run(
        applicationDirectory: applicationDirectory,
        pythonExecutable: installedPython,
        dependencyPaths: nextPaths,
      );
      statusMessage = report.complete
          ? _l('依赖安装并校验完成。', 'Dependencies were installed and verified.')
          : _l(
              '安装已结束，但仍缺少：${report.allMissing.join('、')}',
              'Installation finished, but these items are still missing: ${report.allMissing.join(', ')}',
            );
      return report;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> migrateDatabaseAndStart(String destinationRoot) async {
    final currentStorage = storage;
    final currentConfiguration = configuration;
    if (currentStorage == null || currentConfiguration == null) {
      throw StateError(
        _l('尚未配置源数据库。', 'The source database is not configured.'),
      );
    }
    await _runBusy(() async {
      _updateStatus('正在停止本地服务…', 'Stopping the local service…');
      await _stopRuntime();
      _updateStatus('正在准备新的数据库位置…', 'Preparing the new database location…');
      final migration = await storageManager.migrate(
        source: currentStorage,
        destinationRootPath: destinationRoot.trim(),
        onProgress: (progress) {
          switch (progress.phase) {
            case 'copying':
              _updateStatus(
                '正在复制数据库：已复制 ${progress.filesCopied} 个文件…',
                'Copying the database: ${progress.filesCopied} files copied…',
              );
            case 'verifying':
              _updateStatus('正在校验复制后的数据库…', 'Verifying the copied database…');
          }
        },
      );
      final next = RuntimeConfiguration(
        databaseRoot: migration.destination.selectedRootPath,
        applicationDirectory: currentConfiguration.applicationDirectory,
        pythonExecutable: currentConfiguration.pythonExecutable,
        logDirectory: currentConfiguration.logDirectory,
        dependencyPaths: currentConfiguration.dependencyPaths,
      );
      _updateStatus('正在保存新的数据库配置…', 'Saving the new database configuration…');
      await configurationStore.save(next);
      configuration = next;
      storage = migration.destination;
      _updateStatus('正在读取迁移后的索引状态…', 'Loading the migrated index state…');
      await _loadScope();
      await _loadIndexCoverage();
      await _startRuntime();
      statusMessage = _l(
        '数据库已复制并校验：${migration.filesCopied} 个文件，${migration.bytesCopied} 字节；原位置仍保留。',
        'Database copied and verified: ${migration.filesCopied} files, ${migration.bytesCopied} bytes. The original remains in place.',
      );
    });
  }

  Future<void> startSavedRuntime() async {
    if (configuration == null || storage == null) {
      throw StateError(
        _l(
          '请先保存数据库和运行环境配置。',
          'Save the database and runtime configuration first.',
        ),
      );
    }
    await _runBusy(() async {
      await _startRuntime();
      statusMessage = _l('本地服务已启动。', 'The local service has started.');
    });
  }

  Future<void> setScopeMode(IndexScopeMode mode) async {
    scope = IndexScope(
      mode: mode,
      includedPaths: scope.includedPaths,
      excludedPaths: scope.excludedPaths,
      recursive: scope.recursive,
    );
    await _saveScope();
    notifyListeners();
  }

  Future<void> addIndexPath(String path) async {
    if (path.trim().isEmpty) return;
    scope = scope.addPath(path.trim());
    await _saveScope();
    notifyListeners();
  }

  Future<void> replaceIndexPath(String oldPath, String newPath) async {
    if (newPath.trim().isEmpty) return;
    scope = scope.replacePath(oldPath, newPath.trim());
    await _saveScope();
    notifyListeners();
  }

  Future<void> removeIndexPath(String path) async {
    scope = scope.removePath(path);
    await _saveScope();
    notifyListeners();
  }

  Future<void> replaceIndexPaths(Iterable<String> paths) async {
    scope = IndexScope(
      mode: IndexScopeMode.selectedPaths,
      includedPaths: paths,
      excludedPaths: scope.excludedPaths,
      recursive: scope.recursive,
    );
    await _saveScope();
    statusMessage = _l(
      '已将未建立索引的查询范围填入文件库，请确认后手动开始扫描。',
      'The unindexed search locations were added to the library. Review them, then start scanning manually.',
    );
    notifyListeners();
  }

  Future<void> mergeIndexPaths(Iterable<String> paths) async {
    scope = IndexScope(
      mode: IndexScopeMode.selectedPaths,
      includedPaths: [...scope.includedPaths, ...paths],
      excludedPaths: scope.excludedPaths,
      recursive: scope.recursive,
    );
    await _saveScope();
    statusMessage = _l(
      '已合并原有路径和未建立索引的查询范围，请确认后手动开始扫描。',
      'The existing library locations and unindexed search locations were merged. Review them, then start scanning manually.',
    );
    notifyListeners();
  }

  Future<void> addExcludedPath(String path) async {
    if (path.trim().isEmpty) return;
    scope = scope.exclude(path.trim());
    await _saveScope();
    notifyListeners();
  }

  Future<void> removeExcludedPath(String path) async {
    final target = PathRules.canonical(path);
    scope = IndexScope(
      mode: scope.mode,
      includedPaths: scope.includedPaths,
      excludedPaths: scope.excludedPaths.where((item) => item != target),
      recursive: scope.recursive,
    );
    await _saveScope();
    notifyListeners();
  }

  Future<void> runIndex() async {
    final runner = _indexRunner;
    if (runner == null) {
      throw StateError(_l('本地服务尚未启动。', 'The local service has not started.'));
    }
    if (indexing) {
      throw StateError(
        _l('已有索引任务正在运行。', 'An indexing task is already running.'),
      );
    }
    if (scope.mode == IndexScopeMode.selectedPaths &&
        scope.includedPaths.isEmpty) {
      throw StateError(
        _l('请先添加至少一个文件或文件夹路径。', 'Add at least one file or folder path first.'),
      );
    }
    _jobControl = IndexJobControl();
    indexState = null;
    indexFileStates.clear();
    busy = true;
    statusMessage = _l('索引任务正在等待开始。', 'The indexing task is waiting to start.');
    notifyListeners();
    try {
      indexState = await runner.run(
        scope: scope,
        comparison: indexComparison,
        control: _jobControl,
        onProgress: (value) {
          indexState = value;
          statusMessage = _indexProgressStatus(value);
          notifyListeners();
        },
        onFileProgress: (value) {
          indexFileStates[value.fileObjectId] = value;
          statusMessage = _fileProgressStatus(value);
          notifyListeners();
        },
      );
      final result = indexState!;
      if (result.status == IndexJobStatus.completed) {
        indexCoverage = scope.mode == IndexScopeMode.allDevices
            ? IndexCoverage(allDevices: true, roots: indexCoverage.roots)
            : indexCoverage.addRoots(scope.includedPaths);
        await _saveIndexCoverage();
      }
      statusMessage = switch (result.status) {
        IndexJobStatus.completed => _l(
          '索引更新成功。',
          'Index update completed successfully.',
        ),
        IndexJobStatus.partial => _l(
          '索引更新部分完成。请打开高级信息查看详情。',
          'Index update partially completed. Open Advanced information for details.',
        ),
        IndexJobStatus.cancelled => _l('索引更新已取消。', 'Index update cancelled.'),
        IndexJobStatus.failed => _l(
          '索引更新失败。请打开高级信息查看详情。',
          'Index update failed. Open Advanced information for details.',
        ),
        _ => _l('索引更新已结束。', 'Index update finished.'),
      };
    } catch (error) {
      statusMessage = _l('索引任务失败：$error', 'Indexing task failed: $error');
      rethrow;
    } finally {
      busy = false;
      _jobControl = null;
      notifyListeners();
    }
  }

  Future<void> clearAllIndexes() async {
    await _runBusy(() async {
      final currentStorage = storage;
      if (currentStorage == null || configuration == null) {
        throw StateError(
          _l('请先完成数据库配置。', 'Configure the index database first.'),
        );
      }
      if (indexing) {
        throw StateError(
          _l('请先停止正在运行的索引任务。', 'Stop the active indexing task first.'),
        );
      }
      _updateStatus('正在停止本地服务…', 'Stopping the local service…');
      await _stopRuntime();
      _updateStatus(
        '正在删除索引、向量、处理记录和日志…',
        'Deleting indexes, vectors, processing records, and logs…',
      );
      await storageManager.clearAllIndexes(currentStorage);
      if (PathRules.canonical(logDirectory) !=
          PathRules.canonical(currentStorage.failureLogDirectory)) {
        final customLogs = Directory(logDirectory);
        if (await customLogs.exists()) {
          await for (final entity in customLogs.list(followLinks: false)) {
            if (entity is! File) continue;
            final name = p.basename(entity.path);
            if ((name.startsWith('index-results-') && name.endsWith('.log')) ||
                name.endsWith('.retrieval-failures.log')) {
              await entity.delete();
            }
          }
        }
      }
      indexState = null;
      indexFileStates.clear();
      indexCoverage = IndexCoverage();
      queryResponse = null;
      _updateStatus(
        '索引数据已清空，正在重新启动本地服务…',
        'Index data cleared. Restarting the local service…',
      );
      await _startRuntime();
      statusMessage = _l(
        '全部索引已清空，本地服务已重新启动。',
        'All indexes were cleared and the local service was restarted.',
      );
    });
  }

  void setIndexComparisonPreset(IndexComparisonPreset preset) {
    if (preset == IndexComparisonPreset.custom) return;
    indexComparison = IndexComparisonOptions.forPreset(preset);
    notifyListeners();
  }

  void setIndexComparison(IndexComparisonOptions value) {
    indexComparison = value;
    notifyListeners();
  }

  void pauseIndex() {
    _jobControl?.pause();
    final current = indexState;
    if (current?.status == IndexJobStatus.running ||
        current?.status == IndexJobStatus.queued) {
      indexState = current!.copyWith(status: IndexJobStatus.pausing);
      statusMessage = _l(
        '已收到暂停请求；当前文件到达安全边界后暂停。',
        'Pause requested. The task will pause at the next safe file boundary.',
      );
      notifyListeners();
    }
  }

  void resumeIndex() {
    _jobControl?.resume();
    final current = indexState;
    if (current != null) {
      indexState = current.copyWith(status: IndexJobStatus.running);
      statusMessage = _l('索引任务已继续。', 'The indexing task has resumed.');
      notifyListeners();
    }
  }

  void cancelIndex() {
    _jobControl?.cancel();
    final current = indexState;
    if (current != null && indexing) {
      indexState = current.copyWith(status: IndexJobStatus.cancelling);
    }
    statusMessage = _l(
      '已收到停止请求；当前文件到达安全边界后停止。',
      'Stop requested. The task will stop at the next safe file boundary.',
    );
    notifyListeners();
  }

  Future<void> retryFailureLog(String path) async {
    final runner = _indexRunner;
    if (runner == null) {
      throw StateError(_l('本地服务尚未启动。', 'The local service has not started.'));
    }
    await _runBusy(() async {
      var completed = 0;
      _updateStatus(
        '正在读取并校验失败重试记录…',
        'Reading and validating the failure retry record…',
      );
      final plan = await runner.retryFromLog(
        path.trim(),
        onResult: (path, success, error) {
          completed++;
          _updateStatus(
            '正在重新处理失败文件：已完成 $completed 个；当前 ${p.basename(path)}',
            'Retrying failed files: $completed completed; current ${p.basename(path)}',
          );
        },
      );
      statusMessage = _l(
        '失败日志重试完成：接受 ${plan.accepted.length} 条，拒绝 ${plan.rejected.length} 条。',
        'Failure-log retry completed: ${plan.accepted.length} accepted and ${plan.rejected.length} rejected.',
      );
    });
  }

  Future<void> search(QueryRequest request) async {
    final coordinator = _queryCoordinator;
    if (coordinator == null) {
      throw StateError(_l('本地服务尚未启动。', 'The local service has not started.'));
    }
    await _runBusy(() async {
      queryResponse = await coordinator.search(
        request,
        onProgress: (stage, current, total) {
          statusMessage = switch (stage) {
            'preparing' => _l('正在准备查询…', 'Preparing the search…'),
            'description' => _l(
              '正在解析文字查询并匹配索引（$current/$total）…',
              'Processing the text query and matching the index ($current/$total)…',
            ),
            'attachment' => _l(
              '正在解析查询附件并匹配索引（$current/$total）…',
              'Processing a query attachment and matching the index ($current/$total)…',
            ),
            _ => _l('正在整理查询结果…', 'Finalizing search results…'),
          };
          notifyListeners();
        },
      );
      statusMessage = _l(
        '查询完成：${queryResponse!.units.length} 个独立查询单元。',
        'Search completed: ${queryResponse!.units.length} independent query units.',
      );
    });
  }

  Future<void> loadQueryPage(String queryUnitId, int pageIndex) async {
    final coordinator = _queryCoordinator;
    final response = queryResponse;
    if (coordinator == null || response == null) {
      throw StateError(
        _l('当前没有可分页的查询结果。', 'There are no search results to page through.'),
      );
    }
    _updateStatus(
      '正在加载查询结果第 ${pageIndex + 1} 页…',
      'Loading search result page ${pageIndex + 1}…',
    );
    final replacement = await coordinator.page(queryUnitId, pageIndex);
    queryResponse = QueryResponse(
      units: response.units
          .map((unit) => unit.queryUnitId == queryUnitId ? replacement : unit)
          .toList(growable: false),
    );
    statusMessage = _l(
      '查询结果第 ${pageIndex + 1} 页已加载。',
      'Search result page ${pageIndex + 1} loaded.',
    );
    notifyListeners();
  }

  Future<void> refineQueryResults(
    String queryUnitId,
    FileQueryRefinement refinement,
  ) async {
    final coordinator = _queryCoordinator;
    final response = queryResponse;
    if (coordinator == null || response == null) {
      throw StateError(
        _l('当前没有可筛选的查询结果。', 'There are no search results to filter.'),
      );
    }
    _updateStatus('正在应用结果筛选和排序…', 'Applying result filters and sorting…');
    final replacement = await coordinator.refine(queryUnitId, refinement);
    queryResponse = QueryResponse(
      units: response.units
          .map((unit) => unit.queryUnitId == queryUnitId ? replacement : unit)
          .toList(growable: false),
    );
    statusMessage = _l(
      '结果筛选和排序已完成。',
      'Result filtering and sorting completed.',
    );
    notifyListeners();
  }

  Future<List<String>> unindexedQueryPaths(Iterable<String> paths) async {
    _updateStatus(
      '正在检查所选查询范围的索引覆盖情况…',
      'Checking index coverage for the selected search locations…',
    );
    // Compare with canonical paths, but retain the spelling/case selected by
    // the user for warnings and subsequent actions.
    final selectedByCanonical = <String, String>{};
    for (final path in paths) {
      final selected = path.trim();
      if (selected.isEmpty) continue;
      selectedByCanonical.putIfAbsent(
        PathRules.canonical(selected),
        () => selected,
      );
    }
    final normalized = selectedByCanonical.keys.toList()..sort();
    final missing = <String>[];
    for (final path in normalized) {
      final exists =
          await FileSystemEntity.type(path) != FileSystemEntityType.notFound;
      final excluded = scope.excludes(
        path,
        systemPaths: storage?.protectedPaths ?? const [],
      );
      final covered = indexCoverage.covers(path);
      if (!exists || excluded || !covered) {
        missing.add(selectedByCanonical[path]!);
      }
    }
    statusMessage = missing.isEmpty
        ? _l('所选查询范围均已建立索引。', 'All selected search locations are indexed.')
        : _l(
            '发现 ${missing.length} 个尚未建立索引的查询范围。',
            '${missing.length} selected search locations are not indexed.',
          );
    notifyListeners();
    return List.unmodifiable(missing);
  }

  Future<void> setColorMode(UiColorMode mode) async {
    uiPreferences = uiPreferences.copyWith(colorMode: mode);
    notifyListeners();
    await _saveUiPreferences();
  }

  Future<void> setColorPreset(UiColorPreset preset) async {
    uiPreferences = uiPreferences.copyWith(colorPreset: preset);
    notifyListeners();
    await _saveUiPreferences();
  }

  Future<void> setColorVisionPreset(ColorVisionPreset preset) async {
    uiPreferences = uiPreferences.copyWith(colorVisionPreset: preset);
    notifyListeners();
    await _saveUiPreferences();
  }

  Future<void> setHighContrast(bool enabled) async {
    uiPreferences = uiPreferences.copyWith(highContrast: enabled);
    notifyListeners();
    await _saveUiPreferences();
  }

  Future<void> setLanguage(AppLanguage language) async {
    uiPreferences = uiPreferences.copyWith(language: language);
    statusMessage = _l(
      ready ? '索引与查询服务已启动' : '索引与查询服务未启动。请先到“设置”保存配置并启动。',
      ready ? 'The indexing and search service is running.' : 'The indexing and search service is not running. Open Settings, save the configuration, and start it.',
    );
    notifyListeners();
    await _saveUiPreferences();
  }

  Future<void> setTextSize(AppTextSize size) async {
    uiPreferences = uiPreferences.copyWith(textSize: size);
    notifyListeners();
    await _saveUiPreferences();
  }

  Future<void> completeOnboarding() async {
    if (uiPreferences.onboardingCompleted) return;
    uiPreferences = uiPreferences.copyWith(onboardingCompleted: true);
    notifyListeners();
    await _saveUiPreferences();
  }

  Future<void> resetSavedConfiguration() async {
    _updateStatus('正在停止本地服务…', 'Stopping the local service…');
    await _stopRuntime();
    final currentStorage = storage;
    if (currentStorage != null) {
      await IndexScopeStore(
        File(p.join(currentStorage.indexStateDirectory, 'index-scope.json')),
      ).delete();
    }
    _updateStatus(
      '正在清除扫描范围和程序配置…',
      'Clearing scan scope and application configuration…',
    );
    await configurationStore.delete();
    await uiPreferencesStore.delete();
    configuration = null;
    storage = null;
    scope = IndexScope(mode: IndexScopeMode.selectedPaths);
    uiPreferences = const UiPreferences();
    statusMessage = _l(
      '配置已清除，重启程序后将恢复首次使用状态。',
      'Configuration cleared. Restart the application to restore the first-run state.',
    );
    notifyListeners();
  }

  Future<void> resetSavedConfigurationAndRestart() async {
    await resetSavedConfiguration();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await Process.start(
        Platform.resolvedExecutable,
        Platform.executableArguments,
        mode: ProcessStartMode.detached,
        workingDirectory: File(Platform.resolvedExecutable).parent.path,
      );
      exit(0);
    }
  }

  Future<void> _saveUiPreferences() {
    final previous = _uiPreferenceWrite;
    final snapshot = uiPreferences;
    final write = () async {
      try {
        if (previous != null) await previous;
      } catch (_) {
        // A later preference change can still be persisted after one failure.
      }
      await uiPreferencesStore.save(snapshot);
    }();
    _uiPreferenceWrite = write;
    return write;
  }

  void clearQuery() {
    queryResponse = null;
    statusMessage = _l('查询内容已清除。', 'Search content cleared.');
    notifyListeners();
  }

  Future<void> openResult(String path) => fileLauncher.openFile(
    path,
    english: uiPreferences.language == AppLanguage.english,
  );

  Future<void> openResultWith(String path, {String? applicationPath}) =>
      fileLauncher.openFileWith(
        path,
        applicationPath: applicationPath,
        english: uiPreferences.language == AppLanguage.english,
      );

  Future<void> revealResult(String path) => fileLauncher.revealFile(
    path,
    english: uiPreferences.language == AppLanguage.english,
  );

  Future<void> openLogDirectory() async {
    final directory = Directory(logDirectory);
    await directory.create(recursive: true);
    await fileLauncher.openFile(
      directory.path,
      english: uiPreferences.language == AppLanguage.english,
    );
  }

  Future<void> _loadScope() async {
    final currentStorage = storage!;
    final store = IndexScopeStore(
      File(p.join(currentStorage.indexStateDirectory, 'index-scope.json')),
    );
    scope =
        await store.load() ?? IndexScope(mode: IndexScopeMode.selectedPaths);
  }

  Future<void> _saveScope() async {
    final currentStorage = storage;
    if (currentStorage == null) return;
    await IndexScopeStore(
      File(p.join(currentStorage.indexStateDirectory, 'index-scope.json')),
    ).save(scope);
  }

  Future<void> _loadIndexCoverage() async {
    final currentStorage = storage;
    if (currentStorage == null) return;
    indexCoverage = await IndexCoverageStore(
      File(p.join(currentStorage.indexStateDirectory, 'index-coverage.json')),
    ).load();
  }

  Future<void> _saveIndexCoverage() async {
    final currentStorage = storage;
    if (currentStorage == null) return;
    await IndexCoverageStore(
      File(p.join(currentStorage.indexStateDirectory, 'index-coverage.json')),
    ).save(indexCoverage);
  }

  Future<void> _validateRuntime(RuntimeConfiguration value) async {
    final pythonExecutable = RuntimeConfiguration.resolvePythonExecutable(
      applicationDirectory: value.applicationDirectory,
      configuredPath: value.pythonExecutable,
    );
    if (pythonExecutable.isEmpty) {
      throw ArgumentError(
        _l(
          '未找到 Python 解释器。请在设置中选择包含 Python 可执行文件的文件夹。',
          'No Python interpreter was found. Choose the folder containing the Python executable in Settings.',
        ),
      );
    }
    final application = Directory(value.applicationDirectory);
    if (!await application.exists()) {
      throw FileSystemException(
        _l('项目运行目录不存在', 'The application runtime folder does not exist'),
        application.path,
      );
    }
    final modelRoot = DependencyCheck.resolveModelRoot(
      applicationDirectory: application.path,
      pythonExecutable: pythonExecutable,
      configuredModelRoot: value.dependencyPaths['modelRoot'],
    );
    final required = [
      p.join(application.path, 'services', 'chroma', 'service.py'),
      if (modelRoot != null) p.join(modelRoot, 'image', 'mobileclip_s0.pt'),
      p.join(modelRoot ?? '', 'audio', 'faster-whisper-medium', 'model.bin'),
      p.join(modelRoot ?? '', 'audio', 'clap-htsat-fused', 'model.safetensors'),
    ];
    final missing = <String>[];
    for (final path in required) {
      if (!await File(path).exists()) missing.add(path);
    }
    if (missing.isNotEmpty) {
      throw FileSystemException(
        _l(
          '缺少运行文件：${missing.join('；')}',
          'Required runtime files are missing: ${missing.join('; ')}',
        ),
      );
    }
    final dependencyReport = await DependencyCheck.run(
      applicationDirectory: application.path,
      pythonExecutable: pythonExecutable,
      dependencyPaths: value.dependencyPaths,
    );
    if (!dependencyReport.complete) {
      throw StateError(
        _l(
          '依赖尚未准备完整：${dependencyReport.allMissing.join('、')}。请先使用“检查依赖”。',
          'Dependencies are incomplete: ${dependencyReport.allMissing.join(', ')}. Run Check dependencies first.',
        ),
      );
    }
    final pdfiumLibrary = PdfiumRuntime.resolve(
      applicationDirectory: application.path,
      explicitLibrary: RuntimeDependencies.resolve(
        RuntimeDependency.pdfium,
        applicationDirectory: application.path,
        configuredPath: value.dependencyPaths['pdfium'],
      ),
    );
    if (pdfiumLibrary == null) {
      throw FileSystemException(
        _l(
          '未找到当前操作系统可用的 PDFium 动态库。请设置 PDFIUM_LIBRARY，或将动态库放入程序的对应平台依赖目录。',
          'No PDFium library is available for this operating system. Set PDFIUM_LIBRARY or place the library in the packaged platform dependency folder.',
        ),
      );
    }
    final result = await Process.run(pythonExecutable, const ['--version']);
    if (result.exitCode != 0) {
      throw ProcessException(
        pythonExecutable,
        const ['--version'],
        '${result.stderr}',
        result.exitCode,
      );
    }
  }

  Future<void> _startRuntime({bool validate = true}) async {
    if (ready) return;
    _runtimeStarting = true;
    notifyListeners();
    try {
      final config = configuration!;
      final currentStorage = storage!;
      if (validate) {
        _updateStatus('正在校验本地运行环境…', 'Validating the local runtime…');
        await _validateRuntime(config);
      }
      final root = config.applicationDirectory;
      final pythonExecutable = RuntimeConfiguration.resolvePythonExecutable(
        applicationDirectory: root,
        configuredPath: config.pythonExecutable,
      );
      final modelRoot = DependencyCheck.resolveModelRoot(
        applicationDirectory: root,
        pythonExecutable: pythonExecutable,
        configuredModelRoot: config.dependencyPaths['modelRoot'],
      )!;
      final imageModel = p.join(modelRoot, 'image', 'mobileclip_s0.pt');
      final whisperModel = p.join(modelRoot, 'audio', 'faster-whisper-medium');
      final clapModel = p.join(modelRoot, 'audio', 'clap-htsat-fused');
      final pdfiumLibraryPath = PdfiumRuntime.resolve(
        applicationDirectory: root,
        explicitLibrary: RuntimeDependencies.resolve(
          RuntimeDependency.pdfium,
          applicationDirectory: root,
          configuredPath: config.dependencyPaths['pdfium'],
        ),
      );
      String dependency(RuntimeDependency value) => RuntimeDependencies.resolve(
        value,
        applicationDirectory: root,
        configuredPath: config.dependencyPaths[value.name],
      );
      final djvuDirectory = dependency(RuntimeDependency.djvuLibre);
      final ghostDirectory = dependency(RuntimeDependency.ghostPdl);
      final parser = FileParserRouter.python(
        mobileClipModelPath: imageModel,
        whisperModelPath: whisperModel,
        clapModelPath: clapModel,
        pythonExecutable: pythonExecutable,
        javaExecutable: dependency(RuntimeDependency.java),
        tikaJarPath: dependency(RuntimeDependency.tika),
        tesseractExecutable: dependency(RuntimeDependency.tesseract),
        browserExecutable: dependency(RuntimeDependency.browser),
        djvuRenderExecutable: RuntimeDependencies.executableIn(
          RuntimeDependency.djvuLibre,
          djvuDirectory,
        ),
        djvuTextExecutable: _siblingExecutable(
          djvuDirectory,
          Platform.isWindows ? 'djvutxt.exe' : 'djvutxt',
        ),
        djvuScriptExecutable: _siblingExecutable(
          djvuDirectory,
          Platform.isWindows ? 'djvused.exe' : 'djvused',
        ),
        ghostscriptExecutable: RuntimeDependencies.executableIn(
          RuntimeDependency.ghostPdl,
          ghostDirectory,
        ),
        xpsRendererExecutable: _siblingExecutable(
          ghostDirectory,
          Platform.isWindows ? 'gxpswin64c.exe' : 'gxps',
        ),
        jxrDecoderExecutable: dependency(RuntimeDependency.jpegXr),
        pdfiumLibraryPath: pdfiumLibraryPath,
        workingDirectory: root,
        temporaryDirectoryPath: currentStorage.temporaryDirectory,
      );
      _updateStatus(
        '正在加载文本模型并分配内存…',
        'Loading the text model and allocating memory…',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final embedding = await MultimodalEmbeddingEngine.load(
        mobileClipModelPath: imageModel,
        clapModelPath: clapModel,
        pythonExecutable: pythonExecutable,
        workingDirectory: root,
      );
      try {
        _updateStatus('正在启动本地向量数据库…', 'Starting the local vector database…');
        final client = await localVectorService.start(
          pythonExecutable: pythonExecutable,
          serviceScript: p.join(root, 'services', 'chroma', 'service.py'),
          dataDirectory: currentStorage.chromaDirectory,
          workingDirectory: root,
        );
        _updateStatus(
          '正在完成索引与查询服务初始化…',
          'Finishing indexing and search service initialization…',
        );
        _embeddingEngine = embedding;
        _vectorClient = client;
        _indexRunner = IndexJobRunner(
          parser: parser,
          embeddingEngine: embedding,
          vectorStore: client,
          storage: currentStorage,
          logDirectory: config.logDirectory,
        );
        _queryCoordinator = QueryAttachmentCoordinator(
          parser: parser,
          embeddingEngine: embedding,
          vectorStore: client,
          registryStore: FileRegistryStore(
            File(
              p.join(currentStorage.registryDirectory, 'file-registry.json'),
            ),
          ),
        );
      } catch (_) {
        embedding.close();
        rethrow;
      }
    } finally {
      _runtimeStarting = false;
      notifyListeners();
    }
  }

  void _updateStatus(String chinese, String english) {
    statusMessage = _l(chinese, english);
    notifyListeners();
  }

  String _indexProgressStatus(IndexJobState state) => switch (state.status) {
    IndexJobStatus.queued => _l(
      '索引任务正在等待开始…',
      'The indexing task is waiting to start…',
    ),
    IndexJobStatus.running when state.currentPath == null => _l(
      '正在扫描文件：已发现 ${state.discovered} 个，已处理 ${state.processed} 个…',
      'Scanning files: ${state.discovered} discovered and ${state.processed} processed…',
    ),
    IndexJobStatus.running => _l(
      '正在处理文件 ${state.processed + 1}/${state.discovered}：${p.basename(state.currentPath!)}',
      'Processing file ${state.processed + 1}/${state.discovered}: ${p.basename(state.currentPath!)}',
    ),
    IndexJobStatus.pausing => _l(
      '正在等待当前文件到达安全暂停点…',
      'Waiting for the current file to reach a safe pause point…',
    ),
    IndexJobStatus.paused => _l('索引任务已暂停。', 'The indexing task is paused.'),
    IndexJobStatus.cancelling => _l(
      '正在安全停止索引任务…',
      'Stopping the indexing task safely…',
    ),
    IndexJobStatus.cancelled => _l(
      '索引任务已取消。',
      'The indexing task was cancelled.',
    ),
    IndexJobStatus.completed => _l('正在保存最终索引状态…', 'Saving final index state…'),
    IndexJobStatus.partial => _l('正在整理失败记录…', 'Finalizing failure records…'),
    IndexJobStatus.failed => _l('索引任务失败。', 'The indexing task failed.'),
  };

  String _fileProgressStatus(IndexFileState state) {
    final name = p.basename(state.path);
    final units = state.completedUnits == null || state.totalUnits == null
        ? ''
        : ' ${state.completedUnits}/${state.totalUnits}';
    final stage = switch (state.status) {
      IndexFileStatus.discovered => _l('已发现', 'Discovered'),
      IndexFileStatus.unchanged => _l('未变化，跳过', 'Unchanged; skipped'),
      IndexFileStatus.queued => _l('等待处理', 'Queued'),
      IndexFileStatus.processing => _l(
        '正在执行 ${state.stage ?? '处理'}$units',
        'Running ${state.stage ?? 'processing'}$units',
      ),
      IndexFileStatus.indexed => _l('索引已提交', 'Index committed'),
      IndexFileStatus.failed => _l('处理失败', 'Processing failed'),
      IndexFileStatus.cancelled => _l('已取消', 'Cancelled'),
      IndexFileStatus.removed => _l('已清理失效索引', 'Stale index removed'),
    };
    return _l('当前文件：$name；$stage', 'Current file: $name; $stage');
  }

  bool _sameRuntimeConfiguration(
    RuntimeConfiguration? left,
    RuntimeConfiguration right,
  ) =>
      left != null &&
      PathRules.canonical(left.databaseRoot) ==
          PathRules.canonical(right.databaseRoot) &&
      PathRules.canonical(left.applicationDirectory) ==
          PathRules.canonical(right.applicationDirectory) &&
      PathRules.canonical(left.pythonExecutable) ==
          PathRules.canonical(right.pythonExecutable) &&
      PathRules.canonical(left.logDirectory) ==
          PathRules.canonical(right.logDirectory) &&
      _sameDependencyPaths(left.dependencyPaths, right.dependencyPaths);

  bool _sameDependencyPaths(
    Map<String, String> left,
    Map<String, String> right,
  ) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      final other = right[entry.key];
      if (other == null ||
          PathRules.canonical(entry.value) != PathRules.canonical(other)) {
        return false;
      }
    }
    return true;
  }

  String? _siblingExecutable(String configuredPath, String name) {
    if (configuredPath.trim().isEmpty) return null;
    final value = File(configuredPath).existsSync()
        ? File(configuredPath).parent.path
        : configuredPath;
    final candidate = File(p.join(value, name));
    return candidate.existsSync() ? candidate.absolute.path : null;
  }

  Future<void> _stopRuntime() async {
    _jobControl?.cancel();
    _indexRunner = null;
    _queryCoordinator = null;
    _vectorClient?.close();
    _vectorClient = null;
    _embeddingEngine?.close();
    _embeddingEngine = null;
    await localVectorService.stop();
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (busy) {
      throw StateError(_l('当前已有任务正在执行。', 'Another task is already running.'));
    }
    busy = true;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      statusMessage = _l('操作失败：$error', 'Operation failed: $error');
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _jobControl?.cancel();
    _vectorClient?.close();
    _embeddingEngine?.close();
    unawaited(localVectorService.stop());
    super.dispose();
  }
}

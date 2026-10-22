import 'package:flutter/material.dart';

import '../application/application_controller.dart';
import '../application/system_path_picker.dart';
import '../application/ui_preferences.dart';
import '../core/parsing/parser.dart';
import '../indexing/index_job.dart';
import '../indexing/index_comparison.dart';
import '../indexing/index_file_state.dart';
import '../indexing/index_scope.dart';
import 'ui_components.dart';
import '../configuration/presentation/pages/library_page_values.dart';
import 'design_system/presets/app_action_button.dart';
import 'design_system/presets/app_action_strip.dart';
import 'design_system/presets/app_choice_controls.dart';
import 'design_system/presets/app_form_dialog.dart';
import 'design_system/presets/app_path_display.dart';
import 'index_result_dialog.dart';
import 'status_messages.dart';
import 'app_localizations.dart';

class LibraryPage extends StatefulWidget {
  final ApplicationController controller;
  final SystemPathPicker? pathPicker;

  const LibraryPage({super.key, required this.controller, this.pathPicker});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _failureLog = TextEditingController();
  late final SystemPathPicker _pathPicker;
  final Set<_IndexResultKind> _visibleResultKinds = {
    _IndexResultKind.success,
    _IndexResultKind.failure,
  };
  bool _showAdvancedIndexInformation = false;

  @override
  void initState() {
    super.initState();
    _pathPicker = widget.pathPicker ?? SystemPathPicker.platformDefault();
  }

  @override
  void dispose() {
    _failureLog.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      final message = context.tr('操作失败：$error', 'Operation failed: $error');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Semantics(
            liveRegion: true,
            label: message,
            excludeSemantics: true,
            child: Text(message),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final progress = controller.indexState;
    return ListView(
      key: const Key('library-page'),
      padding: const EdgeInsets.all(LibraryPageValues.outerPadding),
      children: [
        PageHeading(
          icon: Icons.folder_copy,
          title: context.tr('建立和更新文件库', 'Build and update the library'),
          description: context.tr(
            '先选择扫描范围，再点击“扫描并更新”，程序将在本机读取文件并建立可查询索引',
            'Choose a scan scope, then select “Scan and update”. The app reads local files and builds a searchable index.',
          ),
        ),
        const SizedBox(height: LibraryPageValues.headingToScopeGap),
        SectionPanel(
          title: context.tr('1. 选择扫描范围', '1. Choose scan scope'),
          description: context.tr(
            '“指定路径”只处理您添加的位置；“全部设备”扫描可访问的本机设备，并自动排除数据库目录。',
            '“Selected paths” processes only locations you add. “All devices” scans accessible local devices and excludes the database folder automatically.',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppSegmentedSelector<IndexScopeMode>(
                semanticLabel: context.tr('扫描范围', 'Scan scope'),
                options: [
                  AppSegmentOption(
                    IndexScopeMode.selectedPaths,
                    context.tr('指定路径', 'Selected paths'),
                    icon: Icons.folder,
                  ),
                  AppSegmentOption(
                    IndexScopeMode.allDevices,
                    context.tr('全部设备', 'All devices'),
                    icon: Icons.storage,
                  ),
                ],
                value: controller.scope.mode,
                onChanged: controller.indexing ? null : _setScopeMode,
              ),
              const SizedBox(
                height: LibraryPageValues.scopeSelectorToPathFieldGap,
              ),
              if (controller.scope.mode == IndexScopeMode.allDevices)
                EmptyMessage(
                  icon: Icons.storage,
                  message: context.tr(
                    '当前将扫描全部可访问的本机设备，已保存的指定路径不参与本次扫描。',
                    'All accessible local devices will be scanned. Saved selected paths are not used for this scan.',
                  ),
                )
              else ...[
                Wrap(
                  spacing: LibraryPageValues.pathPickerHorizontalGap,
                  runSpacing: LibraryPageValues.pathPickerRunGap,
                  children: [
                    AppActionButton(
                      kind: AppActionButtonKind.secondary,
                      onPressed: () => _perform(_chooseFiles),
                      icon: Icons.insert_drive_file_outlined,
                      label: context.tr(
                        '选择一个或多个文件',
                        'Choose one or more files',
                      ),
                    ),
                    AppActionButton(
                      kind: AppActionButtonKind.secondary,
                      onPressed: () => _perform(_chooseFolder),
                      icon: Icons.create_new_folder_outlined,
                      label: context.tr('选择文件夹', 'Choose folder'),
                    ),
                  ],
                ),
                const SizedBox(
                  height: LibraryPageValues.pathPickerToListHeadingGap,
                ),
                Text(
                  context.tr('已选择的路径', 'Selected paths'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: LibraryPageValues.pathHeadingToListGap),
                if (controller.scope.includedPaths.isEmpty)
                  EmptyMessage(
                    icon: Icons.folder_off_outlined,
                    message: context.tr(
                      '还没有添加路径。',
                      'No paths have been added.',
                    ),
                  )
                else
                  ...controller.scope.includedPaths.map(
                    (path) => _PathRow(
                      icon: Icons.folder_open,
                      path: path,
                      firstAction: AppActionButton(
                        kind: AppActionButtonKind.text,
                        onPressed: () => controller.removeIndexPath(path),
                        icon: Icons.delete_outline,
                        label: context.tr('移除', 'Remove'),
                      ),
                    ),
                  ),
              ],
              const Divider(
                height: LibraryPageValues.includedToExcludedDividerHeight,
              ),
              Text(
                context.tr('排除路径（可选）', 'Excluded paths (optional)'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(
                height: LibraryPageValues.excludedHeadingDescriptionGap,
              ),
              Text(
                context.tr(
                  '这里的文件夹不会进入索引。数据库位置会由程序自动排除，无需重复填写。',
                  'Folders listed here are not indexed. The database location is excluded automatically and does not need to be entered.',
                ),
              ),
              const SizedBox(
                height: LibraryPageValues.excludedDescriptionToFieldGap,
              ),
              AppActionButton(
                kind: AppActionButtonKind.secondary,
                onPressed: () => _perform(_chooseExcludedFolder),
                icon: Icons.folder_open,
                label: context.tr('选择要排除的文件夹', 'Choose folder to exclude'),
              ),
              if (controller.scope.excludedPaths.isNotEmpty) ...[
                const SizedBox(
                  height: LibraryPageValues.excludedPickerToListGap,
                ),
                ...controller.scope.excludedPaths.map(
                  (path) => _PathRow(
                    icon: Icons.folder_off_outlined,
                    path: path,
                    firstAction: AppActionButton(
                      kind: AppActionButtonKind.text,
                      onPressed: () => controller.removeExcludedPath(path),
                      icon: Icons.close,
                      label: context.tr('取消排除', 'Remove exclusion'),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: LibraryPageValues.scopeToIndexSectionGap),
        SectionPanel(
          title: context.tr('2. 扫描并更新', '2. Scan and update'),
          description: context.tr(
            '已建立过索引的未变化文件会跳过；失败文件会写入可重新读取的失败路径日志。',
            'Unchanged indexed files are skipped. Failed files are written to a reusable failure-path log.',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppSelectField<IndexComparisonPreset>(
                key: const Key('index-comparison-preset'),
                value:
                    controller.indexComparison.preset ==
                        IndexComparisonPreset.custom
                    ? null
                    : controller.indexComparison.preset,
                label: context.tr('核对预设', 'Comparison preset'),
                options: IndexComparisonPreset.values
                    .where((preset) => preset != IndexComparisonPreset.custom)
                    .map(
                      (preset) => AppSelectOption(
                        preset,
                        _comparisonPresetLabel(context, preset),
                      ),
                    )
                    .toList(),
                onChanged: controller.indexing
                    ? null
                    : (preset) {
                        if (preset != null) {
                          controller.setIndexComparisonPreset(preset);
                        }
                      },
              ),
              const SizedBox(
                height: LibraryPageValues.comparisonPresetToOptionsGap,
              ),
              Text(context.tr('自定义核对项', 'Custom comparison items')),
              AppCheckOption(
                key: const Key('compare-select-all-checkbox'),
                value: _comparisonSelectionState(controller.indexComparison),
                tristate: true,
                bulkControl: true,
                onChanged: controller.indexing
                    ? null
                    : (_) {
                        final allSelected =
                            _comparisonSelectionState(
                              controller.indexComparison,
                            ) ==
                            true;
                        controller.setIndexComparison(
                          allSelected
                              ? const IndexComparisonOptions.none()
                              : const IndexComparisonOptions.complete(),
                        );
                      },
                title: context.tr('全选', 'Select all'),
                subtitle: context.tr(
                  '选中全部核对项；再次点击可全部取消',
                  'Select all comparison items; activate again to clear all',
                ),
              ),
              AppCheckOption(
                key: const Key('compare-path-checkbox'),
                value: controller.indexComparison.path,
                onChanged: controller.indexing
                    ? null
                    : (value) => controller.setIndexComparison(
                        controller.indexComparison.copyWith(path: value),
                      ),
                title: context.tr('路径（包括文件名）', 'Path (including file name)'),
                subtitle: context.tr(
                  '核对路径清单，并清理已删除、移动或重命名文件的失效索引',
                  'Compare the path list and remove stale indexes for deleted, moved, or renamed files',
                ),
              ),
              AppCheckOption(
                key: const Key('compare-size-checkbox'),
                value: controller.indexComparison.size,
                onChanged: controller.indexing
                    ? null
                    : (value) => controller.setIndexComparison(
                        controller.indexComparison.copyWith(size: value),
                      ),
                title: context.tr('文件大小', 'File size'),
              ),
              AppCheckOption(
                key: const Key('compare-modified-checkbox'),
                value: controller.indexComparison.modifiedTime,
                onChanged: controller.indexing
                    ? null
                    : (value) => controller.setIndexComparison(
                        controller.indexComparison.copyWith(
                          modifiedTime: value,
                        ),
                      ),
                title: context.tr('最后修改时间', 'Last modified time'),
              ),
              AppCheckOption(
                key: const Key('compare-hash-checkbox'),
                value: controller.indexComparison.hash,
                onChanged: controller.indexing
                    ? null
                    : (value) => controller.setIndexComparison(
                        controller.indexComparison.copyWith(hash: value),
                      ),
                title: context.tr(
                  '文件内容哈希（SHA-256）',
                  'File content hash (SHA-256)',
                ),
                subtitle: context.tr(
                  '每次核对都会重新读取整个文件并计算哈希',
                  'Each comparison rereads the entire file and calculates its hash',
                ),
              ),
              const SizedBox(
                height: LibraryPageValues.comparisonOptionsToActionsGap,
              ),
              AppActionStrip(
                children: [
                  AppActionButton(
                    key: const Key('run-index-button'),
                    onPressed: !controller.ready || controller.busy
                        ? null
                        : _runIndexAndShowResult,
                    icon: Icons.sync,
                    label: context.tr('扫描并更新', 'Scan and update'),
                  ),
                  AppActionButton(
                    kind: AppActionButtonKind.secondary,
                    onPressed:
                        (progress?.status == IndexJobStatus.running ||
                                progress?.status == IndexJobStatus.queued) &&
                            controller.indexing
                        ? controller.pauseIndex
                        : null,
                    icon: Icons.pause,
                    label: context.tr('暂停', 'Pause'),
                  ),
                  AppActionButton(
                    kind: AppActionButtonKind.secondary,
                    onPressed: progress?.status == IndexJobStatus.paused
                        ? controller.resumeIndex
                        : null,
                    icon: Icons.play_arrow,
                    label: context.tr('继续', 'Resume'),
                  ),
                  AppActionButton(
                    kind: AppActionButtonKind.danger,
                    onPressed: controller.indexing
                        ? controller.cancelIndex
                        : null,
                    icon: Icons.stop,
                    label: context.tr('停止', 'Stop'),
                  ),
                ],
              ),
              const SizedBox(height: LibraryPageValues.actionsToProgressGap),
              if (!controller.ready)
                EmptyMessage(
                  icon: Icons.info_outline,
                  message: StatusMessages.serviceNotStarted(context),
                )
              else
                Semantics(
                  liveRegion: true,
                  label: _indexSummary(controller, progress),
                  child: Text(
                    _indexSummary(controller, progress),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              AppCheckOption(
                key: const Key('advanced-index-information-toggle'),
                value: _showAdvancedIndexInformation,
                toggle: true,
                onChanged: (value) => setState(
                  () => _showAdvancedIndexInformation = value ?? false,
                ),
                title: context.tr('高级信息', 'Advanced information'),
                subtitle: context.tr(
                  '查看处理数量、逐文件状态、内部阶段和日志',
                  'View counts, per-file status, internal stages, and logs',
                ),
              ),
              if (_showAdvancedIndexInformation && controller.ready) ...[
                if (progress == null)
                  EmptyMessage(
                    icon: Icons.hourglass_empty,
                    message: context.tr('尚未运行扫描。', 'No scan has been run.'),
                  )
                else ...[
                  Semantics(
                    liveRegion: true,
                    label: context.tr(
                      '扫描进度，已发现${progress.discovered}，已处理${progress.processed}，已建立或更新${progress.succeeded}，未变化${progress.skipped}，处理失败${progress.failed}',
                      'Scan progress: ${progress.discovered} discovered, ${progress.processed} processed, ${progress.succeeded} indexed or updated, ${progress.skipped} unchanged, ${progress.failed} failed',
                    ),
                    child: Wrap(
                      spacing: LibraryPageValues.metricHorizontalGap,
                      runSpacing: LibraryPageValues.metricRunGap,
                      children: [
                        MetricTile(
                          label: context.tr('已发现', 'Discovered'),
                          value: '${progress.discovered}',
                        ),
                        MetricTile(
                          label: context.tr('已处理', 'Processed'),
                          value: '${progress.processed}',
                        ),
                        MetricTile(
                          label: context.tr('已建立或更新', 'Indexed or updated'),
                          value: '${progress.succeeded}',
                        ),
                        MetricTile(
                          label: context.tr('未变化', 'Unchanged'),
                          value: '${progress.skipped}',
                        ),
                        MetricTile(
                          label: context.tr('处理失败', 'Failed'),
                          value: '${progress.failed}',
                        ),
                      ],
                    ),
                  ),
                  if (progress.currentPath != null) ...[
                    const SizedBox(
                      height: LibraryPageValues.metricsToCurrentPathGap,
                    ),
                    SelectableText(
                      context.tr(
                        '当前文件：${progress.currentPath}',
                        'Current file: ${progress.currentPath}',
                      ),
                    ),
                  ],
                  const SizedBox(
                    height: LibraryPageValues.currentPathToStatusGap,
                  ),
                  Text(
                    context.tr(
                      '任务状态：${_indexStatusLabel(context, progress.status)}',
                      'Task status: ${_indexStatusLabel(context, progress.status)}',
                    ),
                  ),
                  if (progress.fileStateLogPath != null) ...[
                    const SizedBox(
                      height: LibraryPageValues.statusToStateLogGap,
                    ),
                    SelectableText(
                      context.tr(
                        '本次任务日志（UTF-8 .log）：${progress.fileStateLogPath}',
                        'Log for this run (UTF-8 .log): ${progress.fileStateLogPath}',
                      ),
                    ),
                  ],
                  if (_finalFileStates(controller).isNotEmpty) ...[
                    const SizedBox(
                      height: LibraryPageValues.stateLogToFilterGap,
                    ),
                    Wrap(
                      spacing: LibraryPageValues.metricHorizontalGap,
                      runSpacing: LibraryPageValues.metricRunGap,
                      children: [
                        MetricTile(
                          label: context.tr('成功', 'Succeeded'),
                          value:
                              '${_resultCount(controller, _IndexResultKind.success)}',
                        ),
                        MetricTile(
                          label: context.tr('失败', 'Failed'),
                          value:
                              '${_resultCount(controller, _IndexResultKind.failure)}',
                        ),
                      ],
                    ),
                    const SizedBox(
                      height: LibraryPageValues.metricsToBulkFilterGap,
                    ),
                    AppCheckOption(
                      key: const Key('file-result-select-all'),
                      title: context.tr('全选', 'Select all'),
                      subtitle: context.tr(
                        '选择成功和失败两类结果；再次点击可全部取消',
                        'Select successful and failed results; activate again to clear all',
                      ),
                      value: _resultFilterSelectionState,
                      tristate: true,
                      bulkControl: true,
                      onChanged: (_) => _toggleAllResultKinds(),
                    ),
                    const SizedBox(
                      height: LibraryPageValues.resultFilterOptionGap,
                    ),
                    AppCheckOption(
                      key: const Key('file-result-success-filter'),
                      title: context.tr('成功', 'Succeeded'),
                      value: _visibleResultKinds.contains(
                        _IndexResultKind.success,
                      ),
                      onChanged: (value) => _setResultKindVisible(
                        _IndexResultKind.success,
                        value ?? false,
                      ),
                    ),
                    const SizedBox(
                      height: LibraryPageValues.resultFilterOptionGap,
                    ),
                    AppCheckOption(
                      key: const Key('file-result-failure-filter'),
                      title: context.tr('失败', 'Failed'),
                      value: _visibleResultKinds.contains(
                        _IndexResultKind.failure,
                      ),
                      onChanged: (value) => _setResultKindVisible(
                        _IndexResultKind.failure,
                        value ?? false,
                      ),
                    ),
                    const SizedBox(height: LibraryPageValues.filterToRowsGap),
                    if (_visibleResultKinds.isEmpty)
                      EmptyMessage(
                        icon: Icons.filter_alt_off,
                        message: context.tr(
                          '当前未选择任何结果类型。',
                          'No result type is selected.',
                        ),
                      )
                    else
                      ..._visibleFileStates(controller)
                          .map((state) => _FileStateRow(state: state)),
                  ],
                  if (progress.status == IndexJobStatus.cancelled) ...[
                    const SizedBox(
                      height: LibraryPageValues.rowsToCancellationGap,
                    ),
                    Text(
                      _cancellationMessage(controller),
                      key: const Key('index-cancellation-location'),
                    ),
                  ],
                  if (progress.failureLogPath != null) ...[
                    const SizedBox(
                      height: LibraryPageValues.rowsToFailureLogGap,
                    ),
                    SelectableText(
                      context.tr(
                        '失败路径日志：${progress.failureLogPath}',
                        'Failure-path log: ${progress.failureLogPath}',
                      ),
                    ),
                  ],
                ],
              ],
            ],
          ),
        ),
        if (_showAdvancedIndexInformation) ...[
          const SizedBox(height: LibraryPageValues.indexToRetrySectionGap),
          SectionPanel(
            title: context.tr('3. 从失败记录重新测试', '3. Retry from a failure record'),
            description: context.tr(
              '选择程序生成的 *.retrieval-failures.log 失败重试记录。只有标记、校验值和失败登记都匹配的路径才会重试；普通任务结果 .log 不能用于重试。',
              'Choose a *.retrieval-failures.log retry record created by the app. A path is retried only when its marker, checksum, and failure record all match. A regular result .log cannot be used for retrying.',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppActionButton(
                  kind: AppActionButtonKind.secondary,
                  onPressed: controller.busy
                      ? null
                      : () => _perform(_chooseFailureLog),
                  icon: Icons.description_outlined,
                  label: context.tr('选择失败重试记录', 'Choose failure retry record'),
                ),
                const SizedBox(height: LibraryPageValues.retryFieldToActionGap),
                AppPathDisplay(
                  pathKey: const Key('failure-log-field'),
                  label: context.tr('失败重试记录路径', 'Failure retry record path'),
                  path: _failureLog.text,
                  emptyText: context.tr(
                    '尚未选择失败重试记录',
                    'No failure retry record selected',
                  ),
                ),
                const SizedBox(height: LibraryPageValues.retryFieldToActionGap),
                AppActionButton(
                  onPressed: !controller.ready || controller.busy
                      ? null
                      : () => _perform(
                          () => controller.retryFailureLog(_failureLog.text),
                        ),
                  icon: Icons.replay,
                  label: context.tr(
                    '重新测试日志中的失败文件',
                    'Retry failed files in the log',
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  String _indexSummary(
    ApplicationController controller,
    IndexJobState? progress,
  ) {
    if (!controller.ready) return StatusMessages.serviceNotStarted(context);
    if (progress == null) {
      return context.tr('尚未进行索引更新。', 'No index update has been run.');
    }
    return switch (progress.status) {
      IndexJobStatus.queued => context.tr(
        '索引更新正在等待开始。',
        'The index update is waiting to start.',
      ),
      IndexJobStatus.running => _activeIndexSummary(controller, progress),
      IndexJobStatus.pausing => context.tr(
        '索引更新正在暂停。',
        'Pausing the index update.',
      ),
      IndexJobStatus.paused => context.tr(
        '索引更新已暂停。',
        'The index update is paused.',
      ),
      IndexJobStatus.cancelling => context.tr(
        '索引更新正在取消。',
        'Cancelling the index update.',
      ),
      IndexJobStatus.cancelled => context.tr(
        '索引更新已取消。',
        'The index update was cancelled.',
      ),
      IndexJobStatus.completed => context.tr(
        '索引更新成功。',
        'The index update completed successfully.',
      ),
      IndexJobStatus.partial => context.tr(
        '索引更新部分完成：${progress.failed} 个文件失败。',
        'The index update partially completed: ${progress.failed} files failed.',
      ),
      IndexJobStatus.failed => context.tr(
        '索引更新失败。',
        'The index update failed.',
      ),
    };
  }

  String _activeIndexSummary(
    ApplicationController controller,
    IndexJobState progress,
  ) {
    final path = progress.currentPath;
    if (path == null) {
      return context.tr(
        '程序正在扫描所选范围并发现文件，界面仍可正常操作。',
        'Scanning the selected locations and discovering files. The interface remains available.',
      );
    }
    final state = controller.indexFileStates.values
        .where((item) => item.path == path)
        .lastOrNull;
    final stage = _fileStageLabel(context, state?.stage);
    return context.tr(
      '正在执行：$stage\n当前文件：$path\n已处理 ${progress.processed}，已发现 ${progress.discovered}',
      'Working: $stage\nCurrent file: $path\n${progress.processed} processed, ${progress.discovered} discovered',
    );
  }

  Future<void> _runIndexAndShowResult() => _perform(() async {
    await runCompleteIndexFlow(context, widget.controller);
  });

  Future<void> _setScopeMode(IndexScopeMode mode) async {
    if (mode == widget.controller.scope.mode) return;
    if (mode == IndexScopeMode.allDevices) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AppFormDialog(
          title: context.tr('扫描全部设备', 'Scan all devices'),
          content: Text(
            context.tr(
              '全部设备中可能包含大量文件，扫描和建立索引可能需要很长时间，并可能占用大量磁盘空间。您可以使用“排除路径”跳过不需要建立索引的目录。',
              'All devices may contain a large number of files. Scanning and indexing can take a long time and use substantial disk space. Use Excluded locations to skip folders that should not be indexed.',
            ),
          ),
          cancelLabel: context.tr('取消', 'Cancel'),
          confirmLabel: context.tr('继续选择', 'Continue'),
          onCancel: () => Navigator.pop(dialogContext, false),
          onConfirm: () => Navigator.pop(dialogContext, true),
        ),
      );
      if (!mounted || accepted != true) return;
    }
    await widget.controller.setScopeMode(mode);
  }

  Future<void> _chooseFiles() async {
    final files = await _pathPicker.pickFiles(
      english: widget.controller.uiPreferences.language == AppLanguage.english,
    );
    for (final file in files) {
      await widget.controller.addIndexPath(file);
    }
  }

  Future<void> _chooseFolder() async {
    final path = await _pathPicker.pickDirectory(
      english: widget.controller.uiPreferences.language == AppLanguage.english,
    );
    if (path != null) await widget.controller.addIndexPath(path);
  }

  Future<void> _chooseExcludedFolder() async {
    final path = await _pathPicker.pickDirectory(
      english: widget.controller.uiPreferences.language == AppLanguage.english,
    );
    if (path != null) await widget.controller.addExcludedPath(path);
  }

  Future<void> _chooseFailureLog() async {
    final path = await _pathPicker.pickFile(
      english: widget.controller.uiPreferences.language == AppLanguage.english,
      initialDirectory: widget.controller.logDirectory,
      allowedSuffixes: const ['.retrieval-failures.log'],
      filterLabel:
          widget.controller.uiPreferences.language == AppLanguage.english
          ? 'Local Retrieval failure retry logs'
          : '本地文件检索失败重试记录',
    );
    if (path != null && mounted) setState(() => _failureLog.text = path);
  }

  List<IndexFileState> _visibleFileStates(ApplicationController controller) {
    final states =
        _finalFileStates(controller)
            .where((state) => _visibleResultKinds.contains(_resultKind(state)))
            .toList()
          ..sort((left, right) => right.time.compareTo(left.time));
    return states
        .take(LibraryPageValues.visibleFileStateLimit)
        .toList(growable: false);
  }

  List<IndexFileState> _finalFileStates(ApplicationController controller) =>
      controller.indexFileStates.values
          .where((state) => _resultKind(state) != null)
          .toList(growable: false);

  int _resultCount(ApplicationController controller, _IndexResultKind kind) =>
      _finalFileStates(controller)
          .where((state) => _resultKind(state) == kind)
          .length;

  bool? get _resultFilterSelectionState {
    if (_visibleResultKinds.isEmpty) return false;
    if (_visibleResultKinds.length == _IndexResultKind.values.length) {
      return true;
    }
    return null;
  }

  void _toggleAllResultKinds() => setState(() {
    if (_visibleResultKinds.length == _IndexResultKind.values.length) {
      _visibleResultKinds.clear();
    } else {
      _visibleResultKinds
        ..clear()
        ..addAll(_IndexResultKind.values);
    }
  });

  void _setResultKindVisible(_IndexResultKind kind, bool visible) =>
      setState(() {
        if (visible) {
          _visibleResultKinds.add(kind);
        } else {
          _visibleResultKinds.remove(kind);
        }
      });

  String _cancellationMessage(ApplicationController controller) {
    final interrupted = controller.indexFileStates.values
        .where(
          (state) =>
              state.status == IndexFileStatus.failed &&
              state.stage == 'cancelled',
        )
        .firstOrNull;
    if (interrupted == null) {
      return context.tr(
        '本次任务由用户取消；取消时没有正在处理的文件。',
        'The task was cancelled by the user. No file was being processed at the time.',
      );
    }
    return context.tr(
      '本次任务由用户取消。取消时正在处理：${interrupted.path}。该文件未完成索引，已归入失败记录。',
      'The task was cancelled by the user while processing ${interrupted.path}. Its index was not completed, so it was recorded as failed.',
    );
  }
}

class _FileStateRow extends StatelessWidget {
  final IndexFileState state;

  const _FileStateRow({required this.state});

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.all(LibraryPageValues.fileStateCardMargin),
    elevation: LibraryPageValues.fileStateCardElevation,
    shape: RoundedRectangleBorder(
      side: BorderSide(
        color: Theme.of(context).colorScheme.outlineVariant,
        width: LibraryPageValues.fileStateCardBorderWidth,
      ),
      borderRadius: BorderRadius.circular(
        LibraryPageValues.fileStateCardRadius,
      ),
    ),
    child: ExpansionTile(
      title: Text(
        state.path,
        maxLines: LibraryPageValues.pathMaximumLines,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_resultKindLabel(context, _resultKind(state)!)} · '
        '${_fileResultActionLabel(context, state)}',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(
        LibraryPageValues.pathRowLeftPadding,
        LibraryPageValues.pathRowTopPadding,
        LibraryPageValues.pathRowRightPadding,
        LibraryPageValues.pathRowBottomPadding,
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(
            context.tr(
              '结果：${_resultKindLabel(context, _resultKind(state)!)}\n具体动作：${_fileResultActionLabel(context, state)}\n阶段：${_fileStageLabel(context, state.stage)}${_fileUnitProgress(state)}\n${state.detail == null ? '' : '当前内容：${state.detail}\n'}时间：${state.time.toLocal()}\n文件对象：${state.fileObjectId}${state.message == null ? '' : '\n原因：${state.message}'}',
              'Result: ${_resultKindLabel(context, _resultKind(state)!)}\nAction: ${_fileResultActionLabel(context, state)}\nStage: ${_fileStageLabel(context, state.stage)}${_fileUnitProgress(state)}\n${state.detail == null ? '' : 'Current content: ${state.detail}\n'}Time: ${state.time.toLocal()}\nFile object: ${state.fileObjectId}${state.message == null ? '' : '\nReason: ${state.message}'}',
            ),
          ),
        ),
      ],
    ),
  );
}

String _comparisonPresetLabel(
  BuildContext context,
  IndexComparisonPreset preset,
) => switch (preset) {
  IndexComparisonPreset.none => context.tr(
    '不核对（全部不选）',
    'No comparison (none selected)',
  ),
  IndexComparisonPreset.quick => context.tr('快速（路径）', 'Quick (path)'),
  IndexComparisonPreset.standard => context.tr(
    '标准（路径、大小、最后修改时间）',
    'Standard (path, size, and modified time)',
  ),
  IndexComparisonPreset.advanced => context.tr(
    '进阶（路径、哈希）',
    'Advanced (path and hash)',
  ),
  IndexComparisonPreset.complete => context.tr(
    '完整（全部核对）',
    'Complete (all comparisons)',
  ),
  IndexComparisonPreset.custom => throw StateError(
    context.tr(
      '自定义组合不属于可显示预设。',
      'A custom combination is not a displayable preset.',
    ),
  ),
};

enum _IndexResultKind { success, failure }

_IndexResultKind? _resultKind(IndexFileState state) => switch (state.status) {
  IndexFileStatus.unchanged ||
  IndexFileStatus.indexed ||
  IndexFileStatus.removed => _IndexResultKind.success,
  IndexFileStatus.failed ||
  IndexFileStatus.cancelled => _IndexResultKind.failure,
  IndexFileStatus.discovered ||
  IndexFileStatus.queued ||
  IndexFileStatus.processing => null,
};

String _resultKindLabel(BuildContext context, _IndexResultKind kind) =>
    switch (kind) {
      _IndexResultKind.success => context.tr('成功', 'Succeeded'),
      _IndexResultKind.failure => context.tr('失败', 'Failed'),
    };

String _fileResultActionLabel(BuildContext context, IndexFileState state) =>
    switch (state.status) {
      IndexFileStatus.unchanged => context.tr(
        '核对完成，无需更新',
        'Compared; no update needed',
      ),
      IndexFileStatus.indexed => context.tr(
        '索引建立或更新完成',
        'Index built or updated',
      ),
      IndexFileStatus.removed => context.tr('失效索引清理完成', 'Stale index removed'),
      IndexFileStatus.failed when state.stage == 'cancelled' => context.tr(
        '用户取消',
        'Cancelled by user',
      ),
      IndexFileStatus.failed ||
      IndexFileStatus.cancelled => context.tr('处理失败', 'Processing failed'),
      IndexFileStatus.discovered ||
      IndexFileStatus.queued ||
      IndexFileStatus.processing => context.tr('处理中', 'Processing'),
    };

bool? _comparisonSelectionState(IndexComparisonOptions options) {
  final selected = [
    options.path,
    options.size,
    options.modifiedTime,
    options.hash,
  ].where((value) => value).length;
  if (selected == 0) return false;
  if (selected == 4) return true;
  return null;
}

String _fileStageLabel(BuildContext context, String? stage) {
  if (stage == null) return '—';
  final processingStage = FileProcessingStage.values
      .where((value) => value.name == stage)
      .firstOrNull;
  if (processingStage == null) {
    return switch (stage) {
      'discovery' => context.tr('发现文件', 'Discovering file'),
      'metadata' => context.tr('读取文件属性', 'Reading file properties'),
      'fingerprinting' => context.tr(
        '后台计算文件内容哈希',
        'Calculating the file hash in the background',
      ),
      'comparison' => context.tr('核对文件', 'Comparing file'),
      'queued' => context.tr('等待处理', 'Waiting to process'),
      'processing' => context.tr('准备处理', 'Preparing to process'),
      'committed' => context.tr('已提交', 'Committed'),
      'cleanup' => context.tr('清理失效索引', 'Removing stale index'),
      'cancelled' => context.tr('已取消', 'Cancelled'),
      _ => stage,
    };
  }
  return switch (processingStage) {
    FileProcessingStage.reading => context.tr('读取文件', 'Reading file'),
    FileProcessingStage.typeDetection => context.tr(
      '识别文件类型',
      'Detecting file type',
    ),
    FileProcessingStage.structureParsing => context.tr(
      '解析文件结构',
      'Parsing file structure',
    ),
    FileProcessingStage.textExtraction => context.tr('提取正文', 'Extracting text'),
    FileProcessingStage.tableExtraction => context.tr(
      '提取表格',
      'Extracting tables',
    ),
    FileProcessingStage.chartExtraction => context.tr(
      '提取图表数值',
      'Extracting chart values',
    ),
    FileProcessingStage.vectorExtraction => context.tr(
      '提取矢量数据',
      'Extracting vector data',
    ),
    FileProcessingStage.imageDecoding => context.tr('解码图片', 'Decoding images'),
    FileProcessingStage.imageOcr => context.tr('图片 OCR', 'Image OCR'),
    FileProcessingStage.imageAnalysis => context.tr(
      '图片语义分析',
      'Analyzing image semantics',
    ),
    FileProcessingStage.audioReading => context.tr('读取音频', 'Reading audio'),
    FileProcessingStage.speechTranscription => context.tr(
      '语音转写',
      'Transcribing speech',
    ),
    FileProcessingStage.audioAnalysis => context.tr(
      '音频语义分析',
      'Analyzing audio semantics',
    ),
    FileProcessingStage.textChunking => context.tr('文字分块', 'Chunking text'),
    FileProcessingStage.textEmbedding => context.tr(
      '生成文字向量',
      'Creating text embeddings',
    ),
    FileProcessingStage.imageEmbedding => context.tr(
      '生成图片向量',
      'Creating image embeddings',
    ),
    FileProcessingStage.audioEmbedding => context.tr(
      '生成音频向量',
      'Creating audio embeddings',
    ),
    FileProcessingStage.indexStaging => context.tr(
      '暂存新索引',
      'Staging new index',
    ),
    FileProcessingStage.indexValidation => context.tr(
      '校验新索引',
      'Validating new index',
    ),
    FileProcessingStage.indexCommit => context.tr(
      '提交新索引',
      'Committing new index',
    ),
    FileProcessingStage.temporaryCleanup => context.tr(
      '清理临时数据',
      'Cleaning temporary data',
    ),
  };
}

String _fileUnitProgress(IndexFileState state) {
  final completed = state.completedUnits;
  final total = state.totalUnits;
  if (completed == null || total == null || total <= 0) return '';
  return ' ($completed/$total)';
}

String _indexStatusLabel(BuildContext context, IndexJobStatus status) =>
    switch (status) {
      IndexJobStatus.queued => context.tr('等待', 'Queued'),
      IndexJobStatus.running => context.tr('运行', 'Running'),
      IndexJobStatus.pausing => context.tr('暂停中', 'Pausing'),
      IndexJobStatus.paused => context.tr('已暂停', 'Paused'),
      IndexJobStatus.cancelling => context.tr('取消中', 'Cancelling'),
      IndexJobStatus.cancelled => context.tr('已取消', 'Cancelled'),
      IndexJobStatus.completed => context.tr('完成', 'Completed'),
      IndexJobStatus.partial => context.tr('部分完成', 'Partially completed'),
      IndexJobStatus.failed => context.tr('失败', 'Failed'),
    };

class _PathRow extends StatelessWidget {
  final IconData icon;
  final String path;
  final Widget firstAction;

  const _PathRow({
    required this.icon,
    required this.path,
    required this.firstAction,
  });

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(
      bottom: LibraryPageValues.fileStateRowBottomMargin,
    ),
    padding: const EdgeInsets.symmetric(
      horizontal: LibraryPageValues.fileStateRowHorizontalPadding,
      vertical: LibraryPageValues.fileStateRowVerticalPadding,
    ),
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(LibraryPageValues.fileStateRowRadius),
    ),
    child: Row(
      children: [
        Icon(icon, size: LibraryPageValues.fileStateStatusIconSize),
        const SizedBox(width: LibraryPageValues.fileStateIconGap),
        Expanded(child: SelectableText(path)),
        const SizedBox(width: LibraryPageValues.fileStateTextToActionsGap),
        Wrap(
          spacing: LibraryPageValues.fileStateActionGap,
          runSpacing: LibraryPageValues.fileStateActionRunGap,
          children: [firstAction],
        ),
      ],
    ),
  );
}

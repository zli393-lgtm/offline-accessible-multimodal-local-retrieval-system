import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../application/application_controller.dart';
import '../application/system_file_launcher.dart';
import '../application/system_path_picker.dart';
import '../application/ui_preferences.dart';
import '../query/query_models.dart';
import '../query/query_file_type_options.dart';
import '../storage/multimodal_vector_store.dart';
import 'ui_components.dart';
import '../configuration/presentation/pages/search_page_values.dart';
import '../configuration/retrieval/relevance_threshold_values.dart';
import 'design_system/presets/app_action_button.dart';
import 'design_system/presets/app_text_input.dart';
import 'design_system/presets/app_form_dialog.dart';
import 'design_system/presets/app_choice_controls.dart';
import 'status_messages.dart';
import 'app_localizations.dart';

enum _QueryRangeAction { ignoreAndSearch, prepareInLibrary }

enum _LibraryPathTransferAction { replace, merge }

String _fileTypeGroupLabel(
  BuildContext context,
  String group,
) => switch (group) {
  '纯文本、配置与代码' => context.tr('纯文本、配置与代码', 'Plain text, configuration, and code'),
  '文档、网页与电子书' => context.tr('文档、网页与电子书', 'Documents, web pages, and e-books'),
  '图像与图像容器' => context.tr('图像与图像容器', 'Images and image containers'),
  '音频' => context.tr('音频', 'Audio'),
  '压缩包与归档' => context.tr('压缩包与归档', 'Archives'),
  _ => group,
};

enum _QueryPreset {
  fileNameOnly,
  basic,
  standard,
  image,
  audio,
  advanced,
  complete,
}

class SearchPage extends StatefulWidget {
  final ApplicationController controller;
  final SystemPathPicker? pathPicker;
  final VoidCallback onOpenLibrary;

  const SearchPage({
    super.key,
    required this.controller,
    required this.onOpenLibrary,
    this.pathPicker,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _description = TextEditingController();
  final List<String> _attachments = [];
  final List<String> _queryPaths = [];
  final Set<QueryInformationKind> _informationKinds = {
    ...QueryInformationSelection.standard.kinds,
  };
  final Set<QuerySummaryKind> _summaryKinds = {
    ...QuerySummarySelection.all.kinds,
  };
  QueryFileTypeMode _fileTypeMode = QueryFileTypeMode.all;
  bool _showAdvancedFileTypes = false;
  final Set<String> _customFileTypes = {...QueryFileTypeOptions.known};
  bool _customIncludesOther = true;
  RelevanceScope _relevanceScope = RelevanceThresholdValues.defaultScope;
  late final SystemPathPicker _pathPicker;

  @override
  void initState() {
    super.initState();
    _pathPicker = widget.pathPicker ?? SystemPathPicker.platformDefault();
  }

  @override
  void dispose() {
    _description.dispose();
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

  Future<void> _search() => _perform(() async {
    var effectivePaths = List<String>.of(_queryPaths);
    final missing = await widget.controller.unindexedQueryPaths(effectivePaths);
    if (!mounted) return;
    if (missing.isNotEmpty) {
      final action = await showDialog<_QueryRangeAction>(
        context: context,
        builder: (dialogContext) => AppFormDialog(
          title: context.tr(
            '部分查询范围尚未建立索引',
            'Some search locations are not indexed',
          ),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr(
                  '可以忽略这些范围并查询，或者把未建立索引的路径填入文件库。进入文件库后，由您确认范围并手动开始扫描。当前查询内容和查询范围会继续保留。',
                  'You can ignore these locations and search, or send the unindexed locations to the library. In the library, review the locations and start scanning manually. The current search content and locations will be preserved.',
                ),
              ),
              ExpansionTile(
                title: Text(
                  context.tr('查看未建立索引路径', 'View unindexed locations'),
                ),
                children: missing.map((path) => SelectableText(path)).toList(),
              ),
              AppActionButton(
                kind: AppActionButtonKind.secondary,
                label: context.tr(
                  '忽略未索引范围并查询',
                  'Ignore unindexed locations and search',
                ),
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _QueryRangeAction.ignoreAndSearch,
                ),
              ),
            ],
          ),
          cancelLabel: context.tr('返回修改范围', 'Go back and edit locations'),
          confirmLabel: context.tr('填入文件库', 'Send to library'),
          onCancel: () => Navigator.pop(dialogContext),
          onConfirm: () =>
              Navigator.pop(dialogContext, _QueryRangeAction.prepareInLibrary),
        ),
      );
      if (!mounted || action == null) return;
      if (action == _QueryRangeAction.ignoreAndSearch) {
        effectivePaths.removeWhere(missing.contains);
        if (_queryPaths.isNotEmpty && effectivePaths.isEmpty) {
          throw StateError(
            context.tr(
              '忽略未索引范围后，没有剩余的可查询路径。',
              'No searchable locations remain after unindexed locations were ignored.',
            ),
          );
        }
      } else {
        final existingCount = widget.controller.scope.includedPaths.length;
        final transfer = await showDialog<_LibraryPathTransferAction>(
          context: context,
          builder: (dialogContext) => AppFormDialog(
            title: context.tr(
              '如何更新文件库路径',
              'Choose how to update library locations',
            ),
            content: Text(
              context.tr(
                '文件库当前有 $existingCount 个已选路径，本次发现 ${missing.length} 个未建立索引的查询路径。请选择替换原有路径，或者合并两组路径。',
                'The library currently has $existingCount selected locations, and this search found ${missing.length} unindexed locations. Replace the existing selection or merge both sets.',
              ),
            ),
            cancelLabel: context.tr('取消', 'Cancel'),
            alternativeLabel: context.tr('合并全部路径', 'Merge all locations'),
            confirmLabel: context.tr('替换原有路径', 'Replace existing selection'),
            onCancel: () => Navigator.pop(dialogContext),
            onAlternative: () =>
                Navigator.pop(dialogContext, _LibraryPathTransferAction.merge),
            onConfirm: () => Navigator.pop(
              dialogContext,
              _LibraryPathTransferAction.replace,
            ),
          ),
        );
        if (!mounted || transfer == null) return;
        if (transfer == _LibraryPathTransferAction.replace) {
          await widget.controller.replaceIndexPaths(missing);
        } else {
          await widget.controller.mergeIndexPaths(missing);
        }
        if (!mounted) return;
        widget.onOpenLibrary();
        return;
      }
    }
    await widget.controller.search(
      QueryRequest(
        description: _description.text,
        attachmentPaths: List.of(_attachments),
        searchPaths: effectivePaths,
        fileTypeFilterEnabled: _effectiveFileTypeFilter().$1,
        allowedFileTypes: _effectiveFileTypeFilter().$2,
        includeOtherFileTypes: _effectiveFileTypeFilter().$3,
        informationSelection: QueryInformationSelection(
          Set.unmodifiable(_informationKinds),
        ),
        summarySelection: QuerySummarySelection(
          Set.unmodifiable(_summaryKinds),
        ),
        relevanceScope: _relevanceScope,
      ),
    );
  });

  void _clear() {
    setState(() {
      _description.clear();
      _attachments.clear();
      _queryPaths.clear();
      _informationKinds
        ..clear()
        ..addAll(QueryInformationSelection.standard.kinds);
      _summaryKinds
        ..clear()
        ..addAll(QuerySummarySelection.all.kinds);
      _fileTypeMode = QueryFileTypeMode.all;
      _showAdvancedFileTypes = false;
      _customFileTypes
        ..clear()
        ..addAll(QueryFileTypeOptions.known);
      _customIncludesOther = true;
      _relevanceScope = RelevanceThresholdValues.defaultScope;
    });
    widget.controller.clearQuery();
  }

  @override
  Widget build(BuildContext context) {
    final response = widget.controller.queryResponse;
    return SingleChildScrollView(
      key: const Key('search-page'),
      padding: const EdgeInsets.all(SearchPageValues.outerPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeading(
            icon: Icons.search,
            title: context.tr('查询文件库', 'Search the library'),
            description: context.tr(
              '输入说明或添加文件后开始查询。每个附件会单独、完整地查找相关内容，不会与其他附件混合。',
              'Enter a description or add files to begin. Each attachment is searched independently and is never mixed with another attachment.',
            ),
          ),
          const SizedBox(height: SearchPageValues.headingToQueryGap),
          SectionPanel(
            title: context.tr('1. 填写查询内容', '1. Enter search content'),
            description: context.tr(
              '可以输入说明文字或添加查询附件；查询范围不选择时，将在全部已有索引中查询。',
              'Enter text or add search attachments. If no location is selected, all existing indexes are searched.',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _fieldAndButton(
                  field: AppTextInput(
                    key: const Key('query-description-field'),
                    controller: _description,
                    minLines: SearchPageValues.descriptionMinimumLines,
                    maxLines: SearchPageValues.descriptionMaximumLines,
                    label: context.tr('要查找的内容', 'What to find'),
                    hint: context.tr(
                      '例如：查找介绍本地向量数据库设计的文件',
                      'For example: files about local vector database design',
                    ),
                  ),
                  button: AppActionButton(
                    key: const Key('choose-query-attachments-button'),
                    kind: AppActionButtonKind.secondary,
                    onPressed: _chooseAttachments,
                    icon: Icons.attach_file,
                    label: context.tr('添加附件', 'Add attachments'),
                    semanticHint: context.tr(
                      '打开系统文件选择窗口，可选择一个或多个查询附件',
                      'Open the system file picker to choose one or more search attachments',
                    ),
                  ),
                ),
                if (_attachments.isNotEmpty) ...[
                  const SizedBox(
                    height: SearchPageValues.queryToAttachmentListGap,
                  ),
                  _buildAttachmentList(),
                ],
                const SizedBox(height: SearchPageValues.typeToRangeGap),
                Text(
                  context.tr('查询范围', 'Search locations'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: SearchPageValues.rangeHeadingToFieldGap),
                Text(
                  context.tr(
                    '不添加范围时，将在全部已有索引中查询。添加一个或多个文件夹后，只查询这些范围。',
                    'With no locations added, all existing indexes are searched. Add one or more folders to limit the search.',
                  ),
                ),
                const SizedBox(height: SearchPageValues.rangeNoticeToPickerGap),
                AppActionButton(
                  kind: AppActionButtonKind.secondary,
                  onPressed: _chooseQueryFolder,
                  icon: Icons.create_new_folder_outlined,
                  label: context.tr('添加查询范围', 'Add search location'),
                  semanticHint: context.tr(
                    '打开系统文件夹选择窗口',
                    'Open the system folder picker',
                  ),
                ),
                if (_queryPaths.isNotEmpty) ...[
                  const SizedBox(height: SearchPageValues.rangePickerToListGap),
                  ..._queryPaths.map(
                    (path) => Container(
                      margin: const EdgeInsets.only(
                        bottom: SearchPageValues.rangeRowBottomMargin,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: SearchPageValues.rangeRowHorizontalPadding,
                        vertical: SearchPageValues.rangeRowVerticalPadding,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        borderRadius: BorderRadius.circular(
                          SearchPageValues.rangeRowRadius,
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(child: SelectableText(path)),
                          const SizedBox(
                            width: SearchPageValues.rangePathToActionGap,
                          ),
                          AppActionButton(
                            kind: AppActionButtonKind.text,
                            label: context.tr(
                              '移出查询范围',
                              'Remove search location',
                            ),
                            icon: Icons.close,
                            onPressed: () =>
                                setState(() => _queryPaths.remove(path)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: SearchPageValues.descriptionToTypeGap),
                SectionPanel(
                  title: context.tr('查询数据类型', 'Search data types'),
                  description: context.tr(
                    '决定要使用文件中的哪些原始或提取信息进行匹配。文件名始终参与查询。',
                    'Choose which original or extracted file data to match. File names are always included.',
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppSelectField<_QueryPreset>(
                        key: const Key('query-information-preset'),
                        value: _selectedPreset,
                        label: context.tr('查询预设', 'Search preset'),
                        helper: context.tr(
                          '选择预设会立即应用对应组合；当前组合不匹配任何预设时，此处不选中任何项。',
                          'Choosing a preset immediately applies its combination. When the current combination matches no preset, no preset is selected.',
                        ),
                        options: _QueryPreset.values
                            .map(
                              (preset) => AppSelectOption(
                                preset,
                                _queryPresetLabel(preset),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: (preset) {
                          if (preset != null) _applyPreset(preset);
                        },
                      ),
                      const SizedBox(
                        height: SearchPageValues.informationPresetToOptionsGap,
                      ),
                      AppCheckOption(
                        key: const Key('query-information-select-all'),
                        title: context.tr('全选', 'Select all'),
                        value: _informationKindsSelectionState,
                        tristate: true,
                        bulkControl: true,
                        onChanged: (_) => _toggleAllInformationKinds(),
                      ),
                      const SizedBox(
                        height:
                            SearchPageValues.informationBulkActionsToOptionsGap,
                      ),
                      ...QueryInformationKind.values.map(
                        (kind) => AppCheckOption(
                          key: Key('query-information-${kind.name}'),
                          title: _queryInformationLabel(kind),
                          value: _informationKinds.contains(kind),
                          onChanged: (selected) => setState(() {
                            if (selected == true) {
                              _informationKinds.add(kind);
                            } else {
                              _informationKinds.remove(kind);
                            }
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: SearchPageValues.informationGroupGap),
                SectionPanel(
                  title: context.tr('摘要匹配方式', 'Summary matching'),
                  description: context.tr(
                    '决定查询时是否生成并比较内容摘要和语义摘要，用于补充上面的原始数据匹配。',
                    'Choose whether to generate and compare content and semantic summaries in addition to the original data above.',
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppCheckOption(
                        key: const Key('query-summary-select-all'),
                        title: context.tr('全选', 'Select all'),
                        value: _summaryKindsSelectionState,
                        tristate: true,
                        bulkControl: true,
                        onChanged: (_) => _toggleAllSummaryKinds(),
                      ),
                      const SizedBox(
                        height:
                            SearchPageValues.informationBulkActionsToOptionsGap,
                      ),
                      ...QuerySummaryKind.values.map(
                        (kind) => AppCheckOption(
                          key: Key('query-summary-${kind.name}'),
                          title: _querySummaryLabel(kind),
                          value: _summaryKinds.contains(kind),
                          onChanged: (selected) => setState(() {
                            if (selected == true) {
                              _summaryKinds.add(kind);
                            } else {
                              _summaryKinds.remove(kind);
                            }
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: SearchPageValues.informationGroupGap),
                AppSelectField<RelevanceScope>(
                  key: const Key('query-relevance-scope'),
                  value: _relevanceScope,
                  label: context.tr('关联范围', 'Match scope'),
                  helper: context.tr(
                    '决定结果进入列表所需的最低关联程度，不改变默认的索引顺序。',
                    'Sets the minimum relevance required to enter the results without changing the default index order.',
                  ),
                  options: RelevanceScope.values
                      .map(
                        (scope) => AppSelectOption(scope, switch (scope) {
                          RelevanceScope.strict => context.tr('严格', 'Strict'),
                          RelevanceScope.standard => context.tr(
                            '标准（默认）',
                            'Standard (default)',
                          ),
                          RelevanceScope.broad => context.tr('宽泛', 'Broad'),
                          RelevanceScope.unlimited => context.tr(
                            '不限制',
                            'Unlimited',
                          ),
                        }),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value != null) setState(() => _relevanceScope = value);
                  },
                ),
                const SizedBox(height: SearchPageValues.informationGroupGap),
                Text(
                  context.tr('后缀范围', 'File extension range'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(
                  height: SearchPageValues.informationHeadingToOptionsGap,
                ),
                AppCheckOption(
                  key: const Key('query-file-type-advanced'),
                  title: context.tr(
                    '显示高级后缀设置',
                    'Show advanced extension settings',
                  ),
                  subtitle: context.tr(
                    '开启后可以使用自定义后缀列表',
                    'Enable this to use a custom extension list',
                  ),
                  value: _showAdvancedFileTypes,
                  onChanged: (selected) => setState(() {
                    _showAdvancedFileTypes = selected == true;
                    if (!_showAdvancedFileTypes &&
                        _fileTypeMode == QueryFileTypeMode.custom) {
                      _fileTypeMode = QueryFileTypeMode.all;
                    }
                  }),
                ),
                const SizedBox(
                  height: SearchPageValues.informationBulkActionsToOptionsGap,
                ),
                AppSelectField<QueryFileTypeMode>(
                  key: const Key('query-file-type-mode'),
                  value: _fileTypeMode,
                  label: context.tr('后缀筛选方式', 'Extension filtering mode'),
                  options: [
                    AppSelectOption(
                      QueryFileTypeMode.all,
                      context.tr('全部后缀', 'All extensions'),
                    ),
                    AppSelectOption(
                      QueryFileTypeMode.followPreset,
                      context.tr('跟随数据查询预设', 'Follow the data search preset'),
                    ),
                    if (_showAdvancedFileTypes)
                      AppSelectOption(
                        QueryFileTypeMode.custom,
                        context.tr('自定义后缀', 'Custom extensions'),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _fileTypeMode = value);
                  },
                ),
                if (_fileTypeMode == QueryFileTypeMode.custom) ...[
                  const SizedBox(
                    height: SearchPageValues.informationBulkActionsToOptionsGap,
                  ),
                  AppActionButton(
                    key: const Key('open-custom-file-types'),
                    kind: AppActionButtonKind.secondary,
                    label: context.tr('打开自定义列表', 'Open custom list'),
                    icon: Icons.tune,
                    onPressed: _openCustomFileTypes,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(
            height: SearchPageValues.attachmentToActionsSectionGap,
          ),
          SectionPanel(
            title: context.tr('2. 开始查询', '2. Start search'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: SearchPageValues.searchActionHorizontalGap,
                  runSpacing: SearchPageValues.searchActionRunGap,
                  children: [
                    AppActionButton(
                      key: const Key('search-button'),
                      onPressed:
                          !widget.controller.ready || widget.controller.busy
                          ? null
                          : _search,
                      icon: Icons.search,
                      label: context.tr(
                        '分别分析并查询',
                        'Analyze and search separately',
                      ),
                    ),
                    AppActionButton(
                      kind: AppActionButtonKind.secondary,
                      onPressed: widget.controller.busy ? null : _clear,
                      icon: Icons.clear_all,
                      label: context.tr('清除查询内容', 'Clear search content'),
                    ),
                  ],
                ),
                if (!widget.controller.ready) ...[
                  const SizedBox(
                    height: SearchPageValues.searchActionStatusGap,
                  ),
                  EmptyMessage(
                    icon: Icons.info_outline,
                    message: StatusMessages.serviceNotStarted(context),
                  ),
                ] else if (widget.controller.busy) ...[
                  const SizedBox(
                    height: SearchPageValues.searchActionStatusGap,
                  ),
                  EmptyMessage(
                    icon: Icons.hourglass_top,
                    message: context.tr(
                      '程序正在处理其他任务，完成后即可开始查询。',
                      'The app is processing another task. You can search when it finishes.',
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: SearchPageValues.actionsToResultsHeadingGap),
          Semantics(
            header: true,
            child: Text(
              context.tr('查询结果', 'Search results'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const SizedBox(height: SearchPageValues.resultsHeadingToContentGap),
          if (response == null)
            EmptyMessage(
              icon: Icons.manage_search,
              message: context.tr(
                '结果会直接显示在这里，不需要再展开隐藏层级。',
                'Results appear directly here without an additional collapsed section.',
              ),
            )
          else if (response.units.isEmpty)
            EmptyMessage(
              icon: Icons.search_off,
              message: context.tr(
                '没有形成可执行的查询。',
                'No executable search was created.',
              ),
            )
          else
            ...response.units.map(
              (unit) => _QueryUnitCard(
                unit: unit,
                onPage: (page) => _perform(
                  () => widget.controller.loadQueryPage(unit.queryUnitId, page),
                ),
                onRefine: (refinement) => _perform(
                  () => widget.controller.refineQueryResults(
                    unit.queryUnitId,
                    refinement,
                  ),
                ),
                onOpen: (path) =>
                    _perform(() => widget.controller.openResult(path)),
                onOpenWith: _openWith,
                onReveal: (path) =>
                    _perform(() => widget.controller.revealResult(path)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAttachmentList() => Semantics(
    container: true,
    label: context.tr(
      '已添加 ${_attachments.length} 个查询附件',
      '${_attachments.length} search attachments added',
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr(
            '已添加附件（${_attachments.length}）',
            '${_attachments.length} attachments added',
          ),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: SearchPageValues.attachmentHeadingToListGap),
        ..._attachments.asMap().entries.map(
          (entry) => Container(
            margin: const EdgeInsets.only(
              bottom: SearchPageValues.attachmentRowBottomMargin,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: SearchPageValues.attachmentRowHorizontalPadding,
              vertical: SearchPageValues.attachmentRowVerticalPadding,
            ),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(
                SearchPageValues.attachmentRowRadius,
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.insert_drive_file_outlined,
                  size: SearchPageValues.attachmentIconSize,
                ),
                const SizedBox(width: SearchPageValues.attachmentIconToPathGap),
                Expanded(child: SelectableText(entry.value)),
                AppActionButton(
                  kind: AppActionButtonKind.text,
                  onPressed: () =>
                      setState(() => _attachments.removeAt(entry.key)),
                  icon: Icons.close,
                  label: context.tr('移除', 'Remove'),
                  semanticHint: context.tr(
                    '从查询附件中移除 ${p.basename(entry.value)}',
                    'Remove ${p.basename(entry.value)} from search attachments',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _fieldAndButton({required Widget field, required Widget button}) =>
      LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < SearchPageValues.fieldCompactBreakpoint) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                field,
                const SizedBox(height: SearchPageValues.compactFieldButtonGap),
                button,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: field),
              const SizedBox(width: SearchPageValues.wideFieldButtonGap),
              button,
            ],
          );
        },
      );

  Future<void> _openWith(String path) => _perform(() async {
    String? applicationPath;
    if (widget.controller.fileLauncher.platform !=
        FileLauncherPlatform.windows) {
      applicationPath = await _pathPicker.pickApplication(
        english:
            widget.controller.uiPreferences.language == AppLanguage.english,
      );
      if (applicationPath == null) return;
    }
    await widget.controller.openResultWith(
      path,
      applicationPath: applicationPath,
    );
  });

  String _queryInformationLabel(QueryInformationKind kind) => switch (kind) {
    QueryInformationKind.nativeText => context.tr('原生文字', 'Native text'),
    QueryInformationKind.extractedText => context.tr('提取文字', 'Extracted text'),
    QueryInformationKind.image => context.tr('图像信息', 'Image information'),
    QueryInformationKind.audio => context.tr('音频信息', 'Audio information'),
    QueryInformationKind.overallSummary => context.tr(
      '总体摘要',
      'Overall summary',
    ),
  };

  String _querySummaryLabel(QuerySummaryKind kind) => switch (kind) {
    QuerySummaryKind.contentSummary => context.tr('内容摘要', 'Content summary'),
    QuerySummaryKind.semanticSummary => context.tr('语义摘要', 'Semantic summary'),
  };

  _QueryPreset? get _selectedPreset {
    for (final preset in _QueryPreset.values) {
      final kinds = _queryPresetKinds(preset);
      if (_informationKinds.length == kinds.length &&
          _informationKinds.containsAll(kinds)) {
        return preset;
      }
    }
    return null;
  }

  void _applyPreset(_QueryPreset preset) {
    setState(() {
      _informationKinds
        ..clear()
        ..addAll(_queryPresetKinds(preset));
    });
  }

  bool? get _informationKindsSelectionState {
    if (_informationKinds.isEmpty) return false;
    if (_informationKinds.length == QueryInformationKind.values.length) {
      return true;
    }
    return null;
  }

  void _toggleAllInformationKinds() => setState(() {
    if (_informationKinds.length == QueryInformationKind.values.length) {
      _informationKinds.clear();
    } else {
      _informationKinds
        ..clear()
        ..addAll(QueryInformationKind.values);
    }
  });

  bool? get _summaryKindsSelectionState {
    if (_summaryKinds.isEmpty) return false;
    if (_summaryKinds.length == QuerySummaryKind.values.length) return true;
    return null;
  }

  void _toggleAllSummaryKinds() => setState(() {
    if (_summaryKinds.length == QuerySummaryKind.values.length) {
      _summaryKinds.clear();
    } else {
      _summaryKinds
        ..clear()
        ..addAll(QuerySummaryKind.values);
    }
  });

  Set<QueryInformationKind> _queryPresetKinds(_QueryPreset preset) =>
      switch (preset) {
        _QueryPreset.fileNameOnly => const {},
        _QueryPreset.basic => const {QueryInformationKind.nativeText},
        _QueryPreset.standard => const {
          QueryInformationKind.nativeText,
          QueryInformationKind.extractedText,
        },
        _QueryPreset.image => const {QueryInformationKind.image},
        _QueryPreset.audio => const {QueryInformationKind.audio},
        _QueryPreset.advanced => const {
          QueryInformationKind.nativeText,
          QueryInformationKind.extractedText,
          QueryInformationKind.image,
        },
        _QueryPreset.complete => QueryInformationSelection.all.kinds,
      };

  String _queryPresetLabel(_QueryPreset preset) => switch (preset) {
    _QueryPreset.fileNameOnly => context.tr('仅文件名', 'File name only'),
    _QueryPreset.basic => context.tr('基础', 'Basic'),
    _QueryPreset.standard => context.tr('标准（默认）', 'Standard (default)'),
    _QueryPreset.image => context.tr('图像', 'Image'),
    _QueryPreset.audio => context.tr('音频', 'Audio'),
    _QueryPreset.advanced => context.tr('进阶', 'Advanced'),
    _QueryPreset.complete => context.tr('完整', 'Complete'),
  };

  (bool, Set<String>, bool) _effectiveFileTypeFilter() {
    if (_fileTypeMode == QueryFileTypeMode.all) return (false, const {}, false);
    if (_fileTypeMode == QueryFileTypeMode.custom) {
      return (true, Set.unmodifiable(_customFileTypes), _customIncludesOther);
    }
    final preset = _selectedPreset;
    return switch (preset) {
      _QueryPreset.fileNameOnly ||
      _QueryPreset.complete => (false, const {}, false),
      _QueryPreset.basic => (true, QueryFileTypeOptions.pureText, false),
      _QueryPreset.standard => (true, QueryFileTypeOptions.standard, false),
      _QueryPreset.image => (true, QueryFileTypeOptions.images, false),
      _QueryPreset.audio => (true, QueryFileTypeOptions.audio, false),
      _QueryPreset.advanced => (true, QueryFileTypeOptions.advanced, false),
      null => _fileTypesForCustomInformationSelection(),
    };
  }

  (bool, Set<String>, bool) _fileTypesForCustomInformationSelection() {
    if (_informationKinds.isEmpty ||
        _informationKinds.length == QueryInformationKind.values.length) {
      return (false, const {}, false);
    }
    final values = <String>{};
    if (_informationKinds.contains(QueryInformationKind.nativeText)) {
      values.addAll(QueryFileTypeOptions.pureText);
    }
    if (_informationKinds.contains(QueryInformationKind.extractedText)) {
      values.addAll(QueryFileTypeOptions.standard);
    }
    if (_informationKinds.contains(QueryInformationKind.image)) {
      values.addAll(QueryFileTypeOptions.images);
    }
    if (_informationKinds.contains(QueryInformationKind.audio)) {
      values.addAll(QueryFileTypeOptions.audio);
    }
    if (_informationKinds.contains(QueryInformationKind.overallSummary)) {
      values
        ..addAll(QueryFileTypeOptions.advanced)
        ..addAll(QueryFileTypeOptions.audio);
    }
    return (true, Set.unmodifiable(values), false);
  }

  Future<void> _openCustomFileTypes() async {
    final selected = Set<String>.of(_customFileTypes);
    var includesOther = _customIncludesOther;
    final result = await showDialog<(Set<String>, bool)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, updateDialog) {
          final selectedCount = selected.length + (includesOther ? 1 : 0);
          final totalCount = QueryFileTypeOptions.known.length + 1;
          final bool? allState = selectedCount == 0
              ? false
              : selectedCount == totalCount
              ? true
              : null;
          void toggleAll() => updateDialog(() {
            if (selectedCount == totalCount) {
              selected.clear();
              includesOther = false;
            } else {
              selected
                ..clear()
                ..addAll(QueryFileTypeOptions.known);
              includesOther = true;
            }
          });

          final assigned = <String>{};
          final groups = <MapEntry<String, List<String>>>[];
          for (final group in QueryFileTypeOptions.groups.entries) {
            final values =
                group.value.where(assigned.add).toList(growable: false)..sort();
            if (values.isNotEmpty) groups.add(MapEntry(group.key, values));
          }
          return AppFormDialog(
            title: context.tr('自定义查询后缀', 'Custom search extensions'),
            content: SizedBox(
              width: SearchPageValues.fileTypeDialogWidth,
              height: SearchPageValues.fileTypeDialogHeight,
              child: ListView(
                children: [
                  AppCheckOption(
                    key: const Key('custom-file-types-select-all'),
                    title: context.tr('全选', 'Select all'),
                    subtitle: context.tr(
                      '再次点击可全部取消',
                      'Activate again to clear all',
                    ),
                    value: allState,
                    tristate: true,
                    bulkControl: true,
                    onChanged: (_) => toggleAll(),
                  ),
                  for (final group in groups) ...[
                    const SizedBox(height: SearchPageValues.fileTypeGroupGap),
                    Text(
                      _fileTypeGroupLabel(context, group.key),
                      style: Theme.of(dialogContext).textTheme.titleSmall,
                    ),
                    ...group.value.map(
                      (type) => AppCheckOption(
                        key: Key('custom-file-type-$type'),
                        title: type,
                        value: selected.contains(type),
                        onChanged: (value) => updateDialog(() {
                          if (value == true) {
                            selected.add(type);
                          } else {
                            selected.remove(type);
                          }
                        }),
                      ),
                    ),
                  ],
                  const SizedBox(height: SearchPageValues.fileTypeGroupGap),
                  AppCheckOption(
                    key: const Key('custom-file-type-other'),
                    title: 'Other',
                    subtitle: context.tr(
                      '无法识别的后缀以及无后缀文件',
                      'Unknown extensions and files without an extension',
                    ),
                    value: includesOther,
                    onChanged: (value) =>
                        updateDialog(() => includesOther = value == true),
                  ),
                ],
              ),
            ),
            cancelLabel: context.tr('取消', 'Cancel'),
            confirmLabel: context.tr('确定', 'OK'),
            onCancel: () => Navigator.pop(dialogContext),
            onConfirm: () => Navigator.pop(dialogContext, (
              Set<String>.of(selected),
              includesOther,
            )),
          );
        },
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _customFileTypes
        ..clear()
        ..addAll(result.$1);
      _customIncludesOther = result.$2;
    });
  }

  Future<void> _chooseQueryFolder() async {
    await _perform(() async {
      final path = await _pathPicker.pickDirectory(
        english:
            widget.controller.uiPreferences.language == AppLanguage.english,
      );
      if (!mounted || path == null || _queryPaths.contains(path)) return;
      setState(() => _queryPaths.add(path));
    });
  }

  Future<void> _chooseAttachments() async {
    await _perform(() async {
      final files = await _pathPicker.pickFiles(
        english:
            widget.controller.uiPreferences.language == AppLanguage.english,
      );
      if (!mounted || files.isEmpty) return;
      setState(() {
        for (final file in files) {
          if (!_attachments.contains(file)) _attachments.add(file);
        }
      });
    });
  }
}

class _PreviousPageIntent extends Intent {
  const _PreviousPageIntent();
}

class _NextPageIntent extends Intent {
  const _NextPageIntent();
}

class _FirstPageIntent extends Intent {
  const _FirstPageIntent();
}

class _LastPageIntent extends Intent {
  const _LastPageIntent();
}

class _QueryUnitCard extends StatefulWidget {
  final QueryUnitResult unit;
  final Future<void> Function(int page) onPage;
  final Future<void> Function(FileQueryRefinement refinement) onRefine;
  final Future<void> Function(String path) onOpen;
  final Future<void> Function(String path) onOpenWith;
  final Future<void> Function(String path) onReveal;

  const _QueryUnitCard({
    required this.unit,
    required this.onPage,
    required this.onRefine,
    required this.onOpen,
    required this.onOpenWith,
    required this.onReveal,
  });

  @override
  State<_QueryUnitCard> createState() => _QueryUnitCardState();
}

class _QueryUnitCardState extends State<_QueryUnitCard> {
  QueryResultSort _sort = QueryResultSort.indexOrder;
  final Set<String> _selectedTypes = {};
  bool _includeOther = true;

  @override
  void initState() {
    super.initState();
    _selectedTypes.addAll(
      widget.unit.availableFileTypes.where(QueryFileTypeOptions.known.contains),
    );
  }

  @override
  void didUpdateWidget(covariant _QueryUnitCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newlyAvailable = widget.unit.availableFileTypes.difference(
      oldWidget.unit.availableFileTypes,
    );
    _selectedTypes.addAll(
      newlyAvailable.where(QueryFileTypeOptions.known.contains),
    );
  }

  int get _pageCount => widget.unit.pageCount;
  int get _page => widget.unit.pageIndex;
  Future<void> _go(int page) => widget.onPage(
    page.clamp(SearchPageValues.firstResultPageIndex, _pageCount - 1),
  );

  @override
  Widget build(BuildContext context) {
    final visible = widget.unit.fileResults;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft): _PreviousPageIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight): _NextPageIntent(),
        SingleActivator(LogicalKeyboardKey.pageUp): _PreviousPageIntent(),
        SingleActivator(LogicalKeyboardKey.pageDown): _NextPageIntent(),
        SingleActivator(LogicalKeyboardKey.home): _FirstPageIntent(),
        SingleActivator(LogicalKeyboardKey.end): _LastPageIntent(),
      },
      child: Actions(
        actions: {
          _PreviousPageIntent: CallbackAction<_PreviousPageIntent>(
            onInvoke: (_) {
              _go(_page - 1);
              return null;
            },
          ),
          _NextPageIntent: CallbackAction<_NextPageIntent>(
            onInvoke: (_) {
              _go(_page + 1);
              return null;
            },
          ),
          _FirstPageIntent: CallbackAction<_FirstPageIntent>(
            onInvoke: (_) {
              _go(0);
              return null;
            },
          ),
          _LastPageIntent: CallbackAction<_LastPageIntent>(
            onInvoke: (_) {
              _go(_pageCount - 1);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Card(
            elevation: SearchPageValues.queryUnitElevation,
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: SearchPageValues.queryUnitBorderWidth,
              ),
              borderRadius: BorderRadius.circular(
                SearchPageValues.queryUnitRadius,
              ),
            ),
            margin: const EdgeInsets.only(
              bottom: SearchPageValues.queryUnitBottomMargin,
            ),
            child: Padding(
              padding: const EdgeInsets.all(SearchPageValues.queryUnitPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.unit.label,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: SearchPageValues.queryUnitTitleGap),
                  Text(
                    context.tr(
                      '处理状态：${_statusLabel(widget.unit.status)}',
                      'Status: ${_statusLabel(widget.unit.status)}',
                    ),
                  ),
                  if (widget.unit.issues.isNotEmpty) ...[
                    const SizedBox(
                      height: SearchPageValues.queryUnitDescriptionGap,
                    ),
                    Text(
                      context.tr(
                        '需要注意：${widget.unit.issues.join('；')}',
                        'Notes: ${widget.unit.issues.join('; ')}',
                      ),
                    ),
                  ],
                  const SizedBox(height: SearchPageValues.queryUnitMetaGap),
                  Wrap(
                    spacing: SearchPageValues.searchActionHorizontalGap,
                    runSpacing: SearchPageValues.searchActionRunGap,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    children: [
                      SizedBox(
                        width: SearchPageValues.resultSortWidth,
                        child: AppSelectField<QueryResultSort>(
                          key: const Key('query-result-sort'),
                          value: _sort,
                          label: context.tr('结果排序', 'Sort results'),
                          options: QueryResultSort.values
                              .map(
                                (value) =>
                                    AppSelectOption(value, _sortLabel(value)),
                              )
                              .toList(growable: false),
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() => _sort = value);
                            _applyRefinement();
                          },
                        ),
                      ),
                      AppActionButton(
                        key: const Key('query-result-file-type-filter'),
                        kind: AppActionButtonKind.secondary,
                        icon: Icons.filter_alt_outlined,
                        label: context.tr('按后缀筛选', 'Filter by extension'),
                        onPressed: _openResultTypeFilter,
                      ),
                    ],
                  ),
                  const SizedBox(height: SearchPageValues.queryUnitMetaGap),
                  Text(
                    widget.unit.totalIsFinal
                        ? context.tr(
                            '共找到 ${widget.unit.totalFiles} 个文件；每页 ${widget.unit.pageSize} 个',
                            '${widget.unit.totalFiles} files found; ${widget.unit.pageSize} per page',
                          )
                        : context.tr(
                            '已找到至少 ${widget.unit.totalFiles} 个文件，仍在按页读取；每页 ${widget.unit.pageSize} 个',
                            'At least ${widget.unit.totalFiles} files found; more are loaded by page; ${widget.unit.pageSize} per page',
                          ),
                  ),
                  const SizedBox(height: SearchPageValues.queryUnitErrorGap),
                  if (visible.isEmpty)
                    Text(context.tr('没有结果。', 'No results.'))
                  else ...[
                    const _ResultTableHeader(),
                    const SizedBox(
                      height: SearchPageValues.resultHeaderToRowsGap,
                    ),
                    ...visible.asMap().entries.map(
                      (entry) => _ResultRow(
                        key: Key('query-result-${entry.value.fileObjectId}'),
                        rank: _page * widget.unit.pageSize + entry.key + 1,
                        result: entry.value,
                        onOpen: widget.onOpen,
                        onOpenWith: widget.onOpenWith,
                        onReveal: widget.onReveal,
                      ),
                    ),
                  ],
                  const SizedBox(height: SearchPageValues.paginationTopGap),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AppActionButton(
                        kind: AppActionButtonKind.secondary,
                        onPressed: _page == 0 ? null : () => _go(_page - 1),
                        icon: Icons.arrow_left,
                        label: context.tr('上一页', 'Previous page'),
                      ),
                      const SizedBox(
                        width: SearchPageValues.paginationButtonGap,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal:
                              SearchPageValues.paginationLabelHorizontalPadding,
                        ),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            context.tr(
                              '第 ${_page + 1} / $_pageCount 页',
                              'Page ${_page + 1} of $_pageCount',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(
                        width: SearchPageValues.paginationButtonGap,
                      ),
                      AppActionButton(
                        kind: AppActionButtonKind.secondary,
                        onPressed: _page + 1 >= _pageCount
                            ? null
                            : () => _go(_page + 1),
                        icon: Icons.arrow_right,
                        label: context.tr('下一页', 'Next page'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _statusLabel(QueryUnitStatus status) => switch (status) {
    QueryUnitStatus.completed => context.tr('完成', 'Completed'),
    QueryUnitStatus.partial => context.tr('部分完成', 'Partially completed'),
    QueryUnitStatus.failed => context.tr('失败', 'Failed'),
  };

  String _sortLabel(QueryResultSort sort) => switch (sort) {
    QueryResultSort.indexOrder => context.tr('默认顺序', 'Default order'),
    QueryResultSort.relevance => context.tr('相关度', 'Relevance'),
    QueryResultSort.extension => context.tr('后缀', 'Extension'),
    QueryResultSort.fileName => context.tr('文件名', 'File name'),
    QueryResultSort.path => context.tr('完整路径', 'Full path'),
  };

  Future<void> _applyRefinement() => widget.onRefine(
    FileQueryRefinement(
      fileTypeFilterEnabled: true,
      allowedFileTypes: Set.unmodifiable(_selectedTypes),
      includeOtherFileTypes: _includeOther,
      knownFileTypes: QueryFileTypeOptions.known,
      sort: _sort.name,
    ),
  );

  Future<void> _openResultTypeFilter() async {
    final selected = Set<String>.of(_selectedTypes);
    var includeOther = _includeOther;
    final knownAvailable =
        widget.unit.availableFileTypes
            .where(QueryFileTypeOptions.known.contains)
            .toList()
          ..sort();
    final hasOther = widget.unit.availableFileTypes.any(
      (value) =>
          value.isEmpty ||
          value == 'UNKNOWN' ||
          !QueryFileTypeOptions.known.contains(value),
    );
    final result = await showDialog<(Set<String>, bool)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, updateDialog) {
          final count = selected.length + (includeOther && hasOther ? 1 : 0);
          final total = knownAvailable.length + (hasOther ? 1 : 0);
          final bool? state = count == 0
              ? false
              : count == total
              ? true
              : null;
          return AppFormDialog(
            title: context.tr('筛选查询结果后缀', 'Filter result extensions'),
            content: SizedBox(
              width: SearchPageValues.resultFilterDialogWidth,
              height: SearchPageValues.resultFilterDialogHeight,
              child: ListView(
                children: [
                  AppCheckOption(
                    title: context.tr('全选', 'Select all'),
                    value: state,
                    tristate: true,
                    bulkControl: true,
                    onChanged: (_) => updateDialog(() {
                      if (count == total) {
                        selected.clear();
                        includeOther = false;
                      } else {
                        selected
                          ..clear()
                          ..addAll(knownAvailable);
                        includeOther = hasOther;
                      }
                    }),
                  ),
                  ...knownAvailable.map(
                    (type) => AppCheckOption(
                      title: type,
                      value: selected.contains(type),
                      onChanged: (value) => updateDialog(() {
                        if (value == true) {
                          selected.add(type);
                        } else {
                          selected.remove(type);
                        }
                      }),
                    ),
                  ),
                  if (hasOther)
                    AppCheckOption(
                      title: 'Other',
                      value: includeOther,
                      onChanged: (value) =>
                          updateDialog(() => includeOther = value == true),
                    ),
                ],
              ),
            ),
            cancelLabel: context.tr('取消', 'Cancel'),
            confirmLabel: context.tr('应用', 'Apply'),
            onCancel: () => Navigator.pop(dialogContext),
            onConfirm: () => Navigator.pop(dialogContext, (
              Set<String>.of(selected),
              includeOther,
            )),
          );
        },
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _selectedTypes
        ..clear()
        ..addAll(result.$1);
      _includeOther = result.$2;
    });
    await _applyRefinement();
  }
}

class _ResultTableHeader extends StatelessWidget {
  const _ResultTableHeader();

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Row(
      children: [
        Expanded(
          flex: SearchPageValues.resultNameColumnFlex,
          child: Text(
            context.tr('文件名称', 'File name'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        const SizedBox(width: SearchPageValues.resultColumnGap),
        Expanded(
          flex: SearchPageValues.resultPathColumnFlex,
          child: Text(
            context.tr('完整路径', 'Full path'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
      ],
    ),
  );
}

class _ResultRow extends StatefulWidget {
  final int rank;
  final VectorSearchHit result;
  final Future<void> Function(String path) onOpen;
  final Future<void> Function(String path) onOpenWith;
  final Future<void> Function(String path) onReveal;

  const _ResultRow({
    super.key,
    required this.rank,
    required this.result,
    required this.onOpen,
    required this.onOpenWith,
    required this.onReveal,
  });

  @override
  State<_ResultRow> createState() => _ResultRowState();
}

class _ResultRowState extends State<_ResultRow> {
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final fileName = p.basename(result.sourcePath);
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.open_in_new),
          onPressed: () => widget.onOpen(result.sourcePath),
          child: Text(context.tr('打开文件', 'Open file')),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.apps),
          onPressed: () => widget.onOpenWith(result.sourcePath),
          child: Text(context.tr('打开方式', 'Open with')),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.folder_open),
          onPressed: () => widget.onReveal(result.sourcePath),
          child: Text(context.tr('在文件管理器中显示', 'Show in file manager')),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.copy),
          onPressed: () => _copyPath(result.sourcePath),
          child: Text(context.tr('复制完整路径', 'Copy full path')),
        ),
      ],
      builder: (context, menuController, child) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter): () =>
              widget.onOpen(result.sourcePath),
          const SingleActivator(LogicalKeyboardKey.contextMenu):
              menuController.open,
          const SingleActivator(LogicalKeyboardKey.f10, shift: true):
              menuController.open,
        },
        child: Focus(
          focusNode: _focusNode,
          onFocusChange: (focused) => setState(() => _focused = focused),
          child: Semantics(
            button: true,
            label: context.tr(
              '第 ${widget.rank} 个结果，文件名称 $fileName，完整路径 ${result.sourcePath}',
              'Result ${widget.rank}, file name $fileName, full path ${result.sourcePath}',
            ),
            hint: context.tr(
              '双击或按回车打开文件；右键或按 Shift 加 F10 打开操作菜单',
              'Double-click or press Enter to open the file. Right-click or press Shift+F10 for the action menu.',
            ),
            onTap: () => widget.onOpen(result.sourcePath),
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () => widget.onOpen(result.sourcePath),
              onSecondaryTapDown: (_) {
                _focusNode.requestFocus();
                menuController.open();
              },
              child: InkWell(
                canRequestFocus: false,
                onTap: _focusNode.requestFocus,
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(
                    bottom: SearchPageValues.resultCardBottomMargin,
                  ),
                  padding: const EdgeInsets.all(
                    SearchPageValues.resultCardPadding,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(
                      SearchPageValues.resultCardRadius,
                    ),
                    border: Border.all(
                      color: _focused
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
                      width: _focused
                          ? SearchPageValues.resultFocusedBorderWidth
                          : SearchPageValues.resultBorderWidth,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: SearchPageValues.resultNameColumnFlex,
                        child: Text(
                          '${widget.rank}. $fileName',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      const SizedBox(width: SearchPageValues.resultColumnGap),
                      Expanded(
                        flex: SearchPageValues.resultPathColumnFlex,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(result.sourcePath),
                            const SizedBox(
                              height: SearchPageValues.resultTitleToPathGap,
                            ),
                            Text(_description(result)),
                            if (result.document.trim().isNotEmpty &&
                                result.document.trim() != fileName) ...[
                              const SizedBox(
                                height: SearchPageValues.resultPathToExcerptGap,
                              ),
                              Text(
                                result.document.trim(),
                                maxLines:
                                    SearchPageValues.resultExcerptMaximumLines,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copyPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Semantics(
          liveRegion: true,
          label: context.tr('已复制完整路径：$path', 'Full path copied: $path'),
          excludeSemantics: true,
          child: Text(context.tr('已复制完整路径。', 'Full path copied.')),
        ),
      ),
    );
  }

  String _description(VectorSearchHit result) {
    final parts = <String>[
      context.tr('类型：${result.fileType}', 'Type: ${result.fileType}'),
    ];
    final score = result.relevanceScore;
    if (score != null) {
      parts.add(
        context.tr(
          '综合相关度：${score.toStringAsFixed(SearchPageValues.scoreDecimalPlaces)}',
          'Overall relevance: ${score.toStringAsFixed(SearchPageValues.scoreDecimalPlaces)}',
        ),
      );
      final channels = <String>[
        if (result.vectorMatched) context.tr('语义', 'semantic'),
        if (result.keywordMatched) context.tr('关键词', 'keyword'),
      ];
      if (channels.isNotEmpty) {
        parts.add(
          context.tr(
            '命中方式：${channels.join('+')}',
            'Match method: ${channels.join('+')}',
          ),
        );
      }
    } else if (result.distance.isFinite) {
      parts.add(
        '向量距离：'
        '${result.distance.toStringAsFixed(SearchPageValues.scoreDecimalPlaces)}',
      );
    }
    return parts.join('；');
  }
}

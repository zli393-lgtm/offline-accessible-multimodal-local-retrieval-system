import 'dart:io';

import 'package:flutter/material.dart';

import '../application/application_controller.dart';
import '../application/runtime_configuration.dart';
import '../application/runtime_dependencies.dart';
import '../application/system_path_picker.dart';
import '../application/ui_preferences.dart';
import 'app_localizations.dart';
import 'ui_components.dart';
import '../configuration/presentation/pages/settings_page_values.dart';
import 'design_system/presets/app_action_button.dart';
import 'design_system/presets/app_choice_controls.dart';
import 'design_system/presets/app_form_dialog.dart';
import 'design_system/presets/app_path_display.dart';

class SettingsPage extends StatefulWidget {
  final ApplicationController controller;
  final SystemPathPicker? pathPicker;

  const SettingsPage({super.key, required this.controller, this.pathPicker});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _database;
  late final TextEditingController _application;
  late final TextEditingController _python;
  late final TextEditingController _log;
  final Map<RuntimeDependency, TextEditingController> _dependencies = {};
  final _migration = TextEditingController();
  late final SystemPathPicker _pathPicker;

  String _textSizeLabel(BuildContext context, AppTextSize size) =>
      switch (size) {
        AppTextSize.small => context.tr('小', 'Small'),
        AppTextSize.standard => context.tr('标准', 'Standard'),
        AppTextSize.accessibility => context.tr(
          '无障碍（默认）',
          'Accessible (default)',
        ),
        AppTextSize.large => context.tr('大', 'Large'),
        AppTextSize.extraLarge => context.tr('更大', 'Larger'),
      };

  String _colorModeLabel(BuildContext context, UiColorMode mode) =>
      switch (mode) {
        UiColorMode.standard => context.tr('默认配色', 'Standard colors'),
        UiColorMode.accessibility => context.tr(
          '色觉无障碍',
          'Color vision accessibility',
        ),
      };

  String _colorPresetLabel(BuildContext context, UiColorPreset preset) =>
      switch (preset) {
        UiColorPreset.blue => context.tr('蓝色', 'Blue'),
        UiColorPreset.green => context.tr('绿色', 'Green'),
        UiColorPreset.pink => context.tr('粉红色', 'Pink'),
        UiColorPreset.yellow => context.tr('黄色', 'Yellow'),
        UiColorPreset.orange => context.tr('橘色', 'Orange'),
        UiColorPreset.lightPurple => context.tr('浅紫色', 'Light purple'),
        UiColorPreset.grayscale => context.tr('灰阶色', 'Grayscale'),
      };

  String _colorVisionLabel(BuildContext context, ColorVisionPreset preset) =>
      switch (preset) {
        ColorVisionPreset.protanopia => context.tr(
          '红绿色觉辅助（红色型）',
          'Red-green assistance, red type',
        ),
        ColorVisionPreset.deuteranopia => context.tr(
          '红绿色觉辅助（绿色型）',
          'Red-green assistance, green type',
        ),
        ColorVisionPreset.tritanopia => context.tr(
          '蓝黄色觉辅助',
          'Blue-yellow assistance',
        ),
      };

  @override
  void initState() {
    super.initState();
    _pathPicker = widget.pathPicker ?? SystemPathPicker.platformDefault();
    final configuration = widget.controller.configuration;
    _database = TextEditingController(
      text:
          configuration?.databaseRoot ??
          RuntimeConfiguration.suggestedDatabaseRoot(),
    );
    _application = TextEditingController(
      text:
          configuration?.applicationDirectory ??
          RuntimeConfiguration.suggestedApplicationDirectory(),
    );
    _python = TextEditingController(
      text: configuration == null
          ? RuntimeConfiguration.suggestedPythonDirectory(_application.text)
          : RuntimeConfiguration.pythonDirectoryForDisplay(
              configuration.pythonExecutable,
              _application.text,
            ),
    );
    _log = TextEditingController(
      text:
          configuration?.logDirectory ??
          RuntimeConfiguration.suggestedLogDirectory(_database.text),
    );
    for (final dependency in RuntimeDependency.values) {
      final saved = configuration?.dependencyPaths[dependency.name] ?? '';
      _dependencies[dependency] = TextEditingController(
        text: RuntimeDependencies.directoryForConfiguration(
          dependency,
          applicationDirectory: _application.text,
          configuredPath: saved,
        ),
      );
    }
  }

  @override
  void dispose() {
    _database.dispose();
    _application.dispose();
    _python.dispose();
    _log.dispose();
    for (final controller in _dependencies.values) {
      controller.dispose();
    }
    _migration.dispose();
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
    return ListView(
      key: const Key('settings-page'),
      padding: const EdgeInsets.all(SettingsPageValues.outerPadding),
      children: [
        PageHeading(
          icon: Icons.settings,
          title: context.tr('设置', 'Settings'),
          description: context.tr(
            '常用显示选项放在最前面。首次使用只需选择数据库位置，然后保存并启动。',
            'Common display options appear first. To get started, choose where to store the index, then save and start the service.',
          ),
        ),
        const SizedBox(height: SettingsPageValues.headingToAccessibilityGap),
        SectionPanel(
          title: context.tr('界面与无障碍', 'Interface and accessibility'),
          description: context.tr(
            '设置会自动保存；支持键盘操作、系统屏幕阅读器和系统文字缩放。',
            'Changes are saved automatically. Keyboard navigation, screen readers, and system text scaling are supported.',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppSelectField<AppLanguage>(
                key: const Key('language-selector'),
                value: controller.uiPreferences.language,
                label: context.tr('语言', 'Language'),
                helper: context.tr(
                  '切换后立即更新整个程序；文件名、路径和用户内容保持原样。',
                  'The entire application updates immediately. File names, paths, and user content are never translated.',
                ),
                options: AppLanguage.values
                    .map(
                      (language) =>
                          AppSelectOption(language, language.nativeLabel),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) controller.setLanguage(value);
                },
              ),
              const SizedBox(height: SettingsPageValues.languageToColorModeGap),
              AppSegmentedSelector<UiColorMode>(
                key: const Key('color-mode-selector'),
                value: controller.uiPreferences.colorMode,
                semanticLabel: context.tr('界面配色模式', 'Interface color mode'),
                options: UiColorMode.values
                    .map(
                      (mode) => AppSegmentOption(
                        mode,
                        _colorModeLabel(context, mode),
                        icon: mode == UiColorMode.standard
                            ? Icons.palette_outlined
                            : Icons.accessibility_new,
                      ),
                    )
                    .toList(),
                onChanged: controller.setColorMode,
              ),
              const SizedBox(height: SettingsPageValues.colorModeToPresetGap),
              if (controller.uiPreferences.colorMode == UiColorMode.standard)
                AppSelectField<UiColorPreset>(
                  key: const Key('color-preset-selector'),
                  value: controller.uiPreferences.colorPreset,
                  label: context.tr('界面颜色', 'Interface color'),
                  helper: context.tr(
                    '颜色会应用于背景、标题、导航选中状态和主要操作。',
                    'The selected colors apply to backgrounds, headings, selected navigation items, and primary actions.',
                  ),
                  options: UiColorPreset.values
                      .map(
                        (preset) => AppSelectOption(
                          preset,
                          _colorPresetLabel(context, preset),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) controller.setColorPreset(value);
                  },
                )
              else
                AppSelectField<ColorVisionPreset>(
                  key: const Key('color-vision-preset-selector'),
                  value: controller.uiPreferences.colorVisionPreset,
                  label: context.tr('色觉辅助类型', 'Color vision assistance'),
                  helper: context.tr(
                    '采用常见色觉缺陷分类；所有状态仍同时使用文字和图标，不只依赖颜色。',
                    'Uses common color-vision-deficiency categories. Every status also uses text and an icon, never color alone.',
                  ),
                  options: ColorVisionPreset.values
                      .map(
                        (preset) => AppSelectOption(
                          preset,
                          '${_colorVisionLabel(context, preset)} (${preset.standardName})',
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      controller.setColorVisionPreset(value);
                    }
                  },
                ),
              const SizedBox(
                height: SettingsPageValues.presetToHighContrastGap,
              ),
              AppCheckOption(
                key: const Key('high-contrast-switch'),
                title: context.tr('高对比度', 'High contrast'),
                subtitle: context.tr(
                  '增强文字、边框、背景和操作控件之间的明暗区分。',
                  'Increases luminance contrast between text, borders, backgrounds, and controls without changing the selected hues.',
                ),
                toggle: true,
                value: controller.uiPreferences.highContrast,
                onChanged: (value) {
                  if (value != null) controller.setHighContrast(value);
                },
              ),
              const SizedBox(height: SettingsPageValues.presetToTextSizeGap),
              AppSelectField<AppTextSize>(
                key: const Key('text-size-selector'),
                value: controller.uiPreferences.textSize,
                label: context.tr('界面与文字大小', 'Interface and text size'),
                helper: context.tr(
                  '“无障碍”为默认档；可向下减少空间占用，或向上进一步放大。',
                  'Accessible is the default. Choose a smaller size to save space or a larger size for easier reading.',
                ),
                options: AppTextSize.values
                    .map(
                      (size) =>
                          AppSelectOption(size, _textSizeLabel(context, size)),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) controller.setTextSize(value);
                },
              ),
              const SizedBox(height: SettingsPageValues.textSizeToShortcutGap),
              Text(
                context.tr(
                  '键盘快捷键：Alt+1 文件库，Alt+2 查询，Alt+3 设置；Tab 在控件之间移动。',
                  'Keyboard shortcuts: Alt+1 Library, Alt+2 Search, Alt+3 Settings. Press Tab to move between controls.',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: SettingsPageValues.accessibilityToRuntimeGap),
        SectionPanel(
          title: context.tr('数据库与本地运行环境', 'Database and local runtime'),
          description: context.tr(
            '数据库位置由您决定。程序会自动排除该位置，避免把数据库再次写入自身。',
            'You choose where the index database is stored. The application excludes that location automatically so it is never indexed into itself.',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                liveRegion: true,
                label: controller.busy
                    ? controller.statusMessage
                    : controller.ready
                    ? context.tr(
                        '当前状态，本地服务已就绪',
                        'Current status: local service is ready',
                      )
                    : context.tr(
                        '当前状态，本地服务未启动',
                        'Current status: local service is not running',
                      ),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(
                    SettingsPageValues.runtimeStatusPadding,
                  ),
                  decoration: BoxDecoration(
                    color: controller.busy
                        ? Theme.of(context).colorScheme.tertiaryContainer
                        : controller.ready
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(
                      SettingsPageValues.runtimeStatusRadius,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        controller.busy
                            ? Icons.sync
                            : controller.ready
                            ? Icons.check_circle
                            : Icons.info,
                        size: SettingsPageValues.runtimeStatusIconSize,
                      ),
                      const SizedBox(
                        width: SettingsPageValues.runtimeStatusIconGap,
                      ),
                      Expanded(
                        child: Text(
                          controller.busy
                              ? controller.statusMessage
                              : controller.ready
                              ? context.tr(
                                  '本地服务已就绪，可以扫描和查询。',
                                  'The local service is ready. You can now index and search files.',
                                )
                              : context.tr(
                                  '本地服务未启动。完成下面的设置后按“保存并启动”。',
                                  'The local service is not running. Complete the settings below, then select Save and start.',
                                ),
                          style: TextStyle(
                            fontWeight:
                                FontWeight.values[SettingsPageValues
                                    .runtimeStatusFontWeightIndex],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(
                height: SettingsPageValues.runtimeStatusToDatabaseGap,
              ),
              _directoryField(
                key: const Key('database-root-field'),
                controller: _database,
                label: context.tr('数据库存储根目录', 'Index database folder'),
                hint: context.tr(
                  '选择一个空间充足的文件夹',
                  'Choose a folder with sufficient free space',
                ),
                buttonLabel: context.tr('选择数据库位置', 'Choose database folder'),
              ),
              const SizedBox(
                height: SettingsPageValues.databaseToApplicationGap,
              ),
              _directoryField(
                controller: _application,
                label: context.tr('程序资源目录', 'Application resources folder'),
                helper: context.tr(
                  '应包含 assets 和 services；默认使用当前程序自身目录。',
                  'Must contain the assets and services folders. The application folder is used by default.',
                ),
                buttonLabel: context.tr('选择资源目录', 'Choose resources folder'),
              ),
              const SizedBox(height: SettingsPageValues.dependencyHeadingGap),
              ExpansionTile(
                key: const Key('local-dependencies-expansion'),
                initiallyExpanded: false,
                childrenPadding: const EdgeInsets.all(
                  SettingsPageValues.dependencyChildrenPadding,
                ),
                title: Text(context.tr('本地依赖', 'Local dependencies')),
                subtitle: Text(
                  context.tr(
                    '展开后检查或配置文档、图像和音频处理依赖',
                    'Expand to check or configure document, image, and audio dependencies',
                  ),
                ),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      context.tr(
                        '程序优先使用已保存的有效路径，其次检查程序资源目录中的 dependencies 文件夹、环境变量和系统常见安装位置。未找到的项目保持为空，可由您手动选择。浏览器不会从 dependencies 文件夹加载。',
                        'The app first uses a valid saved path, then checks the dependencies folder in the application resources, environment variables, and common system locations. Missing items remain empty for manual selection. Browsers are never loaded from the dependencies folder.',
                      ),
                    ),
                  ),
                  const SizedBox(height: SettingsPageValues.dependencyItemGap),
                  _folderDependencyField(
                    controller: _python,
                    label: context.tr('Python 运行环境', 'Python runtime'),
                    helper: context.tr(
                      '索引和查询后台使用。请选择 Python 安装目录；程序界面本身无需 Python 即可启动。',
                      'Used by the indexing and search backend. Choose the Python installation folder; the app interface itself starts without Python.',
                    ),
                  ),
                  _dependencyField(
                    RuntimeDependency.java,
                    label: context.tr('Java 运行环境', 'Java runtime'),
                    helper: context.tr(
                      '运行 Apache Tika，用于解析 PDF、Office、电子书及其他复合文档。请选择 Java 安装目录。',
                      'Runs Apache Tika to parse PDF, Office, ebook, and other compound documents. Choose the Java installation folder.',
                    ),
                  ),
                  _dependencyField(
                    RuntimeDependency.tika,
                    label: context.tr('Apache Tika', 'Apache Tika'),
                    helper: context.tr(
                      '提取复合文档中的文字和内嵌资源。请选择包含 tika-app-*.jar 的目录。',
                      'Extracts text and embedded resources from compound documents. Choose the folder containing tika-app-*.jar.',
                    ),
                  ),
                  _dependencyField(
                    RuntimeDependency.tesseract,
                    label: context.tr('Tesseract OCR', 'Tesseract OCR'),
                    helper: context.tr(
                      '识别图片和扫描页中的文字；语言数据应与程序安装在同一套 Tesseract 环境中。',
                      'Recognizes text in images and scanned pages. Language data must belong to the same Tesseract installation.',
                    ),
                  ),
                  _dependencyField(
                    RuntimeDependency.pdfium,
                    label: context.tr('PDFium 动态库', 'PDFium library'),
                    helper: context.tr(
                      '读取 PDF 的原生文字、页面结构和图像对象。请选择包含当前操作系统 PDFium 动态库的目录。',
                      'Reads native PDF text, page structure, and image objects. Choose the folder containing the PDFium library for this operating system.',
                    ),
                  ),
                  _dependencyField(
                    RuntimeDependency.djvuLibre,
                    label: context.tr(
                      'DjVuLibre 工具目录',
                      'DjVuLibre tools folder',
                    ),
                    helper: context.tr(
                      '读取 DjVu 文件。目录中应同时包含 ddjvu、djvutxt 和 djvused。',
                      'Reads DjVu files. The folder must contain ddjvu, djvutxt, and djvused.',
                    ),
                  ),
                  _dependencyField(
                    RuntimeDependency.ghostPdl,
                    label: context.tr('GhostPDL 工具目录', 'GhostPDL tools folder'),
                    helper: context.tr(
                      '读取和渲染 PostScript、EPS、XPS及 OXPS。目录中应包含 Ghostscript 和 GhostXPS 命令行程序。',
                      'Reads and renders PostScript, EPS, XPS, and OXPS. The folder must contain the Ghostscript and GhostXPS command-line tools.',
                    ),
                  ),
                  _dependencyField(
                    RuntimeDependency.jpegXr,
                    label: context.tr('JPEG XR 解码器', 'JPEG XR decoder'),
                    helper: context.tr(
                      '解码 JXR、WDP 和 HDP 图像。请选择包含 JxrDecApp 的目录。',
                      'Decodes JXR, WDP, and HDP images. Choose the folder containing JxrDecApp.',
                    ),
                  ),
                  _dependencyField(
                    RuntimeDependency.browser,
                    label: context.tr('浏览器渲染程序', 'Browser renderer'),
                    helper: context.tr(
                      '安全渲染 SVG 等结构化图像。请选择 Edge、Chrome 或 Chromium 的安装目录；浏览器不参与自包含打包。',
                      'Safely renders SVG and other structured images. Choose the Edge, Chrome, or Chromium installation folder. Browsers are not included in self-contained packages.',
                    ),
                  ),
                  const SizedBox(
                    height: SettingsPageValues.dependencyListBottomGap,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      AppActionButton(
                        key: const Key('check-dependencies-button'),
                        kind: AppActionButtonKind.secondary,
                        onPressed: controller.busy ? null : _checkDependencies,
                        label: context.tr('检查依赖', 'Check dependencies'),
                      ),
                    ],
                  ),
                  const SizedBox(
                    height: SettingsPageValues.dependencyCheckBottomGap,
                  ),
                ],
              ),
              const SizedBox(height: SettingsPageValues.pythonToActionsGap),
              Wrap(
                spacing: SettingsPageValues.runtimeActionGap,
                runSpacing: SettingsPageValues.runtimeActionRunGap,
                children: [
                  AppActionButton(
                    key: const Key('save-start-button'),
                    onPressed: controller.busy
                        ? null
                        : () => _perform(
                            () => controller.saveConfigurationAndStart(
                              databaseRoot: _database.text,
                              applicationDirectory: _application.text,
                              pythonExecutable: _python.text,
                              logDirectory: _log.text,
                              dependencyPaths: {
                                ...?controller.configuration?.dependencyPaths,
                                for (final entry in _dependencies.entries)
                                  entry.key.name: entry.value.text.trim(),
                              },
                            ),
                          ),
                    icon: Icons.play_arrow,
                    label: context.tr('保存并启动', 'Save and start'),
                  ),
                  AppActionButton(
                    kind: AppActionButtonKind.secondary,
                    onPressed: controller.busy
                        ? null
                        : () => _perform(controller.startSavedRuntime),
                    icon: Icons.restart_alt,
                    label: context.tr('按已保存配置启动', 'Start with saved settings'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SettingsPageValues.runtimeToLogGap),
        SectionPanel(
          title: context.tr('日志', 'Logs'),
          description: context.tr(
            '每次索引任务生成一份 UTF-8 纯文本 .log 文件，按文件记录最终成功或失败，内容为中英对照。',
            'Each indexing run creates one UTF-8 plain-text .log file containing the final success or failure of every recorded file in both Chinese and English.',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _directoryField(
                controller: _log,
                label: context.tr('日志存储位置', 'Log folder'),
                helper: context.tr(
                  '每次索引任务的成功、失败和失败重试日志都保存在这里。',
                  'Success, failure, and retry logs for every indexing run are stored here.',
                ),
                buttonLabel: context.tr('选择日志位置', 'Choose log folder'),
              ),
              const SizedBox(height: SettingsPageValues.logPathToActionGap),
              AppActionButton(
                kind: AppActionButtonKind.secondary,
                onPressed: () => _perform(() async {
                  final selected = Directory(_log.text.trim());
                  if (!await selected.exists()) {
                    await selected.create(recursive: true);
                  }
                  await controller.fileLauncher.openFile(
                    selected.path,
                    english:
                        controller.uiPreferences.language ==
                        AppLanguage.english,
                  );
                }),
                icon: Icons.folder_open,
                label: context.tr('打开日志目录', 'Open log folder'),
              ),
            ],
          ),
        ),
        const SizedBox(height: SettingsPageValues.runtimeToMigrationGap),
        SectionPanel(
          title: context.tr('迁移数据库', 'Move the database'),
          description: context.tr(
            '先停止本地服务，完整复制并校验后再切换；原数据库不会被删除。',
            'The local service stops first. The database is copied and verified before switching, and the original is not deleted.',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _directoryField(
                controller: _migration,
                label: context.tr('新的存储根目录', 'New database folder'),
                buttonLabel: context.tr('选择新位置', 'Choose new folder'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(
                height: SettingsPageValues.migrationFieldToActionGap,
              ),
              AppActionButton(
                onPressed: controller.busy || _migration.text.trim().isEmpty
                    ? null
                    : () => _perform(
                        () =>
                            controller.migrateDatabaseAndStart(_migration.text),
                      ),
                icon: Icons.drive_file_move,
                label: context.tr('复制、校验并切换', 'Copy, verify, and switch'),
              ),
            ],
          ),
        ),
        const SizedBox(height: SettingsPageValues.resetSectionGap),
        SectionPanel(
          title: context.tr('清理与重置', 'Cleanup and reset'),
          description: context.tr(
            '分别清空索引数据或恢复程序初始配置。两个操作互相独立，执行前都会要求确认。',
            'Clear index data or restore the application configuration independently. Both operations require confirmation.',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.tr('索引数据', 'Index data'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                context.tr(
                  '删除当前数据库中的索引、向量、处理记录和日志，不删除原始文件、扫描范围或界面配置。',
                  'Delete indexes, vectors, processing records, and logs from the current database without deleting original files, scan locations, or interface settings.',
                ),
              ),
              const SizedBox(height: SettingsPageValues.resetActionGap),
              AppActionButton(
                key: const Key('clear-all-indexes-button'),
                kind: AppActionButtonKind.danger,
                onPressed: !controller.ready || controller.busy
                    ? null
                    : () => _confirmClearAllIndexes(controller),
                label: context.tr('清空全部索引', 'Clear all indexes'),
              ),
              const SizedBox(height: SettingsPageValues.resetOperationGap),
              Text(
                context.tr('程序配置', 'Application configuration'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                context.tr(
                  '清除界面、运行环境和扫描范围配置，随后重启并恢复首次使用状态；索引数据不会删除。',
                  'Clear interface, runtime, and scan-scope settings, then restart in the first-run state. Index data is not deleted.',
                ),
              ),
              const SizedBox(height: SettingsPageValues.resetActionGap),
              AppActionButton(
                key: const Key('reset-configuration-button'),
                kind: AppActionButtonKind.secondary,
                label: context.tr('清除配置并重启', 'Clear configuration and restart'),
                onPressed: controller.busy
                    ? null
                    : () => _confirmResetConfiguration(controller),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClearAllIndexes(ApplicationController controller) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppFormDialog(
        title: context.tr('清空全部索引', 'Clear all indexes'),
        content: Text(
          context.tr(
            '这会永久删除当前数据库中的全部文件索引、向量数据、处理记录和日志。您的原始文件、扫描范围和界面配置不会被删除。此操作无法撤销。',
            'This permanently deletes every file index, vector, processing record, and log in the current database. Original files, scan locations, and interface settings are preserved. This cannot be undone.',
          ),
        ),
        cancelLabel: context.tr('取消', 'Cancel'),
        confirmLabel: context.tr('确认清空', 'Clear indexes'),
        onCancel: () => Navigator.pop(dialogContext, false),
        onConfirm: () => Navigator.pop(dialogContext, true),
      ),
    );
    if (confirmed == true && mounted) {
      await _perform(controller.clearAllIndexes);
    }
  }

  Future<void> _confirmResetConfiguration(
    ApplicationController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppFormDialog(
        title: context.tr('恢复初始配置', 'Restore initial configuration'),
        content: Text(
          context.tr(
            '确定后将清除已保存的语言、颜色、字号、运行环境路径、扫描模式、已选路径和排除路径，然后立即重启本程序。已建立的索引数据不会删除。取消则不会修改任何配置。',
            'Confirm to clear the saved language, colors, text size, runtime paths, scan mode, selected paths, and excluded paths, then restart this application immediately. Existing index data is not deleted. Cancel changes nothing.',
          ),
        ),
        cancelLabel: context.tr('取消', 'Cancel'),
        confirmLabel: context.tr('确定并重启', 'Confirm and restart'),
        onCancel: () => Navigator.pop(dialogContext, false),
        onConfirm: () => Navigator.pop(dialogContext, true),
      ),
    );
    if (confirmed == true) {
      await controller.resetSavedConfigurationAndRestart();
    }
  }

  Widget _directoryField({
    Key? key,
    required TextEditingController controller,
    required String label,
    required String buttonLabel,
    String? hint,
    String? helper,
    ValueChanged<String>? onChanged,
  }) => _pickerAndPath(
    button: AppActionButton(
      kind: AppActionButtonKind.secondary,
      onPressed: () => _perform(() async {
        final path = await _pathPicker.pickDirectory(
          english:
              widget.controller.uiPreferences.language == AppLanguage.english,
        );
        if (path != null && mounted) {
          setState(() => controller.text = path);
          onChanged?.call(path);
        }
      }),
      icon: Icons.folder_open,
      label: buttonLabel,
    ),
    display: AppPathDisplay(
      key: key,
      label: label,
      path: controller.text,
      emptyText: hint,
      helper: helper,
    ),
  );

  Widget _pickerAndPath({required Widget button, required Widget display}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: SettingsPageValues.pathButtonWidth, child: button),
          const SizedBox(height: SettingsPageValues.compactFieldButtonGap),
          display,
        ],
      );

  Widget _dependencyField(
    RuntimeDependency dependency, {
    required String label,
    required String helper,
  }) => _folderDependencyField(
    controller: _dependencies[dependency]!,
    label: label,
    helper: helper,
  );

  Widget _folderDependencyField({
    required TextEditingController controller,
    required String label,
    required String helper,
  }) {
    final english =
        widget.controller.uiPreferences.language == AppLanguage.english;
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(
        bottom: SettingsPageValues.dependencyItemGap,
      ),
      padding: const EdgeInsets.all(SettingsPageValues.dependencyCardPadding),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(
          SettingsPageValues.dependencyCardRadius,
        ),
        border: Border.all(
          color: colors.outlineVariant,
          width: SettingsPageValues.dependencyCardBorderWidth,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppPathDisplay(
            label: label,
            path: controller.text,
            emptyText: context.tr('尚未找到，请手动选择', 'Not found; choose manually'),
            helper: helper,
          ),
          const SizedBox(height: SettingsPageValues.dependencyPathToButtonGap),
          SizedBox(
            width: SettingsPageValues.pathButtonWidth,
            child: AppActionButton(
              kind: AppActionButtonKind.secondary,
              onPressed: () => _perform(() async {
                final path = await _pathPicker.pickDirectory(english: english);
                if (path != null && mounted) {
                  setState(() => controller.text = path);
                }
              }),
              label: context.tr('选择文件夹', 'Choose folder'),
              semanticHint: context.tr(
                '为“$label”选择文件夹',
                'Choose a folder for $label',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Map<String, String> _dependencyDraft() => {
    ...?widget.controller.configuration?.dependencyPaths,
    for (final entry in _dependencies.entries)
      entry.key.name: entry.value.text.trim(),
  };

  Future<void> _checkDependencies() async {
    await _perform(() async {
      final report = await widget.controller.checkDependencies(
        applicationDirectory: _application.text.trim(),
        pythonDirectory: _python.text.trim(),
        dependencyPaths: _dependencyDraft(),
      );
      if (!mounted) return;
      if (report.complete) {
        await showDialog<void>(
          context: context,
          builder: (context) => AppFormDialog(
            title: context.tr('依赖检查完成', 'Dependency check complete'),
            content: Text(
              context.tr(
                '全部主依赖、Python 组件和本地模型均已准备完成。',
                'All root dependencies, Python components, and local models are ready.',
              ),
            ),
            cancelLabel: context.tr('确定', 'OK'),
            onCancel: () => Navigator.pop(context),
          ),
        );
        return;
      }
      await _showDependencyInstallDialog(report.allMissing);
    });
  }

  Future<void> _showDependencyInstallDialog(List<String> missing) async {
    final installToProgram = await showDialog<bool>(
      context: context,
      builder: (context) => AppFormDialog(
        title: context.tr('依赖尚未完整', 'Dependencies are incomplete'),
        content: Text(
          context.tr(
            '缺少：${missing.join('、')}。\n\n安装需要网络，只会自动安装 Python 组件和模型；Java、Tika等主依赖仍需由用户选择。请选择安装位置。',
            'Missing: ${missing.join(', ')}.\n\nNetwork access is required. Only Python components and models are installed automatically; root dependencies such as Java and Tika must still be selected. Choose an installation location.',
          ),
        ),
        cancelLabel: context.tr('取消', 'Cancel'),
        alternativeLabel: context.tr(
          '安装到 Python 位置',
          'Install into Python location',
        ),
        confirmLabel: context.tr('安装到程序位置', 'Install into application folder'),
        onCancel: () => Navigator.pop(context),
        onAlternative: () => Navigator.pop(context, false),
        onConfirm: () => Navigator.pop(context, true),
      ),
    );
    if (installToProgram == null || !mounted) return;
    final report = await widget.controller.installLowerDependencies(
      applicationDirectory: _application.text.trim(),
      pythonDirectory: _python.text.trim(),
      dependencyPaths: _dependencyDraft(),
      installToProgram: installToProgram,
    );
    if (!mounted) return;
    final configuration = widget.controller.configuration;
    setState(() {
      if (installToProgram) {
        _python.text = RuntimeConfiguration.suggestedPythonDirectory(
          _application.text,
        );
      } else if (configuration != null) {
        _python.text = RuntimeConfiguration.pythonDirectoryForDisplay(
          configuration.pythonExecutable,
          _application.text,
        );
      }
    });
    await showDialog<void>(
      context: context,
      builder: (context) => AppFormDialog(
        title: report.complete
            ? context.tr('安装完成', 'Installation complete')
            : context.tr('安装未完成', 'Installation incomplete'),
        content: Text(
          report.complete
              ? context.tr(
                  '全部依赖已经安装并通过检查。',
                  'All dependencies were installed and passed validation.',
                )
              : context.tr(
                  '仍缺少：${report.allMissing.join('、')}',
                  'Still missing: ${report.allMissing.join(', ')}',
                ),
        ),
        cancelLabel: context.tr('确定', 'OK'),
        onCancel: () => Navigator.pop(context),
      ),
    );
  }
}

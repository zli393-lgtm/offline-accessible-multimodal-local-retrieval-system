import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/application/application_controller.dart';
import 'package:retrieval/application/runtime_configuration.dart';
import 'package:retrieval/application/system_file_launcher.dart';
import 'package:retrieval/application/ui_preferences.dart';
import 'package:retrieval/main.dart';
import 'package:retrieval/indexing/index_comparison.dart';
import 'package:retrieval/query/query_models.dart';
import 'package:retrieval/storage/multimodal_vector_store.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('widget-test-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  ApplicationController controller() => ApplicationController(
    onboardingEnabled: false,
    systemLanguage: AppLanguage.simplifiedChinese,
    configurationStore: RuntimeConfigurationStore(
      File(p.join(temporary.path, 'settings.json')),
    ),
    uiPreferencesStore: UiPreferencesStore(
      File(p.join(temporary.path, 'interface-settings.json')),
    ),
  );

  testWidgets('first launch explains accessibility and opens settings', (
    tester,
  ) async {
    final appController = ApplicationController(
      systemLanguage: AppLanguage.simplifiedChinese,
      configurationStore: RuntimeConfigurationStore(
        File(p.join(temporary.path, 'first-run-settings.json')),
      ),
      uiPreferencesStore: UiPreferencesStore(
        File(p.join(temporary.path, 'first-run-interface.json')),
      ),
    );
    await tester.runAsync(appController.initialize);
    await tester.pumpWidget(RetrievalApp(controller: appController));
    await tester.pumpAndSettle();

    expect(find.text('首次使用提醒'), findsOneWidget);
    expect(find.text('前往设置'), findsOneWidget);
    await tester.tap(find.text('前往设置'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('settings-page')), findsOneWidget);
    expect(appController.uiPreferences.onboardingCompleted, isTrue);
  });

  testWidgets('first launch follows the system language', (tester) async {
    final appController = ApplicationController(
      systemLanguage: AppLanguage.english,
      configurationStore: RuntimeConfigurationStore(
        File(p.join(temporary.path, 'english-runtime.json')),
      ),
      uiPreferencesStore: UiPreferencesStore(
        File(p.join(temporary.path, 'english-interface.json')),
      ),
    );
    await tester.runAsync(appController.initialize);
    await tester.pumpWidget(RetrievalApp(controller: appController));
    await tester.pumpAndSettle();

    expect(appController.uiPreferences.language, AppLanguage.english);
    expect(find.text('First-use information'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
  });

  test('language names are always written in their own language', () {
    expect(AppLanguage.simplifiedChinese.nativeLabel, '简体中文');
    expect(AppLanguage.english.nativeLabel, 'English');
  });

  testWidgets(
    'main interface exposes library, independent query, and settings',
    (tester) async {
      final appController = controller();
      await tester.runAsync(appController.initialize);
      await tester.pumpWidget(RetrievalApp(controller: appController));

      expect(find.text('本地文件检索'), findsOneWidget);
      expect(find.text('建立和更新文件库'), findsOneWidget);
      expect(find.text('选择一个或多个文件'), findsOneWidget);
      await _dragUntilBuilt(
        tester,
        page: find.byKey(const Key('library-page')),
        target: find.byKey(const Key('index-comparison-preset')),
      );
      expect(find.byKey(const Key('compare-path-checkbox')), findsOneWidget);
      expect(find.byKey(const Key('compare-size-checkbox')), findsOneWidget);
      expect(
        find.byKey(const Key('compare-modified-checkbox')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('compare-hash-checkbox')), findsOneWidget);
      expect(find.text('自定义'), findsNothing);
      expect(
        find.byKey(const Key('compare-select-all-checkbox')),
        findsOneWidget,
      );

      await tester.tap(find.text('查询'));
      await tester.pumpAndSettle();
      expect(find.text('查询文件库'), findsOneWidget);
      expect(find.byKey(const Key('query-description-field')), findsOneWidget);
      expect(find.textContaining('每个附件会单独、完整地查找'), findsOneWidget);
      await _dragUntilBuilt(
        tester,
        page: find.byKey(const Key('search-page')),
        target: find.byKey(const Key('query-file-type-mode')),
      );
      expect(find.byKey(const Key('query-file-type-mode')), findsOneWidget);
      await _dragUntilBuilt(
        tester,
        page: find.byKey(const Key('search-page')),
        target: find.byKey(const Key('query-information-preset')),
      );
      expect(find.textContaining('文件名始终参与查询'), findsOneWidget);
      expect(find.byKey(const Key('query-information-fileName')), findsNothing);
      expect(
        find.byKey(const Key('query-information-nativeText')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('query-information-extractedText')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('query-information-image')), findsOneWidget);
      expect(find.byKey(const Key('query-information-audio')), findsOneWidget);
      expect(find.text('自定义'), findsNothing);
      expect(
        find.byKey(const Key('query-information-select-all')),
        findsOneWidget,
      );
      await _dragUntilBuilt(
        tester,
        page: find.byKey(const Key('search-page')),
        target: find.byKey(const Key('choose-query-attachments-button')),
      );
      expect(
        find.byKey(const Key('choose-query-attachments-button')),
        findsOneWidget,
      );

      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('界面与无障碍'), findsOneWidget);
      expect(find.byKey(const Key('high-contrast-switch')), findsOneWidget);
      await _dragUntilBuilt(
        tester,
        page: find.byKey(const Key('settings-page')),
        target: find.byKey(const Key('database-root-field')),
      );
      expect(find.text('数据库与本地运行环境'), findsOneWidget);
      expect(find.byKey(const Key('database-root-field')), findsOneWidget);
      await _dragUntilBuilt(
        tester,
        page: find.byKey(const Key('settings-page')),
        target: find.text('复制、校验并切换'),
      );
      expect(find.text('复制、校验并切换'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('query information supports a tri-state select-all option', (
    tester,
  ) async {
    final appController = controller();
    await tester.runAsync(appController.initialize);
    await tester.pumpWidget(RetrievalApp(controller: appController));

    await tester.tap(find.text('查询'));
    await tester.pumpAndSettle();
    await _dragUntilBuilt(
      tester,
      page: find.byKey(const Key('search-page')),
      target: find.byKey(const Key('query-information-select-all')),
    );

    final selectAll = find.byKey(const Key('query-information-select-all'));
    expect(
      tester
          .widget<Checkbox>(
            find.descendant(of: selectAll, matching: find.byType(Checkbox)),
          )
          .value,
      isNull,
    );

    await tester.tap(selectAll);
    await tester.pumpAndSettle();
    for (final kind in QueryInformationKind.values) {
      final checkbox = tester.widget<Checkbox>(
        find.descendant(
          of: find.byKey(Key('query-information-${kind.name}')),
          matching: find.byType(Checkbox),
        ),
      );
      expect(checkbox.value, isTrue);
    }

    await tester.tap(selectAll);
    await tester.pumpAndSettle();
    for (final kind in QueryInformationKind.values) {
      final checkbox = tester.widget<Checkbox>(
        find.descendant(
          of: find.byKey(Key('query-information-${kind.name}')),
          matching: find.byType(Checkbox),
        ),
      );
      expect(checkbox.value, isFalse);
    }
  });

  testWidgets('index comparison supports a tri-state select-all option', (
    tester,
  ) async {
    final appController = controller();
    await tester.runAsync(appController.initialize);
    await tester.pumpWidget(RetrievalApp(controller: appController));
    await _dragUntilBuilt(
      tester,
      page: find.byKey(const Key('library-page')),
      target: find.byKey(const Key('compare-select-all-checkbox')),
    );

    final selectAll = find.byKey(const Key('compare-select-all-checkbox'));
    expect(
      tester
          .widget<Checkbox>(
            find.descendant(of: selectAll, matching: find.byType(Checkbox)),
          )
          .value,
      isNull,
    );

    await tester.tap(selectAll);
    await tester.pumpAndSettle();
    expect(
      appController.indexComparison.preset,
      IndexComparisonPreset.complete,
    );

    await tester.tap(selectAll);
    await tester.pumpAndSettle();
    expect(appController.indexComparison.preset, IndexComparisonPreset.none);
  });

  testWidgets(
    'summary methods default to all and support tri-state selection',
    (tester) async {
      final appController = controller();
      await tester.runAsync(appController.initialize);
      await tester.pumpWidget(RetrievalApp(controller: appController));
      await tester.tap(find.text('查询'));
      await tester.pumpAndSettle();
      await _dragUntilBuilt(
        tester,
        page: find.byKey(const Key('search-page')),
        target: find.byKey(const Key('query-summary-select-all')),
      );
      final selectAll = find.byKey(const Key('query-summary-select-all'));
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: selectAll, matching: find.byType(Checkbox)),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('query-summary-contentSummary')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: selectAll, matching: find.byType(Checkbox)),
            )
            .value,
        isNull,
      );
    },
  );

  testWidgets(
    'custom index combinations leave every visible preset unselected',
    (tester) async {
      final appController = controller();
      await tester.runAsync(appController.initialize);
      await tester.pumpWidget(RetrievalApp(controller: appController));
      await _dragUntilBuilt(
        tester,
        page: find.byKey(const Key('library-page')),
        target: find.byKey(const Key('compare-size-checkbox')),
      );

      await tester.tap(find.byKey(const Key('compare-size-checkbox')));
      await tester.pumpAndSettle();

      expect(
        appController.indexComparison.preset,
        IndexComparisonPreset.custom,
      );
      final field = tester
          .widget<DropdownButtonFormField<IndexComparisonPreset>>(
            find.descendant(
              of: find.byKey(const Key('index-comparison-preset')),
              matching: find.byType(
                DropdownButtonFormField<IndexComparisonPreset>,
              ),
            ),
          );
      expect(field.initialValue, isNull);
      expect(find.text('自定义'), findsNothing);
    },
  );

  testWidgets('keyboard shortcuts switch the three top-level pages', (
    tester,
  ) async {
    final appController = controller();
    await tester.runAsync(appController.initialize);
    await tester.pumpWidget(RetrievalApp(controller: appController));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-page')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-page')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-page')), findsOneWidget);
  });

  testWidgets(
    'query results expose two columns and an accessible action menu',
    (tester) async {
      final runner = _RecordingFileLauncherRunner();
      final appController = ApplicationController(
        onboardingEnabled: false,
        systemLanguage: AppLanguage.simplifiedChinese,
        configurationStore: RuntimeConfigurationStore(
          File(p.join(temporary.path, 'settings.json')),
        ),
        uiPreferencesStore: UiPreferencesStore(
          File(p.join(temporary.path, 'interface-settings.json')),
        ),
        fileLauncher: SystemFileLauncher(
          platform: FileLauncherPlatform.windows,
          commandRunner: runner,
        ),
      );
      await tester.runAsync(appController.initialize);
      final path =
          r'C:'
          r'\protected folder\Quarterly Report.pdf';
      final hit = VectorSearchHit(
        id: 'result-record',
        fileObjectId: 'result-object',
        sourcePath: path,
        fileType: 'PDF',
        space: VectorSpaceKind.text,
        document: 'quarterly result',
        distance: 0.1,
        metadata: {},
      );
      appController.queryResponse = QueryResponse(
        units: [
          QueryUnitResult(
            queryUnitId: 'query-0',
            type: QueryUnitType.textDescription,
            label: 'quarterly',
            attachment: null,
            textResults: [hit],
            imageResults: [],
            audioResults: [],
            status: QueryUnitStatus.completed,
            issues: [],
            totalFiles: 1,
            orderedFileResults: [hit],
          ),
        ],
      );
      await tester.pumpWidget(RetrievalApp(controller: appController));
      await tester.tap(find.text('查询'));
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('query-result-result-object'));
      await _dragUntilBuilt(
        tester,
        page: find.byKey(const Key('search-page')),
        target: row,
      );

      expect(find.text('文件名称'), findsOneWidget);
      expect(find.text('完整路径'), findsOneWidget);
      expect(find.textContaining('Quarterly Report.pdf'), findsWidgets);
      expect(find.text(path), findsOneWidget);

      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(row);
      await tester.pump();
      expect(runner.commands.single.$1, 'explorer.exe');
      expect(runner.commands.single.$2, [path]);

      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(find.text('打开文件'), findsOneWidget);
      expect(find.text('打开方式'), findsOneWidget);
      expect(find.text('在文件管理器中显示'), findsOneWidget);
      expect(find.text('复制完整路径'), findsOneWidget);
    },
  );

  testWidgets('high contrast and large text remain usable', (tester) async {
    tester.view.physicalSize = const Size(720, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final appController = ApplicationController(
      onboardingEnabled: false,
      configurationStore: RuntimeConfigurationStore(
        File(p.join(temporary.path, 'settings.json')),
      ),
      uiPreferencesStore: _PresetUiPreferencesStore(
        const UiPreferences(
          highContrast: true,
          textSize: AppTextSize.extraLarge,
        ),
      ),
    );
    await tester.runAsync(appController.initialize);
    await tester.pumpWidget(RetrievalApp(controller: appController));
    await tester.tap(find.text('设置'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const Key('high-contrast-switch')), findsOneWidget);
    expect(find.byKey(const Key('text-size-selector')), findsOneWidget);
    expect(appController.uiPreferences.highContrast, isTrue);
    expect(appController.uiPreferences.textSize, AppTextSize.extraLarge);
    final scheme = Theme.of(
      tester.element(find.byKey(const Key('settings-page'))),
    ).colorScheme;
    expect(scheme.surface.computeLuminance(), greaterThan(0.9));
    expect(scheme.surfaceContainerHigh.computeLuminance(), greaterThan(0.7));
    expect(scheme.onSurface.computeLuminance(), lessThan(0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('primary buttons meet a 48 pixel minimum tap target', (
    tester,
  ) async {
    final appController = controller();
    await tester.runAsync(appController.initialize);
    await tester.pumpWidget(RetrievalApp(controller: appController));

    final button = find.byKey(const Key('run-index-button'));
    await _dragUntilBuilt(
      tester,
      page: find.byKey(const Key('library-page')),
      target: button,
    );
    final size = tester.getSize(button);
    expect(size.height, greaterThanOrEqualTo(48));
    expect(size.width, greaterThanOrEqualTo(48));
  });

  testWidgets('destructive index cleanup is located in settings', (
    tester,
  ) async {
    final appController = controller();
    await tester.runAsync(appController.initialize);
    await tester.pumpWidget(RetrievalApp(controller: appController));

    expect(find.byKey(const Key('clear-all-indexes-button')), findsNothing);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await _dragUntilBuilt(
      tester,
      page: find.byKey(const Key('settings-page')),
      target: find.byKey(const Key('clear-all-indexes-button')),
    );

    expect(find.text('清理与重置'), findsOneWidget);
    final clearIndexes = find.byKey(const Key('clear-all-indexes-button'));
    final resetConfiguration = find.byKey(
      const Key('reset-configuration-button'),
    );
    expect(clearIndexes, findsOneWidget);
    expect(resetConfiguration, findsOneWidget);
    expect(find.text('清除配置并重启'), findsOneWidget);
    expect(
      find.descendant(of: clearIndexes, matching: find.byType(Icon)),
      findsNothing,
    );
    expect(
      find.descendant(of: resetConfiguration, matching: find.byType(Icon)),
      findsNothing,
    );
  });

  testWidgets(
    'index details are hidden until advanced information is enabled',
    (tester) async {
      final appController = controller();
      await tester.runAsync(appController.initialize);
      await tester.pumpWidget(RetrievalApp(controller: appController));

      final toggle = find.byKey(const Key('advanced-index-information-toggle'));
      await _dragUntilBuilt(
        tester,
        page: find.byKey(const Key('library-page')),
        target: toggle,
      );
      expect(find.textContaining('索引与查询服务未启动'), findsWidgets);
      expect(find.text('3. 从失败记录重新测试'), findsNothing);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await _dragUntilBuilt(
        tester,
        page: find.byKey(const Key('library-page')),
        target: find.text('3. 从失败记录重新测试'),
      );
      expect(find.text('3. 从失败记录重新测试'), findsOneWidget);
    },
  );
}

class _PresetUiPreferencesStore extends UiPreferencesStore {
  final UiPreferences preferences;

  _PresetUiPreferencesStore(this.preferences) : super(File('unused'));

  @override
  Future<UiPreferences?> load() async => preferences;

  @override
  Future<void> save(UiPreferences preferences) async {}
}

class _RecordingFileLauncherRunner implements FileLauncherCommandRunner {
  final List<(String, List<String>)> commands = [];

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) async {
    commands.add((executable, List.of(arguments)));
    return ProcessResult(1, 0, '', '');
  }
}

Future<void> _dragUntilBuilt(
  WidgetTester tester, {
  required Finder page,
  required Finder target,
}) async {
  for (var attempt = 0; attempt < 12 && target.evaluate().isEmpty; attempt++) {
    await tester.drag(page, const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 100));
}

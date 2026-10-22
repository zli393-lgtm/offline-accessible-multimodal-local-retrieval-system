import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/presentation/design_system/base/base_image_frame.dart';
import 'package:retrieval/presentation/design_system/presets/app_action_button.dart';
import 'package:retrieval/presentation/design_system/presets/app_action_strip.dart';
import 'package:retrieval/presentation/design_system/presets/app_choice_controls.dart';
import 'package:retrieval/presentation/design_system/presets/app_text_input.dart';
import 'package:retrieval/presentation/design_system/presets/app_form_dialog.dart';
import 'package:retrieval/configuration/presentation/controls/action_button_values.dart';
import 'package:retrieval/configuration/presentation/controls/action_strip_values.dart';
import 'package:retrieval/configuration/presentation/controls/image_frame_values.dart';
import 'package:retrieval/configuration/presentation/controls/text_input_values.dart';
import 'package:retrieval/configuration/presentation/controls/form_dialog_values.dart';

void main() {
  testWidgets('preset action strip owns one fixed control height', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppActionStrip(
            children: [
              AppActionButton(label: '执行', onPressed: () {}),
              const AppActionButton(label: '禁用', onPressed: null),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(AppActionStrip)).height,
      ActionStripValues.height,
    );
    expect(
      tester.getSize(find.byType(AppActionButton).first).height,
      ActionButtonValues.height,
    );
  });

  testWidgets('standard input delegates its geometry to the preset', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppTextInput(controller: controller, label: '名称'),
        ),
      ),
    );

    expect(find.text('名称'), findsOneWidget);
    expect(
      tester.getSize(find.byType(AppTextInput)).height,
      greaterThanOrEqualTo(TextInputValues.minimumHeight),
    );
  });

  testWidgets('base image frame applies caller supplied opacity', (
    tester,
  ) async {
    final bytes = Uint8List.fromList(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
      ),
    );
    const opacity = 0.42;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BaseImageFrame(
            image: MemoryImage(bytes),
            width: ImageFrameValues.width,
            height: ImageFrameValues.height,
            opacity: opacity,
            minimumOpacity: ImageFrameValues.minimumOpacity,
            maximumOpacity: ImageFrameValues.maximumOpacity,
            radius: ImageFrameValues.radius,
            borderWidth: ImageFrameValues.borderWidth,
            borderColor: Colors.black,
            backgroundColor: Colors.white,
            fit: BoxFit.contain,
            alignment: Alignment.center,
            semanticLabel: '测试图片',
          ),
        ),
      ),
    );

    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, opacity);
  });

  testWidgets('choice presets expose labels and state without page styling', (
    tester,
  ) async {
    var selected = 'a';
    var checked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AppSelectField<String>(
                value: selected,
                label: '模式',
                options: const [AppSelectOption('a', '标准')],
                onChanged: (value) => selected = value!,
              ),
              AppCheckOption(
                title: '路径',
                value: checked,
                onChanged: (value) => checked = value!,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('模式'), findsOneWidget);
    expect(find.text('标准'), findsOneWidget);
    await tester.tap(find.text('路径'));
    expect(checked, isTrue);
  });

  testWidgets('action controls keep semantics and targets under text scaling', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3)),
          child: Scaffold(
            body: AppActionStrip(
              children: [
                AppActionButton(
                  label: '扫描并更新',
                  semanticHint: '建立或替换选定范围的索引',
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('扫描并更新'), findsOneWidget);
    expect(
      tester.getSize(find.byType(AppActionButton)).height,
      greaterThanOrEqualTo(ActionButtonValues.minimumAccessibleTargetSize),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('check options expose one actionable semantic state', (
    tester,
  ) async {
    var checked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppCheckOption(
            title: '高对比度',
            subtitle: '增强明暗区分',
            value: checked,
            toggle: true,
            onChanged: (value) => checked = value!,
          ),
        ),
      ),
    );

    final semantics = find.bySemanticsLabel('高对比度');
    expect(semantics, findsOneWidget);
    await tester.tap(semantics);
    expect(checked, isTrue);
  });

  testWidgets('form dialog exposes a bounded user resize handle', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AppFormDialog(
                title: '可调整弹窗',
                content: const Text('内容'),
                cancelLabel: '取消',
                confirmLabel: '确定',
                onCancel: () {},
                onConfirm: () {},
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('调整弹窗大小'), findsOneWidget);
    final content = find.byType(Stack).last;
    final before = tester.getSize(content);
    await tester.drag(find.bySemanticsLabel('调整弹窗大小'), const Offset(-120, -60));
    await tester.pump();
    final after = tester.getSize(content);
    expect(after.width, greaterThanOrEqualTo(FormDialogValues.minimumWidth));
    expect(after.height, greaterThanOrEqualTo(FormDialogValues.minimumHeight));
    expect(after.width, lessThan(before.width));
  });
}

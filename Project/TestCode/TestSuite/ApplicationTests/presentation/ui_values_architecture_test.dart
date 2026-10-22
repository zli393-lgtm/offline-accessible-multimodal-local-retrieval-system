import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('UI value files remain data-only', () async {
    final files = Directory(p.join('lib', 'presentation'))
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) =>
              file.path.endsWith('.dart') &&
              p.split(p.normalize(file.path)).contains('values'),
        );
    for (final file in files) {
      final source = await file.readAsString();
      expect(source, isNot(contains("import 'package:flutter")));
      expect(source, isNot(contains('Widget')));
      expect(source, isNot(contains('BuildContext')));
      expect(source, isNot(contains('ChangeNotifier')));
    }
  });

  test(
    'presentation code does not reintroduce common raw visual values',
    () async {
      final files = <File>[
        File(p.join('lib', 'main.dart')),
        ...Directory(p.join('lib', 'presentation'))
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (file) =>
                  file.path.endsWith('.dart') &&
                  !p.split(p.normalize(file.path)).contains('values'),
            ),
      ];
      final forbidden = <RegExp>[
        RegExp(r'Color\(\s*0x[0-9a-fA-F]+'),
        RegExp(r'BorderRadius\.circular\(\s*\d'),
        RegExp(r'fontSize:\s*\d'),
        RegExp(r'fontWeight:\s*FontWeight\.(?:w\d+|normal|bold)'),
        RegExp(r'(?:iconSize|size|strokeWidth|elevation|blurRadius):\s*\d'),
        RegExp(r'(?:opacity|alpha):\s*\d'),
        RegExp(r'(?:width|height):\s*\d+(?:\.\d+)?'),
        RegExp(r'constraints\.maxWidth\s*<\s*\d'),
        RegExp(r'EdgeInsets\.[A-Za-z]+\([^)]*\b\d+(?:\.\d+)?'),
        RegExp(r'EdgeInsets\.zero'),
        RegExp(r'\.clamp\(\s*\d'),
      ];

      final violations = <String>[];
      for (final file in files) {
        final source = await file.readAsString();
        for (final pattern in forbidden) {
          if (pattern.hasMatch(source)) {
            violations.add('${file.path}: ${pattern.pattern}');
          }
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    },
  );

  test('UI dependencies follow the layered control standard', () async {
    final files = Directory(p.join('lib', 'presentation'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    final violations = <String>[];
    for (final file in files) {
      final normalized = p.normalize(file.path);
      final source = await file.readAsString();
      final isBase = normalized.contains(
        p.normalize(p.join('design_system', 'base')),
      );
      final isValue = p.split(normalized).contains('values');
      final isPage = !normalized.contains(p.normalize('design_system'));
      if (isValue && source.contains("package:flutter")) {
        violations.add('$normalized: value layer imports Flutter');
      }
      if (isBase && source.contains('/presets/')) {
        violations.add('$normalized: base layer imports preset layer');
      }
      if (isPage && source.contains('design_system/base/')) {
        violations.add('$normalized: page bypasses preset layer');
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test(
    'pages use preset controls instead of raw interactive controls',
    () async {
      final pages = Directory(p.join('lib', 'presentation'))
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      const forbidden = [
        'TextField(',
        'TextButton',
        'FilledButton',
        'OutlinedButton',
        'IconButton',
        'DropdownButtonFormField',
        'CheckboxListTile',
        'SwitchListTile',
        'SegmentedButton',
        'AlertDialog(',
      ];
      final violations = <String>[];
      for (final page in pages) {
        final source = await page.readAsString();
        for (final control in forbidden) {
          if (source.contains(control))
            violations.add('${page.path}: $control');
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    },
  );

  test('all application dialogs use the standard form dialog', () async {
    final presentationRoot = Directory(p.join('lib', 'presentation'));
    final standardDialog = p.normalize(
      p.join(
        'lib',
        'presentation',
        'design_system',
        'presets',
        'app_form_dialog.dart',
      ),
    );
    final rawDialog = RegExp(r'\b(?:AlertDialog|SimpleDialog|Dialog)\s*\(');
    final violations = <String>[];
    for (final file
        in presentationRoot.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') ||
          p.normalize(file.path).endsWith(standardDialog)) {
        continue;
      }
      if (rawDialog.hasMatch(await file.readAsString())) {
        violations.add(file.path);
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test(
    'numeric inputs use semantic names, not shared spacing buckets',
    () async {
      final files = Directory(p.join('lib', 'presentation'))
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (file) =>
                file.path.endsWith('.dart') &&
                p.split(p.normalize(file.path)).contains('values'),
          );
      final violations = <String>[];
      final genericName = RegExp(r'\bspace\d+\b');
      for (final file in files) {
        if (genericName.hasMatch(await file.readAsString())) {
          violations.add('${file.path}: generic spacing name');
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    },
  );

  test('accessibility remains implemented in the layered controls', () async {
    final baseDirectory = Directory(
      p.join('lib', 'presentation', 'design_system', 'base'),
    );
    final interactiveFiles = [
      'base_rect_button.dart',
      'base_ellipse_button.dart',
      'base_choice_controls.dart',
    ];
    final violations = <String>[];
    for (final name in interactiveFiles) {
      final source = await File(p.join(baseDirectory.path, name))
          .readAsString();
      if (!source.contains('Semantics(')) {
        violations.add('$name: missing semantics integration');
      }
      if (!source.contains('minimumAccessibleTargetSize')) {
        violations.add('$name: missing accessible target constraint');
      }
    }
    final strip = await File(
      p.join(
        'lib',
        'presentation',
        'design_system',
        'presets',
        'app_action_strip.dart',
      ),
    ).readAsString();
    if (!strip.contains('FocusTraversalGroup')) {
      violations.add('app_action_strip.dart: missing focus traversal group');
    }
    final app = await File(p.join('lib', 'main.dart')).readAsString();
    if (app.contains('maximumTextScale') ||
        app.contains('textScaler.scale(1).clamp')) {
      violations.add('main.dart: system accessibility text scale is capped');
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}

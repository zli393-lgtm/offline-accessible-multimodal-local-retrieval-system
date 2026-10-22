import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/application/runtime_configuration.dart';
import 'package:retrieval/application/runtime_dependencies.dart';

void main() {
  test('saved native dependency wins and invalid saved path falls back', () {
    final root = Directory.systemTemp.createTempSync('dependency-order-');
    addTearDown(() => root.deleteSync(recursive: true));
    final application = Directory(p.join(root.path, 'application'))
      ..createSync(recursive: true);
    final portable = File(
      p.join(
        application.path,
        'dependencies',
        'java',
        Platform.isWindows ? 'java.exe' : 'java',
      ),
    )..createSync(recursive: true);
    final saved = File(
      p.join(root.path, 'saved', Platform.isWindows ? 'java.exe' : 'java'),
    )..createSync(recursive: true);

    expect(
      RuntimeDependencies.resolve(
        RuntimeDependency.java,
        applicationDirectory: application.path,
        configuredPath: saved.path,
      ),
      saved.absolute.path,
    );
    expect(
      RuntimeDependencies.resolve(
        RuntimeDependency.java,
        applicationDirectory: application.path,
        configuredPath: p.join(root.path, 'missing'),
      ),
      portable.absolute.path,
    );
    expect(
      RuntimeDependencies.directoryForConfiguration(
        RuntimeDependency.java,
        applicationDirectory: application.path,
        configuredPath: saved.parent.path,
      ),
      saved.parent.absolute.path,
    );
  });

  test('saved Python wins and invalid saved path falls back to portable', () {
    final root = Directory.systemTemp.createTempSync('python-order-');
    addTearDown(() => root.deleteSync(recursive: true));
    final executableName = Platform.isWindows ? 'python.exe' : 'python3';
    final portable = File(
      p.join(
        root.path,
        'application',
        'dependencies',
        'python',
        executableName,
      ),
    )..createSync(recursive: true);
    final saved = File(p.join(root.path, 'saved', executableName))
      ..createSync(recursive: true);

    expect(
      RuntimeConfiguration.resolvePythonExecutable(
        applicationDirectory: p.join(root.path, 'application'),
        configuredPath: saved.path,
      ),
      p.normalize(saved.path),
    );
    expect(
      RuntimeConfiguration.resolvePythonExecutable(
        applicationDirectory: p.join(root.path, 'application'),
        configuredPath: p.join(root.path, 'missing'),
      ),
      p.normalize(portable.path),
    );
  });

  test(
    'runtime settings store folder paths and migrate old executable paths',
    () {
      final root = Directory.systemTemp.createTempSync('runtime-settings-');
      addTearDown(() => root.deleteSync(recursive: true));
      final executable = File(
        p.join(root.path, Platform.isWindows ? 'python.exe' : 'python3'),
      )..createSync(recursive: true);
      final migrated = RuntimeConfiguration.fromJson({
        'version': 2,
        'databaseRoot': root.path,
        'applicationDirectory': root.path,
        'pythonExecutable': executable.path,
        'dependencyPaths': <String, String>{},
      });

      expect(migrated.pythonExecutable, executable.parent.path);
    expect(migrated.toJson()['version'], 4);
      expect(migrated.toJson()['pythonDirectory'], executable.parent.path);
      expect(migrated.toJson().containsKey('pythonExecutable'), isFalse);
    },
  );
}

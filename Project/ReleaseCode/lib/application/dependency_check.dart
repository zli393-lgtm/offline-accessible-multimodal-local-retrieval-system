import 'dart:io';

import 'package:path/path.dart' as p;

import 'runtime_dependencies.dart';

class DependencyCheckReport {
  final List<String> missingRootDependencies;
  final List<String> missingPythonDependencies;
  final List<String> missingModels;
  final String? modelRoot;

  const DependencyCheckReport({
    required this.missingRootDependencies,
    required this.missingPythonDependencies,
    required this.missingModels,
    this.modelRoot,
  });

  bool get complete =>
      missingRootDependencies.isEmpty &&
      missingPythonDependencies.isEmpty &&
      missingModels.isEmpty;

  List<String> get allMissing => [
    ...missingRootDependencies,
    ...missingPythonDependencies,
    ...missingModels,
  ];
}

abstract final class DependencyCheck {
  static const _pythonModules = <String>[
    'av',
    'bs4',
    'chromadb',
    'ebooklib',
    'faster_whisper',
    'imagecodecs',
    'librosa',
    'lxml',
    'matplotlib',
    'mobileclip',
    'mutagen',
    'numpy',
    'odf',
    'olefile',
    'openpyxl',
    'PIL',
    'fitz',
    'pytesseract',
    'docx',
    'pptx',
    'resvg_py',
    'soundfile',
    'striprtf',
    'torch',
    'torchvision',
    'transformers',
  ];

  static Future<DependencyCheckReport> run({
    required String applicationDirectory,
    required String pythonExecutable,
    required Map<String, String> dependencyPaths,
  }) async {
    final missingRoot = <String>[];
    if (!File(pythonExecutable).existsSync()) missingRoot.add('Python');
    for (final dependency in RuntimeDependency.values) {
      final configured = dependencyPaths[dependency.name] ?? '';
      final resolved = RuntimeDependencies.resolve(
        dependency,
        applicationDirectory: applicationDirectory,
        configuredPath: configured,
      );
      if (!_rootComplete(dependency, resolved)) {
        missingRoot.add(dependency.name);
      }
    }

    final missingPython = <String>[];
    if (File(pythonExecutable).existsSync()) {
      final script =
          'import importlib.util,json; names=${_pythonModules.map((value) => "'$value'").toList()}; '
          'print(json.dumps([n for n in names if importlib.util.find_spec(n) is None]))';
      final result = await Process.run(pythonExecutable, ['-c', script]);
      if (result.exitCode != 0) {
        missingPython.add('Python package inspection failed');
      } else {
        final output = '${result.stdout}'.trim();
        final match = RegExp(r'"([^"\\]+)"').allMatches(output);
        missingPython.addAll(match.map((value) => value.group(1)!));
      }
    }

    final modelRoot = resolveModelRoot(
      applicationDirectory: applicationDirectory,
      pythonExecutable: pythonExecutable,
      configuredModelRoot: dependencyPaths['modelRoot'],
    );
    final missingModels = <String>[];
    if (modelRoot == null) {
      missingModels.addAll(const ['MobileCLIP', 'Faster-Whisper', 'CLAP']);
    } else {
      final required = {
        'MobileCLIP': p.join(modelRoot, 'image', 'mobileclip_s0.pt'),
        'Faster-Whisper': p.join(
          modelRoot,
          'audio',
          'faster-whisper-medium',
          'model.bin',
        ),
        'CLAP': p.join(
          modelRoot,
          'audio',
          'clap-htsat-fused',
          'model.safetensors',
        ),
      };
      for (final entry in required.entries) {
        if (!File(entry.value).existsSync()) missingModels.add(entry.key);
      }
    }
    return DependencyCheckReport(
      missingRootDependencies: missingRoot,
      missingPythonDependencies: missingPython,
      missingModels: missingModels,
      modelRoot: modelRoot,
    );
  }

  static String? resolveModelRoot({
    required String applicationDirectory,
    required String pythonExecutable,
    String? configuredModelRoot,
  }) {
    final candidates = [
      p.join(applicationDirectory, 'dependencies', 'models'),
      ?configuredModelRoot,
      p.join(applicationDirectory, 'assets', 'models'),
      p.join(
        File(pythonExecutable).parent.parent.path,
        'local_retrieval_models',
      ),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) return p.normalize(candidate);
    }
    return null;
  }

  static bool _rootComplete(RuntimeDependency dependency, String configured) {
    if (configured.trim().isEmpty) return false;
    if (dependency == RuntimeDependency.djvuLibre) {
      final directory = Directory(configured);
      final names = Platform.isWindows
          ? const ['ddjvu.exe', 'djvutxt.exe', 'djvused.exe']
          : const ['ddjvu', 'djvutxt', 'djvused'];
      return directory.existsSync() &&
          names.every(
            (name) => File(p.join(directory.path, name)).existsSync(),
          );
    }
    if (dependency == RuntimeDependency.ghostPdl) {
      final directory = Directory(configured);
      final ghostscript = Platform.isWindows
          ? const ['gswin64c.exe', 'gswin32c.exe']
          : const ['gs'];
      return directory.existsSync() &&
          ghostscript.any(
            (name) => File(p.join(directory.path, name)).existsSync(),
          );
    }
    return File(configured).existsSync();
  }
}

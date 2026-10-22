import 'dart:io';

import 'package:path/path.dart' as p;

enum RuntimeDependency {
  java,
  tika,
  tesseract,
  pdfium,
  djvuLibre,
  ghostPdl,
  jpegXr,
  browser,
}

/// Discovers independently installed native dependencies. A valid saved path
/// wins; portable copies are the first automatic source. Browsers are excluded
/// from portable lookup.
abstract final class RuntimeDependencies {
  static String portableRoot(String applicationDirectory) =>
      p.join(applicationDirectory, 'dependencies');

  static String discover(
    RuntimeDependency dependency, {
    required String applicationDirectory,
  }) => resolve(dependency, applicationDirectory: applicationDirectory);

  /// Returns a folder-level path for display and storage. Runtime code resolves
  /// the concrete executable, JAR, or dynamic library inside this folder.
  static String directoryForConfiguration(
    RuntimeDependency dependency, {
    required String applicationDirectory,
    String? configuredPath,
  }) {
    final candidates = <String>[
      if (configuredPath != null && configuredPath.trim().isNotEmpty)
        configuredPath,
      if (dependency != RuntimeDependency.browser)
        ..._portableCandidates(dependency, applicationDirectory),
      ..._environmentCandidates(dependency),
      ..._commonCandidates(dependency),
    ];
    for (final raw in candidates) {
      final candidate = p.normalize(raw.trim().replaceAll('"', ''));
      if (candidate.isEmpty) continue;
      final resolved = _resolveCandidate(dependency, candidate);
      if (resolved == null) continue;
      final directory = Directory(candidate);
      if (directory.existsSync()) return directory.absolute.path;
      final file = File(candidate);
      if (file.existsSync()) return file.parent.absolute.path;
      return File(resolved).parent.absolute.path;
    }
    return '';
  }

  /// Uses one identical lookup path for every release: the user's saved path
  /// first, then portable files, environment/PATH, and common locations.
  static String resolve(
    RuntimeDependency dependency, {
    required String applicationDirectory,
    String? configuredPath,
  }) {
    final candidates = <String>[
      if (configuredPath != null && configuredPath.trim().isNotEmpty)
        configuredPath,
      if (dependency != RuntimeDependency.browser)
        ..._portableCandidates(dependency, applicationDirectory),
      ..._environmentCandidates(dependency),
      ..._commonCandidates(dependency),
    ];
    for (final candidate in candidates) {
      final resolved = _resolveCandidate(dependency, candidate);
      if (resolved != null) {
        if (dependency == RuntimeDependency.djvuLibre ||
            dependency == RuntimeDependency.ghostPdl) {
          return File(resolved).parent.path;
        }
        return resolved;
      }
    }
    return '';
  }

  static String executableIn(
    RuntimeDependency dependency,
    String configuredPath,
  ) => _resolveCandidate(dependency, configuredPath) ?? '';

  static Iterable<String> _portableCandidates(
    RuntimeDependency dependency,
    String applicationDirectory,
  ) sync* {
    final root = portableRoot(applicationDirectory);
    yield p.join(root, _folderName(dependency));
  }

  static Iterable<String> _environmentCandidates(
    RuntimeDependency dependency,
  ) sync* {
    final environment = Platform.environment;
    for (final key in switch (dependency) {
      RuntimeDependency.java => const ['JAVA_HOME'],
      RuntimeDependency.tika => const ['TIKA_APP_JAR', 'TIKA_HOME'],
      RuntimeDependency.tesseract => const ['TESSERACT_CMD', 'TESSERACT_HOME'],
      RuntimeDependency.pdfium => const ['PDFIUM_LIBRARY', 'PDFIUM_ROOT'],
      RuntimeDependency.browser => const ['SVG_RENDERER_EXECUTABLE'],
      RuntimeDependency.djvuLibre => const ['DJVULIBRE_HOME'],
      RuntimeDependency.ghostPdl => const ['GHOSTPDL_HOME', 'GHOSTSCRIPT_HOME'],
      RuntimeDependency.jpegXr => const ['JPEGXR_HOME'],
    }) {
      final value = environment[key];
      if (value != null && value.trim().isNotEmpty) yield value;
    }
    final path = environment['PATH'] ?? '';
    yield* path
        .split(Platform.isWindows ? ';' : ':')
        .map((value) => value.trim().replaceAll('"', ''))
        .where((value) => value.isNotEmpty);
  }

  static Iterable<String> _commonCandidates(
    RuntimeDependency dependency,
  ) sync* {
    if (Platform.isWindows) {
      final programFiles =
          Platform.environment['ProgramW6432'] ??
          Platform.environment['ProgramFiles'] ??
          '';
      final programFilesX86 =
          Platform.environment['ProgramFiles(x86)'] ?? '';
      switch (dependency) {
        case RuntimeDependency.java:
          if (programFiles.isNotEmpty) yield p.join(programFiles, 'Java');
        case RuntimeDependency.tesseract:
          if (programFiles.isNotEmpty) {
            yield p.join(programFiles, 'Tesseract-OCR');
          }
        case RuntimeDependency.ghostPdl:
          if (programFiles.isNotEmpty) yield p.join(programFiles, 'gs');
        case RuntimeDependency.browser:
          if (programFiles.isNotEmpty) {
            yield p.join(programFiles, 'Microsoft', 'Edge', 'Application');
            yield p.join(programFiles, 'Google', 'Chrome', 'Application');
          }
          if (programFilesX86.isNotEmpty) {
            yield p.join(
              programFilesX86,
              'Microsoft',
              'Edge',
              'Application',
            );
          }
        case RuntimeDependency.pdfium:
        case RuntimeDependency.tika:
        case RuntimeDependency.djvuLibre:
        case RuntimeDependency.jpegXr:
          break;
      }
      return;
    }
    if (Platform.isMacOS) {
      yield '/usr/local/bin';
      yield '/opt/homebrew/bin';
      yield '/usr/local/lib';
      yield '/opt/homebrew/lib';
      if (dependency == RuntimeDependency.browser) {
        yield '/Applications/Google Chrome.app/Contents/MacOS';
        yield '/Applications/Microsoft Edge.app/Contents/MacOS';
        yield '/Applications/Chromium.app/Contents/MacOS';
      }
      return;
    }
    yield '/usr/bin';
    yield '/usr/local/bin';
    yield '/usr/lib';
    yield '/usr/local/lib';
    yield '/usr/lib64';
  }

  static String? _resolveCandidate(RuntimeDependency dependency, String raw) {
    if (raw.trim().isEmpty) return null;
    final candidate = p.normalize(raw.trim().replaceAll('"', ''));
    final direct = File(candidate);
    if (direct.existsSync() && _matches(dependency, p.basename(candidate))) {
      return direct.absolute.path;
    }
    final directory = Directory(candidate);
    if (!directory.existsSync()) return null;
    for (final name in _fileNames(dependency)) {
      final file = File(p.join(candidate, name));
      if (file.existsSync()) return file.absolute.path;
    }
    try {
      final pending = <(Directory, int)>[(directory, 0)];
      final matches = <File>[];
      var inspected = 0;
      while (pending.isNotEmpty && inspected < 5000) {
        final (current, depth) = pending.removeAt(0);
        for (final entity in current.listSync(followLinks: false)) {
          inspected++;
          if (entity is File && _matches(dependency, p.basename(entity.path))) {
            matches.add(entity);
          } else if (entity is Directory && depth < 4) {
            pending.add((entity, depth + 1));
          }
          if (inspected >= 5000) break;
        }
      }
      matches.sort((left, right) => right.path.compareTo(left.path));
      if (matches.isNotEmpty) return matches.first.absolute.path;
    } on FileSystemException {
      return null;
    }
    return null;
  }

  static bool _matches(RuntimeDependency dependency, String name) {
    final lower = name.toLowerCase();
    if (dependency == RuntimeDependency.tika) {
      return lower.startsWith('tika-app-') && lower.endsWith('.jar');
    }
    return _fileNames(dependency).any((value) => value.toLowerCase() == lower);
  }

  static List<String> _fileNames(RuntimeDependency dependency) =>
      switch (dependency) {
        RuntimeDependency.java =>
          Platform.isWindows ? const ['java.exe'] : const ['java'],
        RuntimeDependency.tika => const ['tika-app.jar'],
        RuntimeDependency.tesseract =>
          Platform.isWindows ? const ['tesseract.exe'] : const ['tesseract'],
        RuntimeDependency.pdfium =>
          Platform.isWindows
              ? const ['pdfium.dll']
              : Platform.isMacOS
              ? const ['libpdfium.dylib']
              : const ['libpdfium.so'],
        RuntimeDependency.djvuLibre =>
          Platform.isWindows ? const ['ddjvu.exe'] : const ['ddjvu'],
        RuntimeDependency.ghostPdl =>
          Platform.isWindows
              ? const ['gswin64c.exe', 'gswin32c.exe', 'gxpswin64c.exe']
              : const ['gs', 'gxps'],
        RuntimeDependency.jpegXr =>
          Platform.isWindows ? const ['JxrDecApp.exe'] : const ['JxrDecApp'],
        RuntimeDependency.browser =>
          Platform.isWindows
              ? const ['msedge.exe', 'chrome.exe', 'chromium.exe']
              : Platform.isMacOS
              ? const ['Google Chrome', 'Microsoft Edge', 'Chromium']
              : const [
                  'google-chrome',
                  'chromium',
                  'chromium-browser',
                  'msedge',
                ],
      };

  static String _folderName(RuntimeDependency dependency) =>
      switch (dependency) {
        RuntimeDependency.java => 'java',
        RuntimeDependency.tika => 'tika',
        RuntimeDependency.tesseract => 'tesseract',
        RuntimeDependency.pdfium => 'pdfium',
        RuntimeDependency.djvuLibre => 'djvulibre',
        RuntimeDependency.ghostPdl => 'ghostpdl',
        RuntimeDependency.jpegXr => 'jpeg_xr',
        RuntimeDependency.browser => 'browser',
      };
}

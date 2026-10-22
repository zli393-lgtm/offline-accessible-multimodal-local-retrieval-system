import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class RuntimeConfiguration {
  final String databaseRoot;
  final String applicationDirectory;
  final String pythonExecutable;
  final String logDirectory;
  final Map<String, String> dependencyPaths;

  const RuntimeConfiguration({
    required this.databaseRoot,
    required this.applicationDirectory,
    required this.pythonExecutable,
    required this.logDirectory,
    this.dependencyPaths = const {},
  });

  Map<String, Object> toJson() => {
    'version': 4,
    'databaseRoot': databaseRoot,
    'applicationDirectory': applicationDirectory,
    'pythonDirectory': pythonExecutable,
    'logDirectory': logDirectory,
    'dependencyPaths': dependencyPaths,
  };

  factory RuntimeConfiguration.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 &&
        json['version'] != 2 &&
        json['version'] != 3 &&
        json['version'] != 4) {
      throw const FormatException('Unsupported runtime settings format.');
    }
    final storedPython = json['version'] == 3 || json['version'] == 4
        ? json['pythonDirectory'] as String
        : json['pythonExecutable'] as String;
    final databaseRoot = json['databaseRoot'] as String;
    return RuntimeConfiguration(
      databaseRoot: databaseRoot,
      applicationDirectory: json['applicationDirectory'] as String,
      pythonExecutable: File(storedPython).existsSync()
          ? File(storedPython).parent.path
          : storedPython,
      logDirectory:
          json['logDirectory'] as String? ??
          suggestedLogDirectory(databaseRoot),
      dependencyPaths:
          (json['dependencyPaths'] as Map<String, dynamic>? ?? const {}).map(
            (key, value) => MapEntry(key, '$value'),
          ),
    );
  }

  static String suggestedApplicationDirectory() {
    final candidates = [
      Directory.current.path,
      p.join(
        File(Platform.resolvedExecutable).parent.path,
        'data',
        'local_retrieval',
      ),
      p.normalize(
        p.join(
          File(Platform.resolvedExecutable).parent.path,
          '..',
          'Resources',
          'local_retrieval',
        ),
      ),
      p.join(
        File(Platform.resolvedExecutable).parent.path,
        'data',
        'flutter_assets',
      ),
    ];
    for (final candidate in candidates) {
      if (Directory(p.join(candidate, 'assets')).existsSync() &&
          Directory(p.join(candidate, 'services')).existsSync()) {
        return p.normalize(candidate);
      }
    }
    return p.normalize(Directory.current.path);
  }

  static String suggestedDatabaseRoot() =>
      p.join(RuntimeConfigurationStore.settingsDirectory(), 'index_database');

  static String suggestedLogDirectory([String? databaseRoot]) => p.join(
    databaseRoot ?? suggestedDatabaseRoot(),
    'LocalRetrievalData',
    'failure-logs',
  );

  /// Returns the folder containing the first usable Python interpreter found
  /// through the process environment. The UI presents folders consistently,
  /// whether the value was detected or selected by the user.
  static String suggestedPythonDirectory([String? applicationDirectory]) {
    final executable = resolvePythonExecutable(
      applicationDirectory: applicationDirectory ?? '',
    );
    return executable.isEmpty ? '' : File(executable).parent.path;
  }

  static String resolvePythonExecutable({
    required String applicationDirectory,
    String? configuredPath,
  }) {
    final names = Platform.isWindows
        ? const ['python.exe', 'python3.exe']
        : const ['python3', 'python'];
    final candidates = <String>[
      if (configuredPath != null && configuredPath.trim().isNotEmpty)
        configuredPath,
      if (applicationDirectory.isNotEmpty)
        p.join(applicationDirectory, 'dependencies', 'python'),
      ...(Platform.environment['PATH'] ?? '').split(
        Platform.isWindows ? ';' : ':',
      ),
      ..._commonPythonDirectories(),
    ];
    for (final raw in candidates) {
      final value = raw.trim().replaceAll('"', '');
      if (value.isEmpty) continue;
      final direct = File(value);
      if (direct.existsSync()) return p.normalize(direct.path);
      for (final relative in [
        ...names,
        if (Platform.isWindows) 'Scripts/python.exe' else 'bin/python3',
        if (!Platform.isWindows) 'bin/python',
      ]) {
        final candidate = File(p.join(value, relative));
        if (candidate.existsSync()) return p.normalize(candidate.path);
      }
    }
    return '';
  }

  static Iterable<String> _commonPythonDirectories() sync* {
    final environment = Platform.environment;
    if (Platform.isWindows) {
      final local = environment['LOCALAPPDATA'];
      if (local != null && local.isNotEmpty) {
        yield p.join(local, 'Programs', 'Python');
      }
      final programFiles = environment['ProgramFiles'];
      if (programFiles != null && programFiles.isNotEmpty) {
        yield p.join(programFiles, 'Python');
      }
      return;
    }
    yield '/usr/local/bin';
    yield '/usr/bin';
    if (Platform.isMacOS) yield '/opt/homebrew/bin';
  }

  static String pythonDirectoryForDisplay(
    String executable, [
    String? applicationDirectory,
  ]) {
    final value = executable.trim();
    if (value.isEmpty) return suggestedPythonDirectory(applicationDirectory);
    final resolved = resolvePythonExecutable(
      applicationDirectory: applicationDirectory ?? '',
      configuredPath: value,
    );
    return resolved.isEmpty ? '' : p.dirname(resolved);
  }

  static String pythonExecutableInDirectory(String directory) {
    final value = directory.trim();
    if (value.isEmpty) return '';
    final names = Platform.isWindows
        ? const ['python.exe', 'python3.exe']
        : const ['python3', 'python'];
    for (final name in names) {
      final candidate = p.join(value, name);
      if (File(candidate).existsSync()) return p.normalize(candidate);
    }
    return '';
  }
}

class RuntimeConfigurationStore {
  final File file;

  const RuntimeConfigurationStore(this.file);

  factory RuntimeConfigurationStore.platformDefault() =>
      RuntimeConfigurationStore(
        File(p.join(settingsDirectory(), 'runtime-settings.json')),
      );

  Future<RuntimeConfiguration?> load() async {
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Runtime settings must be a JSON object.');
    }
    return RuntimeConfiguration.fromJson(value);
  }

  Future<void> save(RuntimeConfiguration configuration) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(configuration.toJson()),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<void> delete() async {
    if (await file.exists()) await file.delete();
  }

  static String settingsDirectory() {
    final executable = File(Platform.resolvedExecutable);
    if (p.basenameWithoutExtension(executable.path).toLowerCase() ==
        'retrieval') {
      final portable = p.join(executable.parent.path, 'user_config');
      try {
        Directory(portable).createSync(recursive: true);
        final probe = File(p.join(portable, '.write-test'));
        probe.writeAsStringSync('ok', flush: true);
        probe.deleteSync();
        return portable;
      } on FileSystemException {
        // Installed read-only locations fall back to the OS user-data folder.
      }
    }
    final environment = Platform.environment;
    if (Platform.isWindows) {
      final root = environment['LOCALAPPDATA'];
      if (root != null && root.isNotEmpty) {
        return p.join(root, 'LocalRetrieval', 'settings');
      }
    }
    if (Platform.isMacOS) {
      final home = environment['HOME'];
      if (home != null && home.isNotEmpty) {
        return p.join(home, 'Library', 'Application Support', 'LocalRetrieval');
      }
    }
    final xdg = environment['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return p.join(xdg, 'local-retrieval');
    }
    final home = environment['HOME'] ?? environment['USERPROFILE'];
    if (home == null || home.isEmpty) {
      throw const FileSystemException(
        'No user configuration directory is available.',
      );
    }
    return p.join(home, '.config', 'local-retrieval');
  }
}

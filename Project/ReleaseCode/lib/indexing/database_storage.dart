import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/file_object.dart';

class DatabaseStorageProfile {
  static const dataFolderName = 'LocalRetrievalData';

  final String profileId;
  final String selectedRootPath;

  DatabaseStorageProfile._({
    required this.profileId,
    required this.selectedRootPath,
  });

  factory DatabaseStorageProfile.forRoot(String rootPath) {
    if (rootPath.trim().isEmpty) {
      throw ArgumentError.value(rootPath, 'rootPath', '数据库根目录不能为空。');
    }
    final normalized = PathRules.canonical(rootPath);
    return DatabaseStorageProfile._(
      profileId: 'database-${FileObjectIds.fromPath(normalized).substring(5)}',
      selectedRootPath: normalized,
    );
  }

  String get dataRoot => p.join(selectedRootPath, dataFolderName);
  String get chromaDirectory => p.join(dataRoot, 'database', 'chroma');
  String get registryDirectory => p.join(dataRoot, 'database', 'registry');
  String get indexStateDirectory => p.join(dataRoot, 'index-state');
  String get failureLogDirectory => p.join(dataRoot, 'failure-logs');
  String get temporaryDirectory => p.join(dataRoot, 'temporary');

  List<String> get protectedPaths => [dataRoot];

  bool containsRuntimePath(String candidate) =>
      PathRules.isSameOrDescendant(candidate, dataRoot);

  Map<String, Object> toJson() => {
    'version': 1,
    'profileId': profileId,
    'selectedRootPath': selectedRootPath,
    'dataRoot': dataRoot,
  };

  factory DatabaseStorageProfile.fromJson(Map<String, dynamic> json) =>
      DatabaseStorageProfile.forRoot(json['selectedRootPath'] as String);
}

class StorageValidationResult {
  final DatabaseStorageProfile profile;
  final bool writable;
  final List<String> issues;

  const StorageValidationResult({
    required this.profile,
    required this.writable,
    required this.issues,
  });
}

class StorageMigrationResult {
  final DatabaseStorageProfile source;
  final DatabaseStorageProfile destination;
  final int filesCopied;
  final int bytesCopied;
  final bool verified;

  const StorageMigrationResult({
    required this.source,
    required this.destination,
    required this.filesCopied,
    required this.bytesCopied,
    required this.verified,
  });
}

class StorageMigrationProgress {
  final String phase;
  final int filesCopied;
  final int bytesCopied;

  const StorageMigrationProgress({
    required this.phase,
    this.filesCopied = 0,
    this.bytesCopied = 0,
  });
}

class DatabaseStorageManager {
  const DatabaseStorageManager();

  /// Removes every generated index artifact while preserving the user's
  /// selected scan scope. Original user files and application settings are
  /// outside [DatabaseStorageProfile.dataRoot] and are never touched.
  Future<void> clearAllIndexes(DatabaseStorageProfile profile) async {
    final dataRoot = PathRules.canonical(profile.dataRoot);
    final removableDirectories = [
      profile.chromaDirectory,
      profile.registryDirectory,
      profile.failureLogDirectory,
      profile.temporaryDirectory,
    ];
    for (final path in removableDirectories) {
      if (!PathRules.isSameOrDescendant(path, dataRoot) ||
          PathRules.canonical(path) == dataRoot) {
        throw StateError(
          'Refusing to clear a path outside the index database.',
        );
      }
      final directory = Directory(path);
      if (await directory.exists()) await directory.delete(recursive: true);
      await directory.create(recursive: true);
    }

    final stateDirectory = Directory(profile.indexStateDirectory);
    if (await stateDirectory.exists()) {
      await for (final entity in stateDirectory.list(followLinks: false)) {
        if (entity is File && p.basename(entity.path) == 'index-scope.json') {
          continue;
        }
        await entity.delete(recursive: true);
      }
    } else {
      await stateDirectory.create(recursive: true);
    }
  }

  Future<StorageValidationResult> prepare(String rootPath) async {
    final profile = DatabaseStorageProfile.forRoot(rootPath);
    final issues = <String>[];
    final root = Directory(profile.selectedRootPath);
    try {
      if (!await root.exists()) await root.create(recursive: true);
      for (final path in [
        profile.chromaDirectory,
        profile.registryDirectory,
        profile.indexStateDirectory,
        profile.failureLogDirectory,
        profile.temporaryDirectory,
      ]) {
        await Directory(path).create(recursive: true);
      }
      final probe = File(
        p.join(
          profile.temporaryDirectory,
          '.write-probe-$pid-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await probe.writeAsString('storage-write-check', flush: true);
      if (await probe.length() != 19) {
        issues.add('The storage write probe could not be verified.');
      }
      if (await probe.exists()) await probe.delete();
    } on FileSystemException catch (error) {
      issues.add('${error.message}: ${error.path ?? profile.selectedRootPath}');
    }
    return StorageValidationResult(
      profile: profile,
      writable: issues.isEmpty,
      issues: List.unmodifiable(issues),
    );
  }

  /// Copies an existing runtime database to a newly prepared location and
  /// verifies file count and byte size. The source is deliberately never
  /// deleted; cleanup requires a separate, explicit user action.
  Future<StorageMigrationResult> migrate({
    required DatabaseStorageProfile source,
    required String destinationRootPath,
    void Function(StorageMigrationProgress progress)? onProgress,
  }) async {
    onProgress?.call(const StorageMigrationProgress(phase: 'preparing'));
    final prepared = await prepare(destinationRootPath);
    if (!prepared.writable) {
      throw FileSystemException(
        'Destination database location is not writable: '
        '${prepared.issues.join('; ')}',
        destinationRootPath,
      );
    }
    final destination = prepared.profile;
    if (PathRules.pathsOverlap(source.dataRoot, destination.dataRoot)) {
      throw ArgumentError('Source and destination database paths overlap.');
    }
    final sourceDirectory = Directory(source.dataRoot);
    if (!await sourceDirectory.exists()) {
      throw FileSystemException(
        'Source database does not exist',
        source.dataRoot,
      );
    }
    var copiedFiles = 0;
    var copiedBytes = 0;
    await for (final entity in sourceDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entity.path, from: source.dataRoot);
      final targetPath = p.join(destination.dataRoot, relative);
      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
      } else if (entity is File) {
        await File(targetPath).parent.create(recursive: true);
        await entity.copy(targetPath);
        copiedFiles++;
        copiedBytes += await entity.length();
        if (copiedFiles == 1 || copiedFiles % 25 == 0) {
          onProgress?.call(
            StorageMigrationProgress(
              phase: 'copying',
              filesCopied: copiedFiles,
              bytesCopied: copiedBytes,
            ),
          );
        }
      }
    }
    onProgress?.call(
      StorageMigrationProgress(
        phase: 'verifying',
        filesCopied: copiedFiles,
        bytesCopied: copiedBytes,
      ),
    );
    final sourceSummary = await _summary(source.dataRoot);
    final destinationSummary = await _summary(destination.dataRoot);
    final verified =
        sourceSummary.$1 == destinationSummary.$1 &&
        sourceSummary.$2 == destinationSummary.$2;
    if (!verified) {
      throw const FileSystemException(
        'Database migration verification failed; the source was preserved.',
      );
    }
    return StorageMigrationResult(
      source: source,
      destination: destination,
      filesCopied: copiedFiles,
      bytesCopied: copiedBytes,
      verified: true,
    );
  }

  Future<(int, int)> _summary(String root) async {
    var count = 0;
    var bytes = 0;
    await for (final entity in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      if (entity is File) {
        count++;
        bytes += await entity.length();
      }
    }
    return (count, bytes);
  }
}

class DatabaseSettingsStore {
  final File settingsFile;

  const DatabaseSettingsStore(this.settingsFile);

  Future<void> save(DatabaseStorageProfile profile) async {
    await settingsFile.parent.create(recursive: true);
    final temporary = File('${settingsFile.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(profile.toJson()),
      flush: true,
    );
    if (await settingsFile.exists()) await settingsFile.delete();
    await temporary.rename(settingsFile.path);
  }

  Future<DatabaseStorageProfile?> load() async {
    if (!await settingsFile.exists()) return null;
    final value = jsonDecode(await settingsFile.readAsString());
    if (value is! Map<String, dynamic> || value['version'] != 1) {
      throw const FormatException('Unsupported database settings format.');
    }
    return DatabaseStorageProfile.fromJson(value);
  }
}

class PathRules {
  const PathRules._();

  static String canonical(String value) {
    var result = p.normalize(File(value).absolute.path);
    if (Platform.isWindows) result = result.toLowerCase();
    return result;
  }

  static bool isSameOrDescendant(String candidate, String parent) {
    final child = canonical(candidate);
    final root = canonical(parent);
    return child == root || p.isWithin(root, child);
  }

  static bool pathsOverlap(String first, String second) =>
      isSameOrDescendant(first, second) || isSameOrDescendant(second, first);
}

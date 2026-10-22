import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'database_storage.dart';

enum IndexScopeMode { selectedPaths, allDevices }

class IndexScope {
  final IndexScopeMode mode;
  final List<String> includedPaths;
  final List<String> excludedPaths;
  final bool recursive;

  IndexScope({
    required this.mode,
    Iterable<String> includedPaths = const [],
    Iterable<String> excludedPaths = const [],
    this.recursive = true,
  }) : includedPaths = _unique(includedPaths),
       excludedPaths = _unique(excludedPaths);

  static List<String> _unique(Iterable<String> values) => List.unmodifiable(
    values.map(PathRules.canonical).toSet().toList()..sort(),
  );

  IndexScope addPath(String path) => IndexScope(
    mode: mode,
    includedPaths: [...includedPaths, path],
    excludedPaths: excludedPaths,
    recursive: recursive,
  );

  IndexScope removePath(String path) {
    final target = PathRules.canonical(path);
    return IndexScope(
      mode: mode,
      includedPaths: includedPaths.where((item) => item != target),
      excludedPaths: excludedPaths,
      recursive: recursive,
    );
  }

  IndexScope replacePath(String oldPath, String newPath) =>
      removePath(oldPath).addPath(newPath);

  IndexScope exclude(String path) => IndexScope(
    mode: mode,
    includedPaths: includedPaths,
    excludedPaths: [...excludedPaths, path],
    recursive: recursive,
  );

  bool excludes(String path, {Iterable<String> systemPaths = const []}) => [
    ...excludedPaths,
    ...systemPaths,
  ].any((root) => PathRules.isSameOrDescendant(path, root));

  Map<String, Object> toJson() => {
    'version': 1,
    'mode': mode.name,
    'includedPaths': includedPaths,
    'excludedPaths': excludedPaths,
    'recursive': recursive,
  };

  factory IndexScope.fromJson(Map<String, dynamic> json) => IndexScope(
    mode: IndexScopeMode.values.byName(json['mode'] as String),
    includedPaths: (json['includedPaths'] as List).cast<String>(),
    excludedPaths: (json['excludedPaths'] as List).cast<String>(),
    recursive: json['recursive'] as bool? ?? true,
  );
}

class IndexScopeStore {
  final File file;

  const IndexScopeStore(this.file);

  Future<void> save(IndexScope scope) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(scope.toJson()),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<IndexScope?> load() async {
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> || value['version'] != 1) {
      throw const FormatException('Unsupported index-scope format.');
    }
    return IndexScope.fromJson(value);
  }

  Future<void> delete() async {
    if (await file.exists()) await file.delete();
    final temporary = File('${file.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
  }
}

abstract interface class VolumeDiscovery {
  Future<List<String>> roots();
}

class PlatformVolumeDiscovery implements VolumeDiscovery {
  const PlatformVolumeDiscovery();

  @override
  Future<List<String>> roots() async {
    if (!Platform.isWindows) return const ['/'];
    final roots = <String>[];
    for (var code = 'A'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++) {
      final root = '${String.fromCharCode(code)}:${p.separator}';
      if (await Directory(root).exists()) roots.add(PathRules.canonical(root));
    }
    return roots;
  }
}

import 'dart:convert';
import 'dart:io';

import 'database_storage.dart';

class IndexCoverage {
  final bool allDevices;
  final List<String> roots;

  IndexCoverage({this.allDevices = false, Iterable<String> roots = const []})
    : roots = List.unmodifiable(
        roots.map(PathRules.canonical).toSet().toList()..sort(),
      );

  bool covers(String path) =>
      allDevices ||
      roots.any((root) => PathRules.isSameOrDescendant(path, root));

  IndexCoverage addRoots(Iterable<String> values) =>
      IndexCoverage(allDevices: allDevices, roots: [...roots, ...values]);

  Map<String, Object> toJson() => {
    'version': 1,
    'allDevices': allDevices,
    'roots': roots,
  };

  factory IndexCoverage.fromJson(Map<String, dynamic> json) => IndexCoverage(
    allDevices: json['allDevices'] as bool? ?? false,
    roots: (json['roots'] as List? ?? const []).cast<String>(),
  );
}

class IndexCoverageStore {
  final File file;
  const IndexCoverageStore(this.file);

  Future<IndexCoverage> load() async {
    if (!await file.exists()) return IndexCoverage();
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic> || value['version'] != 1) {
      throw const FormatException('Unsupported index coverage format.');
    }
    return IndexCoverage.fromJson(value);
  }

  Future<void> save(IndexCoverage coverage) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(coverage.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}

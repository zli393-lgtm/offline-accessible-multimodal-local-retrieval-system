import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../domain/file_object.dart';
import 'database_storage.dart';

class FileRegistryEntry {
  // Version 4 stores the literal path suffix separately from the parser's
  // detected content type. Existing indexes are rebuilt so JPG/JPEG and
  // compound suffixes such as FB2.ZIP can be filtered exactly.
  static const int currentSchemaVersion = 4;
  final int schemaVersion;
  final String fileObjectId;
  final String path;
  final String fingerprint;
  final int? fileSize;
  final DateTime? modifiedTime;
  final int objectVersion;
  final String databaseProfileId;
  final FileIndexStatus status;
  final DateTime indexedTime;
  final List<String> textRecordIds;
  final List<String> imageRecordIds;
  final List<String> audioRecordIds;

  const FileRegistryEntry({
    this.schemaVersion = currentSchemaVersion,
    required this.fileObjectId,
    required this.path,
    required this.fingerprint,
    required this.fileSize,
    required this.modifiedTime,
    required this.objectVersion,
    required this.databaseProfileId,
    required this.status,
    required this.indexedTime,
    required this.textRecordIds,
    required this.imageRecordIds,
    required this.audioRecordIds,
  });

  factory FileRegistryEntry.fromObject(FileObject object) => FileRegistryEntry(
    schemaVersion: currentSchemaVersion,
    fileObjectId: object.fileObjectId,
    path: PathRules.canonical(object.metadata.filePath),
    fingerprint: object.metadata.fingerprint ?? '',
    fileSize: object.metadata.fileSize,
    modifiedTime: object.metadata.modifiedTime.toUtc(),
    objectVersion: object.objectVersion,
    databaseProfileId: object.index.databaseProfileId!,
    status: object.index.status,
    indexedTime: object.index.indexedTime!,
    textRecordIds: List.unmodifiable(object.index.textRecordIds),
    imageRecordIds: List.unmodifiable(object.index.imageRecordIds),
    audioRecordIds: List.unmodifiable(object.index.audioRecordIds),
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'fileObjectId': fileObjectId,
    'path': path,
    'fingerprint': fingerprint,
    'fileSize': fileSize,
    'modifiedTime': modifiedTime?.toIso8601String(),
    'objectVersion': objectVersion,
    'databaseProfileId': databaseProfileId,
    'status': status.name,
    'indexedTime': indexedTime.toUtc().toIso8601String(),
    'textRecordIds': textRecordIds,
    'imageRecordIds': imageRecordIds,
    'audioRecordIds': audioRecordIds,
  };

  factory FileRegistryEntry.fromJson(Map<String, dynamic> json) =>
      FileRegistryEntry(
        schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
        fileObjectId: json['fileObjectId'] as String,
        path: PathRules.canonical(json['path'] as String),
        fingerprint: json['fingerprint'] as String,
        fileSize: (json['fileSize'] as num?)?.toInt(),
        modifiedTime: json['modifiedTime'] == null
            ? null
            : DateTime.parse(json['modifiedTime'] as String).toUtc(),
        objectVersion: (json['objectVersion'] as num).toInt(),
        databaseProfileId: json['databaseProfileId'] as String,
        status: FileIndexStatus.values.byName(json['status'] as String),
        indexedTime: DateTime.parse(json['indexedTime'] as String).toUtc(),
        textRecordIds: (json['textRecordIds'] as List).cast<String>(),
        imageRecordIds: (json['imageRecordIds'] as List).cast<String>(),
        audioRecordIds: (json['audioRecordIds'] as List).cast<String>(),
      );
}

class FileRegistryStore {
  final File file;

  const FileRegistryStore(this.file);

  Future<Map<String, FileRegistryEntry>> load() async {
    if (!await file.exists()) return {};
    final source = await file.readAsString();
    final value = await Isolate.run(() => jsonDecode(source));
    if (value is! List) {
      throw const FormatException('File registry must contain a JSON list.');
    }
    final result = <String, FileRegistryEntry>{};
    for (var index = 0; index < value.length; index++) {
      final item = value[index];
      final entry = FileRegistryEntry.fromJson(
        Map<String, dynamic>.from(item as Map),
      );
      result[entry.fileObjectId] = entry;
      if (index > 0 && index % 250 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return result;
  }

  Future<void> save(Map<String, FileRegistryEntry> entries) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    final values = <Map<String, Object?>>[];
    var index = 0;
    for (final entry in entries.values) {
      values.add(entry.toJson());
      index++;
      if (index % 250 == 0) await Future<void>.delayed(Duration.zero);
    }
    final encoded = await Isolate.run(
      () => const JsonEncoder.withIndent('  ').convert(values),
    );
    await temporary.writeAsString(encoded, flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}

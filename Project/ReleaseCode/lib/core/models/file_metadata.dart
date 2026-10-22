import 'package:path/path.dart' as p;

class FileMetadata {
  final String filePath;
  final String detectedFileType;
  final int fileSize;
  final DateTime modifiedTime;
  final DateTime? accessedTime;
  final DateTime? changedTime;
  final String? fingerprint;
  final bool? isReadOnly;
  final String? mimeType;

  const FileMetadata({
    required this.filePath,
    required this.detectedFileType,
    required this.fileSize,
    required this.modifiedTime,
    this.accessedTime,
    this.changedTime,
    this.fingerprint,
    this.isReadOnly,
    this.mimeType,
  });

  String get fileName => p.basename(filePath);

  String get extension => p.extension(filePath).toLowerCase();

  FileMetadata copyWith({
    String? filePath,
    String? detectedFileType,
    int? fileSize,
    DateTime? modifiedTime,
    DateTime? accessedTime,
    DateTime? changedTime,
    String? fingerprint,
    bool? isReadOnly,
    String? mimeType,
  }) => FileMetadata(
    filePath: filePath ?? this.filePath,
    detectedFileType: detectedFileType ?? this.detectedFileType,
    fileSize: fileSize ?? this.fileSize,
    modifiedTime: modifiedTime ?? this.modifiedTime,
    accessedTime: accessedTime ?? this.accessedTime,
    changedTime: changedTime ?? this.changedTime,
    fingerprint: fingerprint ?? this.fingerprint,
    isReadOnly: isReadOnly ?? this.isReadOnly,
    mimeType: mimeType ?? this.mimeType,
  );

  Map<String, Object?> toJson() => {
    'filePath': filePath,
    'fileName': fileName,
    'extension': extension,
    'detectedFileType': detectedFileType,
    'fileSize': fileSize,
    'modifiedTime': modifiedTime.toUtc().toIso8601String(),
    'accessedTime': accessedTime?.toUtc().toIso8601String(),
    'changedTime': changedTime?.toUtc().toIso8601String(),
    'fingerprint': fingerprint,
    'isReadOnly': isReadOnly,
    'mimeType': mimeType,
  };
}

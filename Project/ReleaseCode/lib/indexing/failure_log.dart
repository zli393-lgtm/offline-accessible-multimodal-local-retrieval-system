import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'database_storage.dart';

class IndexFailureRecord {
  final String failureId;
  final String fileObjectId;
  final String path;
  final String stage;
  final String code;
  final String message;
  final bool retryable;
  final int attempts;
  final DateTime time;

  const IndexFailureRecord({
    required this.failureId,
    required this.fileObjectId,
    required this.path,
    required this.stage,
    required this.code,
    required this.message,
    required this.retryable,
    required this.attempts,
    required this.time,
  });

  Map<String, Object> get unsignedJson => {
    'failureId': failureId,
    'fileObjectId': fileObjectId,
    'path': path,
    'stage': stage,
    'code': code,
    'message': message,
    'summaryZh': '失败阶段：$stage；错误代码：$code；详细信息：$message',
    'summaryEn':
        'Failed at stage: $stage; error code: $code; details: $message',
    'retryable': retryable,
    'attempts': attempts,
    'time': time.toUtc().toIso8601String(),
  };

  Map<String, Object> toJson() => {
    ...unsignedJson,
    'recordHash': FailureLogCodec.hashRecord(unsignedJson),
  };

  factory IndexFailureRecord.fromJson(Map<String, dynamic> json) {
    final unsigned = Map<String, Object>.from(json)..remove('recordHash');
    if (json['recordHash'] != FailureLogCodec.hashRecord(unsigned)) {
      throw const FormatException('Failure record checksum does not match.');
    }
    final record = IndexFailureRecord(
      failureId: json['failureId'] as String,
      fileObjectId: json['fileObjectId'] as String,
      path: PathRules.canonical(json['path'] as String),
      stage: json['stage'] as String,
      code: json['code'] as String,
      message: json['message'] as String,
      retryable: json['retryable'] as bool,
      attempts: (json['attempts'] as num).toInt(),
      time: DateTime.parse(json['time'] as String).toUtc(),
    );
    return record;
  }
}

class FailureLogReadResult {
  final List<IndexFailureRecord> records;
  final List<String> rejectedEntries;

  const FailureLogReadResult({
    required this.records,
    required this.rejectedEntries,
  });
}

class FailureRetryPlan {
  final List<IndexFailureRecord> accepted;
  final List<String> rejected;

  const FailureRetryPlan({required this.accepted, required this.rejected});
}

class FailureLogCodec {
  static const fileExtension = '.retrieval-failures.log';
  static const header = '[[.__LOCAL_RETRIEVAL_FAILURE_LOG_V1__.]]';
  static const footer = '[[.__END_LOCAL_RETRIEVAL_FAILURE_LOG_V1__.]]';
  static const recordStart = '[[.__FAILURE_RECORD__.]]';
  static const pathLabel = '[[.__FAILED_PATH__.]]';
  static const recordEnd = '[[.__END_FAILURE_RECORD__.]]';

  const FailureLogCodec();

  String encode(Iterable<IndexFailureRecord> records) {
    final buffer = StringBuffer()..writeln(header);
    for (final record in records) {
      buffer
        ..writeln(recordStart)
        ..writeln('$pathLabel ${jsonEncode(record.path)}')
        ..writeln(jsonEncode(record.toJson()))
        ..writeln(recordEnd);
    }
    buffer.writeln(footer);
    return buffer.toString();
  }

  FailureLogReadResult decode(String input) {
    final lines = const LineSplitter().convert(input);
    final rejected = <String>[];
    final records = <IndexFailureRecord>[];
    if (lines.isEmpty || lines.first.trim() != header) {
      throw const FormatException('Failure log header is missing or invalid.');
    }
    if (lines.lastWhere((line) => line.trim().isNotEmpty).trim() != footer) {
      throw const FormatException('Failure log footer is missing or invalid.');
    }
    var index = 1;
    while (index < lines.length) {
      final line = lines[index].trim();
      if (line.isEmpty) {
        index++;
        continue;
      }
      if (line == footer) break;
      if (line != recordStart) {
        rejected.add('Line ${index + 1}: unrecognized content was ignored.');
        index++;
        continue;
      }
      if (index + 3 >= lines.length || lines[index + 3].trim() != recordEnd) {
        rejected.add('Line ${index + 1}: incomplete failure record.');
        index++;
        continue;
      }
      try {
        final pathLine = lines[index + 1].trim();
        if (!pathLine.startsWith('$pathLabel ')) {
          throw const FormatException('Readable failed-path label is missing.');
        }
        final readablePath = jsonDecode(
          pathLine.substring(pathLabel.length).trim(),
        );
        if (readablePath is! String) {
          throw const FormatException('Readable failed path is invalid.');
        }
        final value = jsonDecode(lines[index + 2]);
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Record is not a JSON object.');
        }
        final record = IndexFailureRecord.fromJson(value);
        if (PathRules.canonical(readablePath) != record.path) {
          throw const FormatException(
            'Readable path and signed record path do not match.',
          );
        }
        records.add(record);
      } catch (error) {
        rejected.add('Line ${index + 2}: $error');
      }
      index += 4;
    }
    return FailureLogReadResult(
      records: List.unmodifiable(records),
      rejectedEntries: List.unmodifiable(rejected),
    );
  }

  FailureRetryPlan createRetryPlan({
    required FailureLogReadResult log,
    required Map<String, IndexFailureRecord> knownFailures,
  }) {
    final accepted = <IndexFailureRecord>[];
    final rejected = <String>[...log.rejectedEntries];
    final seen = <String>{};
    for (final candidate in log.records) {
      if (!seen.add(candidate.failureId)) {
        rejected.add('${candidate.failureId}: duplicate record.');
        continue;
      }
      final known = knownFailures[candidate.failureId];
      if (known == null) {
        rejected.add(
          '${candidate.failureId}: not present in the failure registry.',
        );
        continue;
      }
      if (!known.retryable || !candidate.retryable) {
        rejected.add('${candidate.failureId}: failure is not retryable.');
        continue;
      }
      if (known.fileObjectId != candidate.fileObjectId ||
          PathRules.canonical(known.path) !=
              PathRules.canonical(candidate.path)) {
        rejected.add('${candidate.failureId}: object or path was modified.');
        continue;
      }
      accepted.add(known);
    }
    return FailureRetryPlan(
      accepted: List.unmodifiable(accepted),
      rejected: List.unmodifiable(rejected),
    );
  }

  static String hashRecord(Map<String, Object> value) {
    final canonical = jsonEncode(value);
    var hash = BigInt.parse('14695981039346656037');
    final prime = BigInt.from(1099511628211);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final byte in utf8.encode(canonical)) {
      hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

class FailureRecordStore {
  final File registryFile;

  const FailureRecordStore(this.registryFile);

  Future<Map<String, IndexFailureRecord>> load() async {
    if (!await registryFile.exists()) return {};
    final value = jsonDecode(await registryFile.readAsString());
    if (value is! List) {
      throw const FormatException('Failure registry must contain a JSON list.');
    }
    final result = <String, IndexFailureRecord>{};
    for (final item in value) {
      final record = IndexFailureRecord.fromJson(
        Map<String, dynamic>.from(item as Map),
      );
      result[record.failureId] = record;
    }
    return result;
  }

  Future<void> put(IndexFailureRecord record) async {
    final records = await load();
    records[record.failureId] = record;
    await _write(records.values);
  }

  Future<void> remove(String failureId) async {
    final records = await load();
    records.remove(failureId);
    await _write(records.values);
  }

  Future<void> _write(Iterable<IndexFailureRecord> records) async {
    await registryFile.parent.create(recursive: true);
    final temporary = File('${registryFile.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert(records.map((record) => record.toJson()).toList()),
      flush: true,
    );
    if (await registryFile.exists()) await registryFile.delete();
    await temporary.rename(registryFile.path);
  }
}

class FailureLogFile {
  final FailureLogCodec codec;

  const FailureLogFile({this.codec = const FailureLogCodec()});

  Future<File> write({
    required String directory,
    required Iterable<IndexFailureRecord> records,
    String? name,
  }) async {
    final targetDirectory = Directory(directory);
    await targetDirectory.create(recursive: true);
    final base =
        name ??
        'failed-imports-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}'
            '${FailureLogCodec.fileExtension}';
    if (!base.endsWith(FailureLogCodec.fileExtension)) {
      throw ArgumentError(
        'Failure log name must use ${FailureLogCodec.fileExtension}.',
      );
    }
    final file = File(p.join(targetDirectory.path, base));
    await file.writeAsString(codec.encode(records), flush: true);
    return file;
  }

  Future<FailureLogReadResult> read(String path) async {
    if (!path.endsWith(FailureLogCodec.fileExtension)) {
      throw const FormatException('The selected file is not a retry log.');
    }
    return codec.decode(await File(path).readAsString());
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/file_object.dart';
import 'database_storage.dart';

enum IndexFileStatus {
  discovered,
  unchanged,
  queued,
  processing,
  indexed,
  failed,
  cancelled,
  removed,
}

class IndexFileState {
  final String jobId;
  final String fileObjectId;
  final String path;
  final IndexFileStatus status;
  final String? stage;
  final int? completedUnits;
  final int? totalUnits;
  final String? detail;
  final String? message;
  final DateTime time;

  const IndexFileState({
    required this.jobId,
    required this.fileObjectId,
    required this.path,
    required this.status,
    required this.time,
    this.stage,
    this.completedUnits,
    this.totalUnits,
    this.detail,
    this.message,
  });

  factory IndexFileState.forPath({
    required String jobId,
    required String path,
    required IndexFileStatus status,
    String? stage,
    int? completedUnits,
    int? totalUnits,
    String? detail,
    String? message,
  }) {
    final canonicalPath = PathRules.canonical(path);
    return IndexFileState(
      jobId: jobId,
      fileObjectId: FileObjectIds.fromPath(canonicalPath),
      path: canonicalPath,
      status: status,
      stage: stage,
      completedUnits: completedUnits,
      totalUnits: totalUnits,
      detail: detail,
      message: message,
      time: DateTime.now().toUtc(),
    );
  }

  Map<String, Object?> toJson() => {
    'version': 2,
    'jobId': jobId,
    'fileObjectId': fileObjectId,
    'path': path,
    'status': status.name,
    'statusZh': _statusZh(status),
    'statusEn': _statusEn(status),
    'stage': stage,
    'stageZh': stage == null ? null : '处理阶段：$stage',
    'stageEn': stage == null ? null : 'Processing stage: $stage',
    'completedUnits': completedUnits,
    'totalUnits': totalUnits,
    'detail': detail,
    'message': message,
    'messageZh': message == null ? null : '详细信息：$message',
    'messageEn': message == null ? null : 'Details: $message',
    'time': time.toIso8601String(),
  };

  static String _statusZh(IndexFileStatus value) => switch (value) {
    IndexFileStatus.discovered => '已发现',
    IndexFileStatus.unchanged => '未变化',
    IndexFileStatus.queued => '等待处理',
    IndexFileStatus.processing => '处理中',
    IndexFileStatus.indexed => '索引完成',
    IndexFileStatus.failed => '失败',
    IndexFileStatus.cancelled => '已取消',
    IndexFileStatus.removed => '已移除',
  };

  static String _statusEn(IndexFileStatus value) => switch (value) {
    IndexFileStatus.discovered => 'Discovered',
    IndexFileStatus.unchanged => 'Unchanged',
    IndexFileStatus.queued => 'Queued',
    IndexFileStatus.processing => 'Processing',
    IndexFileStatus.indexed => 'Indexed',
    IndexFileStatus.failed => 'Failed',
    IndexFileStatus.cancelled => 'Cancelled',
    IndexFileStatus.removed => 'Removed',
  };

  factory IndexFileState.fromJson(Map<String, dynamic> json) => IndexFileState(
    jobId: json['jobId'] as String,
    fileObjectId: json['fileObjectId'] as String,
    path: PathRules.canonical(json['path'] as String),
    // Older builds could commit a partially processed file. Under the atomic
    // file-object rule that state is a failed object, not a usable index.
    status: json['status'] == 'partial'
        ? IndexFileStatus.failed
        : IndexFileStatus.values.byName(json['status'] as String),
    stage: json['stage'] as String?,
    completedUnits: (json['completedUnits'] as num?)?.toInt(),
    totalUnits: (json['totalUnits'] as num?)?.toInt(),
    detail: json['detail'] as String?,
    message: json['message'] as String?,
    time: DateTime.parse(json['time'] as String).toUtc(),
  );
}

class IndexFileStateStore {
  final String directory;

  const IndexFileStateStore(this.directory);

  File fileFor(String jobId) =>
      File(p.join(directory, 'job-$jobId-files.jsonl'));

  Future<void> append(IndexFileState state) async {
    final file = fileFor(state.jobId);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode(state.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<Map<String, IndexFileState>> loadLatest(String jobId) async {
    final file = fileFor(jobId);
    if (!await file.exists()) return {};
    final result = <String, IndexFileState>{};
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final value = jsonDecode(line);
      final state = IndexFileState.fromJson(
        Map<String, dynamic>.from(value as Map),
      );
      result[state.fileObjectId] = state;
    }
    return result;
  }
}

/// A user-readable, one-file summary of a completed indexing run.
class IndexResultLogFile {
  const IndexResultLogFile();

  Future<File> write({
    required String directory,
    required String jobId,
    required Iterable<IndexFileState> states,
  }) async {
    final finalStates =
        states
            .where(
              (state) => switch (state.status) {
                IndexFileStatus.indexed ||
                IndexFileStatus.unchanged ||
                IndexFileStatus.removed ||
                IndexFileStatus.failed ||
                IndexFileStatus.cancelled => true,
                _ => false,
              },
            )
            .toList()
          ..sort((left, right) => left.path.compareTo(right.path));
    final file = File(p.join(directory, 'index-results-$jobId.log'));
    await file.parent.create(recursive: true);
    final buffer = StringBuffer()
      ..writeln('本地文件检索：索引任务结果 / Local Retrieval: indexing results')
      ..writeln('任务编号 / Job ID: $jobId')
      ..writeln('记录格式 / Format: UTF-8 plain text (.log)')
      ..writeln();
    for (final state in finalStates) {
      final succeeded =
          state.status == IndexFileStatus.indexed ||
          state.status == IndexFileStatus.unchanged ||
          state.status == IndexFileStatus.removed;
      buffer
        ..writeln(succeeded ? '[成功 / SUCCESS]' : '[失败 / FAILED]')
        ..writeln('路径 / Path: ${state.path}')
        ..writeln(
          '结果 / Result: ${IndexFileState._statusZh(state.status)} / '
          '${IndexFileState._statusEn(state.status)}',
        );
      if (state.stage != null) buffer.writeln('阶段 / Stage: ${state.stage}');
      if (state.message != null) {
        buffer.writeln('详情 / Details: ${state.message}');
      }
      buffer.writeln();
    }
    await file.writeAsString(buffer.toString(), flush: true);
    return file;
  }
}

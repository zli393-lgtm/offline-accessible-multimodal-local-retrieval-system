import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/models/extracted_file_content.dart';
import '../core/models/file_metadata.dart';
import '../core/models/parsing_result.dart';
import '../embedding/embedding_result.dart';
import '../embedding/multimodal_embedding_engine.dart';

enum FileObjectOrigin { indexedLibrary, queryAttachment }

enum FileIndexStatus { notIndexed, indexing, indexed, partial, failed, stale }

/// The one text property exposed by a file object.
///
/// Direct text, OCR output, speech transcripts, table data, chart data, and
/// vector-source text are merged into [value]. [sources] only preserves where
/// each part came from; it does not split text into separate top-level types.
class UnifiedTextContent {
  final String value;
  final List<TextInformation> sources;

  const UnifiedTextContent({required this.value, required this.sources});

  factory UnifiedTextContent.fromExtracted(ExtractedFileContent content) {
    // Repeated text is meaningful in some files (for example repeated table
    // rows, captions, or transcript segments), so merge in source order
    // without content-based de-duplication.
    final parts = content.textInformation
        .map((information) => information.text.trim())
        .where((text) => text.isNotEmpty)
        .toList(growable: false);
    return UnifiedTextContent(
      value: parts.join('\n'),
      sources: List.unmodifiable(content.textInformation),
    );
  }

  bool get isEmpty => value.isEmpty;
}

class FileAnalysisData {
  final List<EmbeddingResult> textEmbeddings;
  final List<EmbeddingResult> imageEmbeddings;
  final List<EmbeddingResult> audioEmbeddings;

  const FileAnalysisData({
    this.textEmbeddings = const [],
    this.imageEmbeddings = const [],
    this.audioEmbeddings = const [],
  });

  factory FileAnalysisData.fromBatch(MultimodalEmbeddingBatch batch) =>
      FileAnalysisData(
        textEmbeddings: List.unmodifiable(batch.textEmbeddings),
        imageEmbeddings: List.unmodifiable(batch.imageEmbeddings),
        audioEmbeddings: List.unmodifiable(batch.audioEmbeddings),
      );

  bool get isEmpty =>
      textEmbeddings.isEmpty &&
      imageEmbeddings.isEmpty &&
      audioEmbeddings.isEmpty;
}

class FileIndexData {
  final String? databaseProfileId;
  final String? indexVersion;
  final DateTime? indexedTime;
  final FileIndexStatus status;
  final List<String> textRecordIds;
  final List<String> imageRecordIds;
  final List<String> audioRecordIds;

  const FileIndexData({
    this.databaseProfileId,
    this.indexVersion,
    this.indexedTime,
    this.status = FileIndexStatus.notIndexed,
    this.textRecordIds = const [],
    this.imageRecordIds = const [],
    this.audioRecordIds = const [],
  });
}

class FileProcessingData {
  final ExtractionStatus extractionStatus;
  final EmbeddingStatus? embeddingStatus;
  final List<ExtractionIssue> extractionIssues;
  final List<EmbeddingIssue> embeddingIssues;
  final int attempts;
  final String? lastFailureId;
  final String? lastFailureMessage;

  const FileProcessingData({
    required this.extractionStatus,
    this.embeddingStatus,
    this.extractionIssues = const [],
    this.embeddingIssues = const [],
    this.attempts = 1,
    this.lastFailureId,
    this.lastFailureMessage,
  });
}

/// Aggregate root for one real outer file.
///
/// Physical persistence may normalize this object across a registry and three
/// vector collections, but application code keeps the identity, content,
/// analysis, index state, and failures attached to this one object.
class FileObject {
  final String fileObjectId;
  final int objectVersion;
  final FileObjectOrigin origin;
  final FileMetadata metadata;
  final ExtractedFileContent content;
  final UnifiedTextContent text;
  final FileAnalysisData analysis;
  final FileIndexData index;
  final FileProcessingData processing;

  const FileObject({
    required this.fileObjectId,
    required this.objectVersion,
    required this.origin,
    required this.metadata,
    required this.content,
    required this.text,
    required this.analysis,
    required this.index,
    required this.processing,
  });

  factory FileObject.fromParsingResult(
    ParsingResult result, {
    required FileObjectOrigin origin,
    int objectVersion = 1,
  }) => FileObject(
    fileObjectId: FileObjectIds.fromPath(result.metadata.filePath),
    objectVersion: objectVersion,
    origin: origin,
    metadata: result.metadata,
    content: result.content,
    text: UnifiedTextContent.fromExtracted(result.content),
    analysis: const FileAnalysisData(),
    index: const FileIndexData(),
    processing: FileProcessingData(
      extractionStatus: result.content.status,
      extractionIssues: List.unmodifiable(result.content.issues),
    ),
  );

  FileObject withEmbeddings(MultimodalEmbeddingBatch batch) => FileObject(
    fileObjectId: fileObjectId,
    objectVersion: objectVersion,
    origin: origin,
    metadata: metadata,
    content: content,
    text: text,
    analysis: FileAnalysisData.fromBatch(batch),
    index: index,
    processing: FileProcessingData(
      extractionStatus: processing.extractionStatus,
      embeddingStatus: batch.status,
      extractionIssues: processing.extractionIssues,
      embeddingIssues: List.unmodifiable(batch.issues),
      attempts: processing.attempts,
      lastFailureId: processing.lastFailureId,
      lastFailureMessage: processing.lastFailureMessage,
    ),
  );

  FileObject withIndex(FileIndexData value) => FileObject(
    fileObjectId: fileObjectId,
    objectVersion: objectVersion,
    origin: origin,
    metadata: metadata,
    content: content,
    text: text,
    analysis: analysis,
    index: value,
    processing: processing,
  );

  FileObject withFailure({required String id, required String message}) =>
      FileObject(
        fileObjectId: fileObjectId,
        objectVersion: objectVersion,
        origin: origin,
        metadata: metadata,
        content: content,
        text: text,
        analysis: analysis,
        index: FileIndexData(
          databaseProfileId: index.databaseProfileId,
          indexVersion: index.indexVersion,
          indexedTime: index.indexedTime,
          status: FileIndexStatus.failed,
          textRecordIds: index.textRecordIds,
          imageRecordIds: index.imageRecordIds,
          audioRecordIds: index.audioRecordIds,
        ),
        processing: FileProcessingData(
          extractionStatus: processing.extractionStatus,
          embeddingStatus: processing.embeddingStatus,
          extractionIssues: processing.extractionIssues,
          embeddingIssues: processing.embeddingIssues,
          attempts: processing.attempts + 1,
          lastFailureId: id,
          lastFailureMessage: message,
        ),
      );
}

class FileObjectIds {
  const FileObjectIds._();

  static String fromPath(String path) {
    var normalized = p.normalize(File(path).absolute.path);
    if (Platform.isWindows) normalized = normalized.toLowerCase();
    // Stable 64-bit FNV-1a implemented with BigInt so IDs do not depend on
    // Dart's process-specific String.hashCode implementation.
    var hash = BigInt.parse('14695981039346656037');
    final prime = BigInt.from(1099511628211);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final byte in normalized.codeUnits) {
      hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
    }
    return 'file-${hash.toRadixString(16).padLeft(16, '0')}';
  }
}

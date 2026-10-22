import '../domain/file_object.dart';
import '../core/models/extracted_file_content.dart';
import '../core/parsing/parser.dart';
import '../embedding/embedding_result.dart';
import '../embedding/embedding_space.dart';
import '../configuration/retrieval/relevance_threshold_values.dart';

String literalFileExtension(String filePath) {
  final name = filePath.split(RegExp(r'[/\\]')).last.toLowerCase();
  if (name.endsWith('.fb2.zip')) return 'FB2_ZIP';
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toUpperCase();
}

enum VectorSpaceKind { text, image, audio }

class StoredVectorRecord {
  final String id;
  final String fileObjectId;
  final String sourcePath;
  final String fileType;
  final VectorSpaceKind space;
  final String document;
  final List<double> embedding;
  final Map<String, Object> metadata;

  const StoredVectorRecord({
    required this.id,
    required this.fileObjectId,
    required this.sourcePath,
    required this.fileType,
    required this.space,
    required this.document,
    required this.embedding,
    required this.metadata,
  });

  Map<String, Object> toJson() => {
    'id': id,
    'document': document,
    'embedding': embedding,
    'metadata': {
      'fileObjectId': fileObjectId,
      'sourcePath': sourcePath,
      'fileType': fileType,
      'space': space.name,
      ...metadata,
    },
  };
}

class FileVectorRecords {
  final List<StoredVectorRecord> text;
  final List<StoredVectorRecord> image;
  final List<StoredVectorRecord> audio;

  const FileVectorRecords({
    required this.text,
    required this.image,
    required this.audio,
  });

  factory FileVectorRecords.fromObject(FileObject object) => FileVectorRecords(
    text: _records(
      object,
      object.analysis.textEmbeddings,
      VectorSpaceKind.text,
    ),
    image: _records(
      object,
      object.analysis.imageEmbeddings,
      VectorSpaceKind.image,
    ),
    audio: _records(
      object,
      object.analysis.audioEmbeddings,
      VectorSpaceKind.audio,
    ),
  );

  static List<StoredVectorRecord> _records(
    FileObject object,
    List<EmbeddingResult> embeddings,
    VectorSpaceKind space,
  ) => List.unmodifiable(
    embeddings.asMap().entries.map((entry) {
      final result = entry.value;
      final source = result.source;
      var document = '';
      if (source.summaryText != null) document = source.summaryText!;
      if (space == VectorSpaceKind.text && source.summaryKind == null) {
        final informationIndex = source.informationIndex;
        if (informationIndex != null &&
            informationIndex >= 0 &&
            informationIndex < object.content.textInformation.length) {
          final value = object.content.textInformation[informationIndex].text;
          final start = source.startOffset ?? 0;
          final end = source.endOffset ?? value.length;
          if (start >= 0 && end >= start && end <= value.length) {
            document = value.substring(start, end);
          }
        }
        if (document.isEmpty) document = object.text.value;
      }
      final metadata = <String, Object>{
        'fileExtension': literalFileExtension(object.metadata.filePath),
        'vectorIndex': entry.key,
        'model': result.model,
        'dimensions': result.dimensions,
        'objectVersion': object.objectVersion,
        'recordKind': source.summaryKind ?? 'raw',
        'summaryLevel': source.summaryLevel ?? 'none',
        'queryInformationKind':
            source.queryInformationKind ??
            _rawInformationKind(object, result, space),
        if (space == VectorSpaceKind.text &&
            source.informationIndex != null &&
            source.informationIndex! >= 0 &&
            source.informationIndex! < object.content.textInformation.length)
          'textInformationKind': object
              .content
              .textInformation[source.informationIndex!]
              .informationKind
              .name,
        if (space == VectorSpaceKind.text &&
            source.informationIndex != null &&
            source.informationIndex! >= 0 &&
            source.informationIndex! < object.content.textInformation.length)
          'textExtractionMethod': object
              .content
              .textInformation[source.informationIndex!]
              .extractionMethod
              .name,
        if (source.informationIndex != null)
          'informationIndex': source.informationIndex!,
        if (source.pageIndex != null) 'pageIndex': source.pageIndex!,
        if (source.frameIndex != null) 'frameIndex': source.frameIndex!,
        if (source.chunkIndex != null) 'chunkIndex': source.chunkIndex!,
        if (source.startOffset != null) 'startOffset': source.startOffset!,
        if (source.endOffset != null) 'endOffset': source.endOffset!,
        if (source.startTimeMs != null) 'startTimeMs': source.startTimeMs!,
        if (source.endTimeMs != null) 'endTimeMs': source.endTimeMs!,
      };
      return StoredVectorRecord(
        // A replacement is first written as a separate generation.  The
        // service can therefore remove this generation after a failed write
        // without overwriting the last searchable version of the file.
        id: '${object.fileObjectId}:v${object.objectVersion}:${space.name}:${entry.key}',
        fileObjectId: object.fileObjectId,
        sourcePath: object.metadata.filePath,
        fileType: object.metadata.detectedFileType,
        space: space,
        document: document,
        embedding: result.vector,
        metadata: metadata,
      );
    }),
  );

  static String _rawInformationKind(
    FileObject object,
    EmbeddingResult result,
    VectorSpaceKind space,
  ) {
    if (space == VectorSpaceKind.image) return 'image';
    if (space == VectorSpaceKind.audio) return 'audio';
    final index = result.source.informationIndex;
    if (index == null ||
        index < 0 ||
        index >= object.content.textInformation.length) {
      return 'nativeText';
    }
    final information = object.content.textInformation[index];
    final extracted =
        information.extractionMethod == TextExtractionMethod.ocr ||
        information.extractionMethod ==
            TextExtractionMethod.speechRecognition ||
        information.extractionMethod == TextExtractionMethod.other ||
        information.informationKind == TextInformationKind.ocr ||
        information.informationKind == TextInformationKind.speechTranscript ||
        information.informationKind == TextInformationKind.metadata;
    return extracted ? 'extractedText' : 'nativeText';
  }
}

class FileIndexWriteResult {
  final List<String> textRecordIds;
  final List<String> imageRecordIds;
  final List<String> audioRecordIds;

  const FileIndexWriteResult({
    required this.textRecordIds,
    required this.imageRecordIds,
    required this.audioRecordIds,
  });
}

class VectorSearchHit {
  final String id;
  final String fileObjectId;
  final String sourcePath;
  final String fileType;
  final VectorSpaceKind space;
  final String document;
  final double distance;
  final double? relevanceScore;
  final bool vectorMatched;
  final bool keywordMatched;
  final Map<String, Object?> metadata;

  const VectorSearchHit({
    required this.id,
    required this.fileObjectId,
    required this.sourcePath,
    required this.fileType,
    required this.space,
    required this.document,
    required this.distance,
    required this.metadata,
    this.relevanceScore,
    this.vectorMatched = true,
    this.keywordMatched = false,
  });

  factory VectorSearchHit.fromJson(Map<String, dynamic> json) {
    final metadata = Map<String, Object?>.from(json['metadata'] as Map);
    return VectorSearchHit(
      id: json['id'] as String,
      fileObjectId: metadata['fileObjectId'] as String,
      sourcePath: metadata['sourcePath'] as String,
      fileType: metadata['fileType'] as String,
      space: VectorSpaceKind.values.byName(metadata['space'] as String),
      document: json['document'] as String? ?? '',
      distance: (json['distance'] as num?)?.toDouble() ?? double.infinity,
      metadata: metadata,
      relevanceScore: (json['relevanceScore'] as num?)?.toDouble(),
      vectorMatched: json['vectorMatched'] as bool? ?? true,
      keywordMatched: json['keywordMatched'] as bool? ?? false,
    );
  }

  VectorSearchHit withRanking({
    required double relevanceScore,
    required bool vectorMatched,
    required bool keywordMatched,
  }) => VectorSearchHit(
    id: id,
    fileObjectId: fileObjectId,
    sourcePath: sourcePath,
    fileType: fileType,
    space: space,
    document: document,
    distance: distance,
    metadata: metadata,
    relevanceScore: relevanceScore,
    vectorMatched: vectorMatched,
    keywordMatched: keywordMatched,
  );
}

class VectorCandidateSet {
  final List<VectorSearchHit> vector;
  final List<VectorSearchHit> keyword;

  const VectorCandidateSet({required this.vector, required this.keyword});
}

class FileQueryVector {
  final VectorSpaceKind space;
  final List<double> embedding;
  final List<String> terms;
  final Set<String> allowedRecordKinds;
  final Set<String> allowedInformationKinds;

  const FileQueryVector({
    required this.space,
    required this.embedding,
    this.terms = const [],
    this.allowedRecordKinds = const {'raw'},
    this.allowedInformationKinds = const {},
  });
}

class FileQueryPage {
  final String queryToken;
  final int totalFiles;
  final int pageIndex;
  final int pageSize;
  final List<VectorSearchHit> files;
  final Set<String> availableFileTypes;
  final bool totalIsFinal;
  final bool hasMore;

  const FileQueryPage({
    required this.queryToken,
    required this.totalFiles,
    required this.pageIndex,
    required this.pageSize,
    required this.files,
    this.availableFileTypes = const {},
    this.totalIsFinal = true,
    this.hasMore = false,
  });
}

class FileQueryRefinement {
  final bool fileTypeFilterEnabled;
  final Set<String> allowedFileTypes;
  final bool includeOtherFileTypes;
  final Set<String> knownFileTypes;
  final String sort;

  const FileQueryRefinement({
    this.fileTypeFilterEnabled = false,
    this.allowedFileTypes = const {},
    this.includeOtherFileTypes = false,
    this.knownFileTypes = const {},
    this.sort = 'indexOrder',
  });
}

/// Optional production capability: merge record-level hits in the storage
/// service and return only one stable page of file objects to the application.
abstract interface class PagedFileQueryStore {
  Future<FileQueryPage> prepareFileQuery({
    required List<FileQueryVector> vectors,
    required List<VectorSearchHit> fileNameHits,
    required int pageSize,
    String? fileType,
    bool fileTypeFilterEnabled = false,
    Set<String> allowedFileTypes = const {},
    bool includeOtherFileTypes = false,
    Set<String> knownFileTypes = const {},
    Set<String>? allowedFileObjectIds,
    List<String> fileObjectOrder = const [],
    required bool includeNativeText,
    required bool includeExtractedText,
    RelevanceScope relevanceScope = RelevanceThresholdValues.defaultScope,
  });

  Future<FileQueryPage> loadFileQueryPage(String queryToken, int pageIndex);
}

abstract interface class RefinablePagedFileQueryStore {
  Future<FileQueryPage> refineFileQuery(
    String queryToken,
    FileQueryRefinement refinement,
  );
}

abstract interface class MultimodalVectorStore {
  Future<FileIndexWriteResult> replaceFileObject(
    FileObject object, {
    FileProcessingObserver? observer,
  });

  Future<void> removeFileObject(String fileObjectId);

  Future<List<VectorSearchHit>> searchSpace({
    required VectorSpaceKind space,
    required List<double> embedding,
    List<String> terms = const [],
    int limit = 10,
    String? fileType,
  });
}

VectorSpaceKind vectorSpaceKind(EmbeddingSpace space) => switch (space) {
  EmbeddingSpace.bertText => VectorSpaceKind.text,
  EmbeddingSpace.mobileClip => VectorSpaceKind.image,
  EmbeddingSpace.clap => VectorSpaceKind.audio,
};

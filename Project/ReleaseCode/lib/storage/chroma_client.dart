import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../core/parsing/parser.dart';
import '../retrieval/retrieval_models.dart';
import '../domain/file_object.dart';
import '../retrieval/multimodal_hybrid_retriever.dart';
import '../configuration/retrieval/relevance_threshold_values.dart';
import 'multimodal_vector_store.dart';

class ChromaClient
    implements
        MultimodalVectorStore,
        PagedFileQueryStore,
        RefinablePagedFileQueryStore {
  static const int _vectorWriteBatchSize = 32;

  final Uri baseUri;
  final HttpClient _http;

  ChromaClient({Uri? baseUri, HttpClient? httpClient})
    : baseUri = baseUri ?? Uri.parse('http://127.0.0.1:8765'),
      _http = httpClient ?? HttpClient() {
    if (this.baseUri.host != '127.0.0.1' &&
        this.baseUri.host != 'localhost' &&
        this.baseUri.host != '::1') {
      throw ArgumentError('Chroma service must be loopback-only.');
    }
    if (this.baseUri.scheme != 'http') {
      throw ArgumentError('Local Chroma service requires HTTP.');
    }
    _http.connectionTimeout = const Duration(seconds: 5);
  }

  Future<Map<String, dynamic>> _post(String path, Object body) async {
    final request = await _http.postUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    final bytes = await Isolate.run(() => utf8.encode(jsonEncode(body)));
    // Python's BaseHTTPRequestHandler requires a concrete Content-Length.
    // Setting it explicitly also avoids the chunked-transfer regression that
    // earlier integration tests exposed.
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    final source = await utf8.decodeStream(response);
    final value = await Isolate.run(() => jsonDecode(source));
    if (response.statusCode != 200) {
      throw HttpException('Chroma $path failed: $value');
    }
    return Map<String, dynamic>.from(value as Map);
  }

  Future<int> count() async {
    final response = await _http.getUrl(baseUri.resolve('/health'));
    final result = await response.close();
    if (result.statusCode != 200) {
      throw HttpException('Chroma health check failed: ${result.statusCode}');
    }
    final source = await utf8.decodeStream(result);
    final body = await Isolate.run(() => jsonDecode(source));
    return (body['count'] as num).toInt();
  }

  Future<int> upsert(List<IndexedChunk> chunks) async {
    if (chunks.isEmpty) return 0;
    final result = await _post('/upsert', {
      'rows': chunks.map((chunk) => chunk.toJson()).toList(),
    });
    return (result['upserted'] as num).toInt();
  }

  Future<CandidateSet> search({
    required List<double> embedding,
    required List<String> terms,
    int limit = 10,
  }) async {
    final result = await _post('/search', {
      'embedding': embedding,
      'terms': terms,
      'limit': limit,
    });
    List<SearchCandidate> parse(String key) => (result[key] as List)
        .map(
          (item) =>
              SearchCandidate.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
    return CandidateSet(vector: parse('vector'), keyword: parse('keyword'));
  }

  @override
  Future<FileIndexWriteResult> replaceFileObject(
    FileObject object, {
    FileProcessingObserver? observer,
  }) async {
    final records = FileVectorRecords.fromObject(object);
    final bySpace = <VectorSpaceKind, List<StoredVectorRecord>>{
      VectorSpaceKind.text: records.text,
      VectorSpaceKind.image: records.image,
      VectorSpaceKind.audio: records.audio,
    };
    final idsBySpace = {
      for (final entry in bySpace.entries)
        entry.key: entry.value.map((record) => record.id).toList(),
    };
    try {
      final totalRecords = bySpace.values.fold<int>(
        0,
        (total, records) => total + records.length,
      );
      var stagedRecordCount = 0;
      for (final entry in bySpace.entries) {
        for (
          var offset = 0;
          offset < entry.value.length;
          offset += _vectorWriteBatchSize
        ) {
          await reportFileProcessing(
            observer,
            FileProcessingStage.indexStaging,
            completedUnits: stagedRecordCount,
            totalUnits: totalRecords,
            detail: entry.key.name,
          );
          final batch = entry.value
              .skip(offset)
              .take(_vectorWriteBatchSize)
              .toList(growable: false);
          final staged = await _post('/stage-file', {
            'fileObjectId': object.fileObjectId,
            'space': entry.key.name,
            'rows': batch.map((record) => record.toJson()).toList(),
          });
          final stagedIds = (staged['stagedRecordIds'] as List).cast<String>();
          final expectedIds = batch.map((record) => record.id).toList();
          if (stagedIds.length != expectedIds.length ||
              !stagedIds.toSet().containsAll(expectedIds)) {
            throw StateError('The vector service staged an incomplete batch.');
          }
          stagedRecordCount += batch.length;
        }
      }
      await reportFileProcessing(
        observer,
        FileProcessingStage.indexValidation,
        completedUnits: stagedRecordCount,
        totalUnits: totalRecords,
      );
      await reportFileProcessing(observer, FileProcessingStage.indexCommit);
      final result = await _post('/commit-file', {
        'fileObjectId': object.fileObjectId,
        'textRecordIds': idsBySpace[VectorSpaceKind.text],
        'imageRecordIds': idsBySpace[VectorSpaceKind.image],
        'audioRecordIds': idsBySpace[VectorSpaceKind.audio],
      });
      List<String> ids(String key) => (result[key] as List).cast<String>();
      await reportFileProcessing(
        observer,
        FileProcessingStage.indexCommit,
        completedUnits: totalRecords,
        totalUnits: totalRecords,
      );
      return FileIndexWriteResult(
        textRecordIds: ids('textRecordIds'),
        imageRecordIds: ids('imageRecordIds'),
        audioRecordIds: ids('audioRecordIds'),
      );
    } catch (error) {
      await reportFileProcessing(
        observer,
        FileProcessingStage.temporaryCleanup,
      );
      Object? cleanupError;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await _post('/abort-file', {
            'fileObjectId': object.fileObjectId,
            'textRecordIds': idsBySpace[VectorSpaceKind.text],
            'imageRecordIds': idsBySpace[VectorSpaceKind.image],
            'audioRecordIds': idsBySpace[VectorSpaceKind.audio],
          });
          cleanupError = null;
          break;
        } catch (failure) {
          cleanupError = failure;
          if (attempt < 2) {
            await Future<void>.delayed(
              Duration(milliseconds: 100 * (attempt + 1)),
            );
          }
        }
      }
      if (cleanupError != null) {
        throw StateError(
          'Vector staging failed: $error; cleanup also failed after 3 attempts: '
          '$cleanupError. Partial new records may remain searchable.',
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> removeFileObject(String fileObjectId) async {
    await _post('/remove-file', {'fileObjectId': fileObjectId});
  }

  @override
  Future<List<VectorSearchHit>> searchSpace({
    required VectorSpaceKind space,
    required List<double> embedding,
    List<String> terms = const [],
    int limit = 10,
    String? fileType,
  }) async {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    final hybrid = space == VectorSpaceKind.text && terms.isNotEmpty;
    final hasFilter = fileType != null && fileType.trim().isNotEmpty;
    final expandedLimit = (hybrid || hasFilter) && limit <= 33
        ? limit * 3
        : limit;
    final result = await _post('/search-space', {
      'space': space.name,
      'embedding': embedding,
      'terms': terms,
      'limit': expandedLimit,
    });
    List<VectorSearchHit> parse(String key) =>
        (result[key] as List? ?? const [])
            .map(
              (item) => VectorSearchHit.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(growable: false);

    if (space == VectorSpaceKind.text &&
        (result.containsKey('vector') || result.containsKey('keyword'))) {
      return MultimodalHybridRetriever.fuse(
        VectorCandidateSet(vector: parse('vector'), keyword: parse('keyword')),
        limit: limit,
        fileType: fileType,
      );
    }

    // Compatibility with a service from before hybrid search was added.
    final normalizedType = fileType?.trim().toUpperCase();
    final vectorResults = result.containsKey('vector')
        ? parse('vector')
        : parse('results');
    return vectorResults
        .where(
          (hit) =>
              normalizedType == null ||
              normalizedType.isEmpty ||
              hit.fileType.toUpperCase() == normalizedType,
        )
        .take(limit)
        .toList(growable: false);
  }

  @override
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
  }) async {
    final thresholds = RelevanceThresholdValues.forScope(relevanceScope);
    final result = await _post('/prepare-file-query', {
      'vectors': vectors
          .map(
            (item) => {
              'space': item.space.name,
              'embedding': item.embedding,
              'terms': item.terms,
              'allowedRecordKinds': item.allowedRecordKinds.toList(),
              'allowedInformationKinds': item.allowedInformationKinds.toList(),
            },
          )
          .toList(growable: false),
      'fileNameHits': fileNameHits.map(_hitToJson).toList(growable: false),
      'pageSize': pageSize,
      if (fileType != null && fileType.trim().isNotEmpty) 'fileType': fileType,
      'fileTypeFilterEnabled': fileTypeFilterEnabled,
      'allowedFileTypes': allowedFileTypes.toList(growable: false),
      'includeOtherFileTypes': includeOtherFileTypes,
      'knownFileTypes': knownFileTypes.toList(growable: false),
      if (allowedFileObjectIds != null)
        'allowedFileObjectIds': allowedFileObjectIds.toList(growable: false),
      'fileObjectOrder': fileObjectOrder,
      'includeNativeText': includeNativeText,
      'includeExtractedText': includeExtractedText,
      'relevanceScope': relevanceScope.name,
      if (thresholds != null)
        'relevanceThresholds': {
          'nativeText': thresholds.nativeText,
          'extractedText': thresholds.extractedText,
          'image': thresholds.image,
          'audio': thresholds.audio,
        },
    });
    return _fileQueryPage(result);
  }

  @override
  Future<FileQueryPage> loadFileQueryPage(
    String queryToken,
    int pageIndex,
  ) async => _fileQueryPage(
    await _post('/file-query-page', {
      'queryToken': queryToken,
      'pageIndex': pageIndex,
    }),
  );

  @override
  Future<FileQueryPage> refineFileQuery(
    String queryToken,
    FileQueryRefinement refinement,
  ) async => _fileQueryPage(
    await _post('/refine-file-query', {
      'queryToken': queryToken,
      'fileTypeFilterEnabled': refinement.fileTypeFilterEnabled,
      'allowedFileTypes': refinement.allowedFileTypes.toList(growable: false),
      'includeOtherFileTypes': refinement.includeOtherFileTypes,
      'knownFileTypes': refinement.knownFileTypes.toList(growable: false),
      'sort': refinement.sort,
    }),
  );

  Map<String, Object?> _hitToJson(VectorSearchHit hit) => {
    'id': hit.id,
    'document': hit.document,
    'metadata': {
      ...hit.metadata,
      'fileObjectId': hit.fileObjectId,
      'sourcePath': hit.sourcePath,
      'fileType': hit.fileType,
      'space': hit.space.name,
    },
    'distance': hit.distance.isFinite ? hit.distance : null,
    if (hit.relevanceScore != null) 'relevanceScore': hit.relevanceScore,
    'vectorMatched': hit.vectorMatched,
    'keywordMatched': hit.keywordMatched,
  };

  FileQueryPage _fileQueryPage(Map<String, dynamic> json) => FileQueryPage(
    queryToken: json['queryToken'] as String,
    totalFiles: (json['totalFiles'] as num).toInt(),
    pageIndex: (json['pageIndex'] as num).toInt(),
    pageSize: (json['pageSize'] as num).toInt(),
    files: (json['files'] as List? ?? const [])
        .map(
          (item) =>
              VectorSearchHit.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false),
    availableFileTypes: (json['availableFileTypes'] as List? ?? const [])
        .map((value) => value.toString())
        .toSet(),
    totalIsFinal: json['totalIsFinal'] as bool? ?? true,
    hasMore: json['hasMore'] as bool? ?? false,
  );

  void close() => _http.close();
}

import '../core/parsing/parser.dart';
import '../domain/file_object.dart';
import '../embedding/embedding_result.dart';
import '../embedding/multimodal_embedding_engine.dart';
import '../indexing/database_storage.dart';
import '../indexing/file_registry.dart';
import '../retrieval/hybrid_retriever.dart';
import '../storage/multimodal_vector_store.dart';
import '../configuration/retrieval/relevance_threshold_values.dart';
import 'query_models.dart';

/// Parses independent query inputs, ranks index records, then caches stable
/// file-object pages. The UI never receives the complete record candidate set.
class QueryAttachmentCoordinator {
  static const int _completeCandidateLimit = 0x7fffffff;
  final Parser parser;
  final MultimodalEmbeddingEngine embeddingEngine;
  final MultimodalVectorStore vectorStore;
  final FileRegistryStore? registryStore;
  final Map<String, _PreparedQueryUnit> _prepared = {};

  QueryAttachmentCoordinator({
    required this.parser,
    required this.embeddingEngine,
    required this.vectorStore,
    this.registryStore,
  });

  Future<QueryResponse> search(
    QueryRequest request, {
    void Function(String stage, int current, int total)? onProgress,
  }) async {
    if (request.resultLimit <= 0) {
      throw ArgumentError.value(request.resultLimit, 'resultLimit');
    }
    final description = request.description?.trim() ?? '';
    final fileType = request.fileTypeFilter?.trim();
    if (description.isEmpty && request.attachmentPaths.isEmpty) {
      throw ArgumentError(
        'A description or at least one attachment is required.',
      );
    }
    if (request.attachmentPaths.any((path) => path.trim().isEmpty)) {
      throw ArgumentError('附件路径不能为空。');
    }
    _prepared.clear();
    final units = <QueryUnitResult>[];
    var index = 0;
    final total =
        (description.isNotEmpty ? 1 : 0) + request.attachmentPaths.length;
    onProgress?.call('preparing', 0, total);
    if (description.isNotEmpty) {
      onProgress?.call('description', index + 1, total);
      units.add(
        await _descriptionUnit(
          'query-${index++}',
          description,
          request.resultLimit,
          fileType: fileType == null || fileType.isEmpty ? null : fileType,
          searchPaths: request.searchPaths,
          selection: request.informationSelection,
          summarySelection: request.summarySelection,
          fileTypeFilterEnabled: request.fileTypeFilterEnabled,
          allowedFileTypes: request.allowedFileTypes,
          includeOtherFileTypes: request.includeOtherFileTypes,
          knownFileTypes: request.knownFileTypes,
          relevanceScope: request.relevanceScope,
        ),
      );
    }
    for (final path in request.attachmentPaths) {
      onProgress?.call('attachment', index + 1, total);
      units.add(
        await _attachmentUnit(
          'query-${index++}',
          path.trim(),
          request.resultLimit,
          fileType: fileType == null || fileType.isEmpty ? null : fileType,
          searchPaths: request.searchPaths,
          selection: request.informationSelection,
          summarySelection: request.summarySelection,
          fileTypeFilterEnabled: request.fileTypeFilterEnabled,
          allowedFileTypes: request.allowedFileTypes,
          includeOtherFileTypes: request.includeOtherFileTypes,
          knownFileTypes: request.knownFileTypes,
          relevanceScope: request.relevanceScope,
        ),
      );
    }
    onProgress?.call('finalizing', total, total);
    return QueryResponse(units: List.unmodifiable(units));
  }

  Future<QueryUnitResult> page(String queryUnitId, int pageIndex) async {
    final unit = _prepared[queryUnitId];
    if (unit == null) throw StateError('查询结果已经失效，请重新查询。');
    return unit.page(pageIndex);
  }

  Future<QueryUnitResult> refine(
    String queryUnitId,
    FileQueryRefinement refinement,
  ) async {
    final unit = _prepared[queryUnitId];
    if (unit == null) throw StateError('查询结果已经失效，请重新查询。');
    return unit.refine(refinement);
  }

  Future<QueryUnitResult> _descriptionUnit(
    String id,
    String description,
    int pageSize, {
    String? fileType,
    List<String> searchPaths = const [],
    QueryInformationSelection selection = QueryInformationSelection.standard,
    QuerySummarySelection summarySelection = QuerySummarySelection.all,
    bool fileTypeFilterEnabled = false,
    Set<String> allowedFileTypes = const {},
    bool includeOtherFileTypes = false,
    Set<String> knownFileTypes = const {},
    RelevanceScope relevanceScope = RelevanceThresholdValues.defaultScope,
  }) async {
    try {
      if (selection.isEmpty) {
        final pagedStore = vectorStore is PagedFileQueryStore
            ? vectorStore as PagedFileQueryStore
            : null;
        if (pagedStore != null) {
          return _preparePaged(
            id: id,
            type: QueryUnitType.textDescription,
            label: description,
            attachment: null,
            pageSize: pageSize,
            issues: const [],
            page: await pagedStore.prepareFileQuery(
              vectors: const [],
              fileNameHits: await _fileNameHits(
                description,
                fileType: fileType,
              ),
              pageSize: pageSize,
              fileType: fileType,
              allowedFileObjectIds: await _allowedFileObjectIds(searchPaths),
              fileObjectOrder: await _fileObjectOrder(searchPaths),
              includeNativeText: false,
              includeExtractedText: false,
              fileTypeFilterEnabled: fileTypeFilterEnabled,
              allowedFileTypes: allowedFileTypes,
              includeOtherFileTypes: includeOtherFileTypes,
              knownFileTypes: knownFileTypes,
              relevanceScope: relevanceScope,
            ),
            store: pagedStore,
          );
        }
        return _prepare(
          id: id,
          type: QueryUnitType.textDescription,
          label: description,
          attachment: null,
          hits: _inFileTypes(
            _inPaths(
              await _fileNameHits(description, fileType: fileType),
              searchPaths,
            ),
            enabled: fileTypeFilterEnabled,
            allowed: allowedFileTypes,
            includeOther: includeOtherFileTypes,
            known: knownFileTypes,
          ),
          pageSize: pageSize,
          issues: const [],
        );
      }
      final vectors = await embeddingEngine.embedQuery(description);
      final generatedSummaryVectors =
          summarySelection.includes(QuerySummaryKind.contentSummary) ||
              selection.includes(QueryInformationKind.overallSummary)
          ? await embeddingEngine.embedGeneratedSummariesForText(
              description,
              includeContentSummaries: summarySelection.includes(
                QuerySummaryKind.contentSummary,
              ),
              includeOverallSummary: selection.includes(
                QueryInformationKind.overallSummary,
              ),
            )
          : const <EmbeddingResult>[];
      final pagedStore = vectorStore is PagedFileQueryStore
          ? vectorStore as PagedFileQueryStore
          : null;
      if (pagedStore != null) {
        return _preparePaged(
          id: id,
          type: QueryUnitType.textDescription,
          label: description,
          attachment: null,
          pageSize: pageSize,
          issues: const [],
          page: await pagedStore.prepareFileQuery(
            vectors: _descriptionVectors(
              vectors,
              description,
              selection,
              summarySelection,
              generatedSummaryVectors,
            ),
            fileNameHits: await _fileNameHits(description, fileType: fileType),
            pageSize: pageSize,
            fileType: fileType,
            allowedFileObjectIds: await _allowedFileObjectIds(searchPaths),
            fileObjectOrder: await _fileObjectOrder(searchPaths),
            includeNativeText: selection.includes(
              QueryInformationKind.nativeText,
            ),
            includeExtractedText: selection.includes(
              QueryInformationKind.extractedText,
            ),
            fileTypeFilterEnabled: fileTypeFilterEnabled,
            allowedFileTypes: allowedFileTypes,
            includeOtherFileTypes: includeOtherFileTypes,
            knownFileTypes: knownFileTypes,
            relevanceScope: relevanceScope,
          ),
          store: pagedStore,
        );
      }
      final results = await Future.wait<List<VectorSearchHit>>([
        _searchFileQueryVectors(
          _descriptionVectors(
            vectors,
            description,
            selection,
            summarySelection,
            generatedSummaryVectors,
          ),
          fileType: fileType,
        ),
        _fileNameHits(description, fileType: fileType),
      ]);
      return _prepare(
        id: id,
        type: QueryUnitType.textDescription,
        label: description,
        attachment: null,
        hits: _inFileTypes(
          results.expand((value) => _inPaths(value, searchPaths)),
          enabled: fileTypeFilterEnabled,
          allowed: allowedFileTypes,
          includeOther: includeOtherFileTypes,
          known: knownFileTypes,
        ),
        pageSize: pageSize,
        issues: const [],
      );
    } catch (error) {
      return _failed(
        id,
        QueryUnitType.textDescription,
        description,
        null,
        error,
      );
    }
  }

  Future<QueryUnitResult> _attachmentUnit(
    String id,
    String path,
    int pageSize, {
    String? fileType,
    List<String> searchPaths = const [],
    QueryInformationSelection selection = QueryInformationSelection.standard,
    QuerySummarySelection summarySelection = QuerySummarySelection.all,
    bool fileTypeFilterEnabled = false,
    Set<String> allowedFileTypes = const {},
    bool includeOtherFileTypes = false,
    Set<String> knownFileTypes = const {},
    RelevanceScope relevanceScope = RelevanceThresholdValues.defaultScope,
  }) async {
    FileObject? object;
    try {
      if (selection.isEmpty) {
        final pagedStore = vectorStore is PagedFileQueryStore
            ? vectorStore as PagedFileQueryStore
            : null;
        if (pagedStore != null) {
          return _preparePaged(
            id: id,
            type: QueryUnitType.fileAttachment,
            label: path,
            attachment: null,
            pageSize: pageSize,
            issues: const [],
            page: await pagedStore.prepareFileQuery(
              vectors: const [],
              fileNameHits: await _fileNameHits(
                path.split(RegExp(r'[/\\]')).last,
                fileType: fileType,
              ),
              pageSize: pageSize,
              fileType: fileType,
              allowedFileObjectIds: await _allowedFileObjectIds(searchPaths),
              fileObjectOrder: await _fileObjectOrder(searchPaths),
              includeNativeText: false,
              includeExtractedText: false,
              fileTypeFilterEnabled: fileTypeFilterEnabled,
              allowedFileTypes: allowedFileTypes,
              includeOtherFileTypes: includeOtherFileTypes,
              knownFileTypes: knownFileTypes,
              relevanceScope: relevanceScope,
            ),
            store: pagedStore,
          );
        }
        return _prepare(
          id: id,
          type: QueryUnitType.fileAttachment,
          label: path,
          attachment: null,
          hits: _inFileTypes(
            _inPaths(
              await _fileNameHits(
                path.split(RegExp(r'[/\\]')).last,
                fileType: fileType,
              ),
              searchPaths,
            ),
            enabled: fileTypeFilterEnabled,
            allowed: allowedFileTypes,
            includeOther: includeOtherFileTypes,
            known: knownFileTypes,
          ),
          pageSize: pageSize,
          issues: const [],
        );
      }
      final parsed = await parser.parse(path);
      object = FileObject.fromParsingResult(
        parsed,
        origin: FileObjectOrigin.queryAttachment,
      );
      final embeddings = await embeddingEngine.embedContent(
        object.content,
        summaryOptions: SummaryEmbeddingOptions(
          includeContentSummaries: summarySelection.includes(
            QuerySummaryKind.contentSummary,
          ),
          includeSemanticSummaries: summarySelection.includes(
            QuerySummaryKind.semanticSummary,
          ),
          includeOverallSummary: selection.includes(
            QueryInformationKind.overallSummary,
          ),
        ),
      );
      object = object.withEmbeddings(embeddings);
      final pagedStore = vectorStore is PagedFileQueryStore
          ? vectorStore as PagedFileQueryStore
          : null;
      if (pagedStore != null) {
        final terms = HybridRetriever.terms(object.text.value);
        return _preparePaged(
          id: id,
          type: QueryUnitType.fileAttachment,
          label: path,
          attachment: object,
          pageSize: pageSize,
          issues: [
            ...object.content.issues.map((issue) => issue.message),
            ...embeddings.issues.map((issue) => issue.message),
          ],
          page: await pagedStore.prepareFileQuery(
            vectors: _attachmentVectors(
              object,
              terms,
              selection,
              summarySelection,
            ),
            fileNameHits: await _fileNameHits(
              path.split(RegExp(r'[/\\]')).last,
              fileType: fileType,
            ),
            pageSize: pageSize,
            fileType: fileType,
            allowedFileObjectIds: await _allowedFileObjectIds(searchPaths),
            fileObjectOrder: await _fileObjectOrder(searchPaths),
            includeNativeText: selection.includes(
              QueryInformationKind.nativeText,
            ),
            includeExtractedText: selection.includes(
              QueryInformationKind.extractedText,
            ),
            fileTypeFilterEnabled: fileTypeFilterEnabled,
            allowedFileTypes: allowedFileTypes,
            includeOtherFileTypes: includeOtherFileTypes,
            knownFileTypes: knownFileTypes,
            relevanceScope: relevanceScope,
          ),
          store: pagedStore,
        );
      }
      final results = await Future.wait<List<VectorSearchHit>>([
        _searchFileQueryVectors(
          _attachmentVectors(
            object,
            HybridRetriever.terms(object.text.value),
            selection,
            summarySelection,
          ),
          fileType: fileType,
        ),
        _fileNameHits(path.split(RegExp(r'[/\\]')).last, fileType: fileType),
      ]);
      final issues = [
        ...object.content.issues.map((issue) => issue.message),
        ...embeddings.issues.map((issue) => issue.message),
      ];
      return _prepare(
        id: id,
        type: QueryUnitType.fileAttachment,
        label: path,
        attachment: object,
        hits: _inFileTypes(
          results.expand((value) => _inPaths(value, searchPaths)),
          enabled: fileTypeFilterEnabled,
          allowed: allowedFileTypes,
          includeOther: includeOtherFileTypes,
          known: knownFileTypes,
        ),
        pageSize: pageSize,
        issues: issues,
      );
    } catch (error) {
      return _failed(id, QueryUnitType.fileAttachment, path, object, error);
    }
  }

  Future<List<VectorSearchHit>> _searchFileQueryVectors(
    List<FileQueryVector> vectors, {
    String? fileType,
  }) async {
    final bestRecords = <String, VectorSearchHit>{};
    for (final vector in vectors) {
      final hits = await vectorStore.searchSpace(
        space: vector.space,
        embedding: vector.embedding,
        terms: vector.terms,
        limit: _completeCandidateLimit,
        fileType: fileType,
      );
      for (final hit in hits) {
        final recordKind = hit.metadata['recordKind'] as String? ?? 'raw';
        final informationKind = _hitInformationKind(hit);
        if (!vector.allowedRecordKinds.contains(recordKind)) continue;
        if (vector.allowedInformationKinds.isNotEmpty &&
            !vector.allowedInformationKinds.contains(informationKind)) {
          continue;
        }
        final previous = bestRecords[hit.id];
        if (previous == null || _isBetter(hit, previous)) {
          bestRecords[hit.id] = hit;
        }
      }
    }
    return bestRecords.values.toList(growable: false);
  }

  String _hitInformationKind(VectorSearchHit hit) {
    final explicit = hit.metadata['queryInformationKind'] as String?;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (hit.space == VectorSpaceKind.image) return 'image';
    if (hit.space == VectorSpaceKind.audio) return 'audio';
    final kind = hit.metadata['textInformationKind'] as String?;
    if (kind == 'fileName') return 'fileName';
    final method = hit.metadata['textExtractionMethod'] as String?;
    final extracted =
        method == 'ocr' ||
        method == 'speechRecognition' ||
        method == 'other' ||
        kind == 'ocr' ||
        kind == 'speechTranscript' ||
        kind == 'metadata';
    return extracted ? 'extractedText' : 'nativeText';
  }

  List<FileQueryVector> _descriptionVectors(
    MultimodalQueryEmbeddings vectors,
    String description,
    QueryInformationSelection selection,
    QuerySummarySelection summaries,
    List<EmbeddingResult> generatedSummaryVectors,
  ) {
    final result = <FileQueryVector>[];
    final textKinds = {
      if (selection.includes(QueryInformationKind.nativeText)) 'nativeText',
      if (selection.includes(QueryInformationKind.extractedText))
        'extractedText',
    };
    final terms = HybridRetriever.terms(description);
    if (textKinds.isNotEmpty) {
      result.add(
        FileQueryVector(
          space: VectorSpaceKind.text,
          embedding: vectors.textSearch.vector,
          terms: terms,
          allowedInformationKinds: textKinds,
        ),
      );
    }
    if (selection.includes(QueryInformationKind.image)) {
      result.add(
        FileQueryVector(
          space: VectorSpaceKind.image,
          embedding: vectors.imageSearch.vector,
          allowedInformationKinds: const {'image'},
        ),
      );
    }
    if (selection.includes(QueryInformationKind.audio)) {
      result.add(
        FileQueryVector(
          space: VectorSpaceKind.audio,
          embedding: vectors.audioSearch.vector,
          allowedInformationKinds: const {'audio'},
        ),
      );
    }
    if (summaries.includes(QuerySummaryKind.semanticSummary)) {
      if (textKinds.isNotEmpty) {
        result.add(
          FileQueryVector(
            space: VectorSpaceKind.text,
            embedding: vectors.textSearch.vector,
            allowedRecordKinds: const {'semanticSummary'},
            allowedInformationKinds: textKinds,
          ),
        );
      }
      if (selection.includes(QueryInformationKind.image)) {
        result.add(
          FileQueryVector(
            space: VectorSpaceKind.image,
            embedding: vectors.imageSearch.vector,
            allowedRecordKinds: const {'semanticSummary'},
            allowedInformationKinds: const {'image'},
          ),
        );
      }
      if (selection.includes(QueryInformationKind.audio)) {
        result.add(
          FileQueryVector(
            space: VectorSpaceKind.audio,
            embedding: vectors.audioSearch.vector,
            allowedRecordKinds: const {'semanticSummary'},
            allowedInformationKinds: const {'audio'},
          ),
        );
      }
    }
    final firstLevelKinds = {
      if (selection.includes(QueryInformationKind.nativeText)) 'nativeText',
      if (selection.includes(QueryInformationKind.extractedText))
        'extractedText',
      if (selection.includes(QueryInformationKind.image)) 'image',
      if (selection.includes(QueryInformationKind.audio)) 'audio',
    };
    for (final value in generatedSummaryVectors) {
      if (value.source.summaryKind == 'contentSummary' &&
          summaries.includes(QuerySummaryKind.contentSummary) &&
          firstLevelKinds.isNotEmpty) {
        result.add(
          FileQueryVector(
            space: VectorSpaceKind.text,
            embedding: value.vector,
            allowedRecordKinds: const {'contentSummary'},
            allowedInformationKinds: firstLevelKinds,
          ),
        );
      }
      if (value.source.summaryKind == 'overallSummary' &&
          selection.includes(QueryInformationKind.overallSummary)) {
        result.add(
          FileQueryVector(
            space: VectorSpaceKind.text,
            embedding: value.vector,
            allowedRecordKinds: const {'overallSummary'},
            allowedInformationKinds: const {'overallSummary'},
          ),
        );
      }
    }
    return result;
  }

  List<FileQueryVector> _attachmentVectors(
    FileObject object,
    List<String> terms,
    QueryInformationSelection selection,
    QuerySummarySelection summaries,
  ) {
    final result = <FileQueryVector>[];
    void add(
      VectorSpaceKind space,
      List<EmbeddingResult> values,
      Set<String> informationKinds,
    ) {
      for (final value in values) {
        final recordKind = value.source.summaryKind ?? 'raw';
        if (recordKind == 'semanticSummary' &&
            !summaries.includes(QuerySummaryKind.semanticSummary)) {
          continue;
        }
        if (recordKind != 'raw' && recordKind != 'semanticSummary') continue;
        result.add(
          FileQueryVector(
            space: space,
            embedding: value.vector,
            terms: recordKind == 'raw' && space == VectorSpaceKind.text
                ? terms
                : const [],
            allowedRecordKinds: {recordKind},
            allowedInformationKinds: informationKinds,
          ),
        );
      }
    }

    final textKinds = {
      if (selection.includes(QueryInformationKind.nativeText)) 'nativeText',
      if (selection.includes(QueryInformationKind.extractedText))
        'extractedText',
    };
    if (textKinds.isNotEmpty) {
      add(VectorSpaceKind.text, object.analysis.textEmbeddings, textKinds);
    }
    if (selection.includes(QueryInformationKind.image)) {
      add(VectorSpaceKind.image, object.analysis.imageEmbeddings, const {
        'image',
      });
    }
    if (selection.includes(QueryInformationKind.audio)) {
      add(VectorSpaceKind.audio, object.analysis.audioEmbeddings, const {
        'audio',
      });
    }
    final firstLevelKinds = {
      if (selection.includes(QueryInformationKind.nativeText)) 'nativeText',
      if (selection.includes(QueryInformationKind.extractedText))
        'extractedText',
      if (selection.includes(QueryInformationKind.image)) 'image',
      if (selection.includes(QueryInformationKind.audio)) 'audio',
    };
    for (final value in object.analysis.textEmbeddings) {
      if (value.source.summaryKind == 'contentSummary' &&
          summaries.includes(QuerySummaryKind.contentSummary) &&
          firstLevelKinds.isNotEmpty) {
        result.add(
          FileQueryVector(
            space: VectorSpaceKind.text,
            embedding: value.vector,
            allowedRecordKinds: const {'contentSummary'},
            allowedInformationKinds: firstLevelKinds,
          ),
        );
      }
      if (value.source.summaryKind == 'overallSummary' &&
          selection.includes(QueryInformationKind.overallSummary)) {
        result.add(
          FileQueryVector(
            space: VectorSpaceKind.text,
            embedding: value.vector,
            allowedRecordKinds: const {'overallSummary'},
            allowedInformationKinds: const {'overallSummary'},
          ),
        );
      }
    }
    return result;
  }

  Future<List<VectorSearchHit>> _fileNameHits(
    String query, {
    String? fileType,
  }) async {
    final store = registryStore;
    if (store == null) return const [];
    final terms = HybridRetriever.terms(query)
        .map((term) => term.toLowerCase())
        .where((term) => term.isNotEmpty)
        .toSet();
    if (terms.isEmpty) return const [];
    final normalizedType = fileType?.trim().toUpperCase();
    final entries = (await store.load()).values;
    final hits = <VectorSearchHit>[];
    for (final entry in entries) {
      final fileName = entry.path.split(RegExp(r'[/\\]')).last;
      final lowerName = fileName.toLowerCase();
      final matched = terms.where(lowerName.contains).length;
      if (matched == 0) continue;
      final extension = literalFileExtension(entry.path);
      if (normalizedType != null &&
          normalizedType.isNotEmpty &&
          extension != normalizedType) {
        continue;
      }
      hits.add(
        VectorSearchHit(
          id: '${entry.fileObjectId}:fileName',
          fileObjectId: entry.fileObjectId,
          sourcePath: entry.path,
          fileType: extension,
          space: VectorSpaceKind.text,
          document: fileName,
          distance: 1 - matched / terms.length,
          relevanceScore: matched / terms.length,
          vectorMatched: false,
          keywordMatched: true,
          metadata: {
            'queryInformationKind': 'fileName',
            'fileExtension': extension,
          },
        ),
      );
    }
    return hits;
  }

  Future<Set<String>?> _allowedFileObjectIds(List<String> paths) async {
    if (paths.isEmpty) return null;
    final store = registryStore;
    if (store == null) return <String>{};
    return (await store.load()).values
        .where(
          (entry) => paths.any(
            (root) => PathRules.isSameOrDescendant(entry.path, root),
          ),
        )
        .map((entry) => entry.fileObjectId)
        .toSet();
  }

  Future<List<String>> _fileObjectOrder(List<String> paths) async {
    final store = registryStore;
    if (store == null) return const [];
    final entries = (await store.load()).values;
    return entries
        .where(
          (entry) =>
              paths.isEmpty ||
              paths.any(
                (root) => PathRules.isSameOrDescendant(entry.path, root),
              ),
        )
        .map((entry) => entry.fileObjectId)
        .toList(growable: false);
  }

  QueryUnitResult _preparePaged({
    required String id,
    required QueryUnitType type,
    required String label,
    required FileObject? attachment,
    required int pageSize,
    required List<String> issues,
    required FileQueryPage page,
    required PagedFileQueryStore store,
  }) {
    final prepared = _PreparedQueryUnit.remote(
      id: id,
      type: type,
      label: label,
      attachment: attachment,
      pageSize: pageSize,
      issues: List.unmodifiable(issues),
      store: store,
      queryToken: page.queryToken,
    );
    _prepared[id] = prepared;
    return prepared.fromRemotePage(page);
  }

  QueryUnitResult _prepare({
    required String id,
    required QueryUnitType type,
    required String label,
    required FileObject? attachment,
    required Iterable<VectorSearchHit> hits,
    required int pageSize,
    required List<String> issues,
  }) {
    final bestByFile = <String, VectorSearchHit>{};
    for (final hit in hits) {
      final previous = bestByFile[hit.fileObjectId];
      if (previous == null || _isBetter(hit, previous)) {
        bestByFile[hit.fileObjectId] = hit;
      }
    }
    final files = bestByFile.values.toList()
      ..sort((left, right) {
        if (_isBetter(left, right)) return -1;
        if (_isBetter(right, left)) return 1;
        return left.fileObjectId.compareTo(right.fileObjectId);
      });
    final prepared = _PreparedQueryUnit(
      id: id,
      type: type,
      label: label,
      attachment: attachment,
      files: List.unmodifiable(files),
      pageSize: pageSize,
      issues: List.unmodifiable(issues),
    );
    _prepared[id] = prepared;
    return prepared.localPage(0);
  }

  QueryUnitResult _failed(
    String id,
    QueryUnitType type,
    String label,
    FileObject? attachment,
    Object error,
  ) => QueryUnitResult(
    queryUnitId: id,
    type: type,
    label: label,
    attachment: attachment,
    textResults: const [],
    imageResults: const [],
    audioResults: const [],
    status: QueryUnitStatus.failed,
    issues: ['$error'],
  );

  bool _isBetter(VectorSearchHit candidate, VectorSearchHit previous) {
    final candidateScore = candidate.relevanceScore;
    final previousScore = previous.relevanceScore;
    if (candidateScore != null || previousScore != null) {
      final order = (candidateScore ?? double.negativeInfinity).compareTo(
        previousScore ?? double.negativeInfinity,
      );
      if (order != 0) return order > 0;
    }
    if (candidate.distance != previous.distance) {
      return candidate.distance < previous.distance;
    }
    return candidate.id.compareTo(previous.id) < 0;
  }

  List<VectorSearchHit> _inPaths(
    List<VectorSearchHit> hits,
    List<String> paths,
  ) {
    if (paths.isEmpty) return hits;
    return hits
        .where(
          (hit) => paths.any(
            (root) => PathRules.isSameOrDescendant(hit.sourcePath, root),
          ),
        )
        .toList(growable: false);
  }

  List<VectorSearchHit> _inFileTypes(
    Iterable<VectorSearchHit> hits, {
    required bool enabled,
    required Set<String> allowed,
    required bool includeOther,
    required Set<String> known,
  }) {
    if (!enabled) return hits.toList(growable: false);
    final normalizedAllowed = allowed
        .map((value) => value.toUpperCase())
        .toSet();
    final normalizedKnown = known.map((value) => value.toUpperCase()).toSet();
    return hits
        .where((hit) {
          final type = _literalHitExtension(hit);
          if (normalizedAllowed.contains(type)) return true;
          return includeOther &&
              (type.isEmpty ||
                  type == 'UNKNOWN' ||
                  !normalizedKnown.contains(type));
        })
        .toList(growable: false);
  }
}

class _PreparedQueryUnit {
  final String id;
  final QueryUnitType type;
  final String label;
  final FileObject? attachment;
  final List<VectorSearchHit> files;
  final int pageSize;
  final List<String> issues;
  final PagedFileQueryStore? store;
  final String? queryToken;
  FileQueryRefinement refinement = const FileQueryRefinement();

  _PreparedQueryUnit({
    required this.id,
    required this.type,
    required this.label,
    required this.attachment,
    required this.files,
    required this.pageSize,
    required this.issues,
  }) : store = null,
       queryToken = null;

  _PreparedQueryUnit.remote({
    required this.id,
    required this.type,
    required this.label,
    required this.attachment,
    required this.pageSize,
    required this.issues,
    required this.store,
    required this.queryToken,
  }) : files = const [];

  Future<QueryUnitResult> page(int requestedPage) async {
    final remote = store;
    if (remote != null) {
      return fromRemotePage(
        await remote.loadFileQueryPage(queryToken!, requestedPage),
      );
    }
    return localPage(requestedPage);
  }

  Future<QueryUnitResult> refine(FileQueryRefinement value) async {
    refinement = value;
    final remote = store;
    if (remote case final RefinablePagedFileQueryStore refinable) {
      return fromRemotePage(
        await refinable.refineFileQuery(queryToken!, value),
      );
    }
    return localPage(0);
  }

  QueryUnitResult localPage(int requestedPage) {
    final viewed = _localView();
    final pageCount = viewed.isEmpty ? 1 : (viewed.length / pageSize).ceil();
    final pageIndex = requestedPage.clamp(0, pageCount - 1);
    final start = pageIndex * pageSize;
    final visible = viewed.skip(start).take(pageSize).toList(growable: false);
    return _result(
      visible,
      viewed.length,
      pageIndex,
      availableFileTypes: files.map(_literalHitExtension).toSet(),
    );
  }

  List<VectorSearchHit> _localView() {
    final known = refinement.knownFileTypes
        .map((value) => value.toUpperCase())
        .toSet();
    final allowed = refinement.allowedFileTypes
        .map((value) => value.toUpperCase())
        .toSet();
    final viewed = files
        .where((hit) {
          if (!refinement.fileTypeFilterEnabled) return true;
          final value = _literalHitExtension(hit);
          return allowed.contains(value) ||
              (refinement.includeOtherFileTypes &&
                  (value.isEmpty ||
                      value == 'UNKNOWN' ||
                      !known.contains(value)));
        })
        .toList(growable: false);
    switch (refinement.sort) {
      case 'extension':
        viewed.sort((a, b) {
          final type = _literalHitExtension(a)
              .compareTo(_literalHitExtension(b));
          return type != 0 ? type : a.sourcePath.compareTo(b.sourcePath);
        });
      case 'fileName':
        viewed.sort(
          (a, b) => a.sourcePath
              .split(RegExp(r'[/\\]'))
              .last
              .toLowerCase()
              .compareTo(
                b.sourcePath.split(RegExp(r'[/\\]')).last.toLowerCase(),
              ),
        );
      case 'path':
        viewed.sort(
          (a, b) =>
              a.sourcePath.toLowerCase().compareTo(b.sourcePath.toLowerCase()),
        );
    }
    return viewed;
  }

  QueryUnitResult fromRemotePage(FileQueryPage page) => _result(
    page.files,
    page.totalFiles,
    page.pageIndex,
    availableFileTypes: page.availableFileTypes,
    totalIsFinal: page.totalIsFinal,
    hasMore: page.hasMore,
  );

  QueryUnitResult _result(
    List<VectorSearchHit> visible,
    int totalFiles,
    int pageIndex, {
    Set<String> availableFileTypes = const {},
    bool totalIsFinal = true,
    bool hasMore = false,
  }) {
    return QueryUnitResult(
      queryUnitId: id,
      type: type,
      label: label,
      attachment: attachment,
      textResults: visible
          .where((hit) => hit.space == VectorSpaceKind.text)
          .toList(),
      imageResults: visible
          .where((hit) => hit.space == VectorSpaceKind.image)
          .toList(),
      audioResults: visible
          .where((hit) => hit.space == VectorSpaceKind.audio)
          .toList(),
      status: issues.isEmpty
          ? QueryUnitStatus.completed
          : QueryUnitStatus.partial,
      issues: issues,
      totalFiles: totalFiles,
      pageIndex: pageIndex,
      pageSize: pageSize,
      orderedFileResults: visible,
      availableFileTypes: availableFileTypes,
      totalIsFinal: totalIsFinal,
      hasMore: hasMore,
    );
  }
}

String _literalHitExtension(VectorSearchHit hit) {
  final stored = hit.metadata['fileExtension']?.toString().trim();
  if (stored != null && stored.isNotEmpty) return stored.toUpperCase();
  final literal = literalFileExtension(hit.sourcePath);
  if (literal.isNotEmpty) return literal;
  return hit.fileType.trim().toUpperCase() == 'UNKNOWN'
      ? ''
      : hit.fileType.trim().toUpperCase();
}

import '../domain/file_object.dart';
import '../storage/multimodal_vector_store.dart';
import '../configuration/retrieval/relevance_threshold_values.dart';
import 'query_file_type_options.dart';

enum QueryUnitType { textDescription, fileAttachment }

enum QueryUnitStatus { completed, partial, failed }

/// Optional content channels. File-name matching is an unconditional part of
/// every query and therefore is deliberately not represented as an option.
enum QueryInformationKind {
  nativeText,
  extractedText,
  image,
  audio,
  overallSummary,
}

enum QuerySummaryKind { contentSummary, semanticSummary }

class QuerySummarySelection {
  final Set<QuerySummaryKind> kinds;

  const QuerySummarySelection(this.kinds);

  static const none = QuerySummarySelection({});
  static const all = QuerySummarySelection({
    QuerySummaryKind.contentSummary,
    QuerySummaryKind.semanticSummary,
  });

  bool includes(QuerySummaryKind kind) => kinds.contains(kind);
  bool get isEmpty => kinds.isEmpty;
}

class QueryInformationSelection {
  final Set<QueryInformationKind> kinds;

  const QueryInformationSelection(this.kinds);

  static const fileNameOnly = QueryInformationSelection({});

  static const standard = QueryInformationSelection({
    QueryInformationKind.nativeText,
    QueryInformationKind.extractedText,
  });

  static const all = QueryInformationSelection({
    QueryInformationKind.nativeText,
    QueryInformationKind.extractedText,
    QueryInformationKind.image,
    QueryInformationKind.audio,
    QueryInformationKind.overallSummary,
  });

  bool includes(QueryInformationKind kind) => kinds.contains(kind);
  bool get isEmpty => kinds.isEmpty;
}

class QueryRequest {
  final String? description;
  final List<String> attachmentPaths;
  final int resultLimit;
  final String? fileTypeFilter;
  final bool fileTypeFilterEnabled;
  final Set<String> allowedFileTypes;
  final bool includeOtherFileTypes;
  final Set<String> knownFileTypes;
  final List<String> searchPaths;
  final QueryInformationSelection informationSelection;
  final QuerySummarySelection summarySelection;
  final RelevanceScope relevanceScope;

  const QueryRequest({
    this.description,
    this.attachmentPaths = const [],
    this.resultLimit = 6,
    this.fileTypeFilter,
    this.fileTypeFilterEnabled = false,
    this.allowedFileTypes = const {},
    this.includeOtherFileTypes = false,
    this.knownFileTypes = QueryFileTypeOptions.known,
    this.searchPaths = const [],
    this.informationSelection = QueryInformationSelection.standard,
    this.summarySelection = QuerySummarySelection.all,
    this.relevanceScope = RelevanceThresholdValues.defaultScope,
  });
}

class QueryUnitResult {
  final String queryUnitId;
  final QueryUnitType type;
  final String label;
  final FileObject? attachment;
  final List<VectorSearchHit> textResults;
  final List<VectorSearchHit> imageResults;
  final List<VectorSearchHit> audioResults;
  final QueryUnitStatus status;
  final List<String> issues;
  final int totalFiles;
  final int pageIndex;
  final int pageSize;
  final List<VectorSearchHit> orderedFileResults;
  final Set<String> availableFileTypes;
  final bool totalIsFinal;
  final bool hasMore;

  const QueryUnitResult({
    required this.queryUnitId,
    required this.type,
    required this.label,
    required this.attachment,
    required this.textResults,
    required this.imageResults,
    required this.audioResults,
    required this.status,
    required this.issues,
    this.totalFiles = 0,
    this.pageIndex = 0,
    this.pageSize = 6,
    this.orderedFileResults = const [],
    this.availableFileTypes = const {},
    this.totalIsFinal = true,
    this.hasMore = false,
  });

  List<VectorSearchHit> get fileResults => orderedFileResults.isNotEmpty
      ? orderedFileResults
      : List.unmodifiable([...textResults, ...imageResults, ...audioResults]);

  int get pageCount {
    final known = totalFiles == 0 ? 1 : (totalFiles / pageSize).ceil();
    return hasMore && known <= pageIndex + 1 ? pageIndex + 2 : known;
  }
}

class QueryResponse {
  final List<QueryUnitResult> units;

  const QueryResponse({required this.units});
}

class IndexedChunk {
  final String id;
  final String text;
  final String sourcePath;
  final String fileType;
  final int chunkIndex;
  final int? pageIndex;
  final int? startOffset;
  final int? endOffset;
  final List<double> embedding;

  const IndexedChunk({
    required this.id,
    required this.text,
    required this.sourcePath,
    required this.fileType,
    required this.chunkIndex,
    required this.embedding,
    this.pageIndex,
    this.startOffset,
    this.endOffset,
  });

  Map<String, Object> toJson() => {
    'id': id,
    'text': text,
    'embedding': embedding,
    'metadata': {
      'sourcePath': sourcePath,
      'fileType': fileType,
      'chunkIndex': chunkIndex,
      'pageIndex': ?pageIndex,
      'startOffset': ?startOffset,
      'endOffset': ?endOffset,
    },
  };
}

class SearchCandidate {
  final String id;
  final String text;
  final String sourcePath;
  final String fileType;
  final int chunkIndex;
  final int? pageIndex;
  final int? startOffset;
  final int? endOffset;
  final double? distance;

  const SearchCandidate({
    required this.id,
    required this.text,
    required this.sourcePath,
    required this.fileType,
    required this.chunkIndex,
    this.pageIndex,
    this.startOffset,
    this.endOffset,
    this.distance,
  });

  factory SearchCandidate.fromJson(Map<String, dynamic> json) {
    final metadata = Map<String, dynamic>.from(json['metadata'] as Map);
    return SearchCandidate(
      id: json['id'] as String,
      text: json['text'] as String,
      sourcePath: metadata['sourcePath'] as String,
      fileType: metadata['fileType'] as String,
      chunkIndex: metadata['chunkIndex'] as int,
      pageIndex: metadata['pageIndex'] as int?,
      startOffset: metadata['startOffset'] as int?,
      endOffset: metadata['endOffset'] as int?,
      distance: (json['distance'] as num?)?.toDouble(),
    );
  }
}

class SearchResult {
  final SearchCandidate candidate;
  final double score;
  final bool vectorMatched;
  final bool keywordMatched;

  const SearchResult({
    required this.candidate,
    required this.score,
    required this.vectorMatched,
    required this.keywordMatched,
  });
}

class CandidateSet {
  final List<SearchCandidate> vector;
  final List<SearchCandidate> keyword;

  const CandidateSet({required this.vector, required this.keyword});
}

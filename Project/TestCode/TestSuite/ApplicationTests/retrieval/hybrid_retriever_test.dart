import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/retrieval/hybrid_retriever.dart';
import 'package:retrieval/retrieval/retrieval_models.dart';

void main() {
  const a = SearchCandidate(
    id: 'a',
    text: 'alpha',
    sourcePath: 'a.txt',
    fileType: 'TXT',
    chunkIndex: 0,
  );
  const b = SearchCandidate(
    id: 'b',
    text: 'beta',
    sourcePath: 'b.pdf',
    fileType: 'PDF',
    chunkIndex: 0,
  );

  test('combines matching vector and keyword candidates', () {
    final result = HybridRetriever.fuse(
      const CandidateSet(vector: [a, b], keyword: [b]),
    );
    expect(result.first.candidate.id, 'b');
    expect(result.first.vectorMatched, isTrue);
    expect(result.first.keywordMatched, isTrue);
    expect(result.length, 2);
  });

  test('filters by file type', () {
    final result = HybridRetriever.fuse(
      const CandidateSet(vector: [a, b], keyword: []),
      fileType: 'pdf',
    );
    expect(result.single.candidate.id, 'b');
  });

  test('rejects invalid limit', () {
    expect(
      () => HybridRetriever.fuse(
        const CandidateSet(vector: [], keyword: []),
        limit: 0,
      ),
      throwsArgumentError,
    );
  });

  test('deduplicates query terms', () {
    expect(HybridRetriever.terms(' BERT  bert retrieval '), [
      'bert',
      'retrieval',
    ]);
  });
}

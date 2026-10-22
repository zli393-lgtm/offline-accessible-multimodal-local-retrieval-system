import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/retrieval/multimodal_hybrid_retriever.dart';
import 'package:retrieval/storage/multimodal_vector_store.dart';

void main() {
  const semanticOnly = VectorSearchHit(
    id: 'semantic',
    fileObjectId: 'file-semantic',
    sourcePath: 'semantic.txt',
    fileType: 'TXT',
    space: VectorSpaceKind.text,
    document: 'semantic result',
    distance: 0.01,
    metadata: {},
  );
  const bothChannels = VectorSearchHit(
    id: 'both',
    fileObjectId: 'file-both',
    sourcePath: 'both.pdf',
    fileType: 'PDF',
    space: VectorSpaceKind.text,
    document: 'hybrid result',
    distance: 0.2,
    metadata: {},
  );

  test('RRF ranks a two-channel hit before a closer vector-only hit', () {
    final results = MultimodalHybridRetriever.fuse(
      const VectorCandidateSet(
        vector: [semanticOnly, bothChannels],
        keyword: [bothChannels],
      ),
    );

    expect(results.first.id, 'both');
    expect(results.first.vectorMatched, isTrue);
    expect(results.first.keywordMatched, isTrue);
    expect(results.last.keywordMatched, isFalse);
  });

  test('filters the fused result by file type', () {
    final results = MultimodalHybridRetriever.fuse(
      const VectorCandidateSet(
        vector: [semanticOnly, bothChannels],
        keyword: [bothChannels],
      ),
      fileType: 'pdf',
    );

    expect(results.single.id, 'both');
  });

  test('rejects a non-positive limit', () {
    expect(
      () => MultimodalHybridRetriever.fuse(
        const VectorCandidateSet(vector: [], keyword: []),
        limit: 0,
      ),
      throwsArgumentError,
    );
  });
}

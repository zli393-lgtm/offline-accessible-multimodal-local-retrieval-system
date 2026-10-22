import 'embedding_result.dart';
import 'source_reference.dart';

abstract class EmbeddingEngine {
  Future<EmbeddingResult> embedText({
    required String text,
    required SourceReference source,
  });

  Future<List<EmbeddingResult>> embedTextBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  });

  /// Embeds arbitrarily long text inputs after model-aware chunking.
  Future<List<EmbeddingResult>> embedLongTextBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  });
}

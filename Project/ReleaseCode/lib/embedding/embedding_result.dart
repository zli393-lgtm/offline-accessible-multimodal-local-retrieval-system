import 'embedding_space.dart';
import 'source_reference.dart';

class EmbeddingResult {
  final List<double> vector;
  final EmbeddingSpace space;
  final EmbeddingModality modality;
  final String model;
  final SourceReference source;

  const EmbeddingResult({
    required this.vector,
    required this.space,
    required this.modality,
    required this.model,
    required this.source,
  });

  int get dimensions => vector.length;
}

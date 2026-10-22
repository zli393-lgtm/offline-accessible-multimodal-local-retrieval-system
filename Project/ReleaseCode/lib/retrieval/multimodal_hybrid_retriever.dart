import '../storage/multimodal_vector_store.dart';

/// Fuses semantic and keyword rankings without comparing their raw scores.
///
/// Chroma cosine distances and keyword matches use different scales, so the
/// active multimodal query path uses reciprocal-rank fusion just like the
/// earlier text-only retrieval prototype.
class MultimodalHybridRetriever {
  const MultimodalHybridRetriever._();

  static List<VectorSearchHit> fuse(
    VectorCandidateSet candidates, {
    int limit = 10,
    String? fileType,
  }) {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    final normalizedType = fileType?.trim().toUpperCase();
    final byId = <String, VectorSearchHit>{};
    final scores = <String, double>{};
    final vectorIds = <String>{};
    final keywordIds = <String>{};

    void addChannel(List<VectorSearchHit> channel, Set<String> matchedIds) {
      for (var index = 0; index < channel.length; index++) {
        final hit = channel[index];
        byId.putIfAbsent(hit.id, () => hit);
        matchedIds.add(hit.id);
        scores[hit.id] = (scores[hit.id] ?? 0) + 1 / (60 + index + 1);
      }
    }

    addChannel(candidates.vector, vectorIds);
    addChannel(candidates.keyword, keywordIds);

    final results =
        scores.entries
            .where((entry) {
              if (normalizedType == null || normalizedType.isEmpty) return true;
              return byId[entry.key]!.fileType.toUpperCase() == normalizedType;
            })
            .map(
              (entry) => byId[entry.key]!.withRanking(
                relevanceScore: entry.value,
                vectorMatched: vectorIds.contains(entry.key),
                keywordMatched: keywordIds.contains(entry.key),
              ),
            )
            .toList()
          ..sort((left, right) {
            final scoreOrder = right.relevanceScore!.compareTo(
              left.relevanceScore!,
            );
            if (scoreOrder != 0) return scoreOrder;
            final distanceOrder = left.distance.compareTo(right.distance);
            return distanceOrder != 0
                ? distanceOrder
                : left.id.compareTo(right.id);
          });
    return results.take(limit).toList(growable: false);
  }
}

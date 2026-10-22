import 'retrieval_models.dart';

class HybridRetriever {
  /// Reciprocal-rank fusion avoids combining incomparable raw score scales.
  static List<SearchResult> fuse(
    CandidateSet candidates, {
    int limit = 10,
    String? fileType,
  }) {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    final byId = <String, SearchCandidate>{};
    final scores = <String, double>{};
    final vectorIds = <String>{};
    final keywordIds = <String>{};

    for (var i = 0; i < candidates.vector.length; i++) {
      final item = candidates.vector[i];
      byId[item.id] = item;
      vectorIds.add(item.id);
      scores[item.id] = (scores[item.id] ?? 0) + 1 / (60 + i + 1);
    }
    for (var i = 0; i < candidates.keyword.length; i++) {
      final item = candidates.keyword[i];
      byId.putIfAbsent(item.id, () => item);
      keywordIds.add(item.id);
      scores[item.id] = (scores[item.id] ?? 0) + 1 / (60 + i + 1);
    }

    final result =
        scores.entries
            .where(
              (entry) =>
                  fileType == null ||
                  byId[entry.key]!.fileType.toUpperCase() ==
                      fileType.toUpperCase(),
            )
            .map(
              (entry) => SearchResult(
                candidate: byId[entry.key]!,
                score: entry.value,
                vectorMatched: vectorIds.contains(entry.key),
                keywordMatched: keywordIds.contains(entry.key),
              ),
            )
            .toList()
          ..sort((a, b) {
            final scoreOrder = b.score.compareTo(a.score);
            return scoreOrder != 0
                ? scoreOrder
                : a.candidate.id.compareTo(b.candidate.id);
          });
    return result.take(limit).toList();
  }

  static List<String> terms(String query) => query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .toSet()
      .take(8)
      .toList();
}

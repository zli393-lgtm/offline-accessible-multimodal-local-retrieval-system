/// User-facing semantic match scopes.
///
/// These are deliberately independent from result ordering. A scope decides
/// whether a file may enter the result set; it does not request a global
/// similarity sort.
enum RelevanceScope { strict, standard, broad, unlimited }

/// Minimum raw cosine similarities for one match scope.
///
/// Chroma's cosine distance is converted with `similarity = 1 - distance`.
/// The values below are model-space values, not probabilities or accuracy
/// percentages. Keep every channel independent so later calibration of one
/// model cannot silently change another channel.
class RelevanceThresholdSet {
  final double nativeText;
  final double extractedText;
  final double image;
  final double audio;

  const RelevanceThresholdSet({
    required this.nativeText,
    required this.extractedText,
    required this.image,
    required this.audio,
  });
}

/// Central retrieval-value file for provisional semantic thresholds.
///
/// These initial values are engineering estimates based on the respective
/// model families and their cosine spaces. They have not been calibrated on a
/// representative user corpus. Replace values here after validation; do not
/// copy threshold literals into query, storage, or presentation code.
abstract final class RelevanceThresholdValues {
  static const RelevanceScope defaultScope = RelevanceScope.standard;

  // The first usable defaults divide the 0..1 cosine-similarity range into
  // four equal 25% bands.  They intentionally live only in this file so a
  // later corpus calibration changes values without changing query logic.
  static const RelevanceThresholdSet strict = RelevanceThresholdSet(
    nativeText: 0.75,
    extractedText: 0.75,
    image: 0.75,
    audio: 0.75,
  );

  static const RelevanceThresholdSet standard = RelevanceThresholdSet(
    nativeText: 0.50,
    extractedText: 0.50,
    image: 0.50,
    audio: 0.50,
  );

  static const RelevanceThresholdSet broad = RelevanceThresholdSet(
    nativeText: 0.25,
    extractedText: 0.25,
    image: 0.25,
    audio: 0.25,
  );

  /// Unlimited deliberately has no threshold set: no sentinel such as -1 or
  /// 0 is used, because either value could accidentally become a real filter.
  static RelevanceThresholdSet? forScope(RelevanceScope scope) =>
      switch (scope) {
        RelevanceScope.strict => strict,
        RelevanceScope.standard => standard,
        RelevanceScope.broad => broad,
        RelevanceScope.unlimited => null,
      };

  static double cosineSimilarityFromDistance(double cosineDistance) =>
      1 - cosineDistance;
}

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/configuration/retrieval/relevance_threshold_values.dart';

void main() {
  test('standard is the default relevance scope', () {
    expect(RelevanceThresholdValues.defaultScope, RelevanceScope.standard);
  });

  test('thresholds become less restrictive in scope order', () {
    final strict = RelevanceThresholdValues.strict;
    final standard = RelevanceThresholdValues.standard;
    final broad = RelevanceThresholdValues.broad;

    expect(strict.nativeText, greaterThan(standard.nativeText));
    expect(standard.nativeText, greaterThan(broad.nativeText));
    expect(strict.extractedText, greaterThan(standard.extractedText));
    expect(standard.extractedText, greaterThan(broad.extractedText));
    expect(strict.image, greaterThan(standard.image));
    expect(standard.image, greaterThan(broad.image));
    expect(strict.audio, greaterThan(standard.audio));
    expect(standard.audio, greaterThan(broad.audio));
  });

  test('unlimited has no accidental numeric cutoff', () {
    expect(RelevanceThresholdValues.forScope(RelevanceScope.unlimited), isNull);
  });

  test('converts Chroma cosine distance to cosine similarity', () {
    expect(RelevanceThresholdValues.cosineSimilarityFromDistance(0.28), 0.72);
  });
}

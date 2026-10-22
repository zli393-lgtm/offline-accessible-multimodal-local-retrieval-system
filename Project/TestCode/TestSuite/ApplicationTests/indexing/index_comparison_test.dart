import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/indexing/index_comparison.dart';

void main() {
  test('named presets select the specified comparison points', () {
    expect(
      const IndexComparisonOptions.none().preset,
      IndexComparisonPreset.none,
    );
    expect(
      const IndexComparisonOptions.quick().preset,
      IndexComparisonPreset.quick,
    );
    expect(
      const IndexComparisonOptions.standard().preset,
      IndexComparisonPreset.standard,
    );
    expect(
      const IndexComparisonOptions.advanced().preset,
      IndexComparisonPreset.advanced,
    );
    expect(
      const IndexComparisonOptions.complete().preset,
      IndexComparisonPreset.complete,
    );
  });

  test('an arbitrary combination is marked custom', () {
    const options = IndexComparisonOptions(
      path: false,
      size: true,
      modifiedTime: false,
      hash: true,
    );

    expect(options.preset, IndexComparisonPreset.custom);
  });
}

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/embedding/text/bert_pooling.dart';

void main() {
  group('BertPooling', () {
    test('mean pools valid tokens and ignores padding', () {
      final hiddenStates = Float32List.fromList([
        1.0,
        0.0,
        0.0,
        1.0,
        100.0,
        100.0,
      ]);

      final result = BertPooling.meanPoolAndNormalize(
        hiddenStates: hiddenStates,
        attentionMask: [1, 1, 0],
        hiddenSize: 2,
      );

      final expected = 1 / math.sqrt(2);

      expect(result.length, 2);
      expect(result[0], closeTo(expected, 1e-6));
      expect(result[1], closeTo(expected, 1e-6));
    });

    test('returns an L2 normalized embedding', () {
      final hiddenStates = Float32List.fromList([3.0, 4.0]);

      final result = BertPooling.meanPoolAndNormalize(
        hiddenStates: hiddenStates,
        attentionMask: [1],
        hiddenSize: 2,
      );

      expect(result[0], closeTo(0.6, 1e-6));
      expect(result[1], closeTo(0.8, 1e-6));

      final norm = math.sqrt(
        result.fold<double>(0.0, (sum, value) => sum + value * value),
      );

      expect(norm, closeTo(1.0, 1e-6));
    });

    test('rejects hidden state length that does not match mask', () {
      final hiddenStates = Float32List.fromList([1.0, 2.0, 3.0]);

      expect(
        () => BertPooling.meanPoolAndNormalize(
          hiddenStates: hiddenStates,
          attentionMask: [1, 1],
          hiddenSize: 2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects attention mask values other than zero or one', () {
      final hiddenStates = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);

      expect(
        () => BertPooling.meanPoolAndNormalize(
          hiddenStates: hiddenStates,
          attentionMask: [1, 2],
          hiddenSize: 2,
        ),
        throwsArgumentError,
      );
    });

    test('rejects attention mask with no valid tokens', () {
      final hiddenStates = Float32List.fromList([1.0, 2.0, 3.0, 4.0]);

      expect(
        () => BertPooling.meanPoolAndNormalize(
          hiddenStates: hiddenStates,
          attentionMask: [0, 0],
          hiddenSize: 2,
        ),
        throwsStateError,
      );
    });

    test('rejects zero vector after mean pooling', () {
      final hiddenStates = Float32List.fromList([0.0, 0.0, 0.0, 0.0]);

      expect(
        () => BertPooling.meanPoolAndNormalize(
          hiddenStates: hiddenStates,
          attentionMask: [1, 1],
          hiddenSize: 2,
        ),
        throwsStateError,
      );
    });
  });
}

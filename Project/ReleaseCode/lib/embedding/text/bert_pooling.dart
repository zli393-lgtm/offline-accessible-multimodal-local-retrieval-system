import 'dart:math' as math;
import 'dart:typed_data';

class BertPooling {
  const BertPooling._();

  static Float32List meanPoolAndNormalize({
    required Float32List hiddenStates,
    required List<int> attentionMask,
    required int hiddenSize,
  }) {
    if (hiddenSize <= 0) {
      throw ArgumentError.value(hiddenSize, 'hiddenSize', 'hiddenSize 必须大于 0。');
    }

    if (attentionMask.isEmpty) {
      throw ArgumentError('attentionMask 不能为空。');
    }

    final expectedLength = attentionMask.length * hiddenSize;

    if (hiddenStates.length != expectedLength) {
      throw ArgumentError(
        'hiddenStates 长度不正确。'
        '预期 $expectedLength，实际 ${hiddenStates.length}。',
      );
    }

    final sums = Float64List(hiddenSize);
    var validTokenCount = 0;

    for (var tokenIndex = 0; tokenIndex < attentionMask.length; tokenIndex++) {
      final maskValue = attentionMask[tokenIndex];

      if (maskValue != 0 && maskValue != 1) {
        throw ArgumentError('attentionMask 只能包含 0 或 1。');
      }

      if (maskValue == 0) {
        continue;
      }

      validTokenCount++;

      final baseIndex = tokenIndex * hiddenSize;

      for (var dimension = 0; dimension < hiddenSize; dimension++) {
        sums[dimension] += hiddenStates[baseIndex + dimension];
      }
    }

    if (validTokenCount == 0) {
      throw StateError('attentionMask 中没有有效 token。');
    }

    final means = Float64List(hiddenSize);
    var squaredNorm = 0.0;

    for (var dimension = 0; dimension < hiddenSize; dimension++) {
      final mean = sums[dimension] / validTokenCount;

      means[dimension] = mean;
      squaredNorm += mean * mean;
    }

    final norm = math.sqrt(squaredNorm);

    if (!norm.isFinite || norm == 0.0) {
      throw StateError('无法对零向量或无效向量进行 L2 Normalization。');
    }

    final normalized = Float32List(hiddenSize);

    for (var dimension = 0; dimension < hiddenSize; dimension++) {
      normalized[dimension] = means[dimension] / norm;
    }

    return normalized;
  }
}

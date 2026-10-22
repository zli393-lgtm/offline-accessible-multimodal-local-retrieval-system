import 'dart:typed_data';

import 'package:flutter_litert/flutter_litert.dart';

class BertTfliteRunner {
  static const String modelAssetPath =
      'assets/models/bert/bert_base_uncased_dynamic.tflite';

  static const int maxSequenceLength = 512;

  final Interpreter _interpreter;
  final int hiddenSize;

  BertTfliteRunner._(this._interpreter, {required this.hiddenSize});

  static Future<BertTfliteRunner> load() async {
    final interpreter = await Interpreter.fromAsset(modelAssetPath);

    interpreter.allocateTensors();

    final inputTensors = interpreter.getInputTensors();
    final outputTensors = interpreter.getOutputTensors();

    if (inputTensors.length != 3) {
      interpreter.close();

      throw StateError(
        'BERT TFLite 模型应有 3 个输入，'
        '实际为 ${inputTensors.length}。',
      );
    }

    if (outputTensors.length != 1) {
      interpreter.close();

      throw StateError(
        'BERT TFLite 模型应有 1 个输出，'
        '实际为 ${outputTensors.length}。',
      );
    }

    for (final tensor in inputTensors) {
      if (tensor.shape.length != 2) {
        interpreter.close();

        throw StateError(
          'BERT 输入 Tensor 必须是二维 Tensor：'
          '${tensor.name} ${tensor.shape}',
        );
      }
    }

    final outputShape = outputTensors.first.shape;

    if (outputShape.length != 3 || outputShape[2] <= 0) {
      interpreter.close();

      throw StateError('BERT 输出 Tensor 形状不正确：$outputShape');
    }

    return BertTfliteRunner._(interpreter, hiddenSize: outputShape[2]);
  }

  int get sequenceLength => maxSequenceLength;

  Float32List run({
    required Int32List inputIds,
    required Int32List attentionMask,
    required Int32List tokenTypeIds,
  }) {
    if (inputIds.isEmpty) {
      throw ArgumentError('inputIds 不能为空。');
    }

    return runBatch(
      batchSize: 1,
      actualSequenceLength: inputIds.length,
      inputIds: inputIds,
      attentionMask: attentionMask,
      tokenTypeIds: tokenTypeIds,
    );
  }

  Float32List runBatch({
    required int batchSize,
    required int actualSequenceLength,
    required Int32List inputIds,
    required Int32List attentionMask,
    required Int32List tokenTypeIds,
  }) {
    if (batchSize <= 0) {
      throw ArgumentError.value(batchSize, 'batchSize', 'batchSize 必须大于 0。');
    }

    if (actualSequenceLength <= 0 || actualSequenceLength > maxSequenceLength) {
      throw ArgumentError.value(
        actualSequenceLength,
        'actualSequenceLength',
        '实际 sequence length 必须位于 1 到 '
            '$maxSequenceLength 之间。',
      );
    }

    final expectedInputLength = batchSize * actualSequenceLength;

    _validateInputLength(inputIds, expectedInputLength, 'inputIds');

    _validateInputLength(attentionMask, expectedInputLength, 'attentionMask');

    _validateInputLength(tokenTypeIds, expectedInputLength, 'tokenTypeIds');

    _resizeInputs(batchSize: batchSize, sequenceLength: actualSequenceLength);

    final inputTensors = _interpreter.getInputTensors();

    final expectedInputShape = [batchSize, actualSequenceLength];

    for (final tensor in inputTensors) {
      if (!_sameShape(tensor.shape, expectedInputShape)) {
        throw StateError(
          'BERT 输入 Tensor 形状不正确。'
          '预期 $expectedInputShape，'
          '实际 ${tensor.shape}。',
        );
      }
    }

    final inputs = <Object>[];

    for (final tensor in inputTensors) {
      final name = tensor.name;

      if (name.contains('attention_mask')) {
        inputs.add(attentionMask);
      } else if (name.contains('input_ids')) {
        inputs.add(inputIds);
      } else if (name.contains('token_type_ids')) {
        inputs.add(tokenTypeIds);
      } else {
        throw StateError('发现无法识别的 BERT 输入 Tensor：$name');
      }
    }

    final output = Float32List(batchSize * actualSequenceLength * hiddenSize);

    _interpreter.runForMultipleInputs(inputs, {0: output});

    final outputTensor = _interpreter.getOutputTensor(0);

    final expectedOutputShape = [batchSize, actualSequenceLength, hiddenSize];

    if (!_sameShape(outputTensor.shape, expectedOutputShape)) {
      throw StateError(
        'BERT 推理后的输出 Tensor 形状不正确。'
        '预期 $expectedOutputShape，'
        '实际 ${outputTensor.shape}。',
      );
    }

    return output;
  }

  void _resizeInputs({required int batchSize, required int sequenceLength}) {
    final inputTensors = _interpreter.getInputTensors();

    final expectedShape = [batchSize, sequenceLength];

    final alreadyCorrect = inputTensors.every(
      (tensor) => _sameShape(tensor.shape, expectedShape),
    );

    if (alreadyCorrect) {
      return;
    }

    for (var inputIndex = 0; inputIndex < inputTensors.length; inputIndex++) {
      _interpreter.resizeInputTensor(inputIndex, expectedShape);
    }

    _interpreter.allocateTensors();
  }

  void _validateInputLength(Int32List values, int expectedLength, String name) {
    if (values.length != expectedLength) {
      throw ArgumentError(
        '$name 长度必须为 $expectedLength，'
        '实际为 ${values.length}。',
      );
    }
  }

  static bool _sameShape(List<int> actual, List<int> expected) {
    if (actual.length != expected.length) {
      return false;
    }

    for (var index = 0; index < actual.length; index++) {
      if (actual[index] != expected[index]) {
        return false;
      }
    }

    return true;
  }

  void close() {
    _interpreter.close();
  }
}

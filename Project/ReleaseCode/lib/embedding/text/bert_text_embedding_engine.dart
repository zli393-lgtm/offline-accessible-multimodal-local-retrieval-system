import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../embedding_engine.dart';
import '../embedding_result.dart';
import '../embedding_space.dart';
import '../source_reference.dart';
import 'bert_pooling.dart';
import 'bert_tflite_runner.dart';
import 'bert_tokenizer.dart';
import 'text_chunker.dart';

class BertTextEmbeddingEngine implements EmbeddingEngine {
  static const String tokenizerAssetPath = 'assets/models/bert/tokenizer.json';
  static const int defaultInferenceBatchSize = 8;

  final BertTokenizer _tokenizer;
  final BertTfliteRunner _runner;

  bool _closed = false;

  BertTextEmbeddingEngine._(this._tokenizer, this._runner);

  static Future<BertTextEmbeddingEngine> load() async {
    final tokenizerData = await rootBundle.load(tokenizerAssetPath);

    final tokenizerBytes = tokenizerData.buffer.asUint8List(
      tokenizerData.offsetInBytes,
      tokenizerData.lengthInBytes,
    );

    final tokenizer = BertTokenizer.fromBytes(tokenizerBytes);

    try {
      final runner = await BertTfliteRunner.load();

      return BertTextEmbeddingEngine._(tokenizer, runner);
    } catch (_) {
      tokenizer.close();
      rethrow;
    }
  }

  int get sequenceLength => BertTfliteRunner.maxSequenceLength;

  int get hiddenSize => _runner.hiddenSize;

  late final TextChunker _chunker = TextChunker(tokenizer: _tokenizer);

  @override
  Future<EmbeddingResult> embedText({
    required String text,
    required SourceReference source,
  }) async {
    final results = await embedTextBatch(texts: [text], sources: [source]);

    return results.single;
  }

  @override
  Future<List<EmbeddingResult>> embedTextBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) async {
    _ensureOpen();

    if (texts.length != sources.length) {
      throw ArgumentError(
        'texts 和 sources 数量必须一致。'
        'texts=${texts.length}，sources=${sources.length}。',
      );
    }

    if (texts.isEmpty) {
      return const <EmbeddingResult>[];
    }

    final encodedTexts = <List<int>>[];
    var actualSequenceLength = 0;

    for (var batchIndex = 0; batchIndex < texts.length; batchIndex++) {
      final text = texts[batchIndex];

      if (text.trim().isEmpty) {
        throw ArgumentError(
          '第 $batchIndex 个文本为空，'
          '不能生成 BERT embedding。',
        );
      }

      final tokenIds = _tokenizer.encode(text, addSpecialTokens: true);

      if (tokenIds.length > sequenceLength) {
        throw ArgumentError(
          '第 $batchIndex 个文本产生 '
          '${tokenIds.length} 个 BERT token，'
          '超过模型输入上限 $sequenceLength。'
          '长文本必须先经过 TextChunker。',
        );
      }

      encodedTexts.add(tokenIds);

      if (tokenIds.length > actualSequenceLength) {
        actualSequenceLength = tokenIds.length;
      }
    }

    final batchSize = texts.length;

    final totalInputLength = batchSize * actualSequenceLength;

    final inputIds = Int32List(totalInputLength);
    final attentionMask = Int32List(totalInputLength);
    final tokenTypeIds = Int32List(totalInputLength);

    final padTokenId = _tokenizer.padTokenId;

    for (var batchIndex = 0; batchIndex < batchSize; batchIndex++) {
      final tokenIds = encodedTexts[batchIndex];

      final rowStart = batchIndex * actualSequenceLength;

      final rowEnd = rowStart + actualSequenceLength;

      for (var index = rowStart; index < rowEnd; index++) {
        inputIds[index] = padTokenId;
      }

      for (var tokenIndex = 0; tokenIndex < tokenIds.length; tokenIndex++) {
        final flatIndex = rowStart + tokenIndex;

        inputIds[flatIndex] = tokenIds[tokenIndex];

        attentionMask[flatIndex] = 1;
      }
    }

    final hiddenStates = _runner.runBatch(
      batchSize: batchSize,
      actualSequenceLength: actualSequenceLength,
      inputIds: inputIds,
      attentionMask: attentionMask,
      tokenTypeIds: tokenTypeIds,
    );

    final hiddenValuesPerItem = actualSequenceLength * hiddenSize;

    final results = <EmbeddingResult>[];

    for (var batchIndex = 0; batchIndex < batchSize; batchIndex++) {
      final hiddenStart = batchIndex * hiddenValuesPerItem;

      final itemHiddenStates = Float32List(hiddenValuesPerItem);

      itemHiddenStates.setRange(
        0,
        hiddenValuesPerItem,
        hiddenStates,
        hiddenStart,
      );

      final maskStart = batchIndex * actualSequenceLength;

      final maskEnd = maskStart + actualSequenceLength;

      final itemAttentionMask = attentionMask.sublist(maskStart, maskEnd);

      final embedding = BertPooling.meanPoolAndNormalize(
        hiddenStates: itemHiddenStates,
        attentionMask: itemAttentionMask,
        hiddenSize: hiddenSize,
      );

      results.add(
        EmbeddingResult(
          vector: embedding,
          space: EmbeddingSpace.bertText,
          modality: EmbeddingModality.text,
          model: 'bert-base-uncased-tflite',
          source: sources[batchIndex],
        ),
      );
    }

    return results;
  }

  @override
  Future<List<EmbeddingResult>> embedLongTextBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) async {
    _ensureOpen();
    if (texts.length != sources.length) {
      throw ArgumentError(
        'texts 和 sources 数量必须一致。'
        'texts=${texts.length}，sources=${sources.length}。',
      );
    }
    final chunks = <String>[];
    final chunkSources = <SourceReference>[];
    for (
      var informationIndex = 0;
      informationIndex < texts.length;
      informationIndex++
    ) {
      final text = texts[informationIndex];
      if (text.trim().isEmpty) {
        continue;
      }
      final parts = _chunker.chunk(text);
      for (var chunkIndex = 0; chunkIndex < parts.length; chunkIndex++) {
        final part = parts[chunkIndex];
        chunks.add(part.text);
        chunkSources.add(
          sources[informationIndex].copyWith(
            chunkIndex: chunkIndex,
            startOffset: part.startOffset,
            endOffset: part.endOffset,
          ),
        );
      }
    }
    final results = <EmbeddingResult>[];
    for (
      var offset = 0;
      offset < chunks.length;
      offset += defaultInferenceBatchSize
    ) {
      // Let Flutter process paint, window, pause, and stop events between
      // bounded native inference batches.
      await Future<void>.delayed(Duration.zero);
      final end = (offset + defaultInferenceBatchSize).clamp(0, chunks.length);
      results.addAll(
        await embedTextBatch(
          texts: chunks.sublist(offset, end),
          sources: chunkSources.sublist(offset, end),
        ),
      );
    }
    return results;
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('BertTextEmbeddingEngine 已经关闭。');
    }
  }

  void close() {
    if (_closed) {
      return;
    }

    _closed = true;
    _runner.close();
    _tokenizer.close();
  }
}

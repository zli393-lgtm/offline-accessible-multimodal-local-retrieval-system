import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/embedding/embedding_space.dart';
import 'package:retrieval/embedding/source_reference.dart';
import 'package:retrieval/embedding/text/bert_text_embedding_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BertTextEmbeddingEngine', () {
    late BertTextEmbeddingEngine engine;

    setUpAll(() async {
      engine = await BertTextEmbeddingEngine.load();
    });

    tearDownAll(() {
      engine.close();
    });

    test('loads full dynamic-batch BERT TFLite model configuration', () {
      expect(engine.sequenceLength, 512);
      expect(engine.hiddenSize, 768);
    });

    test(
      'generates normalized 768-dimensional embedding on local CPU',
      () async {
        const source = SourceReference(
          sourcePath: 'test_document.txt',
          chunkIndex: 0,
          startOffset: 0,
          endOffset: 29,
        );

        final result = await engine.embedText(
          text: 'local semantic retrieval test',
          source: source,
        );

        expect(result.space, EmbeddingSpace.bertText);
        expect(result.modality, EmbeddingModality.text);
        expect(result.model, 'bert-base-uncased-tflite');
        expect(result.vector.length, 768);

        final norm = math.sqrt(
          result.vector.fold<double>(0.0, (sum, value) => sum + value * value),
        );

        expect(norm, closeTo(1.0, 1e-5));

        expect(result.source.sourcePath, 'test_document.txt');

        expect(result.source.chunkIndex, 0);
        expect(result.source.startOffset, 0);
        expect(result.source.endOffset, 29);
      },
    );

    test(
      'generates multiple embeddings in one real TFLite batch inference',
      () async {
        const texts = [
          'local semantic retrieval test',
          'multimodal embedding engine development',
        ];

        const sources = [
          SourceReference(sourcePath: 'document_a.txt', chunkIndex: 0),
          SourceReference(sourcePath: 'document_b.txt', chunkIndex: 0),
        ];

        final stopwatch = Stopwatch()..start();

        final results = await engine.embedTextBatch(
          texts: texts,
          sources: sources,
        );

        stopwatch.stop();

        expect(results.length, 2);

        for (final result in results) {
          expect(result.space, EmbeddingSpace.bertText);
          expect(result.vector.length, 768);

          final norm = math.sqrt(
            result.vector.fold<double>(
              0.0,
              (sum, value) => sum + value * value,
            ),
          );

          expect(norm, closeTo(1.0, 1e-5));
        }

        expect(results[0].source.sourcePath, 'document_a.txt');

        expect(results[1].source.sourcePath, 'document_b.txt');

        expect(results[0].vector, isNot(equals(results[1].vector)));

        print(
          'FLUTTER BERT BATCH INFERENCE OK '
          '| batch_size=2 '
          '| dimensions=768 '
          '| elapsed_ms=${stopwatch.elapsedMilliseconds}',
        );
      },
    );

    test('returns empty result for empty batch', () async {
      final results = await engine.embedTextBatch(
        texts: const [],
        sources: const [],
      );

      expect(results, isEmpty);
    });

    test('chunks and embeds long text as one model-aware batch', () async {
      final results = await engine.embedLongTextBatch(
        texts: [List.filled(700, 'retrieval').join(' ')],
        sources: const [
          SourceReference(sourcePath: 'long.txt', informationIndex: 4),
        ],
      );
      expect(results.length, greaterThan(1));
      expect(results.first.source.informationIndex, 4);
      expect(results.first.source.chunkIndex, 0);
      expect(results.first.source.startOffset, 0);
      expect(results.last.source.endOffset, greaterThan(0));
    });

    test('rejects mismatched text and source counts', () {
      expect(
        () => engine.embedTextBatch(
          texts: const ['first text', 'second text'],
          sources: const [SourceReference(sourcePath: 'only_one_source.txt')],
        ),
        throwsArgumentError,
      );
    });

    test('rejects empty text before model inference', () {
      const source = SourceReference(sourcePath: 'empty.txt');

      expect(
        () => engine.embedText(text: '   ', source: source),
        throwsArgumentError,
      );
    });

    test('rejects text exceeding BERT input capacity', () {
      const source = SourceReference(sourcePath: 'long_document.txt');

      final longText = List.filled(600, 'retrieval').join(' ');

      expect(
        () => engine.embedText(text: longText, source: source),
        throwsArgumentError,
      );
    });
  });
}

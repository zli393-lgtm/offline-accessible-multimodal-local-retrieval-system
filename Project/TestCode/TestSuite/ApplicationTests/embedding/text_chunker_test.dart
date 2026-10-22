import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/embedding/text/bert_tokenizer.dart';
import 'package:retrieval/embedding/text/text_chunker.dart';

void main() {
  group('TextChunker', () {
    late BertTokenizer tokenizer;

    setUp(() {
      tokenizer = BertTokenizer.fromFile('assets/models/bert/tokenizer.json');
    });

    tearDown(() {
      tokenizer.close();
    });

    test('returns empty list for empty text', () {
      final chunker = TextChunker(tokenizer: tokenizer);

      final chunks = chunker.chunk('');

      expect(chunks, isEmpty);
    });

    test('returns empty list when text contains no content tokens', () {
      final chunker = TextChunker(tokenizer: tokenizer);

      final chunks = chunker.chunk('     ');

      expect(chunks, isEmpty);
    });

    test('splits text according to real BERT token budget', () {
      final chunker = TextChunker(
        tokenizer: tokenizer,
        maxInputTokens: 6,
        overlapTokens: 1,
      );

      const text = 'one two three four five six seven';

      final chunks = chunker.chunk(text);

      expect(chunks.length, 2);

      expect(chunks[0].text, 'one two three four ');

      expect(chunks[1].text, 'four five six seven');

      for (final chunk in chunks) {
        expect(chunk.modelTokenCount, lessThanOrEqualTo(6));

        expect(text.substring(chunk.startOffset, chunk.endOffset), chunk.text);
      }

      expect(chunks[0].chunkIndex, 0);
      expect(chunks[1].chunkIndex, 1);

      expect(chunks[0].startOffset, 0);
      expect(chunks[0].endOffset, 19);

      expect(chunks[1].startOffset, 14);
      expect(chunks[1].endOffset, text.length);
    });

    test('converts tokenizer byte offsets to Dart string offsets', () {
      final chunker = TextChunker(
        tokenizer: tokenizer,
        maxInputTokens: 4,
        overlapTokens: 0,
      );

      const text = 'café hello world';

      final chunks = chunker.chunk(text);

      expect(chunks.length, 2);

      expect(chunks[0].text, 'café hello ');

      expect(chunks[1].text, 'world');

      expect(chunks[0].startOffset, 0);
      expect(chunks[0].endOffset, 11);

      expect(chunks[1].startOffset, 11);
      expect(chunks[1].endOffset, text.length);

      for (final chunk in chunks) {
        expect(text.substring(chunk.startOffset, chunk.endOffset), chunk.text);
      }
    });

    test('rejects overlap that leaves no forward token budget', () {
      expect(
        () => TextChunker(
          tokenizer: tokenizer,
          maxInputTokens: 4,
          overlapTokens: 2,
        ),
        throwsArgumentError,
      );
    });
  });
}

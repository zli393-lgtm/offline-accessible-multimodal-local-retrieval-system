import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/embedding/text/bert_tokenizer.dart';

void main() {
  group('BertTokenizer', () {
    late BertTokenizer tokenizer;

    setUp(() {
      tokenizer = BertTokenizer.fromFile('assets/models/bert/tokenizer.json');
    });

    tearDown(() {
      tokenizer.close();
    });

    test('loads official BERT vocabulary', () {
      expect(tokenizer.vocabSize, 30522);
      expect(tokenizer.clsTokenId, 101);
      expect(tokenizer.sepTokenId, 102);
      expect(tokenizer.padTokenId, 0);
      expect(tokenizer.unkTokenId, 100);
    });

    test('matches official BERT token ids for simple English text', () {
      final ids = tokenizer.encode('hello world');

      expect(ids, [101, 7592, 2088, 102]);
    });

    test('matches BERT normalization and WordPiece behaviour', () {
      final ids = tokenizer.encode(
        'The naïve café in São Paulo',
        addSpecialTokens: false,
      );

      expect(ids, [1996, 15743, 7668, 1999, 7509, 9094]);
    });

    test('counts special tokens as part of the model input', () {
      expect(tokenizer.count('hello world'), 4);

      expect(tokenizer.count('hello world', addSpecialTokens: false), 2);
    });
  });
}

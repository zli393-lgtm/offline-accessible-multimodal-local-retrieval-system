import 'dart:convert';

import 'bert_tokenizer.dart';

class TextChunk {
  final String text;
  final int chunkIndex;
  final int startOffset;
  final int endOffset;
  final int modelTokenCount;

  const TextChunk({
    required this.text,
    required this.chunkIndex,
    required this.startOffset,
    required this.endOffset,
    required this.modelTokenCount,
  });
}

class TextChunker {
  final BertTokenizer tokenizer;

  /// BERT 整个模型输入允许的最大 token 数量。
  /// 该数量包含 [CLS] 和 [SEP] 等特殊 token。
  final int maxInputTokens;

  /// 相邻 chunk 重复的内容 token 数量。
  final int overlapTokens;

  late final int _specialTokenCount;
  late final int _contentBudget;

  TextChunker({
    required this.tokenizer,
    this.maxInputTokens = 512,
    this.overlapTokens = 32,
  }) {
    _specialTokenCount = tokenizer.count('');

    _contentBudget = maxInputTokens - _specialTokenCount;

    if (_contentBudget <= 0) {
      throw ArgumentError(
        'maxInputTokens 必须大于模型需要的特殊 token 数量 '
        '($_specialTokenCount)。',
      );
    }

    if (overlapTokens < 0 || overlapTokens >= _contentBudget) {
      throw ArgumentError(
        'overlapTokens 必须 >= 0 并且小于可用内容 token 数量 '
        '($_contentBudget)。',
      );
    }
  }

  List<TextChunk> chunk(String text) {
    if (text.isEmpty) {
      return const [];
    }

    final tokens = tokenizer.encodeWithOffsets(text, addSpecialTokens: false);

    // 没有实际内容 token，例如只有空格的字符串。
    if (tokens.isEmpty) {
      return const [];
    }

    final sourceBytes = utf8.encode(text);
    final byteToUtf16 = _byteToUtf16Index(text);

    final chunks = <TextChunk>[];

    var startToken = 0;
    var chunkIndex = 0;

    while (startToken < tokens.length) {
      var endTokenExclusive = startToken + _contentBudget;

      if (endTokenExclusive > tokens.length) {
        endTokenExclusive = tokens.length;
      }

      while (true) {
        final startByte = startToken == 0 ? 0 : tokens[startToken].start;

        final endByte = endTokenExclusive == tokens.length
            ? sourceBytes.length
            : tokens[endTokenExclusive].start;

        final chunkText = utf8.decode(sourceBytes.sublist(startByte, endByte));

        // 切出新的文本 chunk 后重新进行 tokenization，
        // 确认该 chunk 的实际模型输入没有超过 maxInputTokens。
        // 这样可以避免因为文本边界变化而导致实际 token 数超出限制。
        final modelTokenCount = tokenizer.count(chunkText);

        if (modelTokenCount <= maxInputTokens) {
          final startOffset = byteToUtf16[startByte];
          final endOffset = byteToUtf16[endByte];

          chunks.add(
            TextChunk(
              text: chunkText,
              chunkIndex: chunkIndex,
              startOffset: startOffset,
              endOffset: endOffset,
              modelTokenCount: modelTokenCount,
            ),
          );

          if (endTokenExclusive == tokens.length) {
            return chunks;
          }

          var nextStartToken = endTokenExclusive - overlapTokens;

          // 保证下一次处理位置一定向前移动，避免出现死循环。
          if (nextStartToken <= startToken) {
            nextStartToken = startToken + 1;
          }

          startToken = nextStartToken;
          chunkIndex++;
          break;
        }

        // 如果重新 tokenization 后仍然超过模型输入限制，
        // 就逐步缩短当前 chunk，直到能够完整进入 BERT。
        endTokenExclusive--;

        if (endTokenExclusive <= startToken) {
          throw StateError(
            '无法在 maxInputTokens=$maxInputTokens 的限制下'
            '构造有效 BERT chunk。',
          );
        }
      }
    }

    return chunks;
  }

  /// Hugging Face tokenizer 返回 UTF-8 byte offset，
  /// Dart String 使用 UTF-16 code-unit offset。
  /// 这里将 tokenizer offset 转换为 Dart 字符串位置，
  /// 保证 SourceReference 能正确定位回原始文本。
  static List<int> _byteToUtf16Index(String text) {
    final map = <int>[];
    var utf16Index = 0;

    for (final rune in text.runes) {
      final int utf8Length;

      if (rune <= 0x7F) {
        utf8Length = 1;
      } else if (rune <= 0x7FF) {
        utf8Length = 2;
      } else if (rune <= 0xFFFF) {
        utf8Length = 3;
      } else {
        utf8Length = 4;
      }

      for (var i = 0; i < utf8Length; i++) {
        map.add(utf16Index);
      }

      utf16Index += rune > 0xFFFF ? 2 : 1;
    }

    map.add(text.length);

    return map;
  }
}

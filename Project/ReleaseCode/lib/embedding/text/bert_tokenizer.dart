import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class TokenOffset {
  final int id;
  final int start;
  final int end;
  const TokenOffset({required this.id, required this.start, required this.end});
}

/// Offline, cross-platform BERT BasicTokenizer + WordPiece implementation.
class BertTokenizer {
  final Map<String, int> _vocabulary;
  final int _maximumWordCharacters;

  BertTokenizer._(this._vocabulary, this._maximumWordCharacters);

  factory BertTokenizer.fromFile(String path) =>
      BertTokenizer.fromBytes(File(path).readAsBytesSync());

  factory BertTokenizer.fromBytes(Uint8List bytes) {
    final root = jsonDecode(utf8.decode(bytes));
    if (root is! Map<String, dynamic>) {
      throw const FormatException(
        'BERT tokenizer JSON root must be an object.',
      );
    }
    final model = root['model'];
    if (model is! Map<String, dynamic> || model['vocab'] is! Map) {
      throw const FormatException('BERT tokenizer JSON has no model.vocab.');
    }
    final vocabulary = <String, int>{};
    (model['vocab'] as Map).forEach((key, value) {
      if (key is String && value is num) vocabulary[key] = value.toInt();
    });
    if (vocabulary.isEmpty) {
      throw const FormatException('BERT tokenizer vocabulary is empty.');
    }
    final maximum = (model['max_input_chars_per_word'] as num?)?.toInt() ?? 100;
    return BertTokenizer._(Map.unmodifiable(vocabulary), maximum);
  }

  int get vocabSize => _vocabulary.length;
  int get clsTokenId => _requiredTokenId('[CLS]');
  int get sepTokenId => _requiredTokenId('[SEP]');
  int get padTokenId => _requiredTokenId('[PAD]');
  int get unkTokenId => _requiredTokenId('[UNK]');

  List<int> encode(String text, {bool addSpecialTokens = true}) =>
      encodeWithOffsets(
        text,
        addSpecialTokens: addSpecialTokens,
      ).map((token) => token.id).toList(growable: false);

  List<TokenOffset> encodeWithOffsets(
    String text, {
    bool addSpecialTokens = true,
  }) {
    final tokens = <TokenOffset>[];
    if (addSpecialTokens) {
      tokens.add(TokenOffset(id: clsTokenId, start: 0, end: 0));
    }
    for (final word in _basicTokens(text)) {
      tokens.addAll(_wordPiece(word));
    }
    if (addSpecialTokens) {
      final end = utf8.encode(text).length;
      tokens.add(TokenOffset(id: sepTokenId, start: end, end: end));
    }
    return tokens;
  }

  int count(String text, {bool addSpecialTokens = true}) =>
      encodeWithOffsets(text, addSpecialTokens: addSpecialTokens).length;

  List<String> chunkByTokens(
    String text,
    int maxTokens, {
    int overlapTokens = 0,
  }) {
    if (maxTokens <= 0 || overlapTokens < 0 || overlapTokens >= maxTokens) {
      throw ArgumentError('Invalid token chunk size or overlap.');
    }
    final tokens = encodeWithOffsets(text, addSpecialTokens: false);
    if (tokens.isEmpty) return const [];
    final bytes = utf8.encode(text);
    final chunks = <String>[];
    for (var start = 0; start < tokens.length;) {
      final end = (start + maxTokens).clamp(0, tokens.length);
      final startByte = start == 0 ? 0 : tokens[start].start;
      final endByte = end == tokens.length ? bytes.length : tokens[end].start;
      chunks.add(utf8.decode(bytes.sublist(startByte, endByte)));
      if (end == tokens.length) break;
      start = end - overlapTokens;
    }
    return chunks;
  }

  Iterable<_BasicToken> _basicTokens(String source) sync* {
    var byteOffset = 0;
    var current = StringBuffer();
    var currentStart = 0;
    var currentEnd = 0;
    _BasicToken? flush() {
      if (current.isEmpty) return null;
      final token = _BasicToken(current.toString(), currentStart, currentEnd);
      current = StringBuffer();
      return token;
    }

    for (final rune in source.runes) {
      final runeText = String.fromCharCode(rune);
      final byteLength = utf8.encode(runeText).length;
      final split = _isPunctuation(rune) || _isChinese(rune);
      if (_isWhitespace(rune) || _isControl(rune) || split) {
        final pending = flush();
        if (pending != null) yield pending;
        if (split && !_isControl(rune)) {
          final normalized = _normalizeRune(runeText);
          if (normalized.isNotEmpty) {
            yield _BasicToken(normalized, byteOffset, byteOffset + byteLength);
          }
        }
      } else {
        if (current.isEmpty) currentStart = byteOffset;
        current.write(_normalizeRune(runeText));
        currentEnd = byteOffset + byteLength;
      }
      byteOffset += byteLength;
    }
    final pending = flush();
    if (pending != null) yield pending;
  }

  Iterable<TokenOffset> _wordPiece(_BasicToken word) sync* {
    final characters = word.text.runes.map(String.fromCharCode).toList();
    if (characters.length > _maximumWordCharacters) {
      yield TokenOffset(id: unkTokenId, start: word.start, end: word.end);
      return;
    }
    final pieces = <int>[];
    var start = 0;
    while (start < characters.length) {
      int? matchedId;
      var matchedEnd = characters.length;
      while (matchedEnd > start) {
        final body = characters.sublist(start, matchedEnd).join();
        matchedId = _vocabulary[start == 0 ? body : '##$body'];
        if (matchedId != null) break;
        matchedEnd--;
      }
      if (matchedId == null) {
        yield TokenOffset(id: unkTokenId, start: word.start, end: word.end);
        return;
      }
      pieces.add(matchedId);
      start = matchedEnd;
    }
    for (final id in pieces) {
      yield TokenOffset(id: id, start: word.start, end: word.end);
    }
  }

  int _requiredTokenId(String token) {
    final id = _vocabulary[token];
    if (id == null) throw StateError('Required BERT token is missing: $token');
    return id;
  }

  static String _normalizeRune(String value) {
    final lower = value.toLowerCase();
    const accents = <String, String>{
      'à': 'a',
      'á': 'a',
      'â': 'a',
      'ã': 'a',
      'ä': 'a',
      'å': 'a',
      'ā': 'a',
      'ă': 'a',
      'ą': 'a',
      'ç': 'c',
      'ć': 'c',
      'ĉ': 'c',
      'ċ': 'c',
      'č': 'c',
      'ď': 'd',
      'đ': 'd',
      'è': 'e',
      'é': 'e',
      'ê': 'e',
      'ë': 'e',
      'ē': 'e',
      'ĕ': 'e',
      'ė': 'e',
      'ę': 'e',
      'ě': 'e',
      'ĝ': 'g',
      'ğ': 'g',
      'ġ': 'g',
      'ģ': 'g',
      'ĥ': 'h',
      'ħ': 'h',
      'ì': 'i',
      'í': 'i',
      'î': 'i',
      'ï': 'i',
      'ĩ': 'i',
      'ī': 'i',
      'ĭ': 'i',
      'į': 'i',
      'ı': 'i',
      'ĵ': 'j',
      'ķ': 'k',
      'ĺ': 'l',
      'ļ': 'l',
      'ľ': 'l',
      'ŀ': 'l',
      'ł': 'l',
      'ñ': 'n',
      'ń': 'n',
      'ņ': 'n',
      'ň': 'n',
      'ò': 'o',
      'ó': 'o',
      'ô': 'o',
      'õ': 'o',
      'ö': 'o',
      'ø': 'o',
      'ō': 'o',
      'ŏ': 'o',
      'ő': 'o',
      'ŕ': 'r',
      'ŗ': 'r',
      'ř': 'r',
      'ś': 's',
      'ŝ': 's',
      'ş': 's',
      'š': 's',
      'ß': 'ss',
      'ţ': 't',
      'ť': 't',
      'ŧ': 't',
      'ù': 'u',
      'ú': 'u',
      'û': 'u',
      'ü': 'u',
      'ũ': 'u',
      'ū': 'u',
      'ŭ': 'u',
      'ů': 'u',
      'ű': 'u',
      'ų': 'u',
      'ŵ': 'w',
      'ý': 'y',
      'ÿ': 'y',
      'ŷ': 'y',
      'ź': 'z',
      'ż': 'z',
      'ž': 'z',
    };
    return accents[lower] ?? lower;
  }

  static bool _isWhitespace(int rune) =>
      rune == 0x20 ||
      rune == 0x09 ||
      rune == 0x0A ||
      rune == 0x0D ||
      rune == 0xA0;
  static bool _isControl(int rune) =>
      (rune < 0x20 && !_isWhitespace(rune)) || (rune >= 0x7F && rune <= 0x9F);
  static bool _isPunctuation(int rune) =>
      (rune >= 33 && rune <= 47) ||
      (rune >= 58 && rune <= 64) ||
      (rune >= 91 && rune <= 96) ||
      (rune >= 123 && rune <= 126) ||
      (rune >= 0x2000 && rune <= 0x206F) ||
      (rune >= 0x3000 && rune <= 0x303F) ||
      (rune >= 0xFF00 && rune <= 0xFF65);
  static bool _isChinese(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0x20000 && rune <= 0x2FA1F);

  void close() {}
}

class _BasicToken {
  final String text;
  final int start;
  final int end;
  const _BasicToken(this.text, this.start, this.end);
}

import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/parsing/parser.dart';
import '../core/parsing/pure_text_parser.dart';
import '../embedding/source_reference.dart';
import '../embedding/text/bert_text_embedding_engine.dart';
import '../embedding/text/bert_tokenizer.dart';
import '../embedding/text/text_chunker.dart';
import '../storage/chroma_client.dart';
import 'hybrid_retriever.dart';
import 'retrieval_models.dart';

class RetrievalPipeline {
  final ChromaClient store;
  final BertTextEmbeddingEngine engine;
  final BertTokenizer tokenizer;
  final Parser? fileParser;
  late final TextChunker chunker;

  RetrievalPipeline({
    required this.store,
    required this.engine,
    required this.tokenizer,
    this.fileParser,
  }) {
    chunker = TextChunker(tokenizer: tokenizer);
  }

  static Future<RetrievalPipeline> load({
    ChromaClient? store,
    Parser? fileParser,
  }) async {
    final tokenizerData = await rootBundle.load(
      BertTextEmbeddingEngine.tokenizerAssetPath,
    );
    final tokenizer = BertTokenizer.fromBytes(
      tokenizerData.buffer.asUint8List(
        tokenizerData.offsetInBytes,
        tokenizerData.lengthInBytes,
      ),
    );
    try {
      final engine = await BertTextEmbeddingEngine.load();
      return RetrievalPipeline(
        store: store ?? ChromaClient(),
        engine: engine,
        tokenizer: tokenizer,
        fileParser: fileParser,
      );
    } catch (_) {
      tokenizer.close();
      rethrow;
    }
  }

  Future<int> indexFile(String path) async {
    final segments = <({String text, int? pageIndex})>[];
    String fileType;
    if (fileParser != null) {
      final result = await fileParser!.parse(path);
      fileType = result.metadata.detectedFileType;
      for (final item in result.content.textInformation) {
        final pageIndex = item.regions.isEmpty
            ? null
            : item.regions.first.pageIndex;
        segments.add((text: item.text, pageIndex: pageIndex));
      }
    } else if (PureTextParser.supports(path)) {
      final result = await const PureTextParser().parse(path);
      fileType = result.metadata.detectedFileType;
      segments.add((text: result.content.mergedText, pageIndex: null));
    } else {
      throw UnsupportedError(
        'Configure a file parser to index this file type. '
        'PDF and other rich documents must use FileParserRouter so their '
        'text, images, OCR and metadata follow the complete indexing path.',
      );
    }

    final pending = <({String text, SourceReference source, int index})>[];
    for (final segment in segments) {
      for (final part in chunker.chunk(segment.text)) {
        pending.add((
          text: part.text,
          source: SourceReference(
            sourcePath: path,
            pageIndex: segment.pageIndex,
            chunkIndex: pending.length,
            startOffset: part.startOffset,
            endOffset: part.endOffset,
          ),
          index: pending.length,
        ));
      }
    }

    var indexed = 0;
    for (var offset = 0; offset < pending.length; offset += 2) {
      final batch = pending.skip(offset).take(2).toList();
      final vectors = await engine.embedTextBatch(
        texts: batch.map((item) => item.text).toList(),
        sources: batch.map((item) => item.source).toList(),
      );
      final rows = <IndexedChunk>[];
      for (var i = 0; i < batch.length; i++) {
        final item = batch[i];
        rows.add(
          IndexedChunk(
            id: base64Url.encode(utf8.encode('$path#${item.index}')),
            text: item.text,
            sourcePath: path,
            fileType: fileType,
            chunkIndex: item.index,
            pageIndex: item.source.pageIndex,
            startOffset: item.source.startOffset,
            endOffset: item.source.endOffset,
            embedding: vectors[i].vector,
          ),
        );
      }
      indexed += await store.upsert(rows);
    }
    return indexed;
  }

  Future<List<SearchResult>> search(
    String query, {
    int limit = 10,
    String? fileType,
  }) async {
    if (query.trim().isEmpty) throw ArgumentError('Search query is empty.');
    final vector = await engine.embedText(
      text: query,
      source: const SourceReference(sourcePath: '<query>'),
    );
    final candidates = await store.search(
      embedding: vector.vector,
      terms: HybridRetriever.terms(query),
      limit: limit * 3,
    );
    return HybridRetriever.fuse(candidates, limit: limit, fileType: fileType);
  }

  void close() {
    engine.close();
    tokenizer.close();
    store.close();
  }
}

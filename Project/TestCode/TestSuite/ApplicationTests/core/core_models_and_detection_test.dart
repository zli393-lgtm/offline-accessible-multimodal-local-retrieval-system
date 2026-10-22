import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/core/file_io/file_type_detector.dart';
import 'package:retrieval/core/models/file_metadata.dart';
import 'package:retrieval/core/models/parsing_result.dart';
import 'package:retrieval/core/models/pdf_content.dart';
import 'package:retrieval/domain/file_object.dart';
import 'package:retrieval/embedding/embedding_result.dart';
import 'package:retrieval/embedding/embedding_space.dart';
import 'package:retrieval/embedding/multimodal_embedding_engine.dart';
import 'package:retrieval/embedding/source_reference.dart';
import 'package:retrieval/indexing/index_coverage.dart';
import 'package:retrieval/query/query_file_type_options.dart';
import 'package:retrieval/retrieval/retrieval_models.dart';

import '../support/fakes.dart';

void main() {
  test('file metadata exposes names, extensions, copies, and JSON', () {
    final modified = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final accessed = DateTime.utc(2026, 2, 3);
    final changed = DateTime.utc(2026, 3, 4);
    final original = FileMetadata(
      filePath: p.join('folder', 'Report.PDF'),
      detectedFileType: 'PDF',
      fileSize: 12,
      modifiedTime: modified,
      accessedTime: accessed,
      changedTime: changed,
      fingerprint: 'old',
      isReadOnly: true,
      mimeType: 'application/pdf',
    );
    final copy = original.copyWith(
      filePath: p.join('other', 'copy.txt'),
      detectedFileType: 'TXT',
      fileSize: 99,
      modifiedTime: changed,
      fingerprint: 'new',
      isReadOnly: false,
      mimeType: 'text/plain',
    );

    expect(original.fileName, 'Report.PDF');
    expect(original.extension, '.pdf');
    expect(copy.fileName, 'copy.txt');
    expect(copy.fileSize, 99);
    expect(copy.toJson(), containsPair('fingerprint', 'new'));
    expect(original.toJson()['accessedTime'], accessed.toIso8601String());
    expect(original.toJson()['changedTime'], changed.toIso8601String());
  });

  test('PDF blocks expose geometry and retain page content', () {
    final text = PdfTextBlock(
      text: 'hello',
      sourceOrder: 0,
      layoutOrder: 1,
      left: 2,
      bottom: 3,
      right: 12,
      top: 23,
    );
    final image = PdfImageBlock(
      pixelData: Uint8List.fromList([1, 2, 3, 4]),
      pixelWidth: 1,
      pixelHeight: 1,
      stride: 4,
      bitmapFormat: 4,
      sourceOrder: 1,
      layoutOrder: 0,
      left: 0,
      bottom: 0,
      right: 5,
      top: 6,
    );
    final content = PdfContent(
      pages: [
        PdfPageContent(
          pageIndex: 0,
          width: 100,
          height: 200,
          blocks: [text, image],
        ),
      ],
    );

    expect(text.width, 10);
    expect(text.height, 20);
    expect(image.width, 5);
    expect(content.pages.single.blocks, [text, image]);
  });

  test('retrieval records serialize and parse every optional field', () {
    const chunk = IndexedChunk(
      id: 'id',
      text: 'text',
      sourcePath: 'a.txt',
      fileType: 'TXT',
      chunkIndex: 2,
      pageIndex: 3,
      startOffset: 4,
      endOffset: 8,
      embedding: [0.1, 0.2],
    );
    final json = chunk.toJson();
    final candidate = SearchCandidate.fromJson({
      'id': 'id',
      'text': 'text',
      'distance': 0.25,
      'metadata': json['metadata'],
    });
    const result = SearchResult(
      candidate: SearchCandidate(
        id: 'b',
        text: 'b',
        sourcePath: 'b.txt',
        fileType: 'TXT',
        chunkIndex: 0,
      ),
      score: 1,
      vectorMatched: true,
      keywordMatched: false,
    );
    final set = CandidateSet(vector: [candidate], keyword: [result.candidate]);

    expect(candidate.pageIndex, 3);
    expect(candidate.startOffset, 4);
    expect(candidate.endOffset, 8);
    expect(candidate.distance, 0.25);
    expect(set.vector.single.id, 'id');
    expect(result.vectorMatched, isTrue);
  });

  test('query suffix normalization and groups are complete', () {
    expect(QueryFileTypeOptions.normalize(' .Pdf '), 'PDF');
    expect(QueryFileTypeOptions.normalize('txt'), 'TXT');
    expect(QueryFileTypeOptions.groups.keys, hasLength(5));
    expect(
      QueryFileTypeOptions.known,
      containsAll({'PDF', 'PNG', 'MP3', 'ZIP'}),
    );
    expect(QueryFileTypeMode.values, hasLength(3));
    expect(QueryResultSort.values, hasLength(5));
  });

  test('file type detection covers each built-in outer category', () async {
    final root = await Directory.systemTemp.createTemp('type-detection-');
    addTearDown(() => root.delete(recursive: true));
    final expected = <String, String>{
      'sample.txt': 'TXT',
      'sample.png': 'PNG',
      'sample.svg': 'SVG',
      'sample.mp3': 'MP3',
      'sample.docx': 'DOCX',
      'sample.pdf': 'PDF',
      'sample.zip': 'ZIP',
    };
    for (final entry in expected.entries) {
      final file = await File(p.join(root.path, entry.key)).writeAsBytes([1]);
      expect(await FileTypeDetector.detect(file.path), entry.value);
    }
    expect(
      () => FileTypeDetector.detect(p.join(root.path, 'missing.txt')),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'index coverage normalizes, persists, reloads, and rejects versions',
    () async {
      final root = await Directory.systemTemp.createTemp('coverage-store-');
      addTearDown(() => root.delete(recursive: true));
      final first = p.join(root.path, 'first');
      final child = p.join(first, 'child', 'file.txt');
      var coverage = IndexCoverage(roots: [first, first]);
      expect(coverage.roots, hasLength(1));
      expect(coverage.covers(child), isTrue);
      expect(coverage.covers(p.join(root.path, 'outside')), isFalse);
      coverage = coverage.addRoots([p.join(root.path, 'second')]);
      final store = IndexCoverageStore(
        File(p.join(root.path, 'state', 'coverage.json')),
      );
      expect((await store.load()).roots, isEmpty);
      await store.save(coverage);
      expect((await store.load()).toJson(), coverage.toJson());
      await store.file.writeAsString('{"version":2}');
      expect(store.load, throwsFormatException);
      expect(IndexCoverage(allDevices: true).covers('anything'), isTrue);
      expect(IndexCoverage.fromJson(const {}).allDevices, isFalse);
    },
  );

  test('file object supports embeddings, index commit, and failure state', () {
    const path = 'library/item.txt';
    final parsed = ParsingResult(
      metadata: FileMetadata(
        filePath: path,
        detectedFileType: 'TXT',
        fileSize: 4,
        modifiedTime: DateTime.utc(2026),
      ),
      content: fakeContent(path, text: ' text '),
    );
    final original = FileObject.fromParsingResult(
      parsed,
      origin: FileObjectOrigin.queryAttachment,
      objectVersion: 2,
    );
    final embedding = EmbeddingResult(
      vector: const [1, 0],
      space: EmbeddingSpace.bertText,
      modality: EmbeddingModality.text,
      model: 'test',
      source: const SourceReference(sourcePath: path, informationIndex: 0),
    );
    final embedded = original.withEmbeddings(
      MultimodalEmbeddingBatch(
        textEmbeddings: [embedding],
        imageEmbeddings: const [],
        audioEmbeddings: const [],
        ignoredVideoCount: 0,
        issues: const [EmbeddingIssue(modality: 'image', message: 'warning')],
        status: EmbeddingStatus.partial,
      ),
    );
    final indexed = embedded.withIndex(
      FileIndexData(
        databaseProfileId: 'db',
        indexVersion: 'v1',
        indexedTime: DateTime.utc(2026),
        status: FileIndexStatus.indexed,
        textRecordIds: const ['record'],
      ),
    );
    final failed = indexed.withFailure(id: 'failure', message: 'broken');

    expect(original.text.value, 'text');
    expect(original.text.isEmpty, isFalse);
    expect(original.analysis.isEmpty, isTrue);
    expect(embedded.analysis.isEmpty, isFalse);
    expect(embedded.processing.embeddingStatus, EmbeddingStatus.partial);
    expect(indexed.index.status, FileIndexStatus.indexed);
    expect(failed.index.status, FileIndexStatus.failed);
    expect(failed.index.textRecordIds, ['record']);
    expect(failed.processing.attempts, 2);
    expect(failed.processing.lastFailureId, 'failure');
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/query/query_attachment_coordinator.dart';
import 'package:retrieval/query/query_models.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/storage/multimodal_vector_store.dart';
import 'package:retrieval/indexing/file_registry.dart';
import 'package:retrieval/domain/file_object.dart';
import 'package:retrieval/configuration/retrieval/relevance_threshold_values.dart';
import 'package:retrieval/embedding/multimodal_embedding_engine.dart';
import 'package:retrieval/summary/summary_generator.dart';

import '../support/fakes.dart';

class _IndependentResultStore extends FakeVectorStore {
  var sequence = 0;

  @override
  Future<List<VectorSearchHit>> searchSpace({
    required VectorSpaceKind space,
    required List<double> embedding,
    List<String> terms = const [],
    int limit = 10,
    String? fileType,
  }) async {
    if (fileType != null && fileType.toUpperCase() != 'TEST') return const [];
    sequence++;
    return [
      VectorSearchHit(
        id: 'result-$sequence',
        fileObjectId: 'matched-file-$sequence',
        sourcePath: 'matched-$sequence.txt',
        fileType: 'TEST',
        space: space,
        document: terms.join(' '),
        distance: sequence / 100,
        metadata: {'sequence': sequence},
      ),
    ];
  }
}

class _PagedResultStore extends FakeVectorStore implements PagedFileQueryStore {
  final List<int> requestedPages = [];

  VectorSearchHit hit(int index) => VectorSearchHit(
    id: 'record-$index',
    fileObjectId: 'file-$index',
    sourcePath: 'file-$index.txt',
    fileType: 'TXT',
    space: VectorSpaceKind.text,
    document: 'result $index',
    distance: index / 100,
    metadata: const {},
  );

  @override
  Future<FileQueryPage> prepareFileQuery({
    required List<FileQueryVector> vectors,
    required List<VectorSearchHit> fileNameHits,
    required int pageSize,
    String? fileType,
    Set<String>? allowedFileObjectIds,
    List<String> fileObjectOrder = const [],
    required bool includeNativeText,
    required bool includeExtractedText,
    bool fileTypeFilterEnabled = false,
    Set<String> allowedFileTypes = const {},
    bool includeOtherFileTypes = false,
    Set<String> knownFileTypes = const {},
    RelevanceScope relevanceScope = RelevanceThresholdValues.defaultScope,
  }) async => FileQueryPage(
    queryToken: 'prepared-query',
    totalFiles: 8,
    pageIndex: 0,
    pageSize: pageSize,
    files: List.generate(pageSize, hit),
  );

  @override
  Future<FileQueryPage> loadFileQueryPage(
    String queryToken,
    int pageIndex,
  ) async {
    requestedPages.add(pageIndex);
    return FileQueryPage(
      queryToken: queryToken,
      totalFiles: 8,
      pageIndex: pageIndex,
      pageSize: 6,
      files: [hit(6), hit(7)],
    );
  }
}

class _RefinablePagedStore extends _PagedResultStore
    implements RefinablePagedFileQueryStore {
  FileQueryRefinement? refinement;

  @override
  Future<FileQueryPage> refineFileQuery(
    String queryToken,
    FileQueryRefinement refinement,
  ) async {
    this.refinement = refinement;
    return FileQueryPage(
      queryToken: queryToken,
      totalFiles: 1,
      pageIndex: 0,
      pageSize: 6,
      files: [hit(9)],
      availableFileTypes: const {'TXT'},
      totalIsFinal: true,
    );
  }
}

class _QuerySummaryGenerator implements SummaryGenerator {
  @override
  Future<FileSummaryBundle> generate(ExtractedFileContent content) async =>
      const FileSummaryBundle(
        firstLevel: [
          GeneratedSummary(
            sourceKind: SummarySourceKind.nativeText,
            text: 'content summary',
          ),
        ],
        overall: GeneratedSummary(
          sourceKind: SummarySourceKind.overallSummary,
          text: 'overall summary',
        ),
      );
}

void main() {
  late Directory temporary;
  late FakeParser parser;
  late _IndependentResultStore store;
  late QueryAttachmentCoordinator coordinator;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('query-attachment-test-');
    parser = FakeParser();
    store = _IndependentResultStore();
    coordinator = QueryAttachmentCoordinator(
      parser: parser,
      embeddingEngine: fakeMultimodalEngine(),
      vectorStore: store,
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'three unrelated attachments produce three independent query units',
    () async {
      final paths = <String>[];
      for (var index = 0; index < 3; index++) {
        final file = File(p.join(temporary.path, 'file-$index.txt'));
        await file.writeAsString('content $index');
        parser.contentByPath[file.path] = fakeContent(
          file.path,
          text: 'topic $index',
        );
        paths.add(file.path);
      }

      final response = await coordinator.search(
        QueryRequest(attachmentPaths: paths),
      );

      expect(response.units, hasLength(3));
      expect(response.units.map((unit) => unit.label), orderedEquals(paths));
      expect(parser.calls, orderedEquals(paths));
      expect(
        response.units.map((unit) => unit.textResults.single.id).toSet(),
        hasLength(3),
      );
      for (final unit in response.units) {
        expect(unit.type, QueryUnitType.fileAttachment);
        expect(unit.status, QueryUnitStatus.completed);
        expect(unit.attachment!.origin.name, 'queryAttachment');
        expect(unit.imageResults, isEmpty);
        expect(unit.audioResults, isEmpty);
      }
    },
  );

  test('one failed attachment does not suppress other attachments', () async {
    final good = File(p.join(temporary.path, 'good.txt'));
    final bad = File(p.join(temporary.path, 'bad.txt'));
    await good.writeAsString('good');
    await bad.writeAsString('bad');
    parser.failures[bad.path] = const FormatException('damaged');

    final response = await coordinator.search(
      QueryRequest(attachmentPaths: [bad.path, good.path]),
    );

    expect(response.units, hasLength(2));
    expect(response.units[0].status, QueryUnitStatus.failed);
    expect(response.units[1].status, QueryUnitStatus.completed);
    expect(response.units[1].textResults, isNotEmpty);
  });

  test(
    'description is its own multimodal query unit before attachments',
    () async {
      final file = File(p.join(temporary.path, 'attachment.txt'));
      await file.writeAsString('attachment');
      final response = await coordinator.search(
        QueryRequest(
          description: 'find this',
          attachmentPaths: [file.path],
          informationSelection: QueryInformationSelection.all,
        ),
      );

      expect(response.units, hasLength(2));
      expect(response.units.first.type, QueryUnitType.textDescription);
      expect(response.units.first.textResults, hasLength(1));
      expect(response.units.first.imageResults, hasLength(1));
      expect(response.units.first.audioResults, hasLength(1));
      expect(response.units.last.type, QueryUnitType.fileAttachment);
    },
  );

  test('rejects empty queries and non-positive result limits', () async {
    expect(() => coordinator.search(const QueryRequest()), throwsArgumentError);
    expect(
      () => coordinator.search(
        const QueryRequest(description: 'x', resultLimit: 0),
      ),
      throwsArgumentError,
    );
    expect(
      () => coordinator.search(const QueryRequest(attachmentPaths: ['  '])),
      throwsArgumentError,
    );
  });

  test('applies the file type filter to every active search space', () async {
    final response = await coordinator.search(
      const QueryRequest(description: 'find this', fileTypeFilter: 'PDF'),
    );

    expect(response.units.single.textResults, isEmpty);
    expect(response.units.single.imageResults, isEmpty);
    expect(response.units.single.audioResults, isEmpty);
  });

  test('applies custom suffix and Other filters before file paging', () async {
    final excluded = await coordinator.search(
      const QueryRequest(
        description: 'find this',
        fileTypeFilterEnabled: true,
        allowedFileTypes: {'PDF'},
        knownFileTypes: {'TXT', 'PDF'},
      ),
    );
    expect(excluded.units.single.totalFiles, 0);

    final other = await coordinator.search(
      const QueryRequest(
        description: 'find this',
        fileTypeFilterEnabled: true,
        includeOtherFileTypes: true,
        knownFileTypes: {'PDF'},
      ),
    );
    expect(other.units.single.totalFiles, greaterThan(0));
  });

  test('limits returned hits to the selected query paths', () async {
    final response = await coordinator.search(
      const QueryRequest(
        description: 'find this',
        searchPaths: ['matched-1.txt'],
      ),
    );

    expect(response.units.single.textResults, hasLength(1));
    expect(response.units.single.imageResults, isEmpty);
    expect(response.units.single.audioResults, isEmpty);
  });

  test(
    'merges record hits by file object and serves stable data pages',
    () async {
      final pagedStore = FakeVectorStore();
      VectorSearchHit hit(
        String record,
        String object,
        VectorSpaceKind space,
        double distance,
      ) => VectorSearchHit(
        id: record,
        fileObjectId: object,
        sourcePath: '$object.txt',
        fileType: 'TEST',
        space: space,
        document: record,
        distance: distance,
        metadata: const {},
      );
      pagedStore.results[VectorSpaceKind.text] = [
        hit('shared-text', 'shared', VectorSpaceKind.text, 0.01),
        ...List.generate(
          7,
          (index) => hit(
            'text-$index',
            'file-$index',
            VectorSpaceKind.text,
            0.1 + index / 100,
          ),
        ),
      ];
      pagedStore.results[VectorSpaceKind.image] = [
        hit('shared-image', 'shared', VectorSpaceKind.image, 0.02),
      ];
      final paged = QueryAttachmentCoordinator(
        parser: parser,
        embeddingEngine: fakeMultimodalEngine(),
        vectorStore: pagedStore,
      );

      final first = (await paged.search(
        const QueryRequest(description: 'find', resultLimit: 6),
      )).units.single;
      expect(first.totalFiles, 8);
      expect(first.fileResults, hasLength(6));
      expect(
        first.fileResults.where((item) => item.fileObjectId == 'shared'),
        hasLength(1),
      );

      final second = await paged.page(first.queryUnitId, 1);
      expect(second.pageIndex, 1);
      expect(second.totalFiles, 8);
      expect(second.fileResults, hasLength(2));
      expect(
        {
          ...first.fileResults,
          ...second.fileResults,
        }.map((item) => item.fileObjectId).toSet(),
        hasLength(8),
      );
    },
  );

  test('production paged store returns only the requested file page', () async {
    final pagedStore = _PagedResultStore();
    final paged = QueryAttachmentCoordinator(
      parser: parser,
      embeddingEngine: fakeMultimodalEngine(),
      vectorStore: pagedStore,
    );

    final first = (await paged.search(
      const QueryRequest(description: 'find', resultLimit: 6),
    )).units.single;
    expect(first.totalFiles, 8);
    expect(first.fileResults, hasLength(6));
    expect(pagedStore.searches, isEmpty);

    final second = await paged.page(first.queryUnitId, 1);
    expect(pagedStore.requestedPages, [1]);
    expect(second.totalFiles, 8);
    expect(second.fileResults.map((item) => item.fileObjectId), [
      'file-6',
      'file-7',
    ]);
  });

  test('keeps native and extracted text as independent channels', () async {
    final channelStore = FakeVectorStore();
    VectorSearchHit textHit(String id, String method) => VectorSearchHit(
      id: id,
      fileObjectId: id,
      sourcePath: '$id.txt',
      fileType: 'TXT',
      space: VectorSpaceKind.text,
      document: id,
      distance: 0.1,
      metadata: {'textExtractionMethod': method},
    );
    channelStore.results[VectorSpaceKind.text] = [
      textHit('native', 'direct'),
      textHit('ocr', 'ocr'),
      textHit('speech', 'speechRecognition'),
      VectorSearchHit(
        id: 'archive-entry-name',
        fileObjectId: 'archive',
        sourcePath: 'archive.zip',
        fileType: 'ZIP',
        space: VectorSpaceKind.text,
        document: 'nested-report.pdf',
        distance: 0.1,
        metadata: const {
          'textExtractionMethod': 'direct',
          'textInformationKind': 'fileName',
        },
      ),
    ];
    final channelCoordinator = QueryAttachmentCoordinator(
      parser: parser,
      embeddingEngine: fakeMultimodalEngine(),
      vectorStore: channelStore,
    );

    final extracted = (await channelCoordinator.search(
      const QueryRequest(
        description: 'find',
        informationSelection: QueryInformationSelection({
          QueryInformationKind.extractedText,
        }),
        summarySelection: QuerySummarySelection.none,
      ),
    )).units.single;

    expect(
      extracted.fileResults.map((item) => item.fileObjectId),
      unorderedEquals(['ocr', 'speech']),
    );
    expect(channelStore.searches.map((item) => item.space), [
      VectorSpaceKind.text,
    ]);

    final native = (await channelCoordinator.search(
      const QueryRequest(
        description: 'find',
        informationSelection: QueryInformationSelection({
          QueryInformationKind.nativeText,
        }),
        summarySelection: QuerySummarySelection.none,
      ),
    )).units.single;
    expect(native.fileResults.map((item) => item.fileObjectId), ['native']);
  });

  test('file-name channel searches names without file contents', () async {
    final registry = FileRegistryStore(
      File(p.join(temporary.path, 'file-registry.json')),
    );
    final entry = FileRegistryEntry(
      fileObjectId: 'report-object',
      path: p.join(temporary.path, 'Annual Report.pdf'),
      fingerprint: 'hash',
      fileSize: 1,
      modifiedTime: DateTime.utc(2026),
      objectVersion: 1,
      databaseProfileId: 'database-test',
      status: FileIndexStatus.indexed,
      indexedTime: DateTime.utc(2026),
      textRecordIds: const [],
      imageRecordIds: const [],
      audioRecordIds: const [],
    );
    await registry.save({'report-object': entry});
    final nameStore = FakeVectorStore();
    final nameCoordinator = QueryAttachmentCoordinator(
      parser: parser,
      embeddingEngine: fakeMultimodalEngine(),
      vectorStore: nameStore,
      registryStore: registry,
    );

    final result = (await nameCoordinator.search(
      const QueryRequest(
        description: 'annual',
        informationSelection: QueryInformationSelection.fileNameOnly,
      ),
    )).units.single;

    expect(result.totalFiles, 1);
    expect(p.equals(result.fileResults.single.sourcePath, entry.path), isTrue);
    expect(nameStore.searches, isEmpty);
  });

  test(
    'file-name-only queries cover descriptions, attachments and progress',
    () async {
      final registry = FileRegistryStore(
        File(p.join(temporary.path, 'file-name-registry.json')),
      );
      FileRegistryEntry entry(String id, String name) => FileRegistryEntry(
        fileObjectId: id,
        path: p.join(temporary.path, 'scope', name),
        fingerprint: id,
        fileSize: 1,
        modifiedTime: DateTime.utc(2026),
        objectVersion: 1,
        databaseProfileId: 'database-test',
        status: FileIndexStatus.indexed,
        indexedTime: DateTime.utc(2026),
        textRecordIds: const [],
        imageRecordIds: const [],
        audioRecordIds: const [],
      );
      await registry.save({
        'pdf': entry('pdf', 'Annual Report.pdf'),
        'txt': entry('txt', 'Annual Notes.txt'),
      });
      final attachment = File(p.join(temporary.path, 'Annual attachment.pdf'));
      await attachment.writeAsBytes([1]);
      final progress = <String>[];
      final nameCoordinator = QueryAttachmentCoordinator(
        parser: parser,
        embeddingEngine: fakeMultimodalEngine(),
        vectorStore: FakeVectorStore(),
        registryStore: registry,
      );
      final response = await nameCoordinator.search(
        QueryRequest(
          description: 'Annual',
          attachmentPaths: [attachment.path],
          informationSelection: QueryInformationSelection.fileNameOnly,
          fileTypeFilter: 'PDF',
          searchPaths: [p.join(temporary.path, 'scope')],
        ),
        onProgress: (stage, current, total) =>
            progress.add('$stage:$current/$total'),
      );
      expect(response.units, hasLength(2));
      expect(response.units.every((unit) => unit.totalFiles == 1), isTrue);
      expect(
        response.units.every(
          (unit) => unit.fileResults.single.fileObjectId == 'pdf',
        ),
        isTrue,
      );
      expect(parser.calls, isEmpty);
      expect(progress, [
        'preparing:0/2',
        'description:1/2',
        'attachment:2/2',
        'finalizing:2/2',
      ]);
    },
  );

  test(
    'paged file-name-only query avoids parsing and vector generation',
    () async {
      final remoteStore = _PagedResultStore();
      final remote = QueryAttachmentCoordinator(
        parser: parser,
        embeddingEngine: fakeMultimodalEngine(),
        vectorStore: remoteStore,
      );
      final attachment = File(p.join(temporary.path, 'name-only.bin'));
      await attachment.writeAsBytes([1]);
      final description = (await remote.search(
        const QueryRequest(
          description: 'name',
          informationSelection: QueryInformationSelection.fileNameOnly,
        ),
      )).units.single;
      final attached = (await remote.search(
        QueryRequest(
          attachmentPaths: [attachment.path],
          informationSelection: QueryInformationSelection.fileNameOnly,
        ),
      )).units.single;
      expect(description.totalFiles, 8);
      expect(attached.totalFiles, 8);
      expect(parser.calls, isEmpty);
      expect(remoteStore.searches, isEmpty);
    },
  );

  test(
    'local pages clamp indexes and support every result refinement',
    () async {
      final localStore = FakeVectorStore();
      VectorSearchHit hit(
        String id,
        String path,
        String type,
        double distance,
      ) => VectorSearchHit(
        id: id,
        fileObjectId: id,
        sourcePath: path,
        fileType: type,
        space: VectorSpaceKind.text,
        document: id,
        distance: distance,
        metadata: type == 'UNKNOWN' ? const {} : {'fileExtension': type},
      );
      localStore.results[VectorSpaceKind.text] = [
        hit('z', 'folder/Zeta.txt', 'TXT', 0.3),
        hit('a', 'folder/Alpha.pdf', 'PDF', 0.2),
        hit('other', 'folder/no-extension', 'UNKNOWN', 0.1),
      ];
      final local = QueryAttachmentCoordinator(
        parser: parser,
        embeddingEngine: fakeMultimodalEngine(),
        vectorStore: localStore,
      );
      final unit = (await local.search(
        const QueryRequest(description: 'find', resultLimit: 1),
      )).units.single;

      expect((await local.page(unit.queryUnitId, 99)).pageIndex, 2);
      expect((await local.page(unit.queryUnitId, -4)).pageIndex, 0);
      final extension = await local.refine(
        unit.queryUnitId,
        const FileQueryRefinement(sort: 'extension'),
      );
      expect(extension.fileResults.single.fileObjectId, 'other');
      final fileName = await local.refine(
        unit.queryUnitId,
        const FileQueryRefinement(sort: 'fileName'),
      );
      expect(fileName.fileResults.single.fileObjectId, 'a');
      final path = await local.refine(
        unit.queryUnitId,
        const FileQueryRefinement(sort: 'path'),
      );
      expect(path.fileResults.single.fileObjectId, 'a');
      final filtered = await local.refine(
        unit.queryUnitId,
        const FileQueryRefinement(
          fileTypeFilterEnabled: true,
          allowedFileTypes: {'PDF'},
          knownFileTypes: {'PDF', 'TXT'},
        ),
      );
      expect(filtered.totalFiles, 1);
      expect(filtered.fileResults.single.fileObjectId, 'a');
      final other = await local.refine(
        unit.queryUnitId,
        const FileQueryRefinement(
          fileTypeFilterEnabled: true,
          includeOtherFileTypes: true,
          knownFileTypes: {'PDF', 'TXT'},
        ),
      );
      expect(other.fileResults.single.fileObjectId, 'other');
      expect(() => local.page('missing', 0), throwsStateError);
      expect(
        () => local.refine('missing', const FileQueryRefinement()),
        throwsStateError,
      );
    },
  );

  test(
    'remote paged queries delegate refinements to the storage layer',
    () async {
      final remoteStore = _RefinablePagedStore();
      final remote = QueryAttachmentCoordinator(
        parser: parser,
        embeddingEngine: fakeMultimodalEngine(),
        vectorStore: remoteStore,
      );
      final unit = (await remote.search(
        const QueryRequest(description: 'find', resultLimit: 6),
      )).units.single;
      final refined = await remote.refine(
        unit.queryUnitId,
        const FileQueryRefinement(
          fileTypeFilterEnabled: true,
          allowedFileTypes: {'TXT'},
          sort: 'relevance',
        ),
      );
      expect(remoteStore.refinement!.allowedFileTypes, {'TXT'});
      expect(refined.fileResults.single.fileObjectId, 'file-9');
      expect(refined.availableFileTypes, {'TXT'});
    },
  );

  test(
    'description query compares generated content and overall summaries',
    () async {
      final summaryStore = FakeVectorStore();
      final summaryEngine = MultimodalEmbeddingEngine(
        textEngine: FakeTextEngine(),
        imageEngine: FakeImageEngine(),
        audioEngine: FakeAudioEngine(),
        summaryGenerator: _QuerySummaryGenerator(),
      );
      final summaryCoordinator = QueryAttachmentCoordinator(
        parser: parser,
        embeddingEngine: summaryEngine,
        vectorStore: summaryStore,
      );
      final result = await summaryCoordinator.search(
        const QueryRequest(
          description: 'several fruits',
          informationSelection: QueryInformationSelection.all,
          summarySelection: QuerySummarySelection.all,
        ),
      );
      expect(result.units.single.status, QueryUnitStatus.completed);
      expect(
        summaryStore.searches.where(
          (search) => search.space == VectorSpaceKind.text,
        ),
        hasLength(greaterThanOrEqualTo(3)),
      );
    },
  );

  test(
    'attachment query compares generated content and overall summaries',
    () async {
      final file = await File(p.join(temporary.path, 'summary-source.txt'))
          .writeAsString('several fruits');
      parser.contentByPath[file.path] = fakeContent(
        file.path,
        text: 'apples bananas pears',
      );
      final summaryStore = FakeVectorStore();
      final summaryCoordinator = QueryAttachmentCoordinator(
        parser: parser,
        embeddingEngine: MultimodalEmbeddingEngine(
          textEngine: FakeTextEngine(),
          imageEngine: FakeImageEngine(),
          audioEngine: FakeAudioEngine(),
          summaryGenerator: _QuerySummaryGenerator(),
        ),
        vectorStore: summaryStore,
      );
      final result = await summaryCoordinator.search(
        QueryRequest(
          attachmentPaths: [file.path],
          informationSelection: QueryInformationSelection.all,
          summarySelection: QuerySummarySelection.all,
        ),
      );
      expect(result.units.single.status, QueryUnitStatus.completed);
      expect(
        summaryStore.searches.where(
          (search) => search.space == VectorSpaceKind.text,
        ),
        hasLength(greaterThanOrEqualTo(3)),
      );
    },
  );

  test(
    'explicit hit channels and relevance scores control deduplication',
    () async {
      final scoreStore = FakeVectorStore();
      VectorSearchHit hit(String id, double score) => VectorSearchHit(
        id: id,
        fileObjectId: 'same-file',
        sourcePath: 'same.txt',
        fileType: 'TXT',
        space: VectorSpaceKind.text,
        document: id,
        distance: 1 - score,
        relevanceScore: score,
        metadata: const {'queryInformationKind': 'extractedText'},
      );
      scoreStore.results[VectorSpaceKind.text] = [
        hit('lower', 0.2),
        hit('higher', 0.9),
      ];
      final scoreCoordinator = QueryAttachmentCoordinator(
        parser: parser,
        embeddingEngine: fakeMultimodalEngine(),
        vectorStore: scoreStore,
      );
      final result = await scoreCoordinator.search(
        const QueryRequest(
          description: 'find',
          informationSelection: QueryInformationSelection({
            QueryInformationKind.extractedText,
          }),
          summarySelection: QuerySummarySelection.none,
        ),
      );
      expect(result.units.single.fileResults.single.id, 'higher');

      final remote = QueryAttachmentCoordinator(
        parser: parser,
        embeddingEngine: fakeMultimodalEngine(),
        vectorStore: _PagedResultStore(),
      );
      final scoped = await remote.search(
        const QueryRequest(
          description: 'name',
          searchPaths: ['unregistered'],
          informationSelection: QueryInformationSelection.fileNameOnly,
        ),
      );
      expect(scoped.units.single.totalFiles, 8);
    },
  );
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/configuration/retrieval/relevance_threshold_values.dart';
import 'package:retrieval/retrieval/retrieval_models.dart';
import 'package:retrieval/storage/chroma_client.dart';
import 'package:retrieval/storage/multimodal_vector_store.dart';

void main() {
  test('rejects non-loopback Chroma URL', () {
    expect(
      () => ChromaClient(baseUri: Uri.parse('http://example.com:8765')),
      throwsArgumentError,
    );
    expect(
      () => ChromaClient(baseUri: Uri.parse('https://127.0.0.1:8765')),
      throwsArgumentError,
    );
  });

  test('uses multimodal endpoints and parses vector hits', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <Map<String, dynamic>>[];
    final subscription = server.listen((request) async {
      if (request.method == 'GET') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true, 'count': 3}));
      } else {
        final body = Map<String, dynamic>.from(
          jsonDecode(await utf8.decodeStream(request)) as Map,
        );
        requests.add({
          'path': request.uri.path,
          'contentLength': request.headers.contentLength,
          ...body,
        });
        final response = request.uri.path == '/search-space'
            ? {
                'vector': [
                  {
                    'id': 'file-a:text:0',
                    'document': 'matched text',
                    'distance': 0.1,
                    'metadata': {
                      'fileObjectId': 'file-a',
                      'sourcePath': 'a.txt',
                      'fileType': 'TXT',
                      'space': 'text',
                    },
                  },
                  {
                    'id': 'file-b:text:0',
                    'document': 'semantic only',
                    'distance': 0.05,
                    'metadata': {
                      'fileObjectId': 'file-b',
                      'sourcePath': 'b.txt',
                      'fileType': 'PDF',
                      'space': 'text',
                    },
                  },
                ],
                'keyword': [
                  {
                    'id': 'file-a:text:0',
                    'document': 'matched text',
                    'metadata': {
                      'fileObjectId': 'file-a',
                      'sourcePath': 'a.txt',
                      'fileType': 'TXT',
                      'space': 'text',
                    },
                  },
                ],
              }
            : {'removed': body['fileObjectId']};
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(response));
      }
      await request.response.close();
    });
    final client = ChromaClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    try {
      expect(await client.count(), 3);
      final hits = await client.searchSpace(
        space: VectorSpaceKind.text,
        embedding: const [0.6, 0.8],
        terms: const ['matched'],
        limit: 4,
      );
      expect(hits.first.fileObjectId, 'file-a');
      expect(hits.first.sourcePath, 'a.txt');
      expect(hits.first.distance, 0.1);
      expect(hits.first.vectorMatched, isTrue);
      expect(hits.first.keywordMatched, isTrue);
      expect(hits.first.relevanceScore, isNotNull);
      final filtered = await client.searchSpace(
        space: VectorSpaceKind.text,
        embedding: const [0.6, 0.8],
        terms: const ['matched'],
        limit: 4,
        fileType: 'pdf',
      );
      expect(filtered.single.fileObjectId, 'file-b');
      await client.removeFileObject('file-a');
      expect(requests[0]['path'], '/search-space');
      expect(requests[0]['contentLength'], greaterThan(0));
      expect(requests[0]['space'], 'text');
      expect(requests[0]['terms'], ['matched']);
      expect(requests[1]['limit'], 12);
      expect(requests[2], containsPair('fileObjectId', 'file-a'));
    } finally {
      client.close();
      await server.close(force: true);
      await subscription.cancel();
    }
  });

  test('supports legacy search, writes, and paged query refinement', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String, Map<String, dynamic>>{};
    Map<String, Object?> hit(String id) => {
      'id': id,
      'document': 'document $id',
      'distance': 0.2,
      'metadata': {
        'fileObjectId': 'file-$id',
        'sourcePath': '$id.pdf',
        'fileType': 'PDF',
        'space': 'text',
      },
    };
    Map<String, Object?> page(String token, int index) => {
      'queryToken': token,
      'totalFiles': 2,
      'pageIndex': index,
      'pageSize': 1,
      'files': [hit('page-$index')],
      'availableFileTypes': ['PDF', 'TXT'],
      'totalIsFinal': index > 0,
      'hasMore': index == 0,
    };
    final subscription = server.listen((request) async {
      final body = request.method == 'POST'
          ? Map<String, dynamic>.from(
              jsonDecode(await utf8.decodeStream(request)) as Map,
            )
          : <String, dynamic>{};
      requests[request.uri.path] = body;
      final response = switch (request.uri.path) {
        '/upsert' => {'upserted': (body['rows'] as List).length},
        '/search' => {
          'vector': [
            {
              'id': 'candidate',
              'text': 'candidate text',
              'distance': 0.4,
              'metadata': {
                'sourcePath': 'candidate.txt',
                'fileType': 'TXT',
                'chunkIndex': 1,
                'pageIndex': 2,
                'startOffset': 3,
                'endOffset': 4,
              },
            },
          ],
          'keyword': <Object>[],
        },
        '/search-space' => {
          'results': [hit('legacy')],
        },
        '/prepare-file-query' => page('prepared', 0),
        '/file-query-page' => page('prepared', body['pageIndex'] as int),
        '/refine-file-query' => page('refined', 0),
        _ => <String, Object?>{},
      };
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(response));
      await request.response.close();
    });
    final client = ChromaClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    try {
      expect(
        await client.upsert(const [
          IndexedChunk(
            id: 'chunk',
            text: 'text',
            sourcePath: 'a.txt',
            fileType: 'TXT',
            chunkIndex: 0,
            embedding: [1, 0],
          ),
        ]),
        1,
      );
      expect(await client.upsert(const []), 0);
      final candidates = await client.search(
        embedding: const [1, 0],
        terms: const ['candidate'],
        limit: 2,
      );
      expect(candidates.vector.single.pageIndex, 2);
      final legacy = await client.searchSpace(
        space: VectorSpaceKind.image,
        embedding: const [1, 0],
        fileType: 'pdf',
      );
      expect(legacy.single.fileObjectId, 'file-legacy');

      final prepared = await client.prepareFileQuery(
        vectors: const [
          FileQueryVector(
            space: VectorSpaceKind.text,
            embedding: [1, 0],
            terms: ['term'],
            allowedRecordKinds: {'raw', 'contentSummary'},
            allowedInformationKinds: {'nativeText'},
          ),
        ],
        fileNameHits: legacy,
        pageSize: 1,
        fileType: 'PDF',
        fileTypeFilterEnabled: true,
        allowedFileTypes: const {'PDF'},
        includeOtherFileTypes: true,
        knownFileTypes: const {'PDF', 'TXT'},
        allowedFileObjectIds: const {'file-legacy'},
        fileObjectOrder: const ['file-legacy'],
        includeNativeText: true,
        includeExtractedText: false,
        relevanceScope: RelevanceScope.strict,
      );
      expect(prepared.queryToken, 'prepared');
      expect(prepared.availableFileTypes, {'PDF', 'TXT'});
      expect(prepared.hasMore, isTrue);
      final second = await client.loadFileQueryPage('prepared', 1);
      expect(second.pageIndex, 1);
      expect(second.totalIsFinal, isTrue);
      final refined = await client.refineFileQuery(
        'prepared',
        const FileQueryRefinement(
          fileTypeFilterEnabled: true,
          allowedFileTypes: {'TXT'},
          includeOtherFileTypes: false,
          knownFileTypes: {'TXT'},
          sort: 'fileName',
        ),
      );
      expect(refined.queryToken, 'refined');
      expect(requests['/prepare-file-query'], containsPair('pageSize', 1));
      expect(
        requests['/prepare-file-query'],
        containsPair('relevanceScope', 'strict'),
      );
      expect(requests['/refine-file-query'], containsPair('sort', 'fileName'));
    } finally {
      client.close();
      await server.close(force: true);
      await subscription.cancel();
    }
  });
}

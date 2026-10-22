import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/models/file_metadata.dart';
import 'package:retrieval/core/models/parsing_result.dart';
import 'package:retrieval/domain/file_object.dart';
import 'package:retrieval/embedding/embedding_result.dart';
import 'package:retrieval/embedding/embedding_space.dart';
import 'package:retrieval/embedding/multimodal_embedding_engine.dart';
import 'package:retrieval/embedding/source_reference.dart';
import 'package:retrieval/storage/chroma_client.dart';
import 'package:retrieval/storage/multimodal_vector_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'Dart client reaches real Chroma hybrid search over loopback HTTP',
    () async {
      final serviceScript = p.join(
        Directory.current.path,
        'services',
        'chroma',
        'service.py',
      );
      expect(await File(serviceScript).exists(), isTrue);
      final temporary = await Directory.systemTemp.createTemp(
        'chroma-hybrid-http-',
      );
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final python = Platform.environment['SXSX_PYTHON'] ?? 'python';
      final process = await Process.start(
        python,
        [
          '-B',
          serviceScript,
          '--data-dir',
          p.join(temporary.path, 'chroma'),
          '--port',
          '$port',
        ],
        workingDirectory: Directory.current.path,
        environment: {'ANONYMIZED_TELEMETRY': 'False'},
      );
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      process.stdout.transform(utf8.decoder).listen(stdout.write);
      process.stderr.transform(utf8.decoder).listen(stderr.write);
      final client = ChromaClient(baseUri: Uri.parse('http://127.0.0.1:$port'));
      try {
        var ready = false;
        for (var attempt = 0; attempt < 80; attempt++) {
          try {
            await client.count();
            ready = true;
            break;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(
          ready,
          isTrue,
          reason: 'Service did not become ready. stdout=$stdout stderr=$stderr',
        );

        final object = _textObject(
          path: p.join(temporary.path, 'sample.txt'),
          text: 'distinctive offline retrieval example',
          objectVersion: 1,
        );
        final written = await client.replaceFileObject(object);
        expect(written.textRecordIds.single, contains(':v1:text:0'));

        final hits = await client.searchSpace(
          space: VectorSpaceKind.text,
          embedding: _vector(),
          terms: const ['distinctive'],
          limit: 5,
        );
        expect(hits, isNotEmpty);
        expect(hits.first.fileObjectId, object.fileObjectId);
        expect(hits.first.vectorMatched, isTrue);
        expect(hits.first.keywordMatched, isTrue);
        expect(hits.first.relevanceScore, isNotNull);
      } finally {
        client.close();
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));
        if (await temporary.exists()) await temporary.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

FileObject _textObject({
  required String path,
  required String text,
  required int objectVersion,
}) {
  final content = ExtractedFileContent(
    textInformation: [
      TextInformation(
        text: text,
        extractionMethod: TextExtractionMethod.direct,
        sourcePath: path,
        regions: const [],
      ),
    ],
    imageInformation: const [],
    audioInformation: const [],
    videoInformation: const [],
    issues: const [],
    status: ExtractionStatus.completed,
  );
  var object = FileObject.fromParsingResult(
    ParsingResult(
      metadata: FileMetadata(
        filePath: path,
        detectedFileType: 'TXT',
        fileSize: text.length,
        modifiedTime: DateTime.utc(2026),
      ),
      content: content,
    ),
    origin: FileObjectOrigin.indexedLibrary,
    objectVersion: objectVersion,
  );
  object = object.withEmbeddings(
    MultimodalEmbeddingBatch(
      textEmbeddings: [
        EmbeddingResult(
          vector: _vector(),
          space: EmbeddingSpace.bertText,
          modality: EmbeddingModality.text,
          model: 'integration-test',
          source: SourceReference(
            sourcePath: path,
            informationIndex: 0,
            chunkIndex: 0,
            startOffset: 0,
            endOffset: text.length,
          ),
        ),
      ],
      imageEmbeddings: const [],
      audioEmbeddings: const [],
      ignoredVideoCount: 0,
      issues: const [],
      status: EmbeddingStatus.completed,
    ),
  );
  return object;
}

List<double> _vector() => [1.0, ...List<double>.filled(767, 0.0)];

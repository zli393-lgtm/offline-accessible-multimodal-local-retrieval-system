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
    'real loopback Chroma sustains 300 objects and repeated hybrid queries',
    () async {
      final temporary = await Directory.systemTemp.createTemp('chroma-stress-');
      final serviceScript = p.join(
        Directory.current.path,
        'services',
        'chroma',
        'service.py',
      );
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final process = await Process.start(
        Platform.environment['SXSX_PYTHON'] ?? 'python',
        [
          '-B',
          serviceScript,
          '--data-dir',
          p.join(temporary.path, 'chroma'),
          '--port',
          '$port',
        ],
        workingDirectory: Directory.current.path,
        environment: const {'ANONYMIZED_TELEMETRY': 'False'},
      );
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      process.stdout.transform(utf8.decoder).listen(stdout.write);
      process.stderr.transform(utf8.decoder).listen(stderr.write);
      final client = ChromaClient(baseUri: Uri.parse('http://127.0.0.1:$port'));
      addTearDown(() async {
        client.close();
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });

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
      expect(ready, isTrue, reason: 'stdout=$stdout stderr=$stderr');

      final writeTimer = Stopwatch()..start();
      for (var index = 0; index < 300; index++) {
        await client.replaceFileObject(_object(index));
      }
      writeTimer.stop();
      expect(await client.count(), 300);

      final latencies = <int>[];
      for (var index = 0; index < 50; index++) {
        final timer = Stopwatch()..start();
        final hits = await client.searchSpace(
          space: VectorSpaceKind.text,
          embedding: _vector(index),
          terms: ['unique-keyword-$index'],
          limit: 10,
        );
        timer.stop();
        latencies.add(timer.elapsedMicroseconds);
        expect(hits, isNotEmpty);
        expect(
          hits.any((hit) => hit.document.contains('unique-keyword-$index')),
          isTrue,
        );
      }
      latencies.sort();
      final average =
          latencies.reduce((left, right) => left + right) /
          latencies.length /
          1000;
      final p95 = latencies[(latencies.length * 0.95).ceil() - 1] / 1000;
      // These bounds catch pathological regressions without pretending that
      // one development machine defines product-wide latency guarantees.
      expect(average, lessThan(1000));
      expect(p95, lessThan(2000));
      // ignore: avoid_print
      print(
        'CHROMA STRESS | objects=300 queries=50 '
        'write_ms=${writeTimer.elapsedMilliseconds} '
        'average_query_ms=${average.toStringAsFixed(3)} '
        'p95_query_ms=${p95.toStringAsFixed(3)}',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

FileObject _object(int index) {
  final path = 'stress/document-$index.txt';
  final text = 'fixed stress document unique-keyword-$index';
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
    objectVersion: 1,
  );
  object = object.withEmbeddings(
    MultimodalEmbeddingBatch(
      textEmbeddings: [
        EmbeddingResult(
          vector: _vector(index),
          space: EmbeddingSpace.bertText,
          modality: EmbeddingModality.text,
          model: 'stress-fixture',
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

List<double> _vector(int index) {
  final vector = List<double>.filled(768, 0);
  vector[index % 128] = 1;
  vector[128 + (index ~/ 128)] = 0.25;
  return vector;
}

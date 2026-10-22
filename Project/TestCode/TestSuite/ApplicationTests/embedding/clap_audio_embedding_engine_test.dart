import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/embedding/audio/clap_audio_embedding_engine.dart';
import 'package:retrieval/embedding/embedding_space.dart';
import 'package:retrieval/embedding/model_vector.dart';
import 'package:retrieval/embedding/source_reference.dart';

class _FakeClapBackend implements ClapBackend {
  List<String> materializedPaths = [];
  List<String> queries = [];
  List<ModelVector>? audioResults;
  List<ModelVector>? textResults;

  @override
  Future<List<ModelVector>> embedAudioFiles(List<String> filePaths) async {
    materializedPaths = [...filePaths];
    for (final path in filePaths) {
      expect(await File(path).exists(), isTrue);
    }
    return audioResults ??
        List.generate(
          filePaths.length,
          (_) =>
              const ModelVector(model: 'clap-htsat-fused', vector: [0.6, 0.8]),
        );
  }

  @override
  Future<List<ModelVector>> embedTextQueries(List<String> texts) async {
    queries = [...texts];
    return textResults ??
        List.generate(
          texts.length,
          (_) =>
              const ModelVector(model: 'clap-htsat-fused', vector: [0.8, 0.6]),
        );
  }
}

AudioInformation _audio() => AudioInformation(
  sourcePath: 'presentation.pptx',
  bytes: Uint8List.fromList([1, 2, 3]),
  format: 'WAV',
  regions: const [
    ContentRegion(startTime: Duration(milliseconds: 20)),
    ContentRegion(endTime: Duration(milliseconds: 920)),
  ],
);

void main() {
  test(
    'Python CLAP backend runs real audio and text batches locally',
    () async {
      final application = Directory.current.path;
      final backend = PythonClapBackend(
        pythonExecutable: Platform.environment['EMBEDDING_PYTHON'] ?? 'python',
        scriptPath: 'services/embedding/embedding_service.py',
        modelPath: [
          application,
          '..',
          '..',
          'Dependencies',
          'Packageable',
          'Models',
          'audio',
          'clap-htsat-fused',
        ].join(Platform.pathSeparator),
        workingDirectory: application,
      );
      final audioPath =
          Platform.environment['SXSX_TEST_AUDIO'] ??
          [
            application,
            '..',
            'TestCode',
            'TestSuite',
            'Resources',
            'audio_integration_brooklyn.flac',
          ].join(Platform.pathSeparator);
      final audio = await backend.embedAudioFiles([audioPath]);
      final texts = await backend.embedTextQueries(['spoken question']);
      expect(audio.single.vector, hasLength(512));
      expect(texts.single.vector, hasLength(512));
      expect(audio.single.model, 'clap-htsat-fused');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('embeds audio in a batch and preserves time provenance', () async {
    final backend = _FakeClapBackend();
    final engine = ClapAudioEmbeddingEngine(backend: backend);
    final results = await engine.embedAudioBatch([_audio(), _audio()]);
    expect(results, hasLength(2));
    expect(results.first.space, EmbeddingSpace.clap);
    expect(results.first.modality, EmbeddingModality.audio);
    expect(results.first.source.sourcePath, 'presentation.pptx');
    expect(results.first.source.startTimeMs, 20);
    expect(results.first.source.endTimeMs, 920);
    for (final path in backend.materializedPaths) {
      expect(await File(path).exists(), isFalse);
    }
  });

  test('creates CLAP text-query vectors in the audio space', () async {
    final backend = _FakeClapBackend();
    final engine = ClapAudioEmbeddingEngine(backend: backend);
    final results = await engine.embedTextQueriesBatch(
      texts: const ['applause', 'piano music'],
      sources: const [
        SourceReference(sourcePath: '<query-1>'),
        SourceReference(sourcePath: '<query-2>'),
      ],
    );
    expect(backend.queries, ['applause', 'piano music']);
    expect(results, hasLength(2));
    expect(results.first.modality, EmbeddingModality.text);
    expect(results.first.space, EmbeddingSpace.clap);
  });

  test('validates audio bytes and text-query inputs', () async {
    final backend = _FakeClapBackend();
    final engine = ClapAudioEmbeddingEngine(backend: backend);
    await expectLater(
      engine.embedAudioBatch([
        AudioInformation(sourcePath: 'empty.wav', bytes: Uint8List(0)),
      ]),
      throwsArgumentError,
    );
    await expectLater(
      engine.embedTextQueriesBatch(
        texts: const ['one', 'two'],
        sources: const [SourceReference(sourcePath: '<query>')],
      ),
      throwsArgumentError,
    );
    await expectLater(
      engine.embedTextQueriesBatch(
        texts: const ['  '],
        sources: const [SourceReference(sourcePath: '<query>')],
      ),
      throwsArgumentError,
    );
  });
}

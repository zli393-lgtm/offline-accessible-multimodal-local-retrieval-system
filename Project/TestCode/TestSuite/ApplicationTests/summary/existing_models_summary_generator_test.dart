import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/embedding/audio/clap_audio_embedding_engine.dart';
import 'package:retrieval/embedding/embedding_engine.dart';
import 'package:retrieval/embedding/embedding_result.dart';
import 'package:retrieval/embedding/embedding_space.dart';
import 'package:retrieval/embedding/image/mobile_clip_image_embedding_engine.dart';
import 'package:retrieval/embedding/source_reference.dart';
import 'package:retrieval/summary/backends/existing_models/existing_models_summary_generator.dart';
import 'package:retrieval/summary/summary_generator.dart';

EmbeddingResult _result(
  SourceReference source,
  EmbeddingSpace space,
  EmbeddingModality modality,
) => EmbeddingResult(
  vector: const [1, 0],
  space: space,
  modality: modality,
  model: 'existing-model',
  source: source,
);

class _Text implements EmbeddingEngine {
  @override
  Future<EmbeddingResult> embedText({
    required String text,
    required SourceReference source,
  }) async => _result(source, EmbeddingSpace.bertText, EmbeddingModality.text);

  @override
  Future<List<EmbeddingResult>> embedTextBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) async => sources
      .map((source) => _result(
            source,
            EmbeddingSpace.bertText,
            EmbeddingModality.text,
          ))
      .toList();

  @override
  Future<List<EmbeddingResult>> embedLongTextBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) => embedTextBatch(texts: texts, sources: sources);
}

class _Image implements ImageEmbeddingEngine {
  @override
  Future<List<EmbeddingResult>> embedImagesBatch(
    List<ImageInformation> images,
  ) async => List.generate(
    images.length,
    (index) => _result(
      SourceReference(sourcePath: images[index].sourcePath),
      EmbeddingSpace.mobileClip,
      EmbeddingModality.image,
    ),
  );

  @override
  Future<List<EmbeddingResult>> embedTextQueriesBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) async => sources
      .map((source) => _result(
            source,
            EmbeddingSpace.mobileClip,
            EmbeddingModality.text,
          ))
      .toList();
}

class _Audio implements AudioEmbeddingEngine {
  @override
  Future<List<EmbeddingResult>> embedAudioBatch(
    List<AudioInformation> audioInformation,
  ) async => List.generate(
    audioInformation.length,
    (index) => _result(
      SourceReference(sourcePath: audioInformation[index].sourcePath),
      EmbeddingSpace.clap,
      EmbeddingModality.audio,
    ),
  );

  @override
  Future<List<EmbeddingResult>> embedTextQueriesBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) async => sources
      .map((source) => _result(
            source,
            EmbeddingSpace.clap,
            EmbeddingModality.text,
          ))
      .toList();
}

void main() {
  test('produces four first-level summaries and one overall summary', () async {
    final generator = ExistingModelsSummaryGenerator(
      textEngine: _Text(),
      imageEngine: _Image(),
      audioEngine: _Audio(),
    );
    final content = ExtractedFileContent(
      textInformation: const [
        TextInformation(
          text: 'apples bananas pears are described in this catalogue',
          extractionMethod: TextExtractionMethod.direct,
          sourcePath: 'fruit.pdf',
          regions: [],
        ),
        TextInformation(
          text: 'artist piano concert',
          extractionMethod: TextExtractionMethod.speechRecognition,
          sourcePath: 'fruit.pdf',
          regions: [],
        ),
      ],
      imageInformation: [
        ImageInformation(
          sourcePath: 'fruit.pdf',
          format: 'PNG',
          pixelWidth: 640,
          pixelHeight: 480,
          frameCount: 1,
          colorMode: 'RGB',
          hasAlpha: false,
          bytes: Uint8List(0),
          semanticVector: const [],
        ),
      ],
      audioInformation: [
        AudioInformation(
          sourcePath: 'fruit.pdf',
          bytes: Uint8List(0),
          format: 'MP3',
          tags: const {'title': 'Concert', 'artist': 'Performer'},
        ),
      ],
      videoInformation: const [],
      issues: const [],
      status: ExtractionStatus.completed,
    );

    final result = await generator.generate(content);

    expect(result.firstLevel.map((item) => item.sourceKind), containsAll([
      SummarySourceKind.nativeText,
      SummarySourceKind.extractedText,
      SummarySourceKind.image,
      SummarySourceKind.audio,
    ]));
    expect(result.overall?.sourceKind, SummarySourceKind.overallSummary);
    expect(result.overall?.text, contains('原生文字、提取文字、图像、音频'));
    expect(
      result.firstLevel
          .singleWhere((item) => item.sourceKind == SummarySourceKind.audio)
          .text,
      contains('title: Concert'),
    );
  });

  test('does not create absent-modality summaries', () async {
    final generator = ExistingModelsSummaryGenerator(
      textEngine: _Text(),
      imageEngine: _Image(),
      audioEngine: _Audio(),
    );
    final result = await generator.generate(const ExtractedFileContent(
      textInformation: [],
      imageInformation: [],
      audioInformation: [],
      videoInformation: [],
      issues: [],
      status: ExtractionStatus.completed,
    ));
    expect(result.isEmpty, isTrue);
  });
}

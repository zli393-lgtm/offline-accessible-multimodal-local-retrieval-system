import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/embedding/audio/clap_audio_embedding_engine.dart';
import 'package:retrieval/embedding/embedding_engine.dart';
import 'package:retrieval/embedding/embedding_result.dart';
import 'package:retrieval/embedding/embedding_space.dart';
import 'package:retrieval/embedding/image/mobile_clip_image_embedding_engine.dart';
import 'package:retrieval/embedding/model_vector.dart';
import 'package:retrieval/embedding/multimodal_embedding_engine.dart';
import 'package:retrieval/embedding/source_reference.dart';
import 'package:retrieval/summary/summary_generator.dart';

class _FakeSummaryGenerator implements SummaryGenerator {
  @override
  Future<FileSummaryBundle> generate(ExtractedFileContent content) async =>
      const FileSummaryBundle(
        firstLevel: [
          GeneratedSummary(
            sourceKind: SummarySourceKind.nativeText,
            text: 'generated native summary',
          ),
          GeneratedSummary(
            sourceKind: SummarySourceKind.image,
            text: 'generated image summary',
          ),
        ],
        overall: GeneratedSummary(
          sourceKind: SummarySourceKind.overallSummary,
          text: 'generated overall summary',
        ),
      );
}

class _CountingSummaryGenerator implements SummaryGenerator {
  int calls = 0;

  @override
  Future<FileSummaryBundle> generate(ExtractedFileContent content) async {
    calls++;
    return const FileSummaryBundle(
      firstLevel: [
        GeneratedSummary(
          sourceKind: SummarySourceKind.nativeText,
          text: 'first level',
        ),
      ],
      overall: GeneratedSummary(
        sourceKind: SummarySourceKind.overallSummary,
        text: 'overall',
      ),
    );
  }
}

EmbeddingResult _result({
  required EmbeddingSpace space,
  required EmbeddingModality modality,
  required SourceReference source,
}) => EmbeddingResult(
  vector: const [0.6, 0.8],
  space: space,
  modality: modality,
  model: space.name,
  source: source,
);

class _FakeTextEngine implements EmbeddingEngine {
  Object? error;

  @override
  Future<EmbeddingResult> embedText({
    required String text,
    required SourceReference source,
  }) async {
    if (error != null) throw error!;
    return _result(
      space: EmbeddingSpace.bertText,
      modality: EmbeddingModality.text,
      source: source,
    );
  }

  @override
  Future<List<EmbeddingResult>> embedTextBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) async => List.generate(
    texts.length,
    (index) => _result(
      space: EmbeddingSpace.bertText,
      modality: EmbeddingModality.text,
      source: sources[index],
    ),
  );

  @override
  Future<List<EmbeddingResult>> embedLongTextBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) async {
    if (error != null) throw error!;
    return embedTextBatch(texts: texts, sources: sources);
  }
}

class _FakeImageEngine implements ImageEmbeddingEngine {
  Object? error;

  @override
  Future<List<EmbeddingResult>> embedImagesBatch(
    List<ImageInformation> images,
  ) async {
    if (error != null) throw error!;
    return List.generate(
      images.length,
      (index) => _result(
        space: EmbeddingSpace.mobileClip,
        modality: EmbeddingModality.image,
        source: SourceReference(
          sourcePath: images[index].sourcePath,
          informationIndex: index,
        ),
      ),
    );
  }

  @override
  Future<List<EmbeddingResult>> embedTextQueriesBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) async => List.generate(
    texts.length,
    (index) => _result(
      space: EmbeddingSpace.mobileClip,
      modality: EmbeddingModality.text,
      source: sources[index],
    ),
  );
}

class _FakeAudioEngine implements AudioEmbeddingEngine {
  Object? error;

  @override
  Future<List<EmbeddingResult>> embedAudioBatch(
    List<AudioInformation> audioInformation,
  ) async {
    if (error != null) throw error!;
    return List.generate(
      audioInformation.length,
      (index) => _result(
        space: EmbeddingSpace.clap,
        modality: EmbeddingModality.audio,
        source: SourceReference(
          sourcePath: audioInformation[index].sourcePath,
          informationIndex: index,
        ),
      ),
    );
  }

  @override
  Future<List<EmbeddingResult>> embedTextQueriesBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) async => List.generate(
    texts.length,
    (index) => _result(
      space: EmbeddingSpace.clap,
      modality: EmbeddingModality.text,
      source: sources[index],
    ),
  );
}

ExtractedFileContent _content() => ExtractedFileContent(
  textInformation: const [
    TextInformation(
      text: 'document text',
      extractionMethod: TextExtractionMethod.direct,
      sourcePath: 'document.pdf',
      regions: [ContentRegion(pageIndex: 3)],
    ),
  ],
  imageInformation: [
    ImageInformation(
      sourcePath: 'document.pdf',
      format: 'PNG',
      pixelWidth: 1,
      pixelHeight: 1,
      frameCount: 1,
      colorMode: 'RGBA',
      hasAlpha: true,
      bytes: Uint8List.fromList([1]),
      semanticVector: const [],
    ),
  ],
  audioInformation: [
    AudioInformation(
      sourcePath: 'document.pdf',
      bytes: Uint8List.fromList([2]),
    ),
  ],
  videoInformation: [
    VideoInformation(sourcePath: 'ignored.mp4', bytes: Uint8List.fromList([3])),
  ],
  issues: const [],
  status: ExtractionStatus.completed,
);

void main() {
  test(
    'dispatches extracted information by text, image, and audio type',
    () async {
      final engine = MultimodalEmbeddingEngine(
        textEngine: _FakeTextEngine(),
        imageEngine: _FakeImageEngine(),
        audioEngine: _FakeAudioEngine(),
      );
      final result = await engine.embedContent(_content());
      expect(result.status, EmbeddingStatus.completed);
      expect(result.textEmbeddings, hasLength(2));
      expect(result.imageEmbeddings, hasLength(2));
      expect(result.audioEmbeddings, hasLength(2));
      expect(result.all, hasLength(6));
      expect(result.ignoredVideoCount, 1);
      expect(result.textEmbeddings.first.source.pageIndex, 3);
      for (final values in [
        result.textEmbeddings,
        result.imageEmbeddings,
        result.audioEmbeddings,
      ]) {
        expect(values.last.source.summaryKind, 'semanticSummary');
        expect(values.last.source.summaryLevel, 'first');
      }
    },
  );

  test(
    'batches multiple outer-file objects without file-type routing',
    () async {
      final engine = MultimodalEmbeddingEngine(
        textEngine: _FakeTextEngine(),
        imageEngine: _FakeImageEngine(),
        audioEngine: _FakeAudioEngine(),
      );
      final result = await engine.embedContents([_content(), _content()]);
      expect(result.textEmbeddings, hasLength(2));
      expect(result.imageEmbeddings, hasLength(2));
      expect(result.audioEmbeddings, hasLength(2));
      expect(result.ignoredVideoCount, 2);
    },
  );

  test('keeps successful modalities when one embedding type fails', () async {
    final image = _FakeImageEngine()..error = StateError('image failed');
    final engine = MultimodalEmbeddingEngine(
      textEngine: _FakeTextEngine(),
      imageEngine: image,
      audioEngine: _FakeAudioEngine(),
    );
    final result = await engine.embedContent(_content());
    expect(result.status, EmbeddingStatus.partial);
    expect(result.textEmbeddings, hasLength(2));
    expect(result.imageEmbeddings, isEmpty);
    expect(result.audioEmbeddings, hasLength(2));
    expect(result.issues.single.modality, 'image');
  });

  test('creates one compatible text query for every vector space', () async {
    final engine = MultimodalEmbeddingEngine(
      textEngine: _FakeTextEngine(),
      imageEngine: _FakeImageEngine(),
      audioEngine: _FakeAudioEngine(),
    );
    final result = await engine.embedQuery('find a piano beside a red bicycle');
    expect(result.textSearch.space, EmbeddingSpace.bertText);
    expect(result.imageSearch.space, EmbeddingSpace.mobileClip);
    expect(result.audioSearch.space, EmbeddingSpace.clap);
    await expectLater(engine.embedQuery('  '), throwsArgumentError);
  });

  test(
    'embeds first-level and overall generated summaries separately',
    () async {
      final engine = MultimodalEmbeddingEngine(
        textEngine: _FakeTextEngine(),
        imageEngine: _FakeImageEngine(),
        audioEngine: _FakeAudioEngine(),
        summaryGenerator: _FakeSummaryGenerator(),
      );
      final result = await engine.embedContent(_content());
      final generated = result.textEmbeddings
          .where((item) => item.source.summaryKind != null)
          .toList();
      expect(
        generated.where((item) => item.source.summaryKind == 'contentSummary'),
        hasLength(2),
      );
      expect(
        generated.where((item) => item.source.summaryKind == 'overallSummary'),
        hasLength(1),
      );
      expect(
        generated.map((item) => item.source.queryInformationKind),
        containsAll(['nativeText', 'image', 'overallSummary']),
      );
    },
  );

  test('does not calculate disabled summaries for query content', () async {
    final generator = _CountingSummaryGenerator();
    final engine = MultimodalEmbeddingEngine(
      textEngine: _FakeTextEngine(),
      imageEngine: _FakeImageEngine(),
      audioEngine: _FakeAudioEngine(),
      summaryGenerator: generator,
    );
    final result = await engine.embedContent(
      _content(),
      summaryOptions: const SummaryEmbeddingOptions(
        includeContentSummaries: false,
        includeSemanticSummaries: false,
        includeOverallSummary: false,
      ),
    );
    expect(generator.calls, 0);
    expect(
      result.all.where((item) => item.source.summaryKind != null),
      isEmpty,
    );
  });

  test('calculates only the selected content summary levels', () async {
    final generator = _CountingSummaryGenerator();
    final engine = MultimodalEmbeddingEngine(
      textEngine: _FakeTextEngine(),
      imageEngine: _FakeImageEngine(),
      audioEngine: _FakeAudioEngine(),
      summaryGenerator: generator,
    );
    final result = await engine.embedContent(
      _content(),
      summaryOptions: const SummaryEmbeddingOptions(
        includeContentSummaries: false,
        includeSemanticSummaries: false,
        includeOverallSummary: true,
      ),
    );
    expect(generator.calls, 1);
    expect(
      result.textEmbeddings.where(
        (item) => item.source.summaryKind == 'contentSummary',
      ),
      isEmpty,
    );
    expect(
      result.textEmbeddings.where(
        (item) => item.source.summaryKind == 'overallSummary',
      ),
      hasLength(1),
    );
  });

  test('generates selected summaries for a query description', () async {
    final withoutGenerator = MultimodalEmbeddingEngine(
      textEngine: _FakeTextEngine(),
      imageEngine: _FakeImageEngine(),
      audioEngine: _FakeAudioEngine(),
    );
    expect(withoutGenerator.canGenerateContentSummaries, isFalse);
    expect(
      await withoutGenerator.embedGeneratedSummariesForText(
        'query',
        includeContentSummaries: true,
        includeOverallSummary: true,
      ),
      isEmpty,
    );

    final engine = MultimodalEmbeddingEngine(
      textEngine: _FakeTextEngine(),
      imageEngine: _FakeImageEngine(),
      audioEngine: _FakeAudioEngine(),
      summaryGenerator: _FakeSummaryGenerator(),
    );
    expect(engine.canGenerateContentSummaries, isTrue);
    expect(
      await engine.embedGeneratedSummariesForText(
        '   ',
        includeContentSummaries: true,
        includeOverallSummary: true,
      ),
      isEmpty,
    );
    expect(
      await engine.embedGeneratedSummariesForText(
        'query',
        includeContentSummaries: false,
        includeOverallSummary: false,
      ),
      isEmpty,
    );
    final generated = await engine.embedGeneratedSummariesForText(
      '  several kinds of fruit  ',
      includeContentSummaries: true,
      includeOverallSummary: true,
    );
    expect(
      generated.map((item) => item.source.summaryKind).toSet(),
      {'contentSummary', 'overallSummary'},
    );
  });

  test('validates serialized model-vector dimensions', () {
    final vector = ModelVector.fromJson({
      'model': 'test',
      'dimensions': 2,
      'vector': [0.6, 0.8],
    });
    expect(vector.vector, [0.6, 0.8]);
    expect(
      () => ModelVector.fromJson({
        'model': 'bad',
        'dimensions': 3,
        'vector': [1.0],
      }),
      throwsFormatException,
    );
  });
}

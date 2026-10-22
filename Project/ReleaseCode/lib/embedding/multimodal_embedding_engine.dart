import '../core/models/extracted_file_content.dart';
import '../core/parsing/parser.dart';
import 'audio/clap_audio_embedding_engine.dart';
import 'embedding_engine.dart';
import 'embedding_result.dart';
import 'image/mobile_clip_image_embedding_engine.dart';
import 'source_reference.dart';
import 'text/bert_text_embedding_engine.dart';
import '../summary/summary_generator.dart';
import '../summary/backends/existing_models/existing_models_summary_generator.dart';

enum EmbeddingStatus { completed, partial, failed }

class SummaryEmbeddingOptions {
  final bool includeContentSummaries;
  final bool includeSemanticSummaries;
  final bool includeOverallSummary;

  const SummaryEmbeddingOptions({
    required this.includeContentSummaries,
    required this.includeSemanticSummaries,
    required this.includeOverallSummary,
  });

  static const all = SummaryEmbeddingOptions(
    includeContentSummaries: true,
    includeSemanticSummaries: true,
    includeOverallSummary: true,
  );
}

class EmbeddingIssue {
  final String modality;
  final String message;

  const EmbeddingIssue({required this.modality, required this.message});
}

class MultimodalEmbeddingBatch {
  final List<EmbeddingResult> textEmbeddings;
  final List<EmbeddingResult> imageEmbeddings;
  final List<EmbeddingResult> audioEmbeddings;
  final int ignoredVideoCount;
  final List<EmbeddingIssue> issues;
  final EmbeddingStatus status;

  const MultimodalEmbeddingBatch({
    required this.textEmbeddings,
    required this.imageEmbeddings,
    required this.audioEmbeddings,
    required this.ignoredVideoCount,
    required this.issues,
    required this.status,
  });

  List<EmbeddingResult> get all => [
    ...textEmbeddings,
    ...imageEmbeddings,
    ...audioEmbeddings,
  ];
}

class MultimodalQueryEmbeddings {
  final EmbeddingResult textSearch;
  final EmbeddingResult imageSearch;
  final EmbeddingResult audioSearch;

  const MultimodalQueryEmbeddings({
    required this.textSearch,
    required this.imageSearch,
    required this.audioSearch,
  });
}

/// Dispatches already-extracted information by information type, not by file
/// extension. File-type routing remains the responsibility of the parsing layer.
class MultimodalEmbeddingEngine {
  final EmbeddingEngine textEngine;
  final ImageEmbeddingEngine imageEngine;
  final AudioEmbeddingEngine audioEngine;
  final int textInformationBatchSize;
  final int imageBatchSize;
  final int audioBatchSize;
  final SummaryGenerator? summaryGenerator;

  const MultimodalEmbeddingEngine({
    required this.textEngine,
    required this.imageEngine,
    required this.audioEngine,
    this.textInformationBatchSize = 8,
    this.imageBatchSize = 8,
    this.audioBatchSize = 1,
    this.summaryGenerator,
  }) : assert(textInformationBatchSize > 0),
       assert(imageBatchSize > 0),
       assert(audioBatchSize > 0);

  bool get canGenerateContentSummaries => summaryGenerator != null;

  Future<List<EmbeddingResult>> embedGeneratedSummariesForText(
    String text, {
    required bool includeContentSummaries,
    required bool includeOverallSummary,
  }) async {
    if (summaryGenerator == null ||
        text.trim().isEmpty ||
        (!includeContentSummaries && !includeOverallSummary)) {
      return const [];
    }
    final content = ExtractedFileContent(
      textInformation: [
        TextInformation(
          text: text.trim(),
          extractionMethod: TextExtractionMethod.direct,
          sourcePath: '<query-description>',
          regions: const [],
        ),
      ],
      imageInformation: const [],
      audioInformation: const [],
      videoInformation: const [],
      issues: const [],
      status: ExtractionStatus.completed,
    );
    final batch = await embedContent(
      content,
      summaryOptions: SummaryEmbeddingOptions(
        includeContentSummaries: includeContentSummaries,
        includeSemanticSummaries: false,
        includeOverallSummary: includeOverallSummary,
      ),
    );
    return batch.textEmbeddings
        .where(
          (item) =>
              item.source.summaryKind == 'contentSummary' ||
              item.source.summaryKind == 'overallSummary',
        )
        .toList(growable: false);
  }

  static Future<MultimodalEmbeddingEngine> load({
    required String mobileClipModelPath,
    required String clapModelPath,
    String pythonExecutable = 'python',
    String? workingDirectory,
    String device = 'cpu',
    SummaryGenerator? summaryGenerator,
  }) async {
    final text = await BertTextEmbeddingEngine.load();
    final image = MobileClipImageEmbeddingEngine.python(
      modelPath: mobileClipModelPath,
      pythonExecutable: pythonExecutable,
      workingDirectory: workingDirectory,
      device: device,
    );
    final audio = ClapAudioEmbeddingEngine.python(
      modelPath: clapModelPath,
      pythonExecutable: pythonExecutable,
      workingDirectory: workingDirectory,
      device: device,
    );
    return MultimodalEmbeddingEngine(
      textEngine: text,
      imageEngine: image,
      audioEngine: audio,
      summaryGenerator:
          summaryGenerator ??
          ExistingModelsSummaryGenerator(
            textEngine: text,
            imageEngine: image,
            audioEngine: audio,
          ),
    );
  }

  Future<MultimodalEmbeddingBatch> embedContent(
    ExtractedFileContent content, {
    FileProcessingObserver? observer,
    SummaryEmbeddingOptions summaryOptions = SummaryEmbeddingOptions.all,
  }) async {
    final batch = await embedContents([content], observer: observer);
    final semantic = summaryOptions.includeSemanticSummaries
        ? _withSemanticSummaries(content, batch)
        : batch;
    return _withGeneratedSummaries(content, semantic, options: summaryOptions);
  }

  Future<MultimodalEmbeddingBatch> _withGeneratedSummaries(
    ExtractedFileContent content,
    MultimodalEmbeddingBatch batch, {
    required SummaryEmbeddingOptions options,
  }) async {
    final generator = summaryGenerator;
    if (generator == null ||
        (!options.includeContentSummaries && !options.includeOverallSummary)) {
      return batch;
    }
    try {
      final bundle = await generator.generate(content);
      final summaries = <GeneratedSummary>[
        if (options.includeContentSummaries) ...bundle.firstLevel,
        if (options.includeOverallSummary && bundle.overall != null)
          bundle.overall!,
      ].where((item) => item.text.trim().isNotEmpty).toList(growable: false);
      if (summaries.isEmpty) return batch;
      final generated = <EmbeddingResult>[];
      for (final summary in summaries) {
        final level = summary.sourceKind == SummarySourceKind.overallSummary
            ? 'second'
            : 'first';
        generated.addAll(
          await textEngine.embedLongTextBatch(
            texts: [summary.text.trim()],
            sources: [
              SourceReference(
                sourcePath: '<generated-summary>',
                queryInformationKind: summary.sourceKind.name,
                summaryKind: level == 'second'
                    ? 'overallSummary'
                    : 'contentSummary',
                summaryLevel: level,
                summaryText: summary.text.trim(),
              ),
            ],
          ),
        );
      }
      return MultimodalEmbeddingBatch(
        textEmbeddings: List.unmodifiable([
          ...batch.textEmbeddings,
          ...generated,
        ]),
        imageEmbeddings: batch.imageEmbeddings,
        audioEmbeddings: batch.audioEmbeddings,
        ignoredVideoCount: batch.ignoredVideoCount,
        issues: batch.issues,
        status: batch.status,
      );
    } catch (error) {
      return MultimodalEmbeddingBatch(
        textEmbeddings: batch.textEmbeddings,
        imageEmbeddings: batch.imageEmbeddings,
        audioEmbeddings: batch.audioEmbeddings,
        ignoredVideoCount: batch.ignoredVideoCount,
        issues: List.unmodifiable([
          ...batch.issues,
          EmbeddingIssue(modality: 'summary', message: '$error'),
        ]),
        status: batch.all.isEmpty
            ? EmbeddingStatus.failed
            : EmbeddingStatus.partial,
      );
    }
  }

  MultimodalEmbeddingBatch _withSemanticSummaries(
    ExtractedFileContent content,
    MultimodalEmbeddingBatch batch,
  ) {
    EmbeddingResult? aggregate(
      List<EmbeddingResult> values,
      String informationKind,
    ) {
      if (values.isEmpty) return null;
      final dimensions = values.first.vector.length;
      if (dimensions == 0 ||
          values.any((value) => value.vector.length != dimensions)) {
        return null;
      }
      final vector = List<double>.filled(dimensions, 0);
      for (final value in values) {
        for (var index = 0; index < dimensions; index++) {
          vector[index] += value.vector[index];
        }
      }
      var norm = 0.0;
      for (var index = 0; index < dimensions; index++) {
        vector[index] /= values.length;
        norm += vector[index] * vector[index];
      }
      if (norm > 0) {
        final scale = 1 / _sqrt(norm);
        for (var index = 0; index < dimensions; index++) {
          vector[index] *= scale;
        }
      }
      final first = values.first;
      return EmbeddingResult(
        vector: List.unmodifiable(vector),
        space: first.space,
        modality: first.modality,
        model: '${first.model}:mean-pool-v1',
        source: SourceReference(
          sourcePath: first.source.sourcePath,
          queryInformationKind: informationKind,
          summaryKind: 'semanticSummary',
          summaryLevel: 'first',
        ),
      );
    }

    bool isExtracted(TextInformation information) =>
        information.extractionMethod == TextExtractionMethod.ocr ||
        information.extractionMethod ==
            TextExtractionMethod.speechRecognition ||
        information.extractionMethod == TextExtractionMethod.other ||
        information.informationKind == TextInformationKind.ocr ||
        information.informationKind == TextInformationKind.speechTranscript ||
        information.informationKind == TextInformationKind.metadata;

    final native = <EmbeddingResult>[];
    final extracted = <EmbeddingResult>[];
    for (final value in batch.textEmbeddings) {
      final index = value.source.informationIndex;
      if (index == null ||
          index < 0 ||
          index >= content.textInformation.length) {
        continue;
      }
      (isExtracted(content.textInformation[index]) ? extracted : native).add(
        value,
      );
    }
    final text = [...batch.textEmbeddings];
    final nativeSummary = aggregate(native, 'nativeText');
    final extractedSummary = aggregate(extracted, 'extractedText');
    if (nativeSummary != null) text.add(nativeSummary);
    if (extractedSummary != null) text.add(extractedSummary);

    final image = [...batch.imageEmbeddings];
    final imageSummary = aggregate(batch.imageEmbeddings, 'image');
    if (imageSummary != null) image.add(imageSummary);

    final audio = [...batch.audioEmbeddings];
    final audioSummary = aggregate(batch.audioEmbeddings, 'audio');
    if (audioSummary != null) audio.add(audioSummary);

    return MultimodalEmbeddingBatch(
      textEmbeddings: List.unmodifiable(text),
      imageEmbeddings: List.unmodifiable(image),
      audioEmbeddings: List.unmodifiable(audio),
      ignoredVideoCount: batch.ignoredVideoCount,
      issues: batch.issues,
      status: batch.status,
    );
  }

  double _sqrt(double value) {
    if (value <= 0) return 0;
    var estimate = value > 1 ? value : 1.0;
    for (var index = 0; index < 12; index++) {
      estimate = (estimate + value / estimate) / 2;
    }
    return estimate;
  }

  /// Batches information from multiple outer-file objects while retaining
  /// each item's original source path and region provenance.
  Future<MultimodalEmbeddingBatch> embedContents(
    List<ExtractedFileContent> contents, {
    FileProcessingObserver? observer,
  }) async {
    var textResults = <EmbeddingResult>[];
    var imageResults = <EmbeddingResult>[];
    var audioResults = <EmbeddingResult>[];
    final issues = <EmbeddingIssue>[];

    final textInformation = contents
        .expand((content) => content.textInformation)
        .toList(growable: false);
    final imageInformation = contents
        .expand((content) => content.imageInformation)
        .toList(growable: false);
    final audioInformation = contents
        .expand((content) => content.audioInformation)
        .toList(growable: false);
    final ignoredVideoCount = contents.fold<int>(
      0,
      (total, content) => total + content.videoInformation.length,
    );

    final textItems = textInformation
        .asMap()
        .entries
        .where((entry) => entry.value.text.trim().isNotEmpty)
        .toList(growable: false);
    if (textItems.isNotEmpty) {
      try {
        for (
          var offset = 0;
          offset < textItems.length;
          offset += textInformationBatchSize
        ) {
          await reportFileProcessing(
            observer,
            FileProcessingStage.textChunking,
            completedUnits: offset,
            totalUnits: textItems.length,
          );
          await reportFileProcessing(
            observer,
            FileProcessingStage.textEmbedding,
            completedUnits: offset,
            totalUnits: textItems.length,
          );
          final batch = textItems
              .skip(offset)
              .take(textInformationBatchSize)
              .toList(growable: false);
          textResults.addAll(
            await textEngine.embedLongTextBatch(
              texts: batch.map((entry) => entry.value.text).toList(),
              sources: batch.map((entry) {
                final information = entry.value;
                final region = information.regions.isEmpty
                    ? null
                    : information.regions.first;
                return SourceReference(
                  sourcePath: information.sourcePath,
                  informationIndex: entry.key,
                  pageIndex: region?.pageIndex,
                  frameIndex: region?.frameIndex,
                  startTimeMs: region?.startTime?.inMilliseconds,
                  endTimeMs: region?.endTime?.inMilliseconds,
                );
              }).toList(),
            ),
          );
        }
        await reportFileProcessing(
          observer,
          FileProcessingStage.textChunking,
          completedUnits: textItems.length,
          totalUnits: textItems.length,
        );
        await reportFileProcessing(
          observer,
          FileProcessingStage.textEmbedding,
          completedUnits: textItems.length,
          totalUnits: textItems.length,
        );
      } catch (error) {
        if (error is FileProcessingInterrupted) rethrow;
        issues.add(EmbeddingIssue(modality: 'text', message: '$error'));
      }
    }

    if (imageInformation.isNotEmpty) {
      try {
        for (
          var offset = 0;
          offset < imageInformation.length;
          offset += imageBatchSize
        ) {
          await reportFileProcessing(
            observer,
            FileProcessingStage.imageEmbedding,
            completedUnits: offset,
            totalUnits: imageInformation.length,
          );
          imageResults.addAll(
            await imageEngine.embedImagesBatch(
              imageInformation.skip(offset).take(imageBatchSize).toList(),
            ),
          );
        }
        await reportFileProcessing(
          observer,
          FileProcessingStage.imageEmbedding,
          completedUnits: imageInformation.length,
          totalUnits: imageInformation.length,
        );
      } catch (error) {
        if (error is FileProcessingInterrupted) rethrow;
        issues.add(EmbeddingIssue(modality: 'image', message: '$error'));
      }
    }

    if (audioInformation.isNotEmpty) {
      try {
        for (
          var offset = 0;
          offset < audioInformation.length;
          offset += audioBatchSize
        ) {
          await reportFileProcessing(
            observer,
            FileProcessingStage.audioEmbedding,
            completedUnits: offset,
            totalUnits: audioInformation.length,
          );
          audioResults.addAll(
            await audioEngine.embedAudioBatch(
              audioInformation.skip(offset).take(audioBatchSize).toList(),
            ),
          );
        }
        await reportFileProcessing(
          observer,
          FileProcessingStage.audioEmbedding,
          completedUnits: audioInformation.length,
          totalUnits: audioInformation.length,
        );
      } catch (error) {
        if (error is FileProcessingInterrupted) rethrow;
        issues.add(EmbeddingIssue(modality: 'audio', message: '$error'));
      }
    }

    final attemptedKinds = [
      textItems.isNotEmpty,
      imageInformation.isNotEmpty,
      audioInformation.isNotEmpty,
    ].where((attempted) => attempted).length;
    final succeededKinds = [
      textResults.isNotEmpty,
      imageResults.isNotEmpty,
      audioResults.isNotEmpty,
    ].where((succeeded) => succeeded).length;
    final status = issues.isEmpty
        ? EmbeddingStatus.completed
        : succeededKinds == 0 && attemptedKinds > 0
        ? EmbeddingStatus.failed
        : EmbeddingStatus.partial;

    return MultimodalEmbeddingBatch(
      textEmbeddings: textResults,
      imageEmbeddings: imageResults,
      audioEmbeddings: audioResults,
      ignoredVideoCount: ignoredVideoCount,
      issues: issues,
      status: status,
    );
  }

  /// Produces one text query in every compatible vector space. BERT queries
  /// search text, MobileCLIP text queries search images, and CLAP text queries
  /// search audio. These three vectors must be stored and compared separately.
  Future<MultimodalQueryEmbeddings> embedQuery(String query) async {
    if (query.trim().isEmpty) {
      throw ArgumentError('查询文字不能为空。');
    }
    final source = const SourceReference(sourcePath: '<query>');
    final text = await textEngine.embedText(text: query, source: source);
    final image = (await imageEngine.embedTextQueriesBatch(
      texts: [query],
      sources: [source],
    )).single;
    final audio = (await audioEngine.embedTextQueriesBatch(
      texts: [query],
      sources: [source],
    )).single;
    return MultimodalQueryEmbeddings(
      textSearch: text,
      imageSearch: image,
      audioSearch: audio,
    );
  }

  void close() {
    final engine = textEngine;
    if (engine is BertTextEmbeddingEngine) {
      engine.close();
    }
  }
}

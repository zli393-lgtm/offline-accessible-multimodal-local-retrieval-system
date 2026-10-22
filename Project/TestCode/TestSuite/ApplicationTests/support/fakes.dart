import 'dart:io';
import 'dart:typed_data';

import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/models/file_metadata.dart';
import 'package:retrieval/core/models/parsing_result.dart';
import 'package:retrieval/core/parsing/parser.dart';
import 'package:retrieval/domain/file_object.dart';
import 'package:retrieval/embedding/audio/clap_audio_embedding_engine.dart';
import 'package:retrieval/embedding/embedding_engine.dart';
import 'package:retrieval/embedding/embedding_result.dart';
import 'package:retrieval/embedding/embedding_space.dart';
import 'package:retrieval/embedding/image/mobile_clip_image_embedding_engine.dart';
import 'package:retrieval/embedding/multimodal_embedding_engine.dart';
import 'package:retrieval/embedding/source_reference.dart';
import 'package:retrieval/storage/multimodal_vector_store.dart';

EmbeddingResult fakeEmbedding({
  required EmbeddingSpace space,
  required EmbeddingModality modality,
  required SourceReference source,
  List<double> vector = const [0.6, 0.8],
}) => EmbeddingResult(
  vector: vector,
  space: space,
  modality: modality,
  model: 'fake-${space.name}',
  source: source,
);

class FakeTextEngine implements EmbeddingEngine {
  final List<int> observedBatchSizes = [];

  @override
  Future<EmbeddingResult> embedText({
    required String text,
    required SourceReference source,
  }) async => fakeEmbedding(
    space: EmbeddingSpace.bertText,
    modality: EmbeddingModality.text,
    source: source,
  );

  @override
  Future<List<EmbeddingResult>> embedTextBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) async {
    observedBatchSizes.add(texts.length);
    return List.generate(
      texts.length,
      (index) => fakeEmbedding(
        space: EmbeddingSpace.bertText,
        modality: EmbeddingModality.text,
        source: sources[index],
      ),
    );
  }

  @override
  Future<List<EmbeddingResult>> embedLongTextBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) => embedTextBatch(texts: texts, sources: sources);
}

class FakeImageEngine implements ImageEmbeddingEngine {
  final List<int> observedBatchSizes = [];

  @override
  Future<List<EmbeddingResult>> embedImagesBatch(
    List<ImageInformation> images,
  ) async {
    observedBatchSizes.add(images.length);
    return List.generate(
      images.length,
      (index) => fakeEmbedding(
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
    (index) => fakeEmbedding(
      space: EmbeddingSpace.mobileClip,
      modality: EmbeddingModality.text,
      source: sources[index],
    ),
  );
}

class FakeAudioEngine implements AudioEmbeddingEngine {
  final List<int> observedBatchSizes = [];

  @override
  Future<List<EmbeddingResult>> embedAudioBatch(
    List<AudioInformation> audioInformation,
  ) async {
    observedBatchSizes.add(audioInformation.length);
    return List.generate(
      audioInformation.length,
      (index) => fakeEmbedding(
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
    (index) => fakeEmbedding(
      space: EmbeddingSpace.clap,
      modality: EmbeddingModality.text,
      source: sources[index],
    ),
  );
}

MultimodalEmbeddingEngine fakeMultimodalEngine({
  int textBatchSize = 8,
  int imageBatchSize = 8,
  int audioBatchSize = 1,
  FakeTextEngine? text,
  FakeImageEngine? image,
  FakeAudioEngine? audio,
}) => MultimodalEmbeddingEngine(
  textEngine: text ?? FakeTextEngine(),
  imageEngine: image ?? FakeImageEngine(),
  audioEngine: audio ?? FakeAudioEngine(),
  textInformationBatchSize: textBatchSize,
  imageBatchSize: imageBatchSize,
  audioBatchSize: audioBatchSize,
);

ExtractedFileContent fakeContent(
  String path, {
  String text = 'text',
  bool withImage = false,
  bool withAudio = false,
  List<ExtractionIssue> issues = const [],
  ExtractionStatus status = ExtractionStatus.completed,
}) => ExtractedFileContent(
  textInformation: text.isEmpty
      ? const []
      : [
          TextInformation(
            text: text,
            extractionMethod: TextExtractionMethod.direct,
            sourcePath: path,
            regions: const [],
          ),
        ],
  imageInformation: withImage
      ? [
          ImageInformation(
            sourcePath: path,
            format: 'PNG',
            pixelWidth: 1,
            pixelHeight: 1,
            frameCount: 1,
            colorMode: 'RGBA',
            hasAlpha: true,
            bytes: Uint8List.fromList([1]),
            semanticVector: const [],
          ),
        ]
      : const [],
  audioInformation: withAudio
      ? [
          AudioInformation(sourcePath: path, bytes: Uint8List.fromList([2])),
        ]
      : const [],
  videoInformation: const [],
  issues: issues,
  status: status,
);

class FakeParser implements Parser {
  final Map<String, Object> failures = {};
  final Map<String, ExtractedFileContent> contentByPath = {};
  final List<String> calls = [];

  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async {
    await reportFileProcessing(observer, FileProcessingStage.reading);
    calls.add(filePath);
    final failure = failures[filePath];
    if (failure != null) throw failure;
    final file = File(filePath);
    final stat = await file.stat();
    return ParsingResult(
      metadata: FileMetadata(
        filePath: filePath,
        detectedFileType: 'TEST',
        fileSize: stat.size,
        modifiedTime: stat.modified,
      ),
      content: contentByPath[filePath] ?? fakeContent(filePath),
    );
  }
}

class FakeVectorStore implements MultimodalVectorStore {
  final List<FileObject> replaced = [];
  final List<String> removed = [];
  final List<
    ({
      VectorSpaceKind space,
      List<double> vector,
      List<String> terms,
      String? fileType,
    })
  >
  searches = [];
  final Map<VectorSpaceKind, List<VectorSearchHit>> results = {};

  @override
  Future<FileIndexWriteResult> replaceFileObject(
    FileObject object, {
    FileProcessingObserver? observer,
  }) async {
    await reportFileProcessing(observer, FileProcessingStage.indexStaging);
    List<String> ids(VectorSpaceKind space, int count) => List.generate(
      count,
      (index) => '${object.fileObjectId}:${space.name}:$index',
    );
    await reportFileProcessing(observer, FileProcessingStage.indexValidation);
    await reportFileProcessing(observer, FileProcessingStage.indexCommit);
    replaced.add(object);
    final result = FileIndexWriteResult(
      textRecordIds: ids(
        VectorSpaceKind.text,
        object.analysis.textEmbeddings.length,
      ),
      imageRecordIds: ids(
        VectorSpaceKind.image,
        object.analysis.imageEmbeddings.length,
      ),
      audioRecordIds: ids(
        VectorSpaceKind.audio,
        object.analysis.audioEmbeddings.length,
      ),
    );
    final total =
        result.textRecordIds.length +
        result.imageRecordIds.length +
        result.audioRecordIds.length;
    await reportFileProcessing(
      observer,
      FileProcessingStage.indexCommit,
      completedUnits: total,
      totalUnits: total,
    );
    return result;
  }

  @override
  Future<void> removeFileObject(String fileObjectId) async {
    removed.add(fileObjectId);
  }

  @override
  Future<List<VectorSearchHit>> searchSpace({
    required VectorSpaceKind space,
    required List<double> embedding,
    List<String> terms = const [],
    int limit = 10,
    String? fileType,
  }) async {
    searches.add((
      space: space,
      vector: List.of(embedding),
      terms: List.of(terms),
      fileType: fileType,
    ));
    return (results[space] ?? const [])
        .where(
          (hit) =>
              fileType == null ||
              fileType.trim().isEmpty ||
              hit.fileType.toUpperCase() == fileType.trim().toUpperCase(),
        )
        .take(limit)
        .toList();
  }
}

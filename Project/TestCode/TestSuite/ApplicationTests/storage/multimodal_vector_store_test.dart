import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/models/file_metadata.dart';
import 'package:retrieval/core/models/parsing_result.dart';
import 'package:retrieval/domain/file_object.dart';
import 'package:retrieval/embedding/embedding_result.dart';
import 'package:retrieval/embedding/embedding_space.dart';
import 'package:retrieval/embedding/multimodal_embedding_engine.dart';
import 'package:retrieval/embedding/source_reference.dart';
import 'package:retrieval/storage/multimodal_vector_store.dart';

void main() {
  test('serializes text, image, and audio into separate vector spaces', () {
    const path = 'compound.pptx';
    final content = ExtractedFileContent(
      textInformation: const [
        TextInformation(
          text: 'slide text',
          extractionMethod: TextExtractionMethod.direct,
          sourcePath: path,
          regions: [],
        ),
      ],
      imageInformation: [
        ImageInformation(
          sourcePath: path,
          format: 'PNG',
          pixelWidth: 1,
          pixelHeight: 1,
          frameCount: 1,
          colorMode: 'RGBA',
          hasAlpha: true,
          bytes: Uint8List(1),
          semanticVector: const [],
        ),
      ],
      audioInformation: [
        AudioInformation(sourcePath: path, bytes: Uint8List(1)),
      ],
      videoInformation: const [],
      issues: const [],
      status: ExtractionStatus.completed,
    );
    var object = FileObject.fromParsingResult(
      ParsingResult(
        metadata: FileMetadata(
          filePath: path,
          detectedFileType: 'PPTX',
          fileSize: 1,
          modifiedTime: DateTime.utc(2026),
        ),
        content: content,
      ),
      origin: FileObjectOrigin.indexedLibrary,
    );
    object = object.withEmbeddings(
      MultimodalEmbeddingBatch(
        textEmbeddings: const [
          EmbeddingResult(
            vector: [1, 0],
            space: EmbeddingSpace.bertText,
            modality: EmbeddingModality.text,
            model: 'bert',
            source: SourceReference(sourcePath: path, informationIndex: 0),
          ),
        ],
        imageEmbeddings: const [
          EmbeddingResult(
            vector: [0, 1],
            space: EmbeddingSpace.mobileClip,
            modality: EmbeddingModality.image,
            model: 'mobileclip',
            source: SourceReference(sourcePath: path, informationIndex: 0),
          ),
        ],
        audioEmbeddings: const [
          EmbeddingResult(
            vector: [0.5, 0.5],
            space: EmbeddingSpace.clap,
            modality: EmbeddingModality.audio,
            model: 'clap',
            source: SourceReference(sourcePath: path, informationIndex: 0),
          ),
        ],
        ignoredVideoCount: 0,
        issues: const [],
        status: EmbeddingStatus.completed,
      ),
    );

    final records = FileVectorRecords.fromObject(object);
    expect(records.text.single.space, VectorSpaceKind.text);
    expect(records.text.single.document, 'slide text');
    expect(records.image.single.space, VectorSpaceKind.image);
    expect(records.audio.single.space, VectorSpaceKind.audio);
    expect({
      records.text.single.id,
      records.image.single.id,
      records.audio.single.id,
    }, hasLength(3));
    expect(records.text.single.id, contains(':v1:text:'));
    expect(records.text.single.metadata['objectVersion'], 1);
    expect(records.text.single.metadata['fileExtension'], 'PPTX');
    expect(records.text.single.metadata['textInformationKind'], 'plainText');
    expect(records.text.single.metadata['textExtractionMethod'], 'direct');
  });

  test('literal suffix keeps aliases and compound extensions distinct', () {
    expect(literalFileExtension('/images/photo.jpg'), 'JPG');
    expect(literalFileExtension('/books/title.fb2.zip'), 'FB2_ZIP');
    expect(literalFileExtension('/files/README'), isEmpty);
  });

  test('maps each model family to only its compatible search space', () {
    expect(vectorSpaceKind(EmbeddingSpace.bertText), VectorSpaceKind.text);
    expect(vectorSpaceKind(EmbeddingSpace.mobileClip), VectorSpaceKind.image);
    expect(vectorSpaceKind(EmbeddingSpace.clap), VectorSpaceKind.audio);
  });
}

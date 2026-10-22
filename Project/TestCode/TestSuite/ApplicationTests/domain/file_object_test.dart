import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/models/file_metadata.dart';
import 'package:retrieval/core/models/parsing_result.dart';
import 'package:retrieval/domain/file_object.dart';

void main() {
  test('one outer file owns unified text and separate media properties', () {
    final content = ExtractedFileContent(
      textInformation: const [
        TextInformation(
          text: 'direct text',
          extractionMethod: TextExtractionMethod.direct,
          sourcePath: 'sample.pdf',
          regions: [],
        ),
        TextInformation(
          text: 'OCR text',
          extractionMethod: TextExtractionMethod.ocr,
          informationKind: TextInformationKind.ocr,
          sourcePath: 'sample.pdf',
          regions: [],
        ),
        TextInformation(
          text: 'OCR text',
          extractionMethod: TextExtractionMethod.ocr,
          sourcePath: 'sample.pdf',
          regions: [],
        ),
      ],
      imageInformation: [
        ImageInformation(
          sourcePath: 'sample.pdf',
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
        AudioInformation(sourcePath: 'sample.pdf', bytes: Uint8List(1)),
      ],
      videoInformation: const [],
      issues: const [],
      status: ExtractionStatus.completed,
    );
    final object = FileObject.fromParsingResult(
      ParsingResult(
        metadata: FileMetadata(
          filePath: 'sample.pdf',
          detectedFileType: 'PDF',
          fileSize: 42,
          modifiedTime: DateTime.utc(2026),
        ),
        content: content,
      ),
      origin: FileObjectOrigin.indexedLibrary,
    );

    expect(object.text.value, 'direct text\nOCR text\nOCR text');
    expect(object.text.sources, hasLength(3));
    expect(object.content.imageInformation, hasLength(1));
    expect(object.content.audioInformation, hasLength(1));
    expect(object.analysis.textEmbeddings, isEmpty);
    expect(object.analysis.imageEmbeddings, isEmpty);
    expect(object.analysis.audioEmbeddings, isEmpty);
    expect(object.index.status, FileIndexStatus.notIndexed);
  });

  test('file IDs are stable for normalized paths', () {
    expect(
      FileObjectIds.fromPath('folder/../folder/file.txt'),
      FileObjectIds.fromPath('folder/file.txt'),
    );
    expect(
      FileObjectIds.fromPath('folder/file.txt'),
      isNot(FileObjectIds.fromPath('folder/other.txt')),
    );
  });

  test('equal content at different paths remains different file objects', () {
    expect(
      FileObjectIds.fromPath('library/first/report.pdf'),
      isNot(FileObjectIds.fromPath('library/backup/report.pdf')),
    );
  });

  test('moving a path creates a new file object identity', () {
    expect(
      FileObjectIds.fromPath('library/before/report.pdf'),
      isNot(FileObjectIds.fromPath('library/after/report.pdf')),
    );
  });
}

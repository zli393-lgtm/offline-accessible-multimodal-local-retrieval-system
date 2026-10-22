import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/file_io/static_image_file_types.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/parsing/static_image_parser.dart';

class _FakeStaticImageBackend implements StaticImageBackend {
  StaticImageMetadata metadata;
  StaticImageOcrResult ocrResult;
  StaticImageSemanticResult semanticResult;
  Object? inspectError;
  Object? ocrError;
  Object? semanticError;
  final List<String> calls = [];

  _FakeStaticImageBackend({
    this.metadata = const StaticImageMetadata(
      format: 'PNG',
      width: 640,
      height: 480,
      frameCount: 1,
      colorMode: 'RGBA',
      hasAlpha: true,
      pixels: [1, 2, 3, 4],
      rowStride: 4,
    ),
    this.ocrResult = const StaticImageOcrResult(
      text: '图片中的文字',
      languages: 'chi_sim+eng',
      meanConfidence: 96.5,
      words: [
        OcrWord(
          text: '图片中的文字',
          confidence: 96.5,
          left: 10,
          top: 20,
          width: 120,
          height: 30,
        ),
      ],
    ),
    this.semanticResult = const StaticImageSemanticResult(
      model: 'mobileclip_s0',
      dimensions: 3,
      vector: [0.1, 0.2, 0.3],
    ),
    this.inspectError,
    this.ocrError,
    this.semanticError,
  });

  @override
  Future<StaticImageMetadata> inspect(
    String filePath, {
    int frameIndex = 0,
  }) async {
    calls.add('inspect:$frameIndex');
    if (inspectError != null) throw inspectError!;
    return metadata;
  }

  @override
  Future<StaticImageOcrResult> extractText(
    String filePath, {
    required String languages,
    int frameIndex = 0,
  }) async {
    calls.add('ocr:$languages:$frameIndex');
    if (ocrError != null) throw ocrError!;
    return ocrResult;
  }

  @override
  Future<StaticImageSemanticResult> analyzeImage(
    String filePath, {
    int frameIndex = 0,
  }) async {
    calls.add('image_semantics:$frameIndex');
    if (semanticError != null) throw semanticError!;
    return semanticResult;
  }
}

Future<File> _temporaryImage(String extension) async {
  final directory = await Directory.systemTemp.createTemp();
  final file = File('${directory.path}/sample.$extension');
  await file.writeAsBytes([1, 2, 3, 4]);
  return file;
}

Future<void> _deleteFixture(File file) => file.parent.delete(recursive: true);

void main() {
  test('StaticImageFileTypes covers supported static bitmap extensions', () {
    for (final extension in [
      'jpg',
      'jpeg',
      'jfif',
      'png',
      'bmp',
      'tiff',
      'webp',
      'gif',
      'pnm',
    ]) {
      expect(
        StaticImageFileTypes.supports('sample.$extension'),
        isTrue,
        reason: extension,
      );
    }
    expect(StaticImageFileTypes.supports('sample.svg'), isFalse);
    expect(StaticImageFileTypes.supports('sample.pdf'), isFalse);
  });

  test('StaticImageParser returns all fixed information categories', () async {
    final file = await _temporaryImage('png');
    final backend = _FakeStaticImageBackend();
    final parser = StaticImageParser(backend: backend);

    final result = await parser.parse(file.path);

    expect(backend.calls, [
      'inspect:0',
      'ocr:chi_sim+eng:0',
      'image_semantics:0',
    ]);
    expect(result.metadata.detectedFileType, 'PNG');
    expect(result.content.status, ExtractionStatus.completed);
    expect(result.content.textInformation, hasLength(1));
    expect(result.content.textInformation.single.text, '图片中的文字');
    expect(
      result.content.textInformation.single.extractionMethod,
      TextExtractionMethod.ocr,
    );
    expect(result.content.textInformation.single.regions, hasLength(1));
    expect(
      result.content.textInformation.single.regions.single.extractedText,
      '图片中的文字',
    );
    expect(
      result.content.textInformation.single.regions.single.confidence,
      96.5,
    );
    expect(result.content.imageInformation, hasLength(1));
    expect(
      result.content.imageInformation.single.semanticModel,
      'mobileclip_s0',
    );
    expect(result.content.imageInformation.single.semanticVector, hasLength(3));
    expect(result.content.imageInformation.single.hasDecodedPixels, isTrue);
    expect(result.content.imageInformation.single.pixelFormat, 'RGBA8888');
    expect(
      result.content.imageInformation.single.informationKind,
      ImageInformationKind.sourceBitmap,
    );
    expect(result.content.audioInformation, isEmpty);
    expect(result.content.videoInformation, isEmpty);

    await _deleteFixture(file);
  });

  test('StaticImageParser keeps image data when OCR finds no text', () async {
    final file = await _temporaryImage('png');
    final backend = _FakeStaticImageBackend(
      ocrResult: const StaticImageOcrResult(
        text: '',
        languages: 'chi_sim+eng',
        meanConfidence: null,
        words: [],
      ),
    );

    final result = await StaticImageParser(backend: backend).parse(file.path);

    expect(result.content.textInformation, isEmpty);
    expect(result.content.imageInformation, hasLength(1));
    expect(result.content.imageInformation.single.hasSemanticAnalysis, isTrue);
    expect(result.content.status, ExtractionStatus.completed);

    await _deleteFixture(file);
  });

  test(
    'StaticImageParser continues visual analysis after OCR failure',
    () async {
      final file = await _temporaryImage('png');
      final backend = _FakeStaticImageBackend(
        ocrError: StateError('OCR unavailable'),
      );

      final result = await StaticImageParser(backend: backend).parse(file.path);

      expect(backend.calls, [
        'inspect:0',
        'ocr:chi_sim+eng:0',
        'image_semantics:0',
      ]);
      expect(result.content.textInformation, isEmpty);
      expect(
        result.content.imageInformation.single.hasSemanticAnalysis,
        isTrue,
      );
      expect(result.content.status, ExtractionStatus.partial);
      expect(result.content.issues.single.stage, 'ocr');

      await _deleteFixture(file);
    },
  );

  test(
    'StaticImageParser preserves OCR after semantic-analysis failure',
    () async {
      final file = await _temporaryImage('png');
      final backend = _FakeStaticImageBackend(
        semanticError: StateError('Model unavailable'),
      );

      final result = await StaticImageParser(backend: backend).parse(file.path);

      expect(result.content.textInformation.single.text, '图片中的文字');
      expect(
        result.content.imageInformation.single.hasSemanticAnalysis,
        isFalse,
      );
      expect(result.content.status, ExtractionStatus.partial);
      expect(result.content.issues.single.stage, 'image_semantics');

      await _deleteFixture(file);
    },
  );

  test('StaticImageParser reads every animated frame in order', () async {
    final file = await _temporaryImage('gif');
    final backend = _FakeStaticImageBackend(
      metadata: const StaticImageMetadata(
        format: 'GIF',
        width: 100,
        height: 100,
        frameCount: 2,
        colorMode: 'P',
        hasAlpha: false,
      ),
    );

    final result = await StaticImageParser(backend: backend).parse(file.path);

    expect(result.content.imageInformation, hasLength(2));
    expect(
      result.content.imageInformation
          .map((item) => item.region?.frameIndex)
          .toList(),
      [0, 1],
    );
    expect(
      result.content.imageInformation
          .map((item) => item.informationKind)
          .toSet(),
      {ImageInformationKind.animationFrame},
    );
    expect(result.content.textInformation, hasLength(1));
    expect(result.content.textInformation.single.regions, hasLength(2));
    expect(backend.calls, [
      'inspect:0',
      'ocr:chi_sim+eng:0',
      'image_semantics:0',
      'inspect:1',
      'ocr:chi_sim+eng:1',
      'image_semantics:1',
    ]);

    await _deleteFixture(file);
  });

  test('StaticImageParser records extension and content mismatch', () async {
    final file = await _temporaryImage('png');
    final backend = _FakeStaticImageBackend(
      metadata: const StaticImageMetadata(
        format: 'JPEG',
        width: 320,
        height: 200,
        frameCount: 1,
        colorMode: 'RGB',
        hasAlpha: false,
      ),
    );

    final result = await StaticImageParser(backend: backend).parse(file.path);

    expect(result.metadata.detectedFileType, 'JPEG');
    expect(result.content.status, ExtractionStatus.completed);
    expect(result.content.issues, hasLength(1));
    expect(
      result.content.issues.single.severity,
      ExtractionIssueSeverity.warning,
    );

    await _deleteFixture(file);
  });

  test('StaticImageParser throws when file does not exist', () async {
    final parser = StaticImageParser(backend: _FakeStaticImageBackend());

    await expectLater(
      parser.parse('missing.png'),
      throwsA(isA<FileSystemException>()),
    );
  });
}

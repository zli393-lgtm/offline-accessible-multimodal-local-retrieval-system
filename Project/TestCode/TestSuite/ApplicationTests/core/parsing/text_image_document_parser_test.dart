import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/file_io/text_image_document_file_types.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/parsing/static_image_parser.dart';
import 'package:retrieval/core/parsing/text_image_document_parser.dart';

class _FakeDocumentBackend implements TextImageDocumentBackend {
  @override
  Future<TextImageDocumentExtraction> extract(
    String filePath, {
    required String outputDirectory,
  }) async {
    final image = File('$outputDirectory${Platform.pathSeparator}embedded.ppm');
    await image.writeAsString('P3\n1 1\n255\n255 255 255\n');
    return TextImageDocumentExtraction(
      detectedFormat: 'XPS',
      textBlocks: const [
        DocumentTextBlock(
          text: 'direct document text',
          pageIndex: 0,
          sourceOrder: 0,
        ),
      ],
      imageParts: [
        DocumentImagePart(
          filePath: image.path,
          sourceName: 'Documents/1/Resources/embedded.ppm',
          pageIndex: 0,
          sourceOrder: 1,
        ),
      ],
      issues: const [],
    );
  }
}

class _FakeImageBackend implements StaticImageBackend {
  final Object? ocrError;
  final Object? semanticError;
  final List<String> calls = [];

  _FakeImageBackend({this.ocrError, this.semanticError});

  @override
  Future<StaticImageMetadata> inspect(
    String filePath, {
    int frameIndex = 0,
  }) async {
    calls.add('inspect');
    return const StaticImageMetadata(
      format: 'PPM',
      width: 1,
      height: 1,
      frameCount: 1,
      colorMode: 'RGB',
      hasAlpha: false,
    );
  }

  @override
  Future<StaticImageOcrResult> extractText(
    String filePath, {
    required String languages,
    int frameIndex = 0,
  }) async {
    calls.add('ocr:$languages');
    if (ocrError != null) throw ocrError!;
    return const StaticImageOcrResult(
      text: 'image text',
      languages: 'chi_sim+eng',
      meanConfidence: 88,
      words: [
        OcrWord(
          text: 'image text',
          confidence: 88,
          left: 0,
          top: 0,
          width: 1,
          height: 1,
        ),
      ],
    );
  }

  @override
  Future<StaticImageSemanticResult> analyzeImage(
    String filePath, {
    int frameIndex = 0,
  }) async {
    calls.add('semantics');
    if (semanticError != null) throw semanticError!;
    return const StaticImageSemanticResult(
      model: 'mobileclip_s0',
      dimensions: 3,
      vector: [0.1, 0.2, 0.3],
    );
  }
}

class _ProblemDocumentBackend implements TextImageDocumentBackend {
  final String detectedFormat;

  const _ProblemDocumentBackend({this.detectedFormat = 'XPS'});

  @override
  Future<TextImageDocumentExtraction> extract(
    String filePath, {
    required String outputDirectory,
  }) async {
    final real = await File('$outputDirectory/real.dat').writeAsBytes([1, 2]);
    return TextImageDocumentExtraction(
      detectedFormat: detectedFormat,
      textBlocks: const [
        DocumentTextBlock(text: ' ', pageIndex: null, sourceOrder: 3),
        DocumentTextBlock(text: 'later', pageIndex: 2, sourceOrder: 2),
      ],
      imageParts: [
        DocumentImagePart(
          filePath: '$outputDirectory/../outside.png',
          sourceName: 'outside.png',
          pageIndex: null,
          sourceOrder: 0,
        ),
        DocumentImagePart(
          filePath: '$outputDirectory/missing.png',
          sourceName: 'missing.png',
          pageIndex: 0,
          sourceOrder: 1,
        ),
        DocumentImagePart(
          filePath: real.path,
          sourceName: 'real',
          pageIndex: 1,
          sourceOrder: 2,
        ),
      ],
      issues: const [
        DocumentExtractionIssue(
          stage: 'reader',
          message: 'warning',
          isError: false,
        ),
      ],
    );
  }
}

class _ProblemImageBackend implements StaticImageBackend {
  @override
  Future<StaticImageMetadata> inspect(
    String filePath, {
    int frameIndex = 0,
  }) async => const StaticImageMetadata(
    format: 'DAT',
    width: 1,
    height: 1,
    frameCount: 2,
    colorMode: 'X',
    hasAlpha: false,
  );

  @override
  Future<StaticImageOcrResult> extractText(
    String filePath, {
    required String languages,
    int frameIndex = 0,
  }) async => const StaticImageOcrResult(
    text: '',
    languages: 'eng',
    meanConfidence: null,
    words: [],
  );

  @override
  Future<StaticImageSemanticResult> analyzeImage(
    String filePath, {
    int frameIndex = 0,
  }) async => const StaticImageSemanticResult(
    model: 'invalid',
    dimensions: 2,
    vector: [1],
  );
}

void main() {
  test('text-image extraction JSON maps records and optional issues', () {
    final extraction = TextImageDocumentExtraction.fromJson({
      'detected_format': 'XPS',
      'text_blocks': [
        {'text': 'x', 'page_index': 1, 'source_order': 2},
      ],
      'image_parts': [
        {
          'file_path': 'x.png',
          'source_name': 'x.png',
          'page_index': null,
          'source_order': 3,
        },
      ],
    });
    expect(extraction.textBlocks.single.pageIndex, 1);
    expect(extraction.imageParts.single.sourceName, 'x.png');
    expect(extraction.issues, isEmpty);
    final issue = DocumentExtractionIssue.fromJson({
      'stage': 'x',
      'message': 'warning',
      'severity': 'warning',
    });
    expect(issue.isError, isFalse);
  });

  test('text-and-image document type boundary is explicit', () {
    const supported = [
      'a.xps',
      'a.oxps',
      'a.djvu',
      'a.djv',
      'a.fb2',
      'a.fb2.zip',
      'a.ps',
      'a.eps',
    ];
    for (final path in supported) {
      expect(TextImageDocumentFileTypes.supports(path), isTrue, reason: path);
    }

    const excluded = [
      'a.pdf',
      'a.doc',
      'a.docx',
      'a.ppt',
      'a.pptx',
      'a.md',
      'a.png',
    ];
    for (final path in excluded) {
      expect(TextImageDocumentFileTypes.supports(path), isFalse, reason: path);
    }

    expect(TextImageDocumentFileTypes.requiresDjVuLibre('a.djvu'), isTrue);
    expect(TextImageDocumentFileTypes.requiresGhostscript('a.eps'), isTrue);
  });

  test('parser keeps one object and runs OCR before image semantics', () async {
    final sourceDirectory = await Directory.systemTemp.createTemp(
      'text_image_document_source_',
    );
    final workspaceRoot = await Directory.systemTemp.createTemp(
      'text_image_document_workspace_',
    );
    final source = File(
      '${sourceDirectory.path}${Platform.pathSeparator}sample.xps',
    );
    await source.writeAsString('fixture');
    final imageBackend = _FakeImageBackend();
    final parser = TextImageDocumentParser(
      documentBackend: _FakeDocumentBackend(),
      imageBackend: imageBackend,
      temporaryDirectoryPath: workspaceRoot.path,
    );

    try {
      final result = await parser.parse(source.path);

      expect(result.metadata.detectedFileType, 'XPS');
      expect(result.content.status, ExtractionStatus.completed);
      expect(result.content.textInformation, hasLength(2));
      expect(result.content.mergedText, contains('direct document text'));
      expect(result.content.mergedText, contains('image text'));
      expect(
        result.content.textInformation.last.extractionMethod,
        TextExtractionMethod.ocr,
      );
      expect(result.content.imageInformation, hasLength(1));
      expect(result.content.imageInformation.single.sourcePath, source.path);
      expect(result.content.imageInformation.single.semanticVector, [
        0.1,
        0.2,
        0.3,
      ]);
      expect(result.content.audioInformation, isEmpty);
      expect(result.content.videoInformation, isEmpty);
      expect(imageBackend.calls, ['inspect', 'ocr:chi_sim+eng', 'semantics']);
      expect(await workspaceRoot.list().toList(), isEmpty);
    } finally {
      await sourceDirectory.delete(recursive: true);
      await workspaceRoot.delete(recursive: true);
    }
  });

  test('OCR failure does not discard image semantics', () async {
    final sourceDirectory = await Directory.systemTemp.createTemp(
      'text_image_document_source_',
    );
    final workspaceRoot = await Directory.systemTemp.createTemp(
      'text_image_document_workspace_',
    );
    final source = File(
      '${sourceDirectory.path}${Platform.pathSeparator}sample.xps',
    );
    await source.writeAsString('fixture');
    final parser = TextImageDocumentParser(
      documentBackend: _FakeDocumentBackend(),
      imageBackend: _FakeImageBackend(ocrError: StateError('OCR unavailable')),
      temporaryDirectoryPath: workspaceRoot.path,
    );

    try {
      final result = await parser.parse(source.path);

      expect(result.content.status, ExtractionStatus.partial);
      expect(
        result.content.textInformation
            .where((item) => item.extractionMethod == TextExtractionMethod.ocr)
            .toList(),
        isEmpty,
      );
      expect(result.content.imageInformation.single.semanticVector, isNotEmpty);
      expect(result.content.issues.single.stage, 'embedded_image_ocr');
    } finally {
      await sourceDirectory.delete(recursive: true);
      await workspaceRoot.delete(recursive: true);
    }
  });

  test('parser validates paths and retains degraded image records', () async {
    final directory = await Directory.systemTemp.createTemp();
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    TextImageDocumentParser parser(TextImageDocumentBackend backend) =>
        TextImageDocumentParser(
          documentBackend: backend,
          imageBackend: _ProblemImageBackend(),
          temporaryDirectoryPath: '${directory.path}/workspace',
        );
    expect(
      () =>
          parser(const _ProblemDocumentBackend())
              .parse('${directory.path}/missing.xps'),
      throwsA(isA<FileSystemException>()),
    );
    final unsupported = await File('${directory.path}/file.bin')
        .writeAsBytes([1]);
    expect(
      () => parser(const _ProblemDocumentBackend()).parse(unsupported.path),
      throwsA(isA<UnsupportedError>()),
    );
    final source = await File('${directory.path}/file.xps').writeAsBytes([1]);
    expect(
      () =>
          parser(const _ProblemDocumentBackend(detectedFormat: 'OXPS'))
              .parse(source.path),
      throwsA(isA<FormatException>()),
    );
    final result = await parser(const _ProblemDocumentBackend())
        .parse(source.path);
    expect(result.content.status, ExtractionStatus.partial);
    expect(result.content.textInformation.single.text, 'later');
    expect(result.content.imageInformation, hasLength(1));
    expect(result.content.imageInformation.single.format, 'DAT');
    expect(result.content.imageInformation.single.semanticVector, isEmpty);
    expect(
      result.content.issues.map((issue) => issue.stage),
      containsAll([
        'reader',
        'embedded_image_path',
        'embedded_image_export',
        'embedded_image_decode',
        'embedded_image_semantics',
      ]),
    );
  });
}

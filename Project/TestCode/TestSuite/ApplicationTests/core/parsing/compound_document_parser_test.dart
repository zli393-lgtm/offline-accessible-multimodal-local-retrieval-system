import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/parsing/audio_parser.dart';
import 'package:retrieval/core/parsing/compound_document_parser.dart';
import 'package:retrieval/core/parsing/static_image_parser.dart';

class _FakeDocumentBackend implements CompoundDocumentBackend {
  @override
  Future<CompoundExtraction> extract(
    String filePath, {
    required String outputDirectory,
  }) async {
    final image = File('$outputDirectory/embedded.png');
    final audio = File('$outputDirectory/embedded.wav');
    await image.writeAsBytes([1, 2, 3]);
    await audio.writeAsBytes([4, 5, 6]);
    return CompoundExtraction(
      detectedFormat: 'HTML',
      textBlocks: const [
        CompoundTextBlock(
          kind: 'plain_text',
          text: 'direct text',
          pageIndex: null,
          sourceOrder: 0,
          logicalLocation: 'body',
        ),
      ],
      imageParts: [
        CompoundMediaPart(
          filePath: image.path,
          sourceName: 'embedded.png',
          pageIndex: null,
          sourceOrder: 1,
          logicalLocation: 'img:1',
          kind: 'embedded_image',
        ),
      ],
      audioParts: [
        CompoundMediaPart(
          filePath: audio.path,
          sourceName: 'embedded.wav',
          pageIndex: null,
          sourceOrder: 2,
          logicalLocation: 'audio:1',
        ),
      ],
      issues: const [],
    );
  }
}

class _FakeImageBackend implements StaticImageBackend {
  final List<String> calls = [];

  @override
  Future<StaticImageMetadata> inspect(
    String filePath, {
    int frameIndex = 0,
  }) async {
    calls.add('inspect:$frameIndex');
    return const StaticImageMetadata(
      format: 'PNG',
      width: 10,
      height: 10,
      frameCount: 1,
      colorMode: 'RGB',
      hasAlpha: false,
      pixels: [1, 2, 3, 4],
      rowStride: 4,
    );
  }

  @override
  Future<StaticImageOcrResult> extractText(
    String filePath, {
    required String languages,
    int frameIndex = 0,
  }) async {
    calls.add('ocr:$frameIndex');
    return const StaticImageOcrResult(
      text: 'image text',
      languages: 'eng',
      meanConfidence: 90,
      words: [],
    );
  }

  @override
  Future<StaticImageSemanticResult> analyzeImage(
    String filePath, {
    int frameIndex = 0,
  }) async {
    calls.add('analyze:$frameIndex');
    return const StaticImageSemanticResult(
      model: 'mobileclip_s0',
      dimensions: 2,
      vector: [0.1, 0.2],
    );
  }
}

class _FakeAudioBackend implements AudioBackend {
  final List<String> calls = [];

  @override
  Future<AudioMetadata> inspect(String filePath) async {
    calls.add('inspect');
    return const AudioMetadata(
      format: 'WAV',
      codec: 'pcm_s16le',
      duration: Duration(seconds: 1),
      tags: {
        'title': 'Embedded Song',
        'artist': 'Embedded Artist',
        'album': 'Embedded Album',
      },
    );
  }

  @override
  Future<AudioTranscription> transcribe(String filePath) async {
    calls.add('transcribe');
    return const AudioTranscription(
      text: 'speech text',
      model: 'whisper-medium',
      segments: [
        SpeechSegment(
          text: 'speech text',
          start: Duration.zero,
          end: Duration(seconds: 1),
        ),
      ],
    );
  }

  @override
  Future<AudioSemanticResult> analyze(String filePath) async {
    calls.add('analyze');
    return const AudioSemanticResult(
      model: 'clap',
      vector: [0.3, 0.4],
      regions: [
        ContentRegion(startTime: Duration.zero, endTime: Duration(seconds: 1)),
      ],
    );
  }
}

class _ProblemDocumentBackend implements CompoundDocumentBackend {
  final String detectedFormat;
  final bool outsideWorkspace;

  const _ProblemDocumentBackend({
    this.detectedFormat = 'HTML',
    this.outsideWorkspace = false,
  });

  @override
  Future<CompoundExtraction> extract(
    String filePath, {
    required String outputDirectory,
  }) async {
    final missing = outsideWorkspace
        ? File('$outputDirectory/../outside.png')
        : File('$outputDirectory/missing.png');
    return CompoundExtraction(
      detectedFormat: detectedFormat,
      textBlocks: const [
        CompoundTextBlock(
          kind: 'table',
          text: 'same',
          pageIndex: 1,
          sourceOrder: 4,
        ),
        CompoundTextBlock(
          kind: 'chart_data',
          text: 'chart',
          pageIndex: 1,
          sourceOrder: 3,
        ),
        CompoundTextBlock(
          kind: 'vector_data',
          text: 'vector',
          pageIndex: 0,
          sourceOrder: 2,
        ),
      ],
      imageParts: [
        CompoundMediaPart(
          filePath: missing.path,
          sourceName: 'missing.png',
          pageIndex: 0,
          sourceOrder: 0,
        ),
      ],
      audioParts: [
        CompoundMediaPart(
          filePath: '$outputDirectory/missing.wav',
          sourceName: 'missing.wav',
          pageIndex: 0,
          sourceOrder: 1,
        ),
      ],
      issues: const [
        CompoundBackendIssue(
          stage: 'reader',
          message: 'warning',
          isError: false,
        ),
      ],
    );
  }
}

class _ActualMediaDocumentBackend implements CompoundDocumentBackend {
  const _ActualMediaDocumentBackend();

  @override
  Future<CompoundExtraction> extract(
    String filePath, {
    required String outputDirectory,
  }) async {
    final image = await File('$outputDirectory/animation.gif')
        .writeAsBytes([1]);
    final audio = await File('$outputDirectory/broken.wav').writeAsBytes([2]);
    return CompoundExtraction(
      detectedFormat: 'HTML',
      textBlocks: const [],
      imageParts: [
        CompoundMediaPart(
          filePath: image.path,
          sourceName: 'animation.gif',
          pageIndex: 0,
          sourceOrder: 0,
          kind: 'rendered_page',
        ),
      ],
      audioParts: [
        CompoundMediaPart(
          filePath: audio.path,
          sourceName: 'broken.wav',
          pageIndex: 0,
          sourceOrder: 1,
        ),
      ],
      issues: const [],
    );
  }
}

class _PartialImageBackend implements StaticImageBackend {
  @override
  Future<StaticImageMetadata> inspect(
    String filePath, {
    int frameIndex = 0,
  }) async => StaticImageMetadata(
    format: 'GIF',
    width: 2,
    height: 2,
    frameCount: 2,
    colorMode: 'RGBA',
    hasAlpha: true,
    pixels: const [1, 2, 3, 4],
    rowStride: 2,
    frameBytes: frameIndex == 0 ? const [] : const [7, 8],
    frameDuration: const Duration(milliseconds: 20),
  );

  @override
  Future<StaticImageOcrResult> extractText(
    String filePath, {
    required String languages,
    int frameIndex = 0,
  }) async {
    if (frameIndex == 1) throw const FormatException('OCR failed');
    return const StaticImageOcrResult(
      text: 'frame text',
      languages: 'eng',
      meanConfidence: 80,
      words: [],
    );
  }

  @override
  Future<StaticImageSemanticResult> analyzeImage(
    String filePath, {
    int frameIndex = 0,
  }) async =>
      const StaticImageSemanticResult(model: 'bad', dimensions: 2, vector: [1]);
}

class _FailingAudioBackend implements AudioBackend {
  @override
  Future<AudioMetadata> inspect(String filePath) async =>
      throw const FormatException('metadata failed');

  @override
  Future<AudioTranscription> transcribe(String filePath) async =>
      throw const FormatException('speech failed');

  @override
  Future<AudioSemanticResult> analyze(String filePath) async =>
      throw const FormatException('analysis failed');
}

void main() {
  test('compound extraction JSON maps optional collections and severities', () {
    final extraction = CompoundExtraction.fromJson({
      'detected_format': 'HTML',
      'text_blocks': [
        {'text': 'x', 'source_order': 2},
      ],
      'image_parts': [
        {'file_path': 'x.png', 'source_name': 'x.png', 'source_order': 3},
      ],
      'issues': [
        {'stage': 'read', 'message': 'bad', 'severity': 'error'},
      ],
    });
    expect(extraction.textBlocks.single.kind, 'plain_text');
    expect(extraction.textBlocks.single.pageIndex, isNull);
    expect(extraction.imageParts.single.kind, isNull);
    expect(extraction.audioParts, isEmpty);
    expect(extraction.issues.single.isError, isTrue);
  });

  test(
    'Compound parser keeps direct, image, and audio channels together',
    () async {
      final directory = await Directory.systemTemp.createTemp();
      final source = File('${directory.path}/sample.html');
      await source.writeAsString('<p>direct text</p>');
      final imageBackend = _FakeImageBackend();
      final audioBackend = _FakeAudioBackend();
      final parser = CompoundDocumentParser(
        documentBackend: _FakeDocumentBackend(),
        imageBackend: imageBackend,
        audioBackend: audioBackend,
        temporaryDirectoryPath: directory.path,
      );

      final result = await parser.parse(source.path);

      expect(result.content.status, ExtractionStatus.completed);
      expect(result.content.textInformation, hasLength(4));
      expect(result.content.textInformation.map((item) => item.text).toSet(), {
        'direct text',
        'image text',
        'speech text',
        'album: Embedded Album\nartist: Embedded Artist\ntitle: Embedded Song',
      });
      final metadataText = result.content.textInformation.singleWhere(
        (item) => item.informationKind == TextInformationKind.metadata,
      );
      expect(metadataText.extractionMethod, TextExtractionMethod.other);
      expect(metadataText.regions.single.sourceName, 'embedded.wav');
      expect(result.content.imageInformation, hasLength(1));
      expect(
        result.content.imageInformation.single.informationKind,
        ImageInformationKind.embeddedImage,
      );
      expect(result.content.audioInformation, hasLength(1));
      expect(
        result.content.audioInformation.single.informationKind,
        AudioInformationKind.embeddedAudio,
      );
      expect(result.content.videoInformation, isEmpty);
      expect(imageBackend.calls, ['inspect:0', 'ocr:0', 'analyze:0']);
      expect(audioBackend.calls, ['inspect', 'transcribe', 'analyze']);

      await directory.delete(recursive: true);
    },
  );

  test(
    'compound parser validates inputs, formats, and exported media',
    () async {
      final directory = await Directory.systemTemp.createTemp();
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final imageBackend = _FakeImageBackend();
      final audioBackend = _FakeAudioBackend();
      CompoundDocumentParser parser(CompoundDocumentBackend backend) =>
          CompoundDocumentParser(
            documentBackend: backend,
            imageBackend: imageBackend,
            audioBackend: audioBackend,
            temporaryDirectoryPath: '${directory.path}/temporary',
          );

      expect(
        () =>
            parser(const _ProblemDocumentBackend())
                .parse('${directory.path}/missing.html'),
        throwsA(isA<FileSystemException>()),
      );
      final unsupported = File('${directory.path}/unsupported.bin');
      await unsupported.writeAsBytes([1]);
      expect(
        () => parser(const _ProblemDocumentBackend()).parse(unsupported.path),
        throwsA(isA<UnsupportedError>()),
      );
      final source = File('${directory.path}/sample.html');
      await source.writeAsString('<html></html>');
      expect(
        () =>
            parser(const _ProblemDocumentBackend(detectedFormat: 'DOCX'))
                .parse(source.path),
        throwsA(isA<FormatException>()),
      );

      final missing = await parser(const _ProblemDocumentBackend())
          .parse(source.path);
      expect(missing.content.status, ExtractionStatus.partial);
      expect(missing.content.textInformation, hasLength(3));
      expect(
        missing.content.textInformation.map((value) => value.informationKind),
        containsAll([
          TextInformationKind.table,
          TextInformationKind.chartData,
          TextInformationKind.vectorData,
        ]),
      );
      expect(missing.content.issues, hasLength(3));
      expect(
        missing.content.issues.first.severity,
        ExtractionIssueSeverity.warning,
      );
      expect(imageBackend.calls, isEmpty);
      expect(audioBackend.calls, isEmpty);

      final outside = await parser(
        const _ProblemDocumentBackend(outsideWorkspace: true),
      ).parse(source.path);
      expect(
        outside.content.issues.any(
          (issue) => issue.stage == 'embedded_image_path',
        ),
        isTrue,
      );
    },
  );

  test(
    'compound parser preserves usable media when optional analysis fails',
    () async {
      final directory = await Directory.systemTemp.createTemp();
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final source = await File('${directory.path}/media.html')
          .writeAsString('x');
      final parser = CompoundDocumentParser(
        documentBackend: const _ActualMediaDocumentBackend(),
        imageBackend: _PartialImageBackend(),
        audioBackend: _FailingAudioBackend(),
        temporaryDirectoryPath: directory.path,
      );
      final result = await parser.parse(source.path);
      expect(result.content.status, ExtractionStatus.partial);
      expect(result.content.imageInformation, hasLength(2));
      expect(
        result.content.imageInformation.every(
          (item) => item.informationKind == ImageInformationKind.animationFrame,
        ),
        isTrue,
      );
      expect(result.content.imageInformation.last.bytes, [7, 8]);
      expect(result.content.audioInformation, hasLength(1));
      expect(result.content.audioInformation.single.duration, isNull);
      expect(result.content.textInformation.single.text, 'frame text');
      expect(
        result.content.issues.map((issue) => issue.stage),
        containsAll([
          'embedded_image_ocr',
          'embedded_image_semantics',
          'embedded_audio_metadata',
          'embedded_audio_speech',
          'embedded_audio_semantics',
        ]),
      );
      expect(CompoundDocumentParser.supports(source.path), isTrue);
    },
  );
}

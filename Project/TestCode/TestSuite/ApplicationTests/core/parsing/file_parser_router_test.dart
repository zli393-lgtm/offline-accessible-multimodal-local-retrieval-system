import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/models/file_metadata.dart';
import 'package:retrieval/core/models/parsing_result.dart';
import 'package:retrieval/core/parsing/audio_parser.dart';
import 'package:retrieval/core/parsing/compound_document_parser.dart';
import 'package:retrieval/core/parsing/file_parser_router.dart';
import 'package:retrieval/core/parsing/parser.dart';
import 'package:retrieval/core/parsing/pdf_parser.dart';
import 'package:retrieval/core/parsing/static_image_parser.dart';
import 'package:retrieval/core/parsing/structured_visual_parser.dart';
import 'package:retrieval/core/parsing/text_image_document_parser.dart';

ParsingResult _result(String path, String type) => ParsingResult(
  metadata: FileMetadata(
    filePath: path,
    detectedFileType: type,
    fileSize: 0,
    modifiedTime: DateTime.utc(2026),
  ),
  content: const ExtractedFileContent(
    textInformation: [],
    imageInformation: [],
    audioInformation: [],
    videoInformation: [],
    issues: [],
    status: ExtractionStatus.completed,
  ),
);

class _UnusedImageBackend implements StaticImageBackend {
  @override
  Future<StaticImageSemanticResult> analyzeImage(
    String filePath, {
    int frameIndex = 0,
  }) => throw UnimplementedError();

  @override
  Future<StaticImageOcrResult> extractText(
    String filePath, {
    required String languages,
    int frameIndex = 0,
  }) => throw UnimplementedError();

  @override
  Future<StaticImageMetadata> inspect(String filePath, {int frameIndex = 0}) =>
      throw UnimplementedError();
}

class _UnusedAudioBackend implements AudioBackend {
  @override
  Future<AudioSemanticResult> analyze(String filePath) =>
      throw UnimplementedError();

  @override
  Future<AudioMetadata> inspect(String filePath) => throw UnimplementedError();

  @override
  Future<AudioTranscription> transcribe(String filePath) =>
      throw UnimplementedError();
}

class _UnusedStructuredBackend implements StructuredVisualBackend {
  @override
  Future<StructuredExtraction> extract(
    String filePath, {
    required String outputDirectory,
  }) => throw UnimplementedError();
}

class _UnusedTextImageBackend implements TextImageDocumentBackend {
  @override
  Future<TextImageDocumentExtraction> extract(
    String filePath, {
    required String outputDirectory,
  }) => throw UnimplementedError();
}

class _UnusedCompoundBackend implements CompoundDocumentBackend {
  @override
  Future<CompoundExtraction> extract(
    String filePath, {
    required String outputDirectory,
  }) => throw UnimplementedError();
}

class _ImageParser extends StaticImageParser {
  _ImageParser() : super(backend: _UnusedImageBackend());

  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async => _result(filePath, 'IMAGE');
}

class _AudioParser extends AudioParser {
  _AudioParser() : super(backend: _UnusedAudioBackend());

  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async => _result(filePath, 'AUDIO');
}

class _StructuredParser extends StructuredVisualParser {
  _StructuredParser()
    : super(
        backend: _UnusedStructuredBackend(),
        imageBackend: _UnusedImageBackend(),
      );

  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async => _result(filePath, 'STRUCTURED');
}

class _TextImageParser extends TextImageDocumentParser {
  _TextImageParser()
    : super(
        documentBackend: _UnusedTextImageBackend(),
        imageBackend: _UnusedImageBackend(),
      );

  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async => _result(filePath, 'TEXT_IMAGE');
}

class _CompoundParser extends CompoundDocumentParser {
  _CompoundParser()
    : super(
        documentBackend: _UnusedCompoundBackend(),
        imageBackend: _UnusedImageBackend(),
        audioBackend: _UnusedAudioBackend(),
      );

  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async => _result(filePath, 'COMPOUND');
}

class _PdfParser extends PdfParser {
  _PdfParser() : super(libraryPath: 'unused-in-router-test');

  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async => _result(filePath, 'PDFIUM');
}

ParsingResult _richResult(String path, String type, ExtractionStatus status) {
  final text = TextInformation(
    text: 'same text',
    extractionMethod: TextExtractionMethod.direct,
    sourcePath: path,
    regions: const [ContentRegion(pageIndex: 0, logicalLocation: 'page')],
  );
  final image = ImageInformation(
    sourcePath: path,
    format: 'PNG',
    pixelWidth: 1,
    pixelHeight: 1,
    frameCount: 1,
    colorMode: 'RGB',
    hasAlpha: false,
    bytes: Uint8List.fromList([1]),
    region: const ContentRegion(pageIndex: 0, logicalLocation: 'image'),
    semanticVector: const [],
  );
  return ParsingResult(
    metadata: FileMetadata(
      filePath: path,
      detectedFileType: type,
      fileSize: 1,
      modifiedTime: DateTime.utc(2026),
    ),
    content: ExtractedFileContent(
      textInformation: [text],
      imageInformation: [image],
      audioInformation: [
        AudioInformation(sourcePath: path, bytes: Uint8List(0)),
      ],
      videoInformation: [
        VideoInformation(sourcePath: path, bytes: Uint8List(0)),
      ],
      issues: const [
        ExtractionIssue(
          stage: 'test',
          message: 'partial',
          severity: ExtractionIssueSeverity.warning,
        ),
      ],
      status: status,
    ),
  );
}

class _RichPdfParser extends PdfParser {
  _RichPdfParser() : super(libraryPath: 'unused');
  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async => _richResult(filePath, 'PDFIUM', ExtractionStatus.partial);
}

class _RichCompoundParser extends CompoundDocumentParser {
  _RichCompoundParser()
    : super(
        documentBackend: _UnusedCompoundBackend(),
        imageBackend: _UnusedImageBackend(),
        audioBackend: _UnusedAudioBackend(),
      );
  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async => _richResult(filePath, 'PDF', ExtractionStatus.completed);
}

void main() {
  late Directory temporary;
  late FileParserRouter router;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('router-test-');
    router = FileParserRouter(
      imageParser: _ImageParser(),
      structuredVisualParser: _StructuredParser(),
      audioParser: _AudioParser(),
      textImageDocumentParser: _TextImageParser(),
      compoundDocumentParser: _CompoundParser(),
      pdfParser: _PdfParser(),
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'routes by outer file format and gives text-image formats priority',
    () async {
      final text = File(p.join(temporary.path, 'a.txt'))
        ..writeAsStringSync('hello');
      expect((await router.parse(text.path)).metadata.detectedFileType, 'TXT');
      expect((await router.parse('a.png')).metadata.detectedFileType, 'IMAGE');
      expect(
        (await router.parse('a.xlsx')).metadata.detectedFileType,
        'STRUCTURED',
      );
      expect((await router.parse('a.wav')).metadata.detectedFileType, 'AUDIO');
      expect(
        (await router.parse('a.xps')).metadata.detectedFileType,
        'TEXT_IMAGE',
      );
      expect(
        (await router.parse('a.pdf')).metadata.detectedFileType,
        'COMPOUND',
      );
      final archive = File(p.join(temporary.path, 'a.zip'))
        ..writeAsBytesSync([]);
      expect(
        (await router.parse(archive.path)).metadata.detectedFileType,
        'ZIP',
      );
      final unknown = File(p.join(temporary.path, 'a.unknown'))
        ..writeAsBytesSync([0, 1, 2]);
      final unknownResult = await router.parse(unknown.path);
      expect(unknownResult.metadata.detectedFileType, 'UNKNOWN');
      expect(unknownResult.content.textInformation.single.text, 'a.unknown');
      expect(
        unknownResult.content.textInformation.single.informationKind,
        TextInformationKind.fileName,
      );
    },
  );

  test('python factory wires every required file category', () {
    final value = FileParserRouter.python(
      mobileClipModelPath: 'image-model',
      whisperModelPath: 'whisper-model',
      clapModelPath: 'clap-model',
      pythonExecutable: 'python',
      djvuRenderExecutable: 'ddjvu',
      djvuTextExecutable: 'djvutxt',
      djvuScriptExecutable: 'djvused',
      ghostscriptExecutable: 'gs',
      workingDirectory: temporary.path,
      temporaryDirectoryPath: temporary.path,
    );
    expect(value.imageParser, isA<StaticImageParser>());
    expect(value.structuredVisualParser, isA<StructuredVisualParser>());
    expect(value.audioParser, isA<AudioParser>());
    expect(value.textImageDocumentParser, isA<TextImageDocumentParser>());
    expect(value.compoundDocumentParser, isA<CompoundDocumentParser>());
    final documentBackend =
        value.textImageDocumentParser.documentBackend
            as PythonTextImageDocumentBackend;
    expect(documentBackend.djvuRenderExecutable, 'ddjvu');
    expect(documentBackend.djvuTextExecutable, 'djvutxt');
    expect(documentBackend.djvuScriptExecutable, 'djvused');
    expect(documentBackend.ghostscriptExecutable, 'gs');
  });

  test(
    'PDF routing merges required engines without duplicate records',
    () async {
      final rich = FileParserRouter(
        imageParser: _ImageParser(),
        structuredVisualParser: _StructuredParser(),
        audioParser: _AudioParser(),
        textImageDocumentParser: _TextImageParser(),
        compoundDocumentParser: _RichCompoundParser(),
        pdfParser: _RichPdfParser(),
      );
      final result = await rich.parse('merged.pdf');
      expect(result.metadata.detectedFileType, 'PDF');
      expect(result.content.textInformation, hasLength(1));
      expect(result.content.imageInformation, hasLength(1));
      expect(result.content.audioInformation, hasLength(2));
      expect(result.content.videoInformation, hasLength(2));
      expect(result.content.issues, hasLength(2));
      expect(result.content.status, ExtractionStatus.partial);
    },
  );
}

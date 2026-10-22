import 'package:path/path.dart' as p;

import '../file_io/archive_file_types.dart';
import '../file_io/audio_file_types.dart';
import '../file_io/compound_document_file_types.dart';
import '../file_io/pure_text_file_types.dart';
import '../file_io/static_image_file_types.dart';
import '../file_io/structured_visual_file_types.dart';
import '../file_io/text_image_document_file_types.dart';
import '../models/extracted_file_content.dart';
import '../models/parsing_result.dart';
import 'archive_name_parser.dart';
import 'audio_parser.dart';
import 'compound_document_parser.dart';
import 'opaque_file_parser.dart';
import 'parser.dart';
import 'pdf_parser.dart';
import 'pure_text_parser.dart';
import 'static_image_parser.dart';
import 'structured_visual_parser.dart';
import 'text_image_document_parser.dart';

/// Selects a parser by the outer file object's type.
///
/// Information channels discovered inside a compound object do not change the
/// parser selection: they remain children of that one file object.
class FileParserRouter implements Parser {
  final PureTextParser pureTextParser;
  final StaticImageParser imageParser;
  final StructuredVisualParser structuredVisualParser;
  final AudioParser audioParser;
  final TextImageDocumentParser textImageDocumentParser;
  final CompoundDocumentParser compoundDocumentParser;
  final PdfParser pdfParser;
  final ArchiveNameParser archiveParser;
  final OpaqueFileParser opaqueFileParser;

  const FileParserRouter({
    this.pureTextParser = const PureTextParser(),
    required this.imageParser,
    required this.structuredVisualParser,
    required this.audioParser,
    required this.textImageDocumentParser,
    required this.compoundDocumentParser,
    required this.pdfParser,
    this.archiveParser = const ArchiveNameParser(),
    this.opaqueFileParser = const OpaqueFileParser(),
  });

  factory FileParserRouter.python({
    required String mobileClipModelPath,
    required String whisperModelPath,
    required String clapModelPath,
    String pythonExecutable = 'python',
    String mobileClipModelName = 'mobileclip_s0',
    String device = 'cpu',
    String whisperComputeType = 'int8',
    String? browserExecutable,
    String? tesseractExecutable,
    String? djvuRenderExecutable,
    String? djvuTextExecutable,
    String? djvuScriptExecutable,
    String? ghostscriptExecutable,
    String? jxrDecoderExecutable,
    String? xpsRendererExecutable,
    String? javaExecutable,
    String? tikaJarPath,
    String? pdfiumLibraryPath,
    String? workingDirectory,
    String? temporaryDirectoryPath,
    String ocrLanguages = 'chi_sim+eng',
  }) {
    final imageBackend = PythonStaticImageBackend(
      mobileClipModelPath: mobileClipModelPath,
      pythonExecutable: pythonExecutable,
      mobileClipModelName: mobileClipModelName,
      device: device,
      tesseractExecutable: tesseractExecutable,
      workingDirectory: workingDirectory,
    );
    final audioBackend = PythonAudioBackend(
      whisperModelPath: whisperModelPath,
      clapModelPath: clapModelPath,
      pythonExecutable: pythonExecutable,
      device: device,
      whisperComputeType: whisperComputeType,
      workingDirectory: workingDirectory,
    );
    return FileParserRouter(
      imageParser: StaticImageParser(
        backend: imageBackend,
        ocrLanguages: ocrLanguages,
      ),
      structuredVisualParser: StructuredVisualParser(
        backend: PythonStructuredVisualBackend(
          pythonExecutable: pythonExecutable,
          browserExecutable: browserExecutable,
          workingDirectory: workingDirectory,
        ),
        imageBackend: imageBackend,
        ocrLanguages: ocrLanguages,
      ),
      audioParser: AudioParser(backend: audioBackend),
      textImageDocumentParser: TextImageDocumentParser(
        documentBackend: PythonTextImageDocumentBackend(
          pythonExecutable: pythonExecutable,
          workingDirectory: workingDirectory,
          djvuRenderExecutable: djvuRenderExecutable,
          djvuTextExecutable: djvuTextExecutable,
          djvuScriptExecutable: djvuScriptExecutable,
          ghostscriptExecutable: ghostscriptExecutable,
          jxrDecoderExecutable: jxrDecoderExecutable,
          xpsRendererExecutable: xpsRendererExecutable,
        ),
        imageBackend: imageBackend,
        ocrLanguages: ocrLanguages,
        temporaryDirectoryPath: temporaryDirectoryPath,
      ),
      compoundDocumentParser: CompoundDocumentParser(
        documentBackend: PythonCompoundDocumentBackend(
          pythonExecutable: pythonExecutable,
          javaExecutable: javaExecutable,
          tikaJarPath: tikaJarPath,
          workingDirectory: workingDirectory,
        ),
        imageBackend: imageBackend,
        audioBackend: audioBackend,
        ocrLanguages: ocrLanguages,
        temporaryDirectoryPath: temporaryDirectoryPath,
      ),
      pdfParser: PdfParser(libraryPath: pdfiumLibraryPath),
    );
  }

  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async {
    await reportFileProcessing(observer, FileProcessingStage.typeDetection);
    if (p.extension(filePath).toLowerCase() == '.pdf') {
      // PDFium and Apache Tika are both mandatory technologies in the
      // product specification.  The PDFium parser supplies page-native text,
      // geometry and rendered objects; the compound parser invokes Tika and
      // the existing rich-document readers.  A failure in either branch
      // fails this file object, so the indexer cannot silently bypass either
      // required engine.
      final pdfium = await pdfParser.parse(filePath, observer: observer);
      final compound = await compoundDocumentParser.parse(
        filePath,
        observer: observer,
      );
      return _mergeRequiredPdfResults(pdfium, compound);
    }
    if (PureTextFileTypes.supports(filePath)) {
      return pureTextParser.parse(filePath, observer: observer);
    }
    if (StaticImageFileTypes.supports(filePath)) {
      return imageParser.parse(filePath, observer: observer);
    }
    // XLSX/XLSM and SVG remain with their more precise table/chart/vector
    // readers instead of falling through to the general compound reader.
    if (StructuredVisualFileTypes.supports(filePath)) {
      return structuredVisualParser.parse(filePath, observer: observer);
    }
    if (AudioFileTypes.supports(filePath)) {
      return audioParser.parse(filePath, observer: observer);
    }
    if (TextImageDocumentFileTypes.supports(filePath)) {
      return textImageDocumentParser.parse(filePath, observer: observer);
    }
    if (CompoundDocumentFileTypes.supports(filePath)) {
      return compoundDocumentParser.parse(filePath, observer: observer);
    }
    if (ArchiveFileTypes.supports(filePath)) {
      return archiveParser.parse(filePath, observer: observer);
    }
    return opaqueFileParser.parse(filePath, observer: observer);
  }
}

ParsingResult _mergeRequiredPdfResults(
  ParsingResult pdfium,
  ParsingResult compound,
) {
  final texts = <String, TextInformation>{};
  for (final item in [
    ...pdfium.content.textInformation,
    ...compound.content.textInformation,
  ]) {
    final region = item.regions.isEmpty ? null : item.regions.first;
    final key = [
      item.informationKind.name,
      region?.pageIndex,
      region?.logicalLocation,
      item.text.trim(),
    ].join('\u0000');
    texts.putIfAbsent(key, () => item);
  }

  final images = <String, ImageInformation>{};
  for (final item in [
    ...pdfium.content.imageInformation,
    ...compound.content.imageInformation,
  ]) {
    final key = [
      item.informationKind.name,
      item.region?.pageIndex,
      item.region?.logicalLocation,
      item.sourcePath,
      item.bytes.length,
    ].join('\u0000');
    images.putIfAbsent(key, () => item);
  }

  return ParsingResult(
    metadata: compound.metadata,
    content: ExtractedFileContent(
      textInformation: texts.values.toList(growable: false),
      imageInformation: images.values.toList(growable: false),
      audioInformation: [
        ...pdfium.content.audioInformation,
        ...compound.content.audioInformation,
      ],
      videoInformation: [
        ...pdfium.content.videoInformation,
        ...compound.content.videoInformation,
      ],
      issues: [...pdfium.content.issues, ...compound.content.issues],
      status:
          pdfium.content.status == ExtractionStatus.completed &&
              compound.content.status == ExtractionStatus.completed
          ? ExtractionStatus.completed
          : ExtractionStatus.partial,
    ),
  );
}

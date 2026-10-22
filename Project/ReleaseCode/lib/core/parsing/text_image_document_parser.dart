import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../file_io/text_image_document_file_types.dart';
import '../models/extracted_file_content.dart';
import '../models/file_metadata.dart';
import '../models/parsing_result.dart';
import 'parser.dart';
import 'static_image_parser.dart';

class DocumentTextBlock {
  final String text;
  final int? pageIndex;
  final int sourceOrder;

  const DocumentTextBlock({
    required this.text,
    required this.pageIndex,
    required this.sourceOrder,
  });

  factory DocumentTextBlock.fromJson(Map<String, dynamic> json) {
    return DocumentTextBlock(
      text: json['text'] as String,
      pageIndex: (json['page_index'] as num?)?.toInt(),
      sourceOrder: (json['source_order'] as num).toInt(),
    );
  }
}

class DocumentImagePart {
  final String filePath;
  final String sourceName;
  final int? pageIndex;
  final int sourceOrder;

  const DocumentImagePart({
    required this.filePath,
    required this.sourceName,
    required this.pageIndex,
    required this.sourceOrder,
  });

  factory DocumentImagePart.fromJson(Map<String, dynamic> json) {
    return DocumentImagePart(
      filePath: json['file_path'] as String,
      sourceName: json['source_name'] as String,
      pageIndex: (json['page_index'] as num?)?.toInt(),
      sourceOrder: (json['source_order'] as num).toInt(),
    );
  }
}

class DocumentExtractionIssue {
  final String stage;
  final String message;
  final bool isError;

  const DocumentExtractionIssue({
    required this.stage,
    required this.message,
    required this.isError,
  });

  factory DocumentExtractionIssue.fromJson(Map<String, dynamic> json) {
    return DocumentExtractionIssue(
      stage: json['stage'] as String,
      message: json['message'] as String,
      isError: (json['severity'] as String) == 'error',
    );
  }
}

class TextImageDocumentExtraction {
  final String detectedFormat;
  final List<DocumentTextBlock> textBlocks;
  final List<DocumentImagePart> imageParts;
  final List<DocumentExtractionIssue> issues;

  const TextImageDocumentExtraction({
    required this.detectedFormat,
    required this.textBlocks,
    required this.imageParts,
    required this.issues,
  });

  factory TextImageDocumentExtraction.fromJson(Map<String, dynamic> json) {
    return TextImageDocumentExtraction(
      detectedFormat: json['detected_format'] as String,
      textBlocks: (json['text_blocks'] as List<dynamic>)
          .map(
            (item) => DocumentTextBlock.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      imageParts: (json['image_parts'] as List<dynamic>)
          .map(
            (item) => DocumentImagePart.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      issues: (json['issues'] as List<dynamic>? ?? const [])
          .map(
            (item) => DocumentExtractionIssue.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
    );
  }
}

abstract class TextImageDocumentBackend {
  Future<TextImageDocumentExtraction> extract(
    String filePath, {
    required String outputDirectory,
  });
}

class PythonTextImageDocumentBackend implements TextImageDocumentBackend {
  final String pythonExecutable;
  final String scriptPath;
  final String? workingDirectory;
  final String? djvuRenderExecutable;
  final String? djvuTextExecutable;
  final String? djvuScriptExecutable;
  final String? ghostscriptExecutable;
  final String? jxrDecoderExecutable;
  final String? xpsRendererExecutable;
  final Duration timeout;

  const PythonTextImageDocumentBackend({
    this.pythonExecutable = 'python',
    this.scriptPath =
        'services/text_image_document/text_image_document_reader.py',
    this.workingDirectory,
    this.djvuRenderExecutable,
    this.djvuTextExecutable,
    this.djvuScriptExecutable,
    this.ghostscriptExecutable,
    this.jxrDecoderExecutable,
    this.xpsRendererExecutable,
    this.timeout = const Duration(minutes: 10),
  });

  @override
  Future<TextImageDocumentExtraction> extract(
    String filePath, {
    required String outputDirectory,
  }) async {
    final arguments = [
      scriptPath,
      'extract',
      '--input',
      filePath,
      '--output-directory',
      outputDirectory,
    ];
    if (djvuRenderExecutable != null) {
      arguments.addAll(['--djvu-render-executable', djvuRenderExecutable!]);
    }
    if (djvuTextExecutable != null) {
      arguments.addAll(['--djvu-text-executable', djvuTextExecutable!]);
    }
    if (djvuScriptExecutable != null) {
      arguments.addAll(['--djvu-script-executable', djvuScriptExecutable!]);
    }
    if (ghostscriptExecutable != null) {
      arguments.addAll(['--ghostscript-executable', ghostscriptExecutable!]);
    }
    if (jxrDecoderExecutable != null) {
      arguments.addAll(['--jxr-decoder-executable', jxrDecoderExecutable!]);
    }
    if (xpsRendererExecutable != null) {
      arguments.addAll(['--xps-renderer-executable', xpsRendererExecutable!]);
    }

    final result = await Process.run(
      pythonExecutable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(timeout);

    final stdout = (result.stdout as String).trim();
    final stderr = (result.stderr as String).trim();
    Map<String, dynamic>? payload;
    if (stdout.isNotEmpty) {
      try {
        payload = Map<String, dynamic>.from(jsonDecode(stdout) as Map);
      } on FormatException {
        payload = null;
      }
    }

    if (result.exitCode != 0) {
      final message =
          payload?['error']?.toString() ?? (stderr.isEmpty ? stdout : stderr);
      throw ProcessException(
        pythonExecutable,
        arguments,
        message,
        result.exitCode,
      );
    }
    if (payload == null) {
      throw const FormatException(
        'Text-and-image document service returned invalid JSON.',
      );
    }
    return TextImageDocumentExtraction.fromJson(payload);
  }
}

class TextImageDocumentParser implements Parser {
  final TextImageDocumentBackend documentBackend;
  final StaticImageBackend imageBackend;
  final String ocrLanguages;
  final String? temporaryDirectoryPath;

  const TextImageDocumentParser({
    required this.documentBackend,
    required this.imageBackend,
    this.ocrLanguages = 'chi_sim+eng',
    this.temporaryDirectoryPath,
  });

  factory TextImageDocumentParser.python({
    required String mobileClipModelPath,
    String pythonExecutable = 'python',
    String documentScriptPath =
        'services/text_image_document/text_image_document_reader.py',
    String imageScriptPath = 'services/static_image/static_image_reader.py',
    String mobileClipModelName = 'mobileclip_s0',
    String device = 'cpu',
    String? tesseractExecutable,
    String? djvuRenderExecutable,
    String? djvuTextExecutable,
    String? djvuScriptExecutable,
    String? ghostscriptExecutable,
    String? jxrDecoderExecutable,
    String? xpsRendererExecutable,
    String? workingDirectory,
    String? temporaryDirectoryPath,
    String ocrLanguages = 'chi_sim+eng',
  }) {
    return TextImageDocumentParser(
      documentBackend: PythonTextImageDocumentBackend(
        pythonExecutable: pythonExecutable,
        scriptPath: documentScriptPath,
        workingDirectory: workingDirectory,
        djvuRenderExecutable: djvuRenderExecutable,
        djvuTextExecutable: djvuTextExecutable,
        djvuScriptExecutable: djvuScriptExecutable,
        ghostscriptExecutable: ghostscriptExecutable,
        jxrDecoderExecutable: jxrDecoderExecutable,
        xpsRendererExecutable: xpsRendererExecutable,
      ),
      imageBackend: PythonStaticImageBackend(
        mobileClipModelPath: mobileClipModelPath,
        pythonExecutable: pythonExecutable,
        scriptPath: imageScriptPath,
        mobileClipModelName: mobileClipModelName,
        device: device,
        tesseractExecutable: tesseractExecutable,
        workingDirectory: workingDirectory,
      ),
      ocrLanguages: ocrLanguages,
      temporaryDirectoryPath: temporaryDirectoryPath,
    );
  }

  static bool supports(String filePath) =>
      TextImageDocumentFileTypes.supports(filePath);

  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async {
    await reportFileProcessing(observer, FileProcessingStage.reading);
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }
    if (!supports(filePath)) {
      throw UnsupportedError(
        'Not a supported text-and-image document: $filePath',
      );
    }

    final expectedFormat = TextImageDocumentFileTypes.typeLabel(filePath);
    final temporaryRoot = temporaryDirectoryPath == null
        ? Directory.systemTemp
        : Directory(temporaryDirectoryPath!);
    if (!await temporaryRoot.exists()) {
      await temporaryRoot.create(recursive: true);
    }
    final workspace = await temporaryRoot.createTemp(
      'retrieval_text_image_document_',
    );

    try {
      await reportFileProcessing(
        observer,
        FileProcessingStage.structureParsing,
      );
      final extraction = await documentBackend.extract(
        filePath,
        outputDirectory: workspace.path,
      );
      if (extraction.detectedFormat != expectedFormat) {
        throw FormatException(
          'File extension declares $expectedFormat but the document reader '
          'detected ${extraction.detectedFormat}.',
        );
      }

      final textInformation = extraction.textBlocks
          .where((block) => block.text.trim().isNotEmpty)
          .map(
            (block) => TextInformation(
              text: block.text,
              extractionMethod: TextExtractionMethod.direct,
              sourcePath: filePath,
              regions: [
                ContentRegion(
                  pageIndex: block.pageIndex,
                  sourceOrder: block.sourceOrder,
                  layoutOrder: block.sourceOrder,
                ),
              ],
            ),
          )
          .toList();
      if (textInformation.isNotEmpty) {
        await reportFileProcessing(
          observer,
          FileProcessingStage.textExtraction,
          completedUnits: textInformation.length,
          totalUnits: textInformation.length,
        );
      }
      final imageInformation = <ImageInformation>[];
      final issues = extraction.issues
          .map(
            (issue) => ExtractionIssue(
              stage: issue.stage,
              message: issue.message,
              severity: issue.isError
                  ? ExtractionIssueSeverity.error
                  : ExtractionIssueSeverity.warning,
            ),
          )
          .toList();

      for (
        var imageIndex = 0;
        imageIndex < extraction.imageParts.length;
        imageIndex++
      ) {
        final imagePart = extraction.imageParts[imageIndex];
        await reportFileProcessing(
          observer,
          FileProcessingStage.imageDecoding,
          completedUnits: imageIndex,
          totalUnits: extraction.imageParts.length,
          detail: imagePart.sourceName,
        );
        final imageFile = File(imagePart.filePath);
        final normalizedWorkspace = p.normalize(p.absolute(workspace.path));
        final normalizedImage = p.normalize(p.absolute(imageFile.path));
        if (!p.isWithin(normalizedWorkspace, normalizedImage)) {
          issues.add(
            ExtractionIssue(
              stage: 'embedded_image_path',
              message:
                  'The document reader returned an image outside its temporary '
                  'workspace: ${imagePart.sourceName}.',
              severity: ExtractionIssueSeverity.error,
            ),
          );
          continue;
        }
        if (!await imageFile.exists()) {
          issues.add(
            ExtractionIssue(
              stage: 'embedded_image_export',
              message:
                  'The extracted image is missing: '
                  '${imagePart.sourceName}.',
              severity: ExtractionIssueSeverity.error,
            ),
          );
          continue;
        }

        StaticImageMetadata? metadata;
        try {
          metadata = await imageBackend.inspect(imageFile.path);
          if (metadata.frameCount != 1) {
            throw UnsupportedError(
              'Embedded image ${imagePart.sourceName} has '
              '${metadata.frameCount} frames; this stage accepts one-frame '
              'images only.',
            );
          }
        } catch (error) {
          issues.add(
            _imageIssue(
              stage: 'embedded_image_decode',
              imagePart: imagePart,
              error: error,
            ),
          );
        }

        await reportFileProcessing(
          observer,
          FileProcessingStage.imageOcr,
          completedUnits: imageIndex,
          totalUnits: extraction.imageParts.length,
          detail: imagePart.sourceName,
        );
        await _extractImageText(
          filePath: filePath,
          imagePart: imagePart,
          imageFile: imageFile,
          textInformation: textInformation,
          issues: issues,
        );

        await reportFileProcessing(
          observer,
          FileProcessingStage.imageAnalysis,
          completedUnits: imageIndex,
          totalUnits: extraction.imageParts.length,
          detail: imagePart.sourceName,
        );
        final semantics = await _analyzeImage(
          imagePart: imagePart,
          imageFile: imageFile,
          issues: issues,
        );
        final bytes = await imageFile.readAsBytes();

        imageInformation.add(
          ImageInformation(
            sourcePath: filePath,
            format:
                metadata?.format.toUpperCase() ??
                _fallbackImageFormat(imagePart.sourceName),
            pixelWidth: metadata?.width ?? 0,
            pixelHeight: metadata?.height ?? 0,
            frameCount: metadata?.frameCount ?? 1,
            colorMode: metadata?.colorMode ?? 'UNKNOWN',
            hasAlpha: metadata?.hasAlpha ?? false,
            bytes: bytes,
            region: ContentRegion(
              pageIndex: imagePart.pageIndex,
              frameIndex: 0,
              sourceOrder: imagePart.sourceOrder,
              layoutOrder: imagePart.sourceOrder,
            ),
            semanticVector: semantics.vector,
            semanticModel: semantics.model,
          ),
        );
        await reportFileProcessing(
          observer,
          FileProcessingStage.imageAnalysis,
          completedUnits: imageIndex + 1,
          totalUnits: extraction.imageParts.length,
          detail: imagePart.sourceName,
        );
      }

      textInformation.sort(_compareTextInformation);
      final stat = await file.stat();
      final hasErrors = issues.any(
        (issue) => issue.severity == ExtractionIssueSeverity.error,
      );

      return ParsingResult(
        metadata: FileMetadata(
          filePath: filePath,
          detectedFileType: extraction.detectedFormat,
          fileSize: stat.size,
          modifiedTime: stat.modified,
        ),
        content: ExtractedFileContent(
          textInformation: textInformation,
          imageInformation: imageInformation,
          audioInformation: const [],
          videoInformation: const [],
          issues: issues,
          status: hasErrors
              ? ExtractionStatus.partial
              : ExtractionStatus.completed,
        ),
      );
    } finally {
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    }
  }

  Future<void> _extractImageText({
    required String filePath,
    required DocumentImagePart imagePart,
    required File imageFile,
    required List<TextInformation> textInformation,
    required List<ExtractionIssue> issues,
  }) async {
    try {
      final ocr = await imageBackend.extractText(
        imageFile.path,
        languages: ocrLanguages,
      );
      if (ocr.text.trim().isEmpty) return;

      final regions = ocr.words
          .map(
            (word) => ContentRegion(
              pageIndex: imagePart.pageIndex,
              frameIndex: 0,
              sourceOrder: imagePart.sourceOrder,
              layoutOrder: imagePart.sourceOrder,
              left: word.left.toDouble(),
              top: word.top.toDouble(),
              right: (word.left + word.width).toDouble(),
              bottom: (word.top + word.height).toDouble(),
              extractedText: word.text,
              confidence: word.confidence,
            ),
          )
          .toList();

      textInformation.add(
        TextInformation(
          text: ocr.text,
          extractionMethod: TextExtractionMethod.ocr,
          informationKind: TextInformationKind.ocr,
          sourcePath: filePath,
          language: ocr.languages,
          confidence: ocr.meanConfidence,
          regions: regions.isEmpty
              ? [
                  ContentRegion(
                    pageIndex: imagePart.pageIndex,
                    frameIndex: 0,
                    sourceOrder: imagePart.sourceOrder,
                    layoutOrder: imagePart.sourceOrder,
                  ),
                ]
              : regions,
        ),
      );
    } catch (error) {
      issues.add(
        _imageIssue(
          stage: 'embedded_image_ocr',
          imagePart: imagePart,
          error: error,
        ),
      );
    }
  }

  Future<({List<double> vector, String? model})> _analyzeImage({
    required DocumentImagePart imagePart,
    required File imageFile,
    required List<ExtractionIssue> issues,
  }) async {
    try {
      final analysis = await imageBackend.analyzeImage(imageFile.path);
      if (analysis.vector.isEmpty) {
        throw const FormatException(
          'Image semantic analysis returned an empty vector.',
        );
      }
      if (analysis.dimensions != analysis.vector.length) {
        throw FormatException(
          'Image semantic vector declares ${analysis.dimensions} dimensions '
          'but contains ${analysis.vector.length} values.',
        );
      }
      return (vector: analysis.vector, model: analysis.model);
    } catch (error) {
      issues.add(
        _imageIssue(
          stage: 'embedded_image_semantics',
          imagePart: imagePart,
          error: error,
        ),
      );
      return (vector: <double>[], model: null);
    }
  }

  ExtractionIssue _imageIssue({
    required String stage,
    required DocumentImagePart imagePart,
    required Object error,
  }) {
    final page = imagePart.pageIndex == null
        ? ''
        : ' on page ${imagePart.pageIndex! + 1}';
    return ExtractionIssue(
      stage: stage,
      message: '${imagePart.sourceName}$page: $error',
      severity: ExtractionIssueSeverity.error,
    );
  }

  int _compareTextInformation(TextInformation left, TextInformation right) {
    final leftRegion = left.regions.isEmpty ? null : left.regions.first;
    final rightRegion = right.regions.isEmpty ? null : right.regions.first;
    final pageComparison = (leftRegion?.pageIndex ?? -1).compareTo(
      rightRegion?.pageIndex ?? -1,
    );
    if (pageComparison != 0) return pageComparison;
    return (leftRegion?.sourceOrder ?? -1).compareTo(
      rightRegion?.sourceOrder ?? -1,
    );
  }

  String _fallbackImageFormat(String sourceName) {
    final extension = p.extension(sourceName);
    if (extension.isEmpty) return 'UNKNOWN';
    return extension.substring(1).toUpperCase();
  }
}

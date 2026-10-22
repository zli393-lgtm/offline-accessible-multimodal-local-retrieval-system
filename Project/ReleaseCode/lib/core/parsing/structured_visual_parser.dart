import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../file_io/structured_visual_file_types.dart';
import '../models/extracted_file_content.dart';
import '../models/file_metadata.dart';
import '../models/parsing_result.dart';
import 'parser.dart';
import 'static_image_parser.dart';

class StructuredTextBlock {
  final String kind;
  final String text;
  final int sourceOrder;
  final String sourcePath;

  const StructuredTextBlock({
    required this.kind,
    required this.text,
    required this.sourceOrder,
    required this.sourcePath,
  });

  factory StructuredTextBlock.fromJson(Map<String, dynamic> json) {
    return StructuredTextBlock(
      kind: json['kind'] as String,
      text: json['text'] as String,
      sourceOrder: (json['source_order'] as num).toInt(),
      sourcePath: json['source_path'] as String,
    );
  }
}

class StructuredVisualArtifact {
  final String kind;
  final String path;
  final int sourceOrder;
  final String sourcePath;

  const StructuredVisualArtifact({
    required this.kind,
    required this.path,
    required this.sourceOrder,
    required this.sourcePath,
  });

  factory StructuredVisualArtifact.fromJson(Map<String, dynamic> json) {
    return StructuredVisualArtifact(
      kind: json['kind'] as String,
      path: json['path'] as String,
      sourceOrder: (json['source_order'] as num).toInt(),
      sourcePath: json['source_path'] as String,
    );
  }
}

class StructuredBackendIssue {
  final String stage;
  final String message;
  final String severity;

  const StructuredBackendIssue({
    required this.stage,
    required this.message,
    required this.severity,
  });

  factory StructuredBackendIssue.fromJson(Map<String, dynamic> json) {
    return StructuredBackendIssue(
      stage: json['stage'] as String,
      message: json['message'] as String,
      severity: json['severity'] as String,
    );
  }
}

class StructuredExtraction {
  final String format;
  final List<StructuredTextBlock> textBlocks;
  final List<StructuredVisualArtifact> visuals;
  final List<StructuredBackendIssue> issues;

  const StructuredExtraction({
    required this.format,
    required this.textBlocks,
    required this.visuals,
    required this.issues,
  });

  factory StructuredExtraction.fromJson(Map<String, dynamic> json) {
    return StructuredExtraction(
      format: json['format'] as String,
      textBlocks: (json['text_blocks'] as List<dynamic>)
          .map(
            (item) => StructuredTextBlock.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      visuals: (json['visuals'] as List<dynamic>)
          .map(
            (item) => StructuredVisualArtifact.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      issues: (json['issues'] as List<dynamic>)
          .map(
            (item) => StructuredBackendIssue.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
    );
  }
}

abstract class StructuredVisualBackend {
  Future<StructuredExtraction> extract(
    String filePath, {
    required String outputDirectory,
  });
}

class PythonStructuredVisualBackend implements StructuredVisualBackend {
  final String pythonExecutable;
  final String scriptPath;
  final String? browserExecutable;
  final String? workingDirectory;
  final Duration timeout;

  const PythonStructuredVisualBackend({
    this.pythonExecutable = 'python',
    this.scriptPath = 'services/structured_visual/structured_visual_reader.py',
    this.browserExecutable,
    this.workingDirectory,
    this.timeout = const Duration(minutes: 5),
  });

  @override
  Future<StructuredExtraction> extract(
    String filePath, {
    required String outputDirectory,
  }) async {
    final arguments = [
      scriptPath,
      '--input',
      filePath,
      '--output-dir',
      outputDirectory,
    ];
    if (browserExecutable != null) {
      arguments.addAll(['--browser-executable', browserExecutable!]);
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
      throw ProcessException(
        pythonExecutable,
        arguments,
        payload?['error']?.toString() ?? (stderr.isEmpty ? stdout : stderr),
        result.exitCode,
      );
    }
    if (payload == null) {
      throw const FormatException(
        'Structured-visual service returned invalid JSON.',
      );
    }
    return StructuredExtraction.fromJson(payload);
  }
}

class StructuredVisualParser implements Parser {
  final StructuredVisualBackend backend;
  final StaticImageBackend imageBackend;
  final String ocrLanguages;

  const StructuredVisualParser({
    required this.backend,
    required this.imageBackend,
    this.ocrLanguages = 'chi_sim+eng',
  });

  factory StructuredVisualParser.python({
    required String mobileClipModelPath,
    String pythonExecutable = 'python',
    String structuredScriptPath =
        'services/structured_visual/structured_visual_reader.py',
    String imageScriptPath = 'services/static_image/static_image_reader.py',
    String mobileClipModelName = 'mobileclip_s0',
    String device = 'cpu',
    String? browserExecutable,
    String? tesseractExecutable,
    String? workingDirectory,
    String ocrLanguages = 'chi_sim+eng',
  }) {
    return StructuredVisualParser(
      backend: PythonStructuredVisualBackend(
        pythonExecutable: pythonExecutable,
        scriptPath: structuredScriptPath,
        browserExecutable: browserExecutable,
        workingDirectory: workingDirectory,
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
    );
  }

  static bool supports(String filePath) =>
      StructuredVisualFileTypes.supports(filePath);

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
        'Not a supported table/chart/vector file: $filePath',
      );
    }

    final outputDirectory = await Directory.systemTemp.createTemp(
      'structured_visual_',
    );
    try {
      await reportFileProcessing(
        observer,
        FileProcessingStage.structureParsing,
      );
      final extracted = await backend.extract(
        filePath,
        outputDirectory: outputDirectory.path,
      );
      final issues = extracted.issues
          .map(
            (issue) => ExtractionIssue(
              stage: issue.stage,
              message: issue.message,
              severity: issue.severity == 'warning'
                  ? ExtractionIssueSeverity.warning
                  : ExtractionIssueSeverity.error,
            ),
          )
          .toList();
      final expectedFormat = StructuredVisualFileTypes.typeLabel(filePath);
      if (extracted.format.toUpperCase() != expectedFormat) {
        issues.add(
          ExtractionIssue(
            stage: 'file_type',
            message:
                'File extension declares $expectedFormat but the reader '
                'reported ${extracted.format}.',
            severity: ExtractionIssueSeverity.warning,
          ),
        );
      }

      final textInformation = extracted.textBlocks
          .map(
            (block) => TextInformation(
              text: block.text,
              extractionMethod: TextExtractionMethod.direct,
              informationKind: _textKind(block.kind),
              sourcePath: filePath,
              regions: [
                ContentRegion(sourceOrder: block.sourceOrder, layoutOrder: 0),
              ],
            ),
          )
          .toList();
      final directTextCount = textInformation
          .where(
            (item) => item.informationKind == TextInformationKind.plainText,
          )
          .length;
      final tableCount = textInformation
          .where((item) => item.informationKind == TextInformationKind.table)
          .length;
      final chartCount = textInformation
          .where(
            (item) => item.informationKind == TextInformationKind.chartData,
          )
          .length;
      final vectorCount = textInformation
          .where(
            (item) => item.informationKind == TextInformationKind.vectorData,
          )
          .length;
      if (directTextCount > 0) {
        await reportFileProcessing(
          observer,
          FileProcessingStage.textExtraction,
          completedUnits: directTextCount,
          totalUnits: directTextCount,
        );
      }
      if (tableCount > 0) {
        await reportFileProcessing(
          observer,
          FileProcessingStage.tableExtraction,
          completedUnits: tableCount,
          totalUnits: tableCount,
        );
      }
      if (chartCount > 0) {
        await reportFileProcessing(
          observer,
          FileProcessingStage.chartExtraction,
          completedUnits: chartCount,
          totalUnits: chartCount,
        );
      }
      if (vectorCount > 0) {
        await reportFileProcessing(
          observer,
          FileProcessingStage.vectorExtraction,
          completedUnits: vectorCount,
          totalUnits: vectorCount,
        );
      }
      final imageInformation = <ImageInformation>[];

      for (
        var visualIndex = 0;
        visualIndex < extracted.visuals.length;
        visualIndex++
      ) {
        final visual = extracted.visuals[visualIndex];
        await reportFileProcessing(
          observer,
          FileProcessingStage.imageDecoding,
          completedUnits: visualIndex,
          totalUnits: extracted.visuals.length,
        );
        StaticImageMetadata metadata;
        await reportFileProcessing(
          observer,
          FileProcessingStage.imageOcr,
          completedUnits: visualIndex,
          totalUnits: extracted.visuals.length,
        );
        try {
          metadata = await imageBackend.inspect(visual.path);
        } catch (error) {
          issues.add(
            ExtractionIssue(
              stage: 'rendered_pixel_decode',
              message: '${visual.sourcePath}: $error',
              severity: ExtractionIssueSeverity.error,
            ),
          );
          continue;
        }

        await reportFileProcessing(
          observer,
          FileProcessingStage.imageAnalysis,
          completedUnits: visualIndex,
          totalUnits: extracted.visuals.length,
        );
        try {
          final ocr = await imageBackend.extractText(
            visual.path,
            languages: ocrLanguages,
          );
          if (ocr.text.trim().isNotEmpty) {
            final regions = ocr.words
                .map(
                  (word) => ContentRegion(
                    frameIndex: 0,
                    sourceOrder: visual.sourceOrder,
                    layoutOrder: 1,
                    left: word.left.toDouble(),
                    top: word.top.toDouble(),
                    right: (word.left + word.width).toDouble(),
                    bottom: (word.top + word.height).toDouble(),
                    extractedText: word.text,
                    confidence: word.confidence,
                  ),
                )
                .toList();
            if (regions.isEmpty) {
              regions.add(
                ContentRegion(
                  frameIndex: 0,
                  sourceOrder: visual.sourceOrder,
                  layoutOrder: 1,
                  extractedText: ocr.text,
                  confidence: ocr.meanConfidence,
                ),
              );
            }
            textInformation.add(
              TextInformation(
                text: ocr.text,
                extractionMethod: TextExtractionMethod.ocr,
                informationKind: TextInformationKind.ocr,
                sourcePath: filePath,
                language: ocr.languages,
                confidence: ocr.meanConfidence,
                regions: regions,
              ),
            );
          }
        } catch (error) {
          issues.add(
            ExtractionIssue(
              stage: 'ocr',
              message: '${visual.sourcePath}: $error',
              severity: ExtractionIssueSeverity.error,
            ),
          );
        }

        var semanticVector = <double>[];
        String? semanticModel;
        try {
          final semantics = await imageBackend.analyzeImage(visual.path);
          if (semantics.vector.isEmpty ||
              semantics.dimensions != semantics.vector.length) {
            throw const FormatException(
              'Rendered image returned an invalid semantic vector.',
            );
          }
          semanticVector = semantics.vector;
          semanticModel = semantics.model;
        } catch (error) {
          issues.add(
            ExtractionIssue(
              stage: 'image_semantics',
              message: '${visual.sourcePath}: $error',
              severity: ExtractionIssueSeverity.error,
            ),
          );
        }

        imageInformation.add(
          ImageInformation(
            sourcePath: filePath,
            format: metadata.format.toUpperCase(),
            pixelWidth: metadata.width,
            pixelHeight: metadata.height,
            frameCount: metadata.frameCount,
            colorMode: metadata.colorMode,
            hasAlpha: metadata.hasAlpha,
            bytes: await File(visual.path).readAsBytes(),
            pixelBytes: Uint8List.fromList(metadata.pixels),
            pixelFormat: metadata.pixelFormat,
            rowStride: metadata.rowStride,
            informationKind: _imageKind(visual.kind),
            region: ContentRegion(
              frameIndex: 0,
              sourceOrder: visual.sourceOrder,
            ),
            semanticVector: semanticVector,
            semanticModel: semanticModel,
          ),
        );
        await reportFileProcessing(
          observer,
          FileProcessingStage.imageAnalysis,
          completedUnits: visualIndex + 1,
          totalUnits: extracted.visuals.length,
        );
      }

      textInformation.sort((left, right) {
        final leftRegion = left.regions.firstOrNull;
        final rightRegion = right.regions.firstOrNull;
        final order = (leftRegion?.sourceOrder ?? 0).compareTo(
          rightRegion?.sourceOrder ?? 0,
        );
        if (order != 0) return order;
        return (leftRegion?.layoutOrder ?? 0).compareTo(
          rightRegion?.layoutOrder ?? 0,
        );
      });

      final stat = await file.stat();
      final hasErrors = issues.any(
        (issue) => issue.severity == ExtractionIssueSeverity.error,
      );
      final hasContent =
          textInformation.isNotEmpty || imageInformation.isNotEmpty;
      return ParsingResult(
        metadata: FileMetadata(
          filePath: filePath,
          detectedFileType: extracted.format.toUpperCase(),
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
              ? (hasContent
                    ? ExtractionStatus.partial
                    : ExtractionStatus.failed)
              : ExtractionStatus.completed,
        ),
      );
    } finally {
      if (await outputDirectory.exists()) {
        await outputDirectory.delete(recursive: true);
      }
    }
  }

  static TextInformationKind _textKind(String kind) {
    return switch (kind) {
      'table' => TextInformationKind.table,
      'chart_data' => TextInformationKind.chartData,
      'vector_data' => TextInformationKind.vectorData,
      _ => TextInformationKind.plainText,
    };
  }

  static ImageInformationKind _imageKind(String kind) {
    return switch (kind) {
      'rendered_chart' => ImageInformationKind.renderedChart,
      'rendered_vector' => ImageInformationKind.renderedVector,
      _ => ImageInformationKind.sourceBitmap,
    };
  }
}

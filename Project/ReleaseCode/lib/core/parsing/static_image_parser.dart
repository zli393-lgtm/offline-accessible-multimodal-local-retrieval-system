import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../file_io/static_image_file_types.dart';
import '../models/extracted_file_content.dart';
import '../models/file_metadata.dart';
import '../models/parsing_result.dart';
import 'parser.dart';

class StaticImageMetadata {
  final String format;
  final int width;
  final int height;
  final int frameCount;
  final String colorMode;
  final bool hasAlpha;
  final List<int> pixels;
  final String pixelFormat;
  final int rowStride;
  final int frameIndex;
  final Duration? frameDuration;
  final int? disposalMethod;
  final List<int> frameBytes;

  const StaticImageMetadata({
    required this.format,
    required this.width,
    required this.height,
    required this.frameCount,
    required this.colorMode,
    required this.hasAlpha,
    this.pixels = const [],
    this.pixelFormat = 'RGBA8888',
    this.rowStride = 0,
    this.frameIndex = 0,
    this.frameDuration,
    this.disposalMethod,
    this.frameBytes = const [],
  });

  factory StaticImageMetadata.fromJson(Map<String, dynamic> json) {
    return StaticImageMetadata(
      format: json['format'] as String,
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      frameCount: (json['frame_count'] as num).toInt(),
      colorMode: json['color_mode'] as String,
      hasAlpha: json['has_alpha'] as bool,
      pixels: base64Decode(json['pixels_base64'] as String),
      pixelFormat: json['pixel_format'] as String,
      rowStride: (json['row_stride'] as num).toInt(),
      frameIndex: (json['frame_index'] as num? ?? 0).toInt(),
      frameDuration: json['frame_duration_ms'] == null
          ? null
          : Duration(milliseconds: (json['frame_duration_ms'] as num).round()),
      disposalMethod: (json['disposal_method'] as num?)?.toInt(),
      frameBytes: base64Decode(json['frame_png_base64'] as String? ?? ''),
    );
  }
}

class OcrWord {
  final String text;
  final double confidence;
  final int left;
  final int top;
  final int width;
  final int height;

  const OcrWord({
    required this.text,
    required this.confidence,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  factory OcrWord.fromJson(Map<String, dynamic> json) {
    return OcrWord(
      text: json['text'] as String,
      confidence: (json['confidence'] as num).toDouble(),
      left: (json['left'] as num).toInt(),
      top: (json['top'] as num).toInt(),
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
    );
  }
}

class StaticImageOcrResult {
  final String text;
  final String languages;
  final double? meanConfidence;
  final List<OcrWord> words;

  const StaticImageOcrResult({
    required this.text,
    required this.languages,
    required this.meanConfidence,
    required this.words,
  });

  factory StaticImageOcrResult.fromJson(Map<String, dynamic> json) {
    return StaticImageOcrResult(
      text: json['text'] as String,
      languages: json['languages'] as String,
      meanConfidence: (json['mean_confidence'] as num?)?.toDouble(),
      words: (json['words'] as List<dynamic>)
          .map(
            (item) => OcrWord.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(),
    );
  }
}

class StaticImageSemanticResult {
  final String model;
  final int dimensions;
  final List<double> vector;

  const StaticImageSemanticResult({
    required this.model,
    required this.dimensions,
    required this.vector,
  });

  factory StaticImageSemanticResult.fromJson(Map<String, dynamic> json) {
    return StaticImageSemanticResult(
      model: json['model'] as String,
      dimensions: (json['dimensions'] as num).toInt(),
      vector: (json['vector'] as List<dynamic>)
          .map((value) => (value as num).toDouble())
          .toList(),
    );
  }
}

abstract class StaticImageBackend {
  Future<StaticImageMetadata> inspect(String filePath, {int frameIndex = 0});

  Future<StaticImageOcrResult> extractText(
    String filePath, {
    required String languages,
    int frameIndex = 0,
  });

  Future<StaticImageSemanticResult> analyzeImage(
    String filePath, {
    int frameIndex = 0,
  });
}

class PythonStaticImageBackend implements StaticImageBackend {
  final String pythonExecutable;
  final String scriptPath;
  final String mobileClipModelPath;
  final String mobileClipModelName;
  final String device;
  final String? tesseractExecutable;
  final String? workingDirectory;
  final Duration timeout;

  const PythonStaticImageBackend({
    required this.mobileClipModelPath,
    this.pythonExecutable = 'python',
    this.scriptPath = 'services/static_image/static_image_reader.py',
    this.mobileClipModelName = 'mobileclip_s0',
    this.device = 'cpu',
    this.tesseractExecutable,
    this.workingDirectory,
    this.timeout = const Duration(minutes: 5),
  });

  @override
  Future<StaticImageMetadata> inspect(
    String filePath, {
    int frameIndex = 0,
  }) async {
    final json = await _run([
      'inspect',
      '--input',
      filePath,
      '--frame-index',
      '$frameIndex',
    ]);
    return StaticImageMetadata.fromJson(
      Map<String, dynamic>.from(json['metadata'] as Map),
    );
  }

  @override
  Future<StaticImageOcrResult> extractText(
    String filePath, {
    required String languages,
    int frameIndex = 0,
  }) async {
    final arguments = [
      'ocr',
      '--input',
      filePath,
      '--languages',
      languages,
      '--frame-index',
      '$frameIndex',
    ];
    if (tesseractExecutable != null) {
      arguments.addAll(['--tesseract-executable', tesseractExecutable!]);
    }
    return StaticImageOcrResult.fromJson(await _run(arguments));
  }

  @override
  Future<StaticImageSemanticResult> analyzeImage(
    String filePath, {
    int frameIndex = 0,
  }) async {
    return StaticImageSemanticResult.fromJson(
      await _run([
        'analyze',
        '--input',
        filePath,
        '--model-path',
        mobileClipModelPath,
        '--model-name',
        mobileClipModelName,
        '--device',
        device,
        '--frame-index',
        '$frameIndex',
      ]),
    );
  }

  Future<Map<String, dynamic>> _run(List<String> arguments) async {
    final result = await Process.run(
      pythonExecutable,
      [scriptPath, ...arguments],
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
        [scriptPath, ...arguments],
        message,
        result.exitCode,
      );
    }

    if (payload == null) {
      throw const FormatException(
        'Static-image service returned invalid JSON.',
      );
    }
    return payload;
  }
}

class StaticImageParser implements Parser {
  final StaticImageBackend backend;
  final String ocrLanguages;

  const StaticImageParser({
    required this.backend,
    this.ocrLanguages = 'chi_sim+eng',
  });

  factory StaticImageParser.python({
    required String mobileClipModelPath,
    String pythonExecutable = 'python',
    String scriptPath = 'services/static_image/static_image_reader.py',
    String mobileClipModelName = 'mobileclip_s0',
    String device = 'cpu',
    String? tesseractExecutable,
    String? workingDirectory,
    String ocrLanguages = 'chi_sim+eng',
  }) {
    return StaticImageParser(
      backend: PythonStaticImageBackend(
        mobileClipModelPath: mobileClipModelPath,
        pythonExecutable: pythonExecutable,
        scriptPath: scriptPath,
        mobileClipModelName: mobileClipModelName,
        device: device,
        tesseractExecutable: tesseractExecutable,
        workingDirectory: workingDirectory,
      ),
      ocrLanguages: ocrLanguages,
    );
  }

  static bool supports(String filePath) =>
      StaticImageFileTypes.supports(filePath);

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
      throw UnsupportedError('Not a supported static-image file: $filePath');
    }

    await reportFileProcessing(observer, FileProcessingStage.imageDecoding);
    final imageMetadata = await backend.inspect(filePath);
    final detectedFormat = imageMetadata.format.toUpperCase();
    if (!StaticImageFileTypes.supportsDetectedFormat(detectedFormat)) {
      throw UnsupportedError(
        'Unsupported decoded image format: $detectedFormat',
      );
    }
    final issues = <ExtractionIssue>[];
    if (!StaticImageFileTypes.extensionMatchesFormat(
      filePath,
      detectedFormat,
    )) {
      issues.add(
        ExtractionIssue(
          stage: 'file_type',
          message:
              'File extension does not match decoded format '
              '$detectedFormat.',
          severity: ExtractionIssueSeverity.warning,
        ),
      );
    }

    final stat = await file.stat();
    final sourceBytes = await file.readAsBytes();
    final textInformation = <TextInformation>[];
    final imageInformation = <ImageInformation>[];

    for (
      var frameIndex = 0;
      frameIndex < imageMetadata.frameCount;
      frameIndex++
    ) {
      await reportFileProcessing(
        observer,
        FileProcessingStage.imageDecoding,
        completedUnits: frameIndex,
        totalUnits: imageMetadata.frameCount,
      );
      final frameMetadata = frameIndex == 0
          ? imageMetadata
          : await backend.inspect(filePath, frameIndex: frameIndex);
      final fallbackRegion = ContentRegion(
        frameIndex: frameIndex,
        frameDuration: frameMetadata.frameDuration,
      );

      await reportFileProcessing(
        observer,
        FileProcessingStage.imageOcr,
        completedUnits: frameIndex,
        totalUnits: imageMetadata.frameCount,
      );
      try {
        final ocr = await backend.extractText(
          filePath,
          languages: ocrLanguages,
          frameIndex: frameIndex,
        );
        if (ocr.text.trim().isNotEmpty) {
          final regions = ocr.words
              .map(
                (word) => ContentRegion(
                  frameIndex: frameIndex,
                  frameDuration: frameMetadata.frameDuration,
                  left: word.left.toDouble(),
                  top: word.top.toDouble(),
                  right: (word.left + word.width).toDouble(),
                  bottom: (word.top + word.height).toDouble(),
                  extractedText: word.text,
                  confidence: word.confidence,
                ),
              )
              .toList();
          _mergeOcrText(
            target: textInformation,
            text: ocr.text,
            sourcePath: filePath,
            language: ocr.languages,
            confidence: ocr.meanConfidence,
            regions: regions.isEmpty ? [fallbackRegion] : regions,
          );
        }
      } catch (error) {
        issues.add(
          ExtractionIssue(
            stage: 'ocr',
            message: 'Frame ${frameIndex + 1}: $error',
            severity: ExtractionIssueSeverity.error,
          ),
        );
      }

      var semanticVector = <double>[];
      String? semanticModel;
      await reportFileProcessing(
        observer,
        FileProcessingStage.imageAnalysis,
        completedUnits: frameIndex,
        totalUnits: imageMetadata.frameCount,
      );
      try {
        final analysis = await backend.analyzeImage(
          filePath,
          frameIndex: frameIndex,
        );
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
        semanticVector = analysis.vector;
        semanticModel = analysis.model;
      } catch (error) {
        issues.add(
          ExtractionIssue(
            stage: 'image_semantics',
            message: 'Frame ${frameIndex + 1}: $error',
            severity: ExtractionIssueSeverity.error,
          ),
        );
      }

      imageInformation.add(
        ImageInformation(
          sourcePath: filePath,
          format: imageMetadata.frameCount == 1 ? detectedFormat : 'PNG',
          pixelWidth: frameMetadata.width,
          pixelHeight: frameMetadata.height,
          frameCount: imageMetadata.frameCount,
          colorMode: frameMetadata.colorMode,
          hasAlpha: frameMetadata.hasAlpha,
          bytes: Uint8List.fromList(
            imageMetadata.frameCount == 1 || frameMetadata.frameBytes.isEmpty
                ? sourceBytes
                : frameMetadata.frameBytes,
          ),
          pixelBytes: Uint8List.fromList(frameMetadata.pixels),
          pixelFormat: frameMetadata.pixelFormat,
          rowStride: frameMetadata.rowStride,
          informationKind: imageMetadata.frameCount == 1
              ? ImageInformationKind.sourceBitmap
              : ImageInformationKind.animationFrame,
          region: fallbackRegion,
          semanticVector: semanticVector,
          semanticModel: semanticModel,
        ),
      );
      await reportFileProcessing(
        observer,
        FileProcessingStage.imageAnalysis,
        completedUnits: frameIndex + 1,
        totalUnits: imageMetadata.frameCount,
      );
    }

    final hasErrors = issues.any(
      (issue) => issue.severity == ExtractionIssueSeverity.error,
    );

    return ParsingResult(
      metadata: FileMetadata(
        filePath: filePath,
        detectedFileType: detectedFormat,
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
  }

  void _mergeOcrText({
    required List<TextInformation> target,
    required String text,
    required String sourcePath,
    required String language,
    required double? confidence,
    required List<ContentRegion> regions,
  }) {
    final normalized = text.trim();
    final existingIndex = target.indexWhere(
      (item) =>
          item.extractionMethod == TextExtractionMethod.ocr &&
          item.text.trim() == normalized,
    );
    if (existingIndex < 0) {
      target.add(
        TextInformation(
          text: normalized,
          extractionMethod: TextExtractionMethod.ocr,
          informationKind: TextInformationKind.ocr,
          sourcePath: sourcePath,
          language: language,
          confidence: confidence,
          regions: regions,
        ),
      );
      return;
    }
    final existing = target[existingIndex];
    target[existingIndex] = TextInformation(
      text: existing.text,
      extractionMethod: existing.extractionMethod,
      informationKind: existing.informationKind,
      sourcePath: existing.sourcePath,
      language: existing.language,
      confidence: existing.confidence,
      regions: [...existing.regions, ...regions],
    );
  }
}

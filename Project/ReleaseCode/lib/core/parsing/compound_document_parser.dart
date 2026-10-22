import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../file_io/compound_document_file_types.dart';
import '../models/extracted_file_content.dart';
import '../models/file_metadata.dart';
import '../models/parsing_result.dart';
import 'audio_parser.dart';
import 'parser.dart';
import 'static_image_parser.dart';

class CompoundTextBlock {
  final String kind;
  final String text;
  final int? pageIndex;
  final int sourceOrder;
  final String? logicalLocation;

  const CompoundTextBlock({
    required this.kind,
    required this.text,
    required this.pageIndex,
    required this.sourceOrder,
    this.logicalLocation,
  });

  factory CompoundTextBlock.fromJson(Map<String, dynamic> json) =>
      CompoundTextBlock(
        kind: json['kind'] as String? ?? 'plain_text',
        text: json['text'] as String,
        pageIndex: (json['page_index'] as num?)?.toInt(),
        sourceOrder: (json['source_order'] as num).toInt(),
        logicalLocation: json['logical_location'] as String?,
      );
}

class CompoundMediaPart {
  final String filePath;
  final String sourceName;
  final int? pageIndex;
  final int sourceOrder;
  final String? logicalLocation;
  final String? kind;

  const CompoundMediaPart({
    required this.filePath,
    required this.sourceName,
    required this.pageIndex,
    required this.sourceOrder,
    this.logicalLocation,
    this.kind,
  });

  factory CompoundMediaPart.fromJson(Map<String, dynamic> json) =>
      CompoundMediaPart(
        filePath: json['file_path'] as String,
        sourceName: json['source_name'] as String,
        pageIndex: (json['page_index'] as num?)?.toInt(),
        sourceOrder: (json['source_order'] as num).toInt(),
        logicalLocation: json['logical_location'] as String?,
        kind: json['kind'] as String?,
      );
}

class CompoundBackendIssue {
  final String stage;
  final String message;
  final bool isError;

  const CompoundBackendIssue({
    required this.stage,
    required this.message,
    required this.isError,
  });

  factory CompoundBackendIssue.fromJson(Map<String, dynamic> json) =>
      CompoundBackendIssue(
        stage: json['stage'] as String,
        message: json['message'] as String,
        isError: json['severity'] == 'error',
      );
}

class CompoundExtraction {
  final String detectedFormat;
  final List<CompoundTextBlock> textBlocks;
  final List<CompoundMediaPart> imageParts;
  final List<CompoundMediaPart> audioParts;
  final List<CompoundBackendIssue> issues;

  const CompoundExtraction({
    required this.detectedFormat,
    required this.textBlocks,
    required this.imageParts,
    required this.audioParts,
    required this.issues,
  });

  factory CompoundExtraction.fromJson(Map<String, dynamic> json) =>
      CompoundExtraction(
        detectedFormat: json['detected_format'] as String,
        textBlocks: (json['text_blocks'] as List<dynamic>? ?? const [])
            .map(
              (item) => CompoundTextBlock.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(),
        imageParts: (json['image_parts'] as List<dynamic>? ?? const [])
            .map(
              (item) => CompoundMediaPart.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(),
        audioParts: (json['audio_parts'] as List<dynamic>? ?? const [])
            .map(
              (item) => CompoundMediaPart.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(),
        issues: (json['issues'] as List<dynamic>? ?? const [])
            .map(
              (item) => CompoundBackendIssue.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(),
      );
}

abstract class CompoundDocumentBackend {
  Future<CompoundExtraction> extract(
    String filePath, {
    required String outputDirectory,
  });
}

class PythonCompoundDocumentBackend implements CompoundDocumentBackend {
  final String pythonExecutable;
  final String scriptPath;
  final String? javaExecutable;
  final String? tikaJarPath;
  final String? workingDirectory;
  final Duration timeout;

  const PythonCompoundDocumentBackend({
    this.pythonExecutable = 'python',
    this.scriptPath = 'services/compound_document/compound_document_reader.py',
    this.javaExecutable,
    this.tikaJarPath,
    this.workingDirectory,
    this.timeout = const Duration(minutes: 20),
  });

  @override
  Future<CompoundExtraction> extract(
    String filePath, {
    required String outputDirectory,
  }) async {
    final arguments = [
      scriptPath,
      '--input',
      filePath,
      '--output-directory',
      outputDirectory,
      if (javaExecutable != null) ...['--java-executable', javaExecutable!],
      if (tikaJarPath != null) ...['--tika-jar', tikaJarPath!],
    ];
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
        'Compound-document service returned invalid JSON.',
      );
    }
    return CompoundExtraction.fromJson(payload);
  }
}

class CompoundDocumentParser implements Parser {
  final CompoundDocumentBackend documentBackend;
  final StaticImageBackend imageBackend;
  final AudioBackend audioBackend;
  final String ocrLanguages;
  final String? temporaryDirectoryPath;

  const CompoundDocumentParser({
    required this.documentBackend,
    required this.imageBackend,
    required this.audioBackend,
    this.ocrLanguages = 'chi_sim+eng',
    this.temporaryDirectoryPath,
  });

  factory CompoundDocumentParser.python({
    required String mobileClipModelPath,
    required String whisperModelPath,
    required String clapModelPath,
    String pythonExecutable = 'python',
    String documentScriptPath =
        'services/compound_document/compound_document_reader.py',
    String imageScriptPath = 'services/static_image/static_image_reader.py',
    String audioScriptPath = 'services/audio/audio_reader.py',
    String mobileClipModelName = 'mobileclip_s0',
    String device = 'cpu',
    String whisperComputeType = 'int8',
    String? tesseractExecutable,
    String? javaExecutable,
    String? tikaJarPath,
    String? workingDirectory,
    String? temporaryDirectoryPath,
    String ocrLanguages = 'chi_sim+eng',
  }) => CompoundDocumentParser(
    documentBackend: PythonCompoundDocumentBackend(
      pythonExecutable: pythonExecutable,
      scriptPath: documentScriptPath,
      javaExecutable: javaExecutable,
      tikaJarPath: tikaJarPath,
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
    audioBackend: PythonAudioBackend(
      whisperModelPath: whisperModelPath,
      clapModelPath: clapModelPath,
      pythonExecutable: pythonExecutable,
      scriptPath: audioScriptPath,
      device: device,
      whisperComputeType: whisperComputeType,
      workingDirectory: workingDirectory,
    ),
    ocrLanguages: ocrLanguages,
    temporaryDirectoryPath: temporaryDirectoryPath,
  );

  static bool supports(String filePath) =>
      CompoundDocumentFileTypes.supports(filePath);

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
      throw UnsupportedError('Not a supported compound document: $filePath');
    }

    final temporaryRoot = temporaryDirectoryPath == null
        ? Directory.systemTemp
        : Directory(temporaryDirectoryPath!);
    if (!await temporaryRoot.exists()) {
      await temporaryRoot.create(recursive: true);
    }
    final workspace = await temporaryRoot.createTemp('compound_document_');
    try {
      await reportFileProcessing(
        observer,
        FileProcessingStage.structureParsing,
      );
      final extracted = await documentBackend.extract(
        filePath,
        outputDirectory: workspace.path,
      );
      final expected = CompoundDocumentFileTypes.typeLabel(filePath);
      if (extracted.detectedFormat != expected) {
        throw FormatException(
          'File extension declares $expected but the document reader '
          'reported ${extracted.detectedFormat}.',
        );
      }
      final issues = extracted.issues
          .map(
            (item) => ExtractionIssue(
              stage: item.stage,
              message: item.message,
              severity: item.isError
                  ? ExtractionIssueSeverity.error
                  : ExtractionIssueSeverity.warning,
            ),
          )
          .toList();
      final textInformation = extracted.textBlocks
          .map(
            (block) => TextInformation(
              text: block.text,
              extractionMethod: TextExtractionMethod.direct,
              informationKind: _textKind(block.kind),
              sourcePath: filePath,
              regions: [
                ContentRegion(
                  pageIndex: block.pageIndex,
                  sourceOrder: block.sourceOrder,
                  layoutOrder: block.sourceOrder,
                  logicalLocation: block.logicalLocation,
                ),
              ],
            ),
          )
          .toList();
      for (final stage in const [
        FileProcessingStage.textExtraction,
        FileProcessingStage.tableExtraction,
        FileProcessingStage.chartExtraction,
        FileProcessingStage.vectorExtraction,
      ]) {
        final kind = switch (stage) {
          FileProcessingStage.tableExtraction => TextInformationKind.table,
          FileProcessingStage.chartExtraction => TextInformationKind.chartData,
          FileProcessingStage.vectorExtraction =>
            TextInformationKind.vectorData,
          _ => TextInformationKind.plainText,
        };
        final count = textInformation
            .where((item) => item.informationKind == kind)
            .length;
        if (count > 0) {
          await reportFileProcessing(
            observer,
            stage,
            completedUnits: count,
            totalUnits: count,
          );
        }
      }
      final imageInformation = <ImageInformation>[];
      final audioInformation = <AudioInformation>[];

      for (
        var imageIndex = 0;
        imageIndex < extracted.imageParts.length;
        imageIndex++
      ) {
        final part = extracted.imageParts[imageIndex];
        await reportFileProcessing(
          observer,
          FileProcessingStage.imageDecoding,
          completedUnits: imageIndex,
          totalUnits: extracted.imageParts.length,
          detail: part.sourceName,
        );
        final media = await _validatedMedia(part, workspace, issues, 'image');
        if (media == null) continue;
        await _readImagePart(
          filePath,
          part,
          media,
          textInformation,
          imageInformation,
          issues,
          observer,
          imageIndex,
          extracted.imageParts.length,
        );
      }
      for (
        var audioIndex = 0;
        audioIndex < extracted.audioParts.length;
        audioIndex++
      ) {
        final part = extracted.audioParts[audioIndex];
        await reportFileProcessing(
          observer,
          FileProcessingStage.audioReading,
          completedUnits: audioIndex,
          totalUnits: extracted.audioParts.length,
          detail: part.sourceName,
        );
        final media = await _validatedMedia(part, workspace, issues, 'audio');
        if (media == null) continue;
        await _readAudioPart(
          filePath,
          part,
          media,
          textInformation,
          audioInformation,
          issues,
          observer,
          audioIndex,
          extracted.audioParts.length,
        );
      }

      textInformation.sort((left, right) {
        final l = left.regions.firstOrNull;
        final r = right.regions.firstOrNull;
        final page = (l?.pageIndex ?? -1).compareTo(r?.pageIndex ?? -1);
        if (page != 0) return page;
        return (l?.sourceOrder ?? -1).compareTo(r?.sourceOrder ?? -1);
      });
      final stat = await file.stat();
      final hasErrors = issues.any(
        (item) => item.severity == ExtractionIssueSeverity.error,
      );
      final hasContent =
          textInformation.isNotEmpty ||
          imageInformation.isNotEmpty ||
          audioInformation.isNotEmpty;
      return ParsingResult(
        metadata: FileMetadata(
          filePath: filePath,
          detectedFileType: extracted.detectedFormat,
          fileSize: stat.size,
          modifiedTime: stat.modified,
        ),
        content: ExtractedFileContent(
          textInformation: textInformation,
          imageInformation: imageInformation,
          audioInformation: audioInformation,
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
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
        await reportFileProcessing(
          observer,
          FileProcessingStage.temporaryCleanup,
        );
      }
    }
  }

  Future<File?> _validatedMedia(
    CompoundMediaPart part,
    Directory workspace,
    List<ExtractionIssue> issues,
    String type,
  ) async {
    final normalizedRoot = p.normalize(p.absolute(workspace.path));
    final normalizedMedia = p.normalize(p.absolute(part.filePath));
    if (!p.isWithin(normalizedRoot, normalizedMedia)) {
      issues.add(
        ExtractionIssue(
          stage: 'embedded_${type}_path',
          message: '${part.sourceName} is outside the extraction workspace.',
          severity: ExtractionIssueSeverity.error,
        ),
      );
      return null;
    }
    final file = File(normalizedMedia);
    if (!await file.exists()) {
      issues.add(
        ExtractionIssue(
          stage: 'embedded_${type}_export',
          message: '${part.sourceName} is missing.',
          severity: ExtractionIssueSeverity.error,
        ),
      );
      return null;
    }
    return file;
  }

  Future<void> _readImagePart(
    String sourcePath,
    CompoundMediaPart part,
    File media,
    List<TextInformation> textTarget,
    List<ImageInformation> imageTarget,
    List<ExtractionIssue> issues,
    FileProcessingObserver? observer,
    int partIndex,
    int partCount,
  ) async {
    StaticImageMetadata first;
    try {
      first = await imageBackend.inspect(media.path);
    } catch (error) {
      issues.add(_mediaIssue('embedded_image_decode', part, error));
      return;
    }
    for (var frameIndex = 0; frameIndex < first.frameCount; frameIndex++) {
      final metadata = frameIndex == 0
          ? first
          : await imageBackend.inspect(media.path, frameIndex: frameIndex);
      final baseRegion = ContentRegion(
        pageIndex: part.pageIndex,
        frameIndex: frameIndex,
        frameDuration: metadata.frameDuration,
        sourceOrder: part.sourceOrder,
        layoutOrder: part.sourceOrder,
        sourceName: part.sourceName,
        logicalLocation: part.logicalLocation,
      );
      await reportFileProcessing(
        observer,
        FileProcessingStage.imageOcr,
        completedUnits: partIndex,
        totalUnits: partCount,
        detail: part.sourceName,
      );
      try {
        final ocr = await imageBackend.extractText(
          media.path,
          languages: ocrLanguages,
          frameIndex: frameIndex,
        );
        if (ocr.text.trim().isNotEmpty) {
          final regions = ocr.words
              .map(
                (word) => ContentRegion(
                  pageIndex: part.pageIndex,
                  frameIndex: frameIndex,
                  frameDuration: metadata.frameDuration,
                  sourceOrder: part.sourceOrder,
                  layoutOrder: part.sourceOrder,
                  sourceName: part.sourceName,
                  logicalLocation: part.logicalLocation,
                  left: word.left.toDouble(),
                  top: word.top.toDouble(),
                  right: (word.left + word.width).toDouble(),
                  bottom: (word.top + word.height).toDouble(),
                  extractedText: word.text,
                  confidence: word.confidence,
                ),
              )
              .toList();
          _mergeText(
            textTarget,
            TextInformation(
              text: ocr.text.trim(),
              extractionMethod: TextExtractionMethod.ocr,
              informationKind: TextInformationKind.ocr,
              sourcePath: sourcePath,
              language: ocr.languages,
              confidence: ocr.meanConfidence,
              regions: regions.isEmpty ? [baseRegion] : regions,
            ),
          );
        }
      } catch (error) {
        issues.add(_mediaIssue('embedded_image_ocr', part, error, frameIndex));
      }

      var vector = <double>[];
      String? model;
      await reportFileProcessing(
        observer,
        FileProcessingStage.imageAnalysis,
        completedUnits: partIndex,
        totalUnits: partCount,
        detail: part.sourceName,
      );
      try {
        final result = await imageBackend.analyzeImage(
          media.path,
          frameIndex: frameIndex,
        );
        if (result.vector.isEmpty ||
            result.vector.length != result.dimensions) {
          throw const FormatException('Image semantic vector is invalid.');
        }
        vector = result.vector;
        model = result.model;
      } catch (error) {
        issues.add(
          _mediaIssue('embedded_image_semantics', part, error, frameIndex),
        );
      }
      imageTarget.add(
        ImageInformation(
          sourcePath: sourcePath,
          format: first.frameCount == 1 ? metadata.format.toUpperCase() : 'PNG',
          pixelWidth: metadata.width,
          pixelHeight: metadata.height,
          frameCount: first.frameCount,
          colorMode: metadata.colorMode,
          hasAlpha: metadata.hasAlpha,
          bytes: Uint8List.fromList(
            first.frameCount == 1 || metadata.frameBytes.isEmpty
                ? await media.readAsBytes()
                : metadata.frameBytes,
          ),
          pixelBytes: Uint8List.fromList(metadata.pixels),
          pixelFormat: metadata.pixelFormat,
          rowStride: metadata.rowStride,
          informationKind: _imageKind(part.kind, first.frameCount),
          region: baseRegion,
          semanticVector: vector,
          semanticModel: model,
        ),
      );
    }
    await reportFileProcessing(
      observer,
      FileProcessingStage.imageAnalysis,
      completedUnits: partIndex + 1,
      totalUnits: partCount,
      detail: part.sourceName,
    );
  }

  Future<void> _readAudioPart(
    String sourcePath,
    CompoundMediaPart part,
    File media,
    List<TextInformation> textTarget,
    List<AudioInformation> audioTarget,
    List<ExtractionIssue> issues,
    FileProcessingObserver? observer,
    int partIndex,
    int partCount,
  ) async {
    AudioMetadata? metadata;
    try {
      metadata = await audioBackend.inspect(media.path);
    } catch (error) {
      issues.add(_mediaIssue('embedded_audio_metadata', part, error));
    }
    final tagText = audioTagsAsExtractedText(
      metadata?.tags ?? const {},
      sourcePath: sourcePath,
      region: ContentRegion(
        pageIndex: part.pageIndex,
        sourceOrder: part.sourceOrder,
        sourceName: part.sourceName,
        logicalLocation: part.logicalLocation,
      ),
    );
    if (tagText != null) _mergeText(textTarget, tagText);
    await reportFileProcessing(
      observer,
      FileProcessingStage.speechTranscription,
      completedUnits: partIndex,
      totalUnits: partCount,
      detail: part.sourceName,
    );
    try {
      final speech = await audioBackend.transcribe(media.path);
      if (speech.text.trim().isNotEmpty) {
        _mergeText(
          textTarget,
          TextInformation(
            text: speech.text.trim(),
            extractionMethod: TextExtractionMethod.speechRecognition,
            informationKind: TextInformationKind.speechTranscript,
            sourcePath: sourcePath,
            language: speech.language,
            confidence: speech.languageProbability,
            regions: speech.segments
                .map(
                  (segment) => ContentRegion(
                    pageIndex: part.pageIndex,
                    sourceOrder: part.sourceOrder,
                    sourceName: part.sourceName,
                    logicalLocation: part.logicalLocation,
                    startTime: segment.start,
                    endTime: segment.end,
                    extractedText: segment.text,
                    confidence: segment.confidence,
                  ),
                )
                .toList(),
          ),
        );
      }
    } catch (error) {
      issues.add(_mediaIssue('embedded_audio_speech', part, error));
    }
    var vector = <double>[];
    String? model;
    var regions = <ContentRegion>[];
    await reportFileProcessing(
      observer,
      FileProcessingStage.audioAnalysis,
      completedUnits: partIndex,
      totalUnits: partCount,
      detail: part.sourceName,
    );
    try {
      final result = await audioBackend.analyze(media.path);
      vector = result.vector;
      model = result.model;
      regions = result.regions
          .map(
            (region) => ContentRegion(
              pageIndex: part.pageIndex,
              sourceOrder: part.sourceOrder,
              sourceName: part.sourceName,
              logicalLocation: part.logicalLocation,
              startTime: region.startTime,
              endTime: region.endTime,
            ),
          )
          .toList();
    } catch (error) {
      issues.add(_mediaIssue('embedded_audio_semantics', part, error));
    }
    audioTarget.add(
      AudioInformation(
        sourcePath: sourcePath,
        bytes: await media.readAsBytes(),
        duration: metadata?.duration,
        format: metadata?.format,
        codec: metadata?.codec,
        sampleRate: metadata?.sampleRate,
        channels: metadata?.channels,
        bitRate: metadata?.bitRate,
        tags: metadata?.tags ?? const {},
        informationKind: AudioInformationKind.embeddedAudio,
        regions: regions,
        semanticVector: vector,
        semanticModel: model,
      ),
    );
    await reportFileProcessing(
      observer,
      FileProcessingStage.audioAnalysis,
      completedUnits: partIndex + 1,
      totalUnits: partCount,
      detail: part.sourceName,
    );
  }

  void _mergeText(List<TextInformation> target, TextInformation incoming) {
    final index = target.indexWhere(
      (item) =>
          item.extractionMethod == incoming.extractionMethod &&
          item.text.trim() == incoming.text.trim(),
    );
    if (index < 0) {
      target.add(incoming);
      return;
    }
    final existing = target[index];
    target[index] = TextInformation(
      text: existing.text,
      extractionMethod: existing.extractionMethod,
      informationKind: existing.informationKind,
      sourcePath: existing.sourcePath,
      language: existing.language,
      confidence: existing.confidence,
      regions: [...existing.regions, ...incoming.regions],
    );
  }

  ExtractionIssue _mediaIssue(
    String stage,
    CompoundMediaPart part,
    Object error, [
    int? frameIndex,
  ]) => ExtractionIssue(
    stage: stage,
    message:
        '${part.sourceName}${frameIndex == null ? '' : ' frame ${frameIndex + 1}'}: $error',
    severity: ExtractionIssueSeverity.error,
  );

  static TextInformationKind _textKind(String kind) => switch (kind) {
    'table' => TextInformationKind.table,
    'chart_data' => TextInformationKind.chartData,
    'vector_data' => TextInformationKind.vectorData,
    _ => TextInformationKind.plainText,
  };

  static ImageInformationKind _imageKind(String? kind, int frameCount) {
    if (frameCount > 1) return ImageInformationKind.animationFrame;
    return switch (kind) {
      'rendered_page' => ImageInformationKind.renderedPage,
      'rendered_chart' => ImageInformationKind.renderedChart,
      'rendered_vector' => ImageInformationKind.renderedVector,
      _ => ImageInformationKind.embeddedImage,
    };
  }
}

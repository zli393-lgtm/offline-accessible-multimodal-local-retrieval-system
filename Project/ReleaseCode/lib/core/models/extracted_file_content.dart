import 'dart:typed_data';

enum ExtractionStatus { completed, partial, failed }

enum ExtractionIssueSeverity { warning, error }

enum TextExtractionMethod { direct, ocr, speechRecognition, other }

enum TextInformationKind {
  plainText,
  table,
  chartData,
  vectorData,
  ocr,
  speechTranscript,
  metadata,
  fileName,
}

enum ImageInformationKind {
  sourceBitmap,
  animationFrame,
  embeddedImage,
  renderedPage,
  renderedChart,
  renderedVector,
}

enum AudioInformationKind { sourceAudio, embeddedAudio }

class ContentRegion {
  final int? pageIndex;
  final int? frameIndex;
  final int? sourceOrder;
  final int? layoutOrder;
  final double? left;
  final double? top;
  final double? right;
  final double? bottom;
  final Duration? startTime;
  final Duration? endTime;
  final Duration? frameDuration;
  final String? sourceName;
  final String? logicalLocation;
  final String? extractedText;
  final double? confidence;

  const ContentRegion({
    this.pageIndex,
    this.frameIndex,
    this.sourceOrder,
    this.layoutOrder,
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.startTime,
    this.endTime,
    this.frameDuration,
    this.sourceName,
    this.logicalLocation,
    this.extractedText,
    this.confidence,
  });
}

class TextInformation {
  final String text;
  final TextExtractionMethod extractionMethod;
  final TextInformationKind informationKind;
  final String sourcePath;
  final String? language;
  final double? confidence;
  final List<ContentRegion> regions;

  const TextInformation({
    required this.text,
    required this.extractionMethod,
    required this.sourcePath,
    required this.regions,
    this.informationKind = TextInformationKind.plainText,
    this.language,
    this.confidence,
  });
}

class ImageInformation {
  final String sourcePath;
  final String format;
  final int pixelWidth;
  final int pixelHeight;
  final int frameCount;
  final String colorMode;
  final bool hasAlpha;
  final Uint8List bytes;
  final Uint8List? pixelBytes;
  final String? pixelFormat;
  final int? rowStride;
  final ImageInformationKind informationKind;
  final ContentRegion? region;
  final List<double> semanticVector;
  final String? semanticModel;

  const ImageInformation({
    required this.sourcePath,
    required this.format,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.frameCount,
    required this.colorMode,
    required this.hasAlpha,
    required this.bytes,
    required this.semanticVector,
    this.pixelBytes,
    this.pixelFormat,
    this.rowStride,
    this.informationKind = ImageInformationKind.sourceBitmap,
    this.region,
    this.semanticModel,
  });

  bool get hasSemanticAnalysis =>
      semanticModel != null && semanticVector.isNotEmpty;

  bool get hasDecodedPixels =>
      pixelBytes != null &&
      pixelBytes!.isNotEmpty &&
      pixelFormat != null &&
      rowStride != null;
}

class AudioInformation {
  final String sourcePath;
  final Uint8List bytes;
  final Duration? duration;
  final String? format;
  final String? codec;
  final int? sampleRate;
  final int? channels;
  final int? bitRate;
  final Map<String, String> tags;
  final AudioInformationKind informationKind;
  final List<ContentRegion> regions;
  final List<double> semanticVector;
  final String? semanticModel;

  const AudioInformation({
    required this.sourcePath,
    required this.bytes,
    this.duration,
    this.format,
    this.codec,
    this.sampleRate,
    this.channels,
    this.bitRate,
    this.tags = const {},
    this.informationKind = AudioInformationKind.sourceAudio,
    this.regions = const [],
    this.semanticVector = const [],
    this.semanticModel,
  });

  bool get hasSemanticAnalysis =>
      semanticModel != null && semanticVector.isNotEmpty;
}

class VideoInformation {
  final String sourcePath;
  final Uint8List bytes;
  final Duration? duration;
  final String? format;

  const VideoInformation({
    required this.sourcePath,
    required this.bytes,
    this.duration,
    this.format,
  });
}

class ExtractionIssue {
  final String stage;
  final String message;
  final ExtractionIssueSeverity severity;

  const ExtractionIssue({
    required this.stage,
    required this.message,
    required this.severity,
  });
}

class ExtractedFileContent {
  final List<TextInformation> textInformation;
  final List<ImageInformation> imageInformation;
  final List<AudioInformation> audioInformation;
  final List<VideoInformation> videoInformation;
  final List<ExtractionIssue> issues;
  final ExtractionStatus status;

  const ExtractedFileContent({
    required this.textInformation,
    required this.imageInformation,
    required this.audioInformation,
    required this.videoInformation,
    required this.issues,
    required this.status,
  });

  String get mergedText => textInformation
      .map((item) => item.text.trim())
      .where((text) => text.isNotEmpty)
      .join('\n');
}

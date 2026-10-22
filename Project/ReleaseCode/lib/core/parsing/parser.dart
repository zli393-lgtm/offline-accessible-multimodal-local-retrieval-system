import 'dart:async';

import '../models/parsing_result.dart';

enum FileProcessingStage {
  reading,
  typeDetection,
  structureParsing,
  textExtraction,
  tableExtraction,
  chartExtraction,
  vectorExtraction,
  imageDecoding,
  imageOcr,
  imageAnalysis,
  audioReading,
  speechTranscription,
  audioAnalysis,
  textChunking,
  textEmbedding,
  imageEmbedding,
  audioEmbedding,
  indexStaging,
  indexValidation,
  indexCommit,
  temporaryCleanup,
}

class FileProcessingProgress {
  final FileProcessingStage stage;
  final int? completedUnits;
  final int? totalUnits;
  final String? detail;

  const FileProcessingProgress({
    required this.stage,
    this.completedUnits,
    this.totalUnits,
    this.detail,
  });
}

typedef FileProcessingObserver = FutureOr<void> Function(
  FileProcessingProgress progress,
);

class FileProcessingInterrupted implements Exception {
  const FileProcessingInterrupted();
}

Future<void> reportFileProcessing(
  FileProcessingObserver? observer,
  FileProcessingStage stage, {
  int? completedUnits,
  int? totalUnits,
  String? detail,
}) async {
  if (observer == null) return;
  await observer(
    FileProcessingProgress(
      stage: stage,
      completedUnits: completedUnits,
      totalUnits: totalUnits,
      detail: detail,
    ),
  );
}

abstract class Parser {
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  });
}

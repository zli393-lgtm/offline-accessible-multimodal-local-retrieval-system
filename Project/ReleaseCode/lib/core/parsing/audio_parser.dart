import 'dart:convert';
import 'dart:io';

import '../file_io/audio_file_types.dart';
import '../models/extracted_file_content.dart';
import '../models/file_metadata.dart';
import '../models/parsing_result.dart';
import 'parser.dart';

class AudioMetadata {
  final String format;
  final String? codec;
  final Duration? duration;
  final int? sampleRate;
  final int? channels;
  final int? bitRate;
  final Map<String, String> tags;

  const AudioMetadata({
    required this.format,
    this.codec,
    this.duration,
    this.sampleRate,
    this.channels,
    this.bitRate,
    this.tags = const {},
  });

  factory AudioMetadata.fromJson(Map<String, dynamic> json) {
    final durationMs = (json['duration_ms'] as num?)?.round();
    return AudioMetadata(
      format: json['format']?.toString() ?? 'UNKNOWN',
      codec: json['codec']?.toString(),
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      sampleRate: (json['sample_rate'] as num?)?.toInt(),
      channels: (json['channels'] as num?)?.toInt(),
      bitRate: (json['bit_rate'] as num?)?.toInt(),
      tags: Map<String, String>.from(json['tags'] as Map? ?? const {}),
    );
  }
}

TextInformation? audioTagsAsExtractedText(
  Map<String, String> tags, {
  required String sourcePath,
  ContentRegion? region,
}) {
  final entries =
      tags.entries
          .map((entry) => MapEntry(entry.key.trim(), entry.value.trim()))
          .where((entry) => entry.key.isNotEmpty && entry.value.isNotEmpty)
          .toList()
        ..sort(
          (left, right) =>
              left.key.toLowerCase().compareTo(right.key.toLowerCase()),
        );
  if (entries.isEmpty) return null;

  return TextInformation(
    text: entries.map((entry) => '${entry.key}: ${entry.value}').join('\n'),
    extractionMethod: TextExtractionMethod.other,
    informationKind: TextInformationKind.metadata,
    sourcePath: sourcePath,
    regions: region == null ? const [] : [region],
  );
}

class SpeechSegment {
  final String text;
  final Duration start;
  final Duration end;
  final double? confidence;

  const SpeechSegment({
    required this.text,
    required this.start,
    required this.end,
    this.confidence,
  });

  factory SpeechSegment.fromJson(Map<String, dynamic> json) => SpeechSegment(
    text: json['text'] as String,
    start: Duration(milliseconds: (json['start_ms'] as num).round()),
    end: Duration(milliseconds: (json['end_ms'] as num).round()),
    confidence: (json['confidence'] as num?)?.toDouble(),
  );
}

class AudioTranscription {
  final String text;
  final String? language;
  final double? languageProbability;
  final String model;
  final List<SpeechSegment> segments;

  const AudioTranscription({
    required this.text,
    required this.model,
    required this.segments,
    this.language,
    this.languageProbability,
  });

  factory AudioTranscription.fromJson(Map<String, dynamic> json) =>
      AudioTranscription(
        text: json['text'] as String? ?? '',
        model: json['model'] as String? ?? 'unknown',
        language: json['language'] as String?,
        languageProbability: (json['language_probability'] as num?)?.toDouble(),
        segments: (json['segments'] as List<dynamic>? ?? const [])
            .map(
              (item) => SpeechSegment.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(),
      );
}

class AudioSemanticResult {
  final String model;
  final List<double> vector;
  final List<ContentRegion> regions;

  const AudioSemanticResult({
    required this.model,
    required this.vector,
    required this.regions,
  });

  factory AudioSemanticResult.fromJson(Map<String, dynamic> json) {
    final vector = (json['vector'] as List<dynamic>)
        .map((value) => (value as num).toDouble())
        .toList();
    final dimensions = (json['dimensions'] as num).toInt();
    if (dimensions != vector.length || vector.isEmpty) {
      throw const FormatException('Audio semantic vector is invalid.');
    }
    return AudioSemanticResult(
      model: json['model'] as String,
      vector: vector,
      regions: (json['regions'] as List<dynamic>? ?? const []).map((item) {
        final region = Map<String, dynamic>.from(item as Map);
        return ContentRegion(
          startTime: Duration(
            milliseconds: (region['start_ms'] as num).round(),
          ),
          endTime: Duration(milliseconds: (region['end_ms'] as num).round()),
        );
      }).toList(),
    );
  }
}

abstract class AudioBackend {
  Future<AudioMetadata> inspect(String filePath);

  Future<AudioTranscription> transcribe(String filePath);

  Future<AudioSemanticResult> analyze(String filePath);
}

class PythonAudioBackend implements AudioBackend {
  final String pythonExecutable;
  final String scriptPath;
  final String whisperModelPath;
  final String clapModelPath;
  final String device;
  final String whisperComputeType;
  final String? workingDirectory;
  final Duration timeout;

  const PythonAudioBackend({
    required this.whisperModelPath,
    required this.clapModelPath,
    this.pythonExecutable = 'python',
    this.scriptPath = 'services/audio/audio_reader.py',
    this.device = 'cpu',
    this.whisperComputeType = 'int8',
    this.workingDirectory,
    this.timeout = const Duration(minutes: 45),
  });

  @override
  Future<AudioMetadata> inspect(String filePath) async =>
      AudioMetadata.fromJson(await _run(['inspect', '--input', filePath]));

  @override
  Future<AudioTranscription> transcribe(String filePath) async =>
      AudioTranscription.fromJson(
        await _run([
          'transcribe',
          '--input',
          filePath,
          '--model-path',
          whisperModelPath,
          '--device',
          device,
          '--compute-type',
          whisperComputeType,
        ]),
      );

  @override
  Future<AudioSemanticResult> analyze(String filePath) async =>
      AudioSemanticResult.fromJson(
        await _run([
          'analyze',
          '--input',
          filePath,
          '--model-path',
          clapModelPath,
          '--device',
          device,
        ]),
      );

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
      throw ProcessException(
        pythonExecutable,
        [scriptPath, ...arguments],
        payload?['error']?.toString() ?? (stderr.isEmpty ? stdout : stderr),
        result.exitCode,
      );
    }
    if (payload == null) {
      throw const FormatException('Audio service returned invalid JSON.');
    }
    return payload;
  }
}

class AudioParser implements Parser {
  final AudioBackend backend;

  const AudioParser({required this.backend});

  factory AudioParser.python({
    required String whisperModelPath,
    required String clapModelPath,
    String pythonExecutable = 'python',
    String scriptPath = 'services/audio/audio_reader.py',
    String device = 'cpu',
    String whisperComputeType = 'int8',
    String? workingDirectory,
  }) => AudioParser(
    backend: PythonAudioBackend(
      whisperModelPath: whisperModelPath,
      clapModelPath: clapModelPath,
      pythonExecutable: pythonExecutable,
      scriptPath: scriptPath,
      device: device,
      whisperComputeType: whisperComputeType,
      workingDirectory: workingDirectory,
    ),
  );

  static bool supports(String filePath) => AudioFileTypes.supports(filePath);

  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async {
    await reportFileProcessing(observer, FileProcessingStage.audioReading);
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }
    if (!supports(filePath)) {
      throw UnsupportedError('Not a supported sampled-audio file: $filePath');
    }

    final issues = <ExtractionIssue>[];
    AudioMetadata? metadata;
    try {
      metadata = await backend.inspect(filePath);
    } catch (error) {
      issues.add(
        ExtractionIssue(
          stage: 'audio_metadata',
          message: error.toString(),
          severity: ExtractionIssueSeverity.error,
        ),
      );
    }

    final textInformation = <TextInformation>[];
    final tagText = audioTagsAsExtractedText(
      metadata?.tags ?? const {},
      sourcePath: filePath,
    );
    if (tagText != null) textInformation.add(tagText);
    await reportFileProcessing(
      observer,
      FileProcessingStage.speechTranscription,
    );
    try {
      final transcription = await backend.transcribe(filePath);
      if (transcription.text.trim().isNotEmpty) {
        textInformation.add(
          TextInformation(
            text: transcription.text.trim(),
            extractionMethod: TextExtractionMethod.speechRecognition,
            informationKind: TextInformationKind.speechTranscript,
            sourcePath: filePath,
            language: transcription.language,
            confidence: transcription.languageProbability,
            regions: transcription.segments
                .map(
                  (segment) => ContentRegion(
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
      issues.add(
        ExtractionIssue(
          stage: 'speech_recognition',
          message: error.toString(),
          severity: ExtractionIssueSeverity.error,
        ),
      );
    }

    var semanticVector = <double>[];
    String? semanticModel;
    var semanticRegions = <ContentRegion>[];
    await reportFileProcessing(observer, FileProcessingStage.audioAnalysis);
    try {
      final semantics = await backend.analyze(filePath);
      semanticVector = semantics.vector;
      semanticModel = semantics.model;
      semanticRegions = semantics.regions;
    } catch (error) {
      issues.add(
        ExtractionIssue(
          stage: 'audio_semantics',
          message: error.toString(),
          severity: ExtractionIssueSeverity.error,
        ),
      );
    }

    final stat = await file.stat();
    final hasErrors = issues.any(
      (issue) => issue.severity == ExtractionIssueSeverity.error,
    );
    return ParsingResult(
      metadata: FileMetadata(
        filePath: filePath,
        detectedFileType: AudioFileTypes.typeLabel(filePath),
        fileSize: stat.size,
        modifiedTime: stat.modified,
      ),
      content: ExtractedFileContent(
        textInformation: textInformation,
        imageInformation: const [],
        audioInformation: [
          AudioInformation(
            sourcePath: filePath,
            bytes: await file.readAsBytes(),
            duration: metadata?.duration,
            format: metadata?.format ?? AudioFileTypes.typeLabel(filePath),
            codec: metadata?.codec,
            sampleRate: metadata?.sampleRate,
            channels: metadata?.channels,
            bitRate: metadata?.bitRate,
            tags: metadata?.tags ?? const {},
            regions: semanticRegions,
            semanticVector: semanticVector,
            semanticModel: semanticModel,
          ),
        ],
        videoInformation: const [],
        issues: issues,
        status: hasErrors
            ? ExtractionStatus.partial
            : ExtractionStatus.completed,
      ),
    );
  }
}

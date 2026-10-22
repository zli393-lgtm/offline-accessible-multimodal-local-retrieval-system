import 'dart:convert';
import 'dart:io';

import '../../core/models/extracted_file_content.dart';
import '../embedding_result.dart';
import '../embedding_space.dart';
import '../model_vector.dart';
import '../source_reference.dart';

abstract class ClapBackend {
  Future<List<ModelVector>> embedAudioFiles(List<String> filePaths);

  Future<List<ModelVector>> embedTextQueries(List<String> texts);
}

abstract class AudioEmbeddingEngine {
  Future<List<EmbeddingResult>> embedAudioBatch(
    List<AudioInformation> audioInformation,
  );

  Future<List<EmbeddingResult>> embedTextQueriesBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  });
}

class PythonClapBackend implements ClapBackend {
  final String pythonExecutable;
  final String scriptPath;
  final String modelPath;
  final String device;
  final String? workingDirectory;
  final Duration timeout;

  const PythonClapBackend({
    required this.modelPath,
    this.pythonExecutable = 'python',
    this.scriptPath = 'services/embedding/embedding_service.py',
    this.device = 'cpu',
    this.workingDirectory,
    this.timeout = const Duration(minutes: 60),
  });

  @override
  Future<List<ModelVector>> embedAudioFiles(List<String> filePaths) =>
      _runBatch(
        operation: 'audio-batch',
        requests: filePaths
            .map((filePath) => {'path': filePath})
            .toList(growable: false),
      );

  @override
  Future<List<ModelVector>> embedTextQueries(List<String> texts) => _runBatch(
    operation: 'audio-text-batch',
    requests: texts.map((text) => {'text': text}).toList(growable: false),
  );

  Future<List<ModelVector>> _runBatch({
    required String operation,
    required List<Map<String, Object>> requests,
  }) async {
    if (requests.isEmpty) return const [];
    final directory = await Directory.systemTemp.createTemp(
      'retrieval-clap-request-',
    );
    final requestFile = File(
      '${directory.path}${Platform.pathSeparator}request.json',
    );
    try {
      await requestFile.writeAsString(jsonEncode(requests), flush: true);
      final arguments = [
        scriptPath,
        operation,
        '--request-json',
        requestFile.path,
        '--model-path',
        modelPath,
        '--device',
        device,
      ];
      final process = await Process.run(
        pythonExecutable,
        arguments,
        workingDirectory: workingDirectory,
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
      final stdout = (process.stdout as String).trim();
      final stderr = (process.stderr as String).trim();
      Map<String, dynamic>? payload;
      if (stdout.isNotEmpty) {
        try {
          payload = Map<String, dynamic>.from(jsonDecode(stdout) as Map);
        } on FormatException {
          payload = null;
        }
      }
      if (process.exitCode != 0) {
        throw ProcessException(
          pythonExecutable,
          arguments,
          payload?['error']?.toString() ?? (stderr.isEmpty ? stdout : stderr),
          process.exitCode,
        );
      }
      if (payload == null || payload['results'] is! List) {
        throw const FormatException('CLAP service returned invalid JSON.');
      }
      return (payload['results'] as List<dynamic>)
          .map(
            (item) =>
                ModelVector.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false);
    } finally {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }
}

class ClapAudioEmbeddingEngine implements AudioEmbeddingEngine {
  final ClapBackend backend;

  const ClapAudioEmbeddingEngine({required this.backend});

  factory ClapAudioEmbeddingEngine.python({
    required String modelPath,
    String pythonExecutable = 'python',
    String scriptPath = 'services/embedding/embedding_service.py',
    String device = 'cpu',
    String? workingDirectory,
  }) => ClapAudioEmbeddingEngine(
    backend: PythonClapBackend(
      modelPath: modelPath,
      pythonExecutable: pythonExecutable,
      scriptPath: scriptPath,
      device: device,
      workingDirectory: workingDirectory,
    ),
  );

  @override
  Future<List<EmbeddingResult>> embedAudioBatch(
    List<AudioInformation> audioInformation,
  ) async {
    if (audioInformation.isEmpty) return const [];
    final results = List<EmbeddingResult?>.filled(
      audioInformation.length,
      null,
    );
    final missingIndexes = <int>[];
    for (var index = 0; index < audioInformation.length; index++) {
      final audio = audioInformation[index];
      if (audio.hasSemanticAnalysis) {
        final firstRegion = audio.regions.isEmpty ? null : audio.regions.first;
        final lastRegion = audio.regions.isEmpty ? null : audio.regions.last;
        results[index] = EmbeddingResult(
          vector: audio.semanticVector,
          space: EmbeddingSpace.clap,
          modality: EmbeddingModality.audio,
          model: audio.semanticModel!,
          source: SourceReference(
            sourcePath: audio.sourcePath,
            informationIndex: index,
            startTimeMs: firstRegion?.startTime?.inMilliseconds,
            endTimeMs: lastRegion?.endTime?.inMilliseconds,
          ),
        );
      } else {
        missingIndexes.add(index);
      }
    }
    if (missingIndexes.isEmpty) {
      return results.cast<EmbeddingResult>();
    }
    final directory = await Directory.systemTemp.createTemp(
      'retrieval-audio-embedding-',
    );
    try {
      final paths = <String>[];
      for (final index in missingIndexes) {
        final audio = audioInformation[index];
        if (audio.bytes.isEmpty) {
          throw ArgumentError('第 $index 个音频没有可用字节。');
        }
        final extension = _audioExtension(audio.format);
        final file = File(
          '${directory.path}${Platform.pathSeparator}audio_$index.$extension',
        );
        await file.writeAsBytes(audio.bytes, flush: true);
        paths.add(file.path);
      }
      final vectors = await backend.embedAudioFiles(paths);
      _validateCount(vectors, missingIndexes.length, 'CLAP audio');
      for (var resultIndex = 0; resultIndex < vectors.length; resultIndex++) {
        final index = missingIndexes[resultIndex];
        final audio = audioInformation[index];
        final firstRegion = audio.regions.isEmpty ? null : audio.regions.first;
        final lastRegion = audio.regions.isEmpty ? null : audio.regions.last;
        results[index] = EmbeddingResult(
          vector: vectors[resultIndex].vector,
          space: EmbeddingSpace.clap,
          modality: EmbeddingModality.audio,
          model: vectors[resultIndex].model,
          source: SourceReference(
            sourcePath: audio.sourcePath,
            informationIndex: index,
            startTimeMs: firstRegion?.startTime?.inMilliseconds,
            endTimeMs: lastRegion?.endTime?.inMilliseconds,
          ),
        );
      }
      return results.cast<EmbeddingResult>();
    } finally {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  @override
  Future<List<EmbeddingResult>> embedTextQueriesBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  }) async {
    if (texts.length != sources.length) {
      throw ArgumentError(
        '输入与来源数量必须一致：items=${texts.length}，sources=${sources.length}。',
      );
    }
    if (texts.any((text) => text.trim().isEmpty)) {
      throw ArgumentError('CLAP 查询文字不能为空。');
    }
    final vectors = await backend.embedTextQueries(texts);
    _validateCount(vectors, texts.length, 'CLAP text');
    return List.generate(
      texts.length,
      (index) => EmbeddingResult(
        vector: vectors[index].vector,
        space: EmbeddingSpace.clap,
        modality: EmbeddingModality.text,
        model: vectors[index].model,
        source: sources[index],
      ),
      growable: false,
    );
  }
}

void _validateCount(List<ModelVector> vectors, int expected, String label) {
  if (vectors.length != expected) {
    throw StateError('$label 返回 ${vectors.length} 个结果，应为 $expected 个。');
  }
}

String _audioExtension(String? format) {
  final normalized = (format ?? 'audio')
      .split(',')
      .first
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]'), '');
  return normalized.isEmpty ? 'audio' : normalized;
}

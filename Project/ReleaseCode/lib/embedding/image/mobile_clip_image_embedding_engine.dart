import 'dart:convert';
import 'dart:io';

import '../../core/models/extracted_file_content.dart';
import '../embedding_result.dart';
import '../embedding_space.dart';
import '../model_vector.dart';
import '../source_reference.dart';

class ImageFileEmbeddingInput {
  final String filePath;
  final int frameIndex;

  const ImageFileEmbeddingInput({required this.filePath, this.frameIndex = 0});
}

abstract class MobileClipBackend {
  Future<List<ModelVector>> embedImages(List<ImageFileEmbeddingInput> inputs);

  Future<List<ModelVector>> embedTextQueries(List<String> texts);
}

abstract class ImageEmbeddingEngine {
  Future<List<EmbeddingResult>> embedImagesBatch(List<ImageInformation> images);

  Future<List<EmbeddingResult>> embedTextQueriesBatch({
    required List<String> texts,
    required List<SourceReference> sources,
  });
}

class PythonMobileClipBackend implements MobileClipBackend {
  final String pythonExecutable;
  final String scriptPath;
  final String modelPath;
  final String modelName;
  final String device;
  final String? workingDirectory;
  final Duration timeout;

  const PythonMobileClipBackend({
    required this.modelPath,
    this.pythonExecutable = 'python',
    this.scriptPath = 'services/embedding/embedding_service.py',
    this.modelName = 'mobileclip_s0',
    this.device = 'cpu',
    this.workingDirectory,
    this.timeout = const Duration(minutes: 30),
  });

  @override
  Future<List<ModelVector>> embedImages(List<ImageFileEmbeddingInput> inputs) =>
      _runBatch(
        operation: 'image-batch',
        requests: inputs
            .map(
              (input) => {
                'path': input.filePath,
                'frame_index': input.frameIndex,
              },
            )
            .toList(growable: false),
      );

  @override
  Future<List<ModelVector>> embedTextQueries(List<String> texts) => _runBatch(
    operation: 'image-text-batch',
    requests: texts.map((text) => {'text': text}).toList(growable: false),
  );

  Future<List<ModelVector>> _runBatch({
    required String operation,
    required List<Map<String, Object>> requests,
  }) async {
    if (requests.isEmpty) return const [];
    final directory = await Directory.systemTemp.createTemp(
      'retrieval-mobileclip-request-',
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
        '--model-name',
        modelName,
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
        throw const FormatException(
          'MobileCLIP service returned invalid JSON.',
        );
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

class MobileClipImageEmbeddingEngine implements ImageEmbeddingEngine {
  final MobileClipBackend backend;

  const MobileClipImageEmbeddingEngine({required this.backend});

  factory MobileClipImageEmbeddingEngine.python({
    required String modelPath,
    String pythonExecutable = 'python',
    String scriptPath = 'services/embedding/embedding_service.py',
    String modelName = 'mobileclip_s0',
    String device = 'cpu',
    String? workingDirectory,
  }) => MobileClipImageEmbeddingEngine(
    backend: PythonMobileClipBackend(
      modelPath: modelPath,
      pythonExecutable: pythonExecutable,
      scriptPath: scriptPath,
      modelName: modelName,
      device: device,
      workingDirectory: workingDirectory,
    ),
  );

  @override
  Future<List<EmbeddingResult>> embedImagesBatch(
    List<ImageInformation> images,
  ) async {
    if (images.isEmpty) return const [];
    final results = List<EmbeddingResult?>.filled(images.length, null);
    final missingIndexes = <int>[];
    for (var index = 0; index < images.length; index++) {
      final image = images[index];
      if (image.hasSemanticAnalysis) {
        final region = image.region;
        results[index] = EmbeddingResult(
          vector: image.semanticVector,
          space: EmbeddingSpace.mobileClip,
          modality: EmbeddingModality.image,
          model: image.semanticModel!,
          source: SourceReference(
            sourcePath: image.sourcePath,
            informationIndex: index,
            pageIndex: region?.pageIndex,
            frameIndex: region?.frameIndex,
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
      'retrieval-image-embedding-',
    );
    try {
      final inputs = <ImageFileEmbeddingInput>[];
      for (final index in missingIndexes) {
        final image = images[index];
        if (image.bytes.isEmpty) {
          throw ArgumentError('第 $index 个图像没有可用字节。');
        }
        final extension = _imageExtension(image.format);
        final file = File(
          '${directory.path}${Platform.pathSeparator}image_$index.$extension',
        );
        await file.writeAsBytes(image.bytes, flush: true);
        inputs.add(ImageFileEmbeddingInput(filePath: file.path));
      }
      final vectors = await backend.embedImages(inputs);
      _validateCount(vectors, missingIndexes.length, 'MobileCLIP image');
      for (var resultIndex = 0; resultIndex < vectors.length; resultIndex++) {
        final index = missingIndexes[resultIndex];
        final image = images[index];
        final region = image.region;
        results[index] = EmbeddingResult(
          vector: vectors[resultIndex].vector,
          space: EmbeddingSpace.mobileClip,
          modality: EmbeddingModality.image,
          model: vectors[resultIndex].model,
          source: SourceReference(
            sourcePath: image.sourcePath,
            informationIndex: index,
            pageIndex: region?.pageIndex,
            frameIndex: region?.frameIndex,
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
    _validateParallel(texts.length, sources.length);
    if (texts.any((text) => text.trim().isEmpty)) {
      throw ArgumentError('MobileCLIP 查询文字不能为空。');
    }
    final vectors = await backend.embedTextQueries(texts);
    _validateCount(vectors, texts.length, 'MobileCLIP text');
    return List.generate(
      texts.length,
      (index) => EmbeddingResult(
        vector: vectors[index].vector,
        space: EmbeddingSpace.mobileClip,
        modality: EmbeddingModality.text,
        model: vectors[index].model,
        source: sources[index],
      ),
      growable: false,
    );
  }
}

void _validateParallel(int itemCount, int sourceCount) {
  if (itemCount != sourceCount) {
    throw ArgumentError('输入与来源数量必须一致：items=$itemCount，sources=$sourceCount。');
  }
}

void _validateCount(List<ModelVector> vectors, int expected, String label) {
  if (vectors.length != expected) {
    throw StateError('$label 返回 ${vectors.length} 个结果，应为 $expected 个。');
  }
}

String _imageExtension(String format) => switch (format.toLowerCase()) {
  'jpeg' || 'jpg' => 'jpg',
  'tiff' || 'tif' => 'tiff',
  'webp' => 'webp',
  'gif' => 'gif',
  'bmp' => 'bmp',
  _ => 'png',
};

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/embedding/audio/clap_audio_embedding_engine.dart';
import 'package:retrieval/embedding/image/mobile_clip_image_embedding_engine.dart';
import 'package:retrieval/embedding/model_vector.dart';

class _UnusedImageBackend implements MobileClipBackend {
  var imageCalls = 0;

  @override
  Future<List<ModelVector>> embedImages(
    List<ImageFileEmbeddingInput> inputs,
  ) async {
    imageCalls++;
    throw StateError('backend must not be called');
  }

  @override
  Future<List<ModelVector>> embedTextQueries(List<String> texts) async =>
      const [];
}

class _UnusedAudioBackend implements ClapBackend {
  var audioCalls = 0;

  @override
  Future<List<ModelVector>> embedAudioFiles(List<String> filePaths) async {
    audioCalls++;
    throw StateError('backend must not be called');
  }

  @override
  Future<List<ModelVector>> embedTextQueries(List<String> texts) async =>
      const [];
}

void main() {
  test('reuses image analysis already produced during file reading', () async {
    final backend = _UnusedImageBackend();
    final engine = MobileClipImageEmbeddingEngine(backend: backend);
    final result = await engine.embedImagesBatch([
      ImageInformation(
        sourcePath: 'image.png',
        format: 'PNG',
        pixelWidth: 1,
        pixelHeight: 1,
        frameCount: 1,
        colorMode: 'RGBA',
        hasAlpha: true,
        bytes: Uint8List.fromList([1]),
        semanticVector: const [0.6, 0.8],
        semanticModel: 'mobileclip_s0',
      ),
    ]);

    expect(backend.imageCalls, 0);
    expect(result.single.vector, [0.6, 0.8]);
    expect(result.single.model, 'mobileclip_s0');
  });

  test('reuses audio analysis already produced during file reading', () async {
    final backend = _UnusedAudioBackend();
    final engine = ClapAudioEmbeddingEngine(backend: backend);
    final result = await engine.embedAudioBatch([
      AudioInformation(
        sourcePath: 'audio.wav',
        bytes: Uint8List.fromList([1]),
        semanticVector: const [0.6, 0.8],
        semanticModel: 'clap',
      ),
    ]);

    expect(backend.audioCalls, 0);
    expect(result.single.vector, [0.6, 0.8]);
    expect(result.single.model, 'clap');
  });
}

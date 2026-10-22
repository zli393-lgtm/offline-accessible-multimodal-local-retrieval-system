import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/embedding/embedding_space.dart';
import 'package:retrieval/embedding/image/mobile_clip_image_embedding_engine.dart';
import 'package:retrieval/embedding/model_vector.dart';
import 'package:retrieval/embedding/source_reference.dart';

class _FakeMobileClipBackend implements MobileClipBackend {
  List<String> materializedPaths = [];
  List<String> queries = [];
  List<ModelVector>? imageResults;
  List<ModelVector>? textResults;

  @override
  Future<List<ModelVector>> embedImages(
    List<ImageFileEmbeddingInput> inputs,
  ) async {
    materializedPaths = inputs.map((input) => input.filePath).toList();
    for (final input in inputs) {
      expect(await File(input.filePath).exists(), isTrue);
    }
    return imageResults ??
        List.generate(
          inputs.length,
          (_) => const ModelVector(model: 'mobileclip_s0', vector: [0.6, 0.8]),
        );
  }

  @override
  Future<List<ModelVector>> embedTextQueries(List<String> texts) async {
    queries = [...texts];
    return textResults ??
        List.generate(
          texts.length,
          (_) => const ModelVector(model: 'mobileclip_s0', vector: [0.8, 0.6]),
        );
  }
}

ImageInformation _image({int frameIndex = 0}) => ImageInformation(
  sourcePath: 'outer-document.pdf',
  format: 'PNG',
  pixelWidth: 1,
  pixelHeight: 1,
  frameCount: 2,
  colorMode: 'RGBA',
  hasAlpha: true,
  bytes: Uint8List.fromList([1, 2, 3]),
  semanticVector: const [],
  informationKind: ImageInformationKind.animationFrame,
  region: ContentRegion(pageIndex: 2, frameIndex: frameIndex),
);

void main() {
  test(
    'Python MobileCLIP backend runs real image and text batches locally',
    () async {
      final application = Directory.current.path;
      final backend = PythonMobileClipBackend(
        pythonExecutable: Platform.environment['EMBEDDING_PYTHON'] ?? 'python',
        scriptPath: 'services/embedding/embedding_service.py',
        modelPath: [
          application,
          '..',
          '..',
          'Dependencies',
          'Packageable',
          'Models',
          'image',
          'mobileclip_s0.pt',
        ].join(Platform.pathSeparator),
        workingDirectory: application,
      );
      final imagePath =
          '$application/macos/Runner/Assets.xcassets/'
          'AppIcon.appiconset/app_icon_16.png';
      final images = await backend.embedImages([
        ImageFileEmbeddingInput(filePath: imagePath),
      ]);
      final texts = await backend.embedTextQueries(['application icon']);
      expect(images.single.vector, hasLength(512));
      expect(texts.single.vector, hasLength(512));
      expect(images.single.model, 'mobileclip_s0');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'embeds an image batch by information type and preserves source',
    () async {
      final backend = _FakeMobileClipBackend();
      final engine = MobileClipImageEmbeddingEngine(backend: backend);

      final results = await engine.embedImagesBatch([
        _image(),
        _image(frameIndex: 1),
      ]);

      expect(results, hasLength(2));
      expect(results.first.space, EmbeddingSpace.mobileClip);
      expect(results.first.modality, EmbeddingModality.image);
      expect(results.first.model, 'mobileclip_s0');
      expect(results.first.source.sourcePath, 'outer-document.pdf');
      expect(results.first.source.pageIndex, 2);
      expect(results.last.source.frameIndex, 1);
      for (final path in backend.materializedPaths) {
        expect(await File(path).exists(), isFalse);
      }
    },
  );

  test('creates MobileCLIP text-query vectors in the image space', () async {
    final backend = _FakeMobileClipBackend();
    final engine = MobileClipImageEmbeddingEngine(backend: backend);
    final results = await engine.embedTextQueriesBatch(
      texts: const ['red bicycle', 'kitchen'],
      sources: const [
        SourceReference(sourcePath: '<query-1>'),
        SourceReference(sourcePath: '<query-2>'),
      ],
    );
    expect(backend.queries, ['red bicycle', 'kitchen']);
    expect(results, hasLength(2));
    expect(results.first.modality, EmbeddingModality.text);
    expect(results.first.space, EmbeddingSpace.mobileClip);
  });

  test('validates image bytes, query text, and backend result count', () async {
    final backend = _FakeMobileClipBackend();
    final engine = MobileClipImageEmbeddingEngine(backend: backend);
    final empty = _image();
    final invalid = ImageInformation(
      sourcePath: empty.sourcePath,
      format: empty.format,
      pixelWidth: empty.pixelWidth,
      pixelHeight: empty.pixelHeight,
      frameCount: empty.frameCount,
      colorMode: empty.colorMode,
      hasAlpha: empty.hasAlpha,
      bytes: Uint8List(0),
      semanticVector: const [],
    );
    await expectLater(engine.embedImagesBatch([invalid]), throwsArgumentError);
    await expectLater(
      engine.embedTextQueriesBatch(
        texts: const [''],
        sources: const [SourceReference(sourcePath: '<query>')],
      ),
      throwsArgumentError,
    );
    backend.textResults = const [];
    await expectLater(
      engine.embedTextQueriesBatch(
        texts: const ['query'],
        sources: const [SourceReference(sourcePath: '<query>')],
      ),
      throwsStateError,
    );
  });
}

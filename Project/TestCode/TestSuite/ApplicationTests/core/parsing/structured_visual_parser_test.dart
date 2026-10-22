import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/file_io/structured_visual_file_types.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/parsing/static_image_parser.dart';
import 'package:retrieval/core/parsing/structured_visual_parser.dart';

class _FakeStructuredBackend implements StructuredVisualBackend {
  final String format;
  final List<StructuredTextBlock> textBlocks;
  final List<StructuredBackendIssue> issues;
  final bool includeVisual;

  const _FakeStructuredBackend({
    required this.format,
    required this.textBlocks,
    this.issues = const [],
    this.includeVisual = true,
  });

  @override
  Future<StructuredExtraction> extract(
    String filePath, {
    required String outputDirectory,
  }) async {
    final visuals = <StructuredVisualArtifact>[];
    if (includeVisual) {
      final rendered = File('$outputDirectory/rendered.png');
      await rendered.writeAsBytes([137, 80, 78, 71]);
      visuals.add(
        StructuredVisualArtifact(
          kind: format == 'SVG' ? 'rendered_vector' : 'rendered_chart',
          path: rendered.path,
          sourceOrder: 1,
          sourcePath: format == 'SVG' ? 'svg:rendered' : 'sheet:A/chart:1',
        ),
      );
    }
    return StructuredExtraction(
      format: format,
      textBlocks: textBlocks,
      visuals: visuals,
      issues: issues,
    );
  }
}

class _FakeImageBackend implements StaticImageBackend {
  final List<String> calls = [];

  @override
  Future<StaticImageMetadata> inspect(
    String filePath, {
    int frameIndex = 0,
  }) async {
    calls.add('inspect');
    return const StaticImageMetadata(
      format: 'PNG',
      width: 2,
      height: 1,
      frameCount: 1,
      colorMode: 'RGBA',
      hasAlpha: true,
      pixels: [255, 0, 0, 255, 0, 0, 255, 255],
      rowStride: 8,
    );
  }

  @override
  Future<StaticImageOcrResult> extractText(
    String filePath, {
    required String languages,
    int frameIndex = 0,
  }) async {
    calls.add('ocr');
    return const StaticImageOcrResult(
      text: '图中标题',
      languages: 'chi_sim+eng',
      meanConfidence: 95,
      words: [],
    );
  }

  @override
  Future<StaticImageSemanticResult> analyzeImage(
    String filePath, {
    int frameIndex = 0,
  }) async {
    calls.add('semantics');
    return const StaticImageSemanticResult(
      model: 'mobileclip_s0',
      dimensions: 3,
      vector: [0.1, 0.2, 0.3],
    );
  }
}

Future<File> _sourceFile(String extension) async {
  final directory = await Directory.systemTemp.createTemp();
  final file = File('${directory.path}/source.$extension');
  await file.writeAsString('fixture');
  return file;
}

void main() {
  test('file types are dispatched by source format', () {
    for (final extension in ['xlsx', 'xlsm', 'xltx', 'xltm', 'svg', 'svgz']) {
      expect(
        StructuredVisualFileTypes.supports('sample.$extension'),
        isTrue,
        reason: extension,
      );
    }
    expect(StructuredVisualFileTypes.supports('sample.png'), isFalse);
    expect(StructuredVisualFileTypes.supports('sample.pdf'), isFalse);
  });

  test(
    'spreadsheet keeps table/chart text and rendered chart pixels',
    () async {
      final file = await _sourceFile('xlsx');
      final imageBackend = _FakeImageBackend();
      final parser = StructuredVisualParser(
        backend: const _FakeStructuredBackend(
          format: 'XLSX',
          textBlocks: [
            StructuredTextBlock(
              kind: 'table',
              text: 'TABLE\nA1="Month"',
              sourceOrder: 0,
              sourcePath: 'sheet:A',
            ),
            StructuredTextBlock(
              kind: 'chart_data',
              text: 'CHART_DATA\nseries_1_values: [1,2]',
              sourceOrder: 1,
              sourcePath: 'sheet:A/chart:1',
            ),
          ],
        ),
        imageBackend: imageBackend,
      );

      final result = await parser.parse(file.path);

      expect(result.metadata.detectedFileType, 'XLSX');
      expect(
        result.content.textInformation.map((item) => item.informationKind),
        [
          TextInformationKind.table,
          TextInformationKind.chartData,
          TextInformationKind.ocr,
        ],
      );
      expect(imageBackend.calls, ['inspect', 'ocr', 'semantics']);
      expect(result.content.imageInformation, hasLength(1));
      final image = result.content.imageInformation.single;
      expect(image.informationKind, ImageInformationKind.renderedChart);
      expect(image.hasDecodedPixels, isTrue);
      expect(image.pixelBytes, hasLength(8));
      expect(image.semanticVector, hasLength(3));
      expect(result.content.audioInformation, isEmpty);
      expect(result.content.videoInformation, isEmpty);
      expect(result.content.status, ExtractionStatus.completed);

      await file.parent.delete(recursive: true);
    },
  );

  test('SVG keeps vector text and rendered vector pixels', () async {
    final file = await _sourceFile('svg');
    final parser = StructuredVisualParser(
      backend: const _FakeStructuredBackend(
        format: 'SVG',
        textBlocks: [
          StructuredTextBlock(
            kind: 'vector_data',
            text: 'VECTOR_DATA\nelement_1: path d="M0 0L1 1"',
            sourceOrder: 0,
            sourcePath: 'svg:source',
          ),
        ],
      ),
      imageBackend: _FakeImageBackend(),
    );

    final result = await parser.parse(file.path);

    expect(
      result.content.textInformation.first.informationKind,
      TextInformationKind.vectorData,
    );
    expect(
      result.content.imageInformation.single.informationKind,
      ImageInformationKind.renderedVector,
    );
    expect(result.content.imageInformation.single.hasDecodedPixels, isTrue);
    expect(result.content.audioInformation, isEmpty);
    expect(result.content.videoInformation, isEmpty);

    await file.parent.delete(recursive: true);
  });

  test(
    'render failure preserves source data and reports partial status',
    () async {
      final file = await _sourceFile('svg');
      final parser = StructuredVisualParser(
        backend: const _FakeStructuredBackend(
          format: 'SVG',
          includeVisual: false,
          textBlocks: [
            StructuredTextBlock(
              kind: 'vector_data',
              text: 'VECTOR_DATA',
              sourceOrder: 0,
              sourcePath: 'svg:source',
            ),
          ],
          issues: [
            StructuredBackendIssue(
              stage: 'vector_render',
              message: 'renderer unavailable',
              severity: 'error',
            ),
          ],
        ),
        imageBackend: _FakeImageBackend(),
      );

      final result = await parser.parse(file.path);

      expect(result.content.textInformation, hasLength(1));
      expect(result.content.imageInformation, isEmpty);
      expect(result.content.status, ExtractionStatus.partial);
      expect(result.content.issues.single.stage, 'vector_render');

      await file.parent.delete(recursive: true);
    },
  );
}

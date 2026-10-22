import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/parsing/audio_parser.dart';
import 'package:retrieval/core/parsing/compound_document_parser.dart';
import 'package:retrieval/core/parsing/static_image_parser.dart';
import 'package:retrieval/core/parsing/structured_visual_parser.dart';
import 'package:retrieval/core/parsing/text_image_document_parser.dart';

void main() {
  test('maps static image metadata, OCR words, and semantic vectors', () {
    final metadata = StaticImageMetadata.fromJson({
      'format': 'PNG',
      'width': 20,
      'height': 10,
      'frame_count': 2,
      'color_mode': 'RGBA',
      'has_alpha': true,
      'pixels_base64': base64Encode([1, 2, 3, 4]),
      'pixel_format': 'RGBA8888',
      'row_stride': 80,
      'frame_index': 1,
      'frame_duration_ms': 125.4,
      'disposal_method': 2,
      'frame_png_base64': base64Encode([5, 6]),
    });
    final ocr = StaticImageOcrResult.fromJson({
      'text': '你好',
      'languages': 'chi_sim+eng',
      'mean_confidence': 91.5,
      'words': [
        {
          'text': '你好',
          'confidence': 91.5,
          'left': 1,
          'top': 2,
          'width': 3,
          'height': 4,
        },
      ],
    });
    final semantic = StaticImageSemanticResult.fromJson({
      'model': 'mobileclip',
      'dimensions': 2,
      'vector': [0.6, 0.8],
    });

    expect(metadata.frameIndex, 1);
    expect(metadata.frameDuration, const Duration(milliseconds: 125));
    expect(metadata.frameBytes, [5, 6]);
    expect(ocr.words.single.width, 3);
    expect(ocr.meanConfidence, 91.5);
    expect(semantic.vector, [0.6, 0.8]);
    expect(semantic.dimensions, 2);
  });

  test('maps audio metadata, transcript provenance, and semantic regions', () {
    final metadata = AudioMetadata.fromJson({
      'format': 'WAV',
      'codec': 'pcm_s16le',
      'duration_ms': 1200.5,
      'sample_rate': 16000,
      'channels': 1,
      'bit_rate': 256000,
      'tags': {'artist': 'tester'},
    });
    final transcript = AudioTranscription.fromJson({
      'text': 'speech',
      'language': 'en',
      'language_probability': 0.98,
      'model': 'whisper',
      'segments': [
        {'text': 'speech', 'start_ms': 100, 'end_ms': 900, 'confidence': 0.8},
      ],
    });
    final semantic = AudioSemanticResult.fromJson({
      'model': 'clap',
      'dimensions': 2,
      'vector': [0.6, 0.8],
      'regions': [
        {'start_ms': 0, 'end_ms': 1000},
      ],
    });

    expect(metadata.duration, const Duration(milliseconds: 1201));
    expect(metadata.tags['artist'], 'tester');
    expect(transcript.segments.single.start, const Duration(milliseconds: 100));
    expect(transcript.languageProbability, 0.98);
    expect(semantic.regions.single.startTime, Duration.zero);
    expect(semantic.regions.single.extractedText, isNull);
  });

  test('maps compound document channels and issues', () {
    final extraction = CompoundExtraction.fromJson({
      'detected_format': 'PPTX',
      'text_blocks': [
        {
          'kind': 'chart_data',
          'text': 'x=1',
          'page_index': 2,
          'source_order': 1,
          'logical_location': 'slide/3',
        },
      ],
      'image_parts': [
        {
          'file_path': 'image.png',
          'source_name': 'image1.png',
          'page_index': 2,
          'source_order': 2,
          'logical_location': 'slide/3',
          'kind': 'rendered_chart',
        },
      ],
      'audio_parts': [
        {
          'file_path': 'sound.wav',
          'source_name': 'sound.wav',
          'page_index': 2,
          'source_order': 3,
          'kind': 'embedded_audio',
        },
      ],
      'issues': [
        {'stage': 'media', 'message': 'warning', 'severity': 'warning'},
      ],
    });

    expect(extraction.textBlocks.single.logicalLocation, 'slide/3');
    expect(extraction.imageParts.single.kind, 'rendered_chart');
    expect(extraction.audioParts.single.sourceName, 'sound.wav');
    expect(extraction.issues.single.isError, isFalse);
  });

  test('maps structured table/chart/vector extraction', () {
    final extraction = StructuredExtraction.fromJson({
      'format': 'XLSX',
      'text_blocks': [
        {
          'kind': 'table',
          'text': 'a,b',
          'source_order': 1,
          'source_path': 'Sheet1',
        },
      ],
      'visuals': [
        {
          'kind': 'rendered_chart',
          'path': 'chart.png',
          'source_order': 2,
          'source_path': 'Sheet1!Chart1',
        },
      ],
      'issues': [
        {'stage': 'render', 'message': 'partial', 'severity': 'warning'},
      ],
    });

    expect(extraction.textBlocks.single.kind, 'table');
    expect(extraction.visuals.single.path, 'chart.png');
    expect(extraction.issues.single.severity, 'warning');
  });

  test('maps text-and-image document text, image, and issue records', () {
    final extraction = TextImageDocumentExtraction.fromJson({
      'detected_format': 'XPS',
      'text_blocks': [
        {'text': 'page text', 'page_index': 0, 'source_order': 1},
      ],
      'image_parts': [
        {
          'file_path': 'page.png',
          'source_name': 'page.png',
          'page_index': 0,
          'source_order': 2,
        },
      ],
      'issues': [
        {'stage': 'render', 'message': 'fallback', 'severity': 'error'},
      ],
    });

    expect(extraction.textBlocks.single.pageIndex, 0);
    expect(extraction.imageParts.single.sourceOrder, 2);
    expect(extraction.issues.single.isError, isTrue);
  });
}

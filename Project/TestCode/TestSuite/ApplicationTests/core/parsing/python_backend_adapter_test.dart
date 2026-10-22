import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/core/parsing/audio_parser.dart';
import 'package:retrieval/core/parsing/compound_document_parser.dart';
import 'package:retrieval/core/parsing/static_image_parser.dart';
import 'package:retrieval/core/parsing/structured_visual_parser.dart';
import 'package:retrieval/core/parsing/text_image_document_parser.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('backend-adapter-test-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  File script(String name, String source) {
    final file = File(p.join(temporary.path, name));
    file.writeAsStringSync(source);
    return file;
  }

  String emit(Object value) => 'print(${jsonEncode(jsonEncode(value))})';

  test('Python audio adapter maps all commands and optional values', () async {
    final file = script('audio.py', '''
import sys
command = sys.argv[1]
if command == "inspect":
    ${emit({
      'format': 'WAV',
      'codec': 'pcm',
      'duration_ms': 1000,
      'sample_rate': 16000,
      'channels': 1,
      'bit_rate': 128000,
      'tags': {'title': 'test'},
    })}
elif command == "transcribe":
    ${emit({
      'text': 'hello',
      'model': 'whisper',
      'language': 'en',
      'segments': [
        {'text': 'hello', 'start_ms': 0, 'end_ms': 500},
      ],
    })}
else:
    ${emit({
      'model': 'clap',
      'dimensions': 2,
      'vector': [0.6, 0.8],
      'regions': [
        {'start_ms': 0, 'end_ms': 1000},
      ],
    })}
''');
    final backend = PythonAudioBackend(
      pythonExecutable: 'python',
      scriptPath: file.path,
      whisperModelPath: 'whisper',
      clapModelPath: 'clap',
      workingDirectory: temporary.path,
    );

    expect((await backend.inspect('sound.wav')).sampleRate, 16000);
    expect((await backend.transcribe('sound.wav')).text, 'hello');
    expect((await backend.analyze('sound.wav')).vector, [0.6, 0.8]);
  });

  test('Python static-image adapter maps inspect, OCR, and analysis', () async {
    final file = script('image.py', '''
import sys
command = sys.argv[1]
if command == "inspect":
    ${emit({
      'metadata': {
        'format': 'PNG',
        'width': 2,
        'height': 1,
        'frame_count': 1,
        'color_mode': 'RGBA',
        'has_alpha': true,
        'pixels_base64': base64Encode([1, 2, 3, 4]),
        'pixel_format': 'RGBA8888',
        'row_stride': 8,
        'frame_png_base64': base64Encode([5]),
      },
    })}
elif command == "ocr":
    ${emit({
      'text': 'ocr',
      'languages': 'eng',
      'mean_confidence': 90,
      'words': [
        {'text': 'ocr', 'confidence': 90, 'left': 0, 'top': 0, 'width': 2, 'height': 1},
      ],
    })}
else:
    ${emit({
      'model': 'mobileclip',
      'dimensions': 2,
      'vector': [0.6, 0.8],
    })}
''');
    final backend = PythonStaticImageBackend(
      pythonExecutable: 'python',
      scriptPath: file.path,
      mobileClipModelPath: 'model',
      tesseractExecutable: 'tesseract',
      workingDirectory: temporary.path,
    );

    expect((await backend.inspect('image.png')).width, 2);
    expect(
      (await backend.extractText('image.png', languages: 'eng')).text,
      'ocr',
    );
    expect((await backend.analyzeImage('image.png')).model, 'mobileclip');
  });

  test(
    'document adapters map compound, structured, and text-image JSON',
    () async {
      final compoundScript = script(
        'compound.py',
        emit({
          'detected_format': 'DOCX',
          'text_blocks': [
            {'text': 'text', 'source_order': 1},
          ],
          'image_parts': [],
          'audio_parts': [],
          'issues': [],
        }),
      );
      final structuredScript = script(
        'structured.py',
        emit({
          'format': 'SVG',
          'text_blocks': [
            {
              'kind': 'vector_data',
              'text': 'path',
              'source_order': 1,
              'source_path': 'svg',
            },
          ],
          'visuals': [],
          'issues': [],
        }),
      );
      final textImageScript = script(
        'text_image.py',
        emit({
          'detected_format': 'XPS',
          'text_blocks': [
            {'text': 'page', 'page_index': 0, 'source_order': 1},
          ],
          'image_parts': [],
          'issues': [],
        }),
      );

      final compound = await PythonCompoundDocumentBackend(
        pythonExecutable: 'python',
        scriptPath: compoundScript.path,
        javaExecutable: 'java',
        tikaJarPath: 'tika.jar',
        workingDirectory: temporary.path,
      ).extract('file.docx', outputDirectory: temporary.path);
      final structured = await PythonStructuredVisualBackend(
        pythonExecutable: 'python',
        scriptPath: structuredScript.path,
        browserExecutable: 'browser',
        workingDirectory: temporary.path,
      ).extract('file.svg', outputDirectory: temporary.path);
      final textImage = await PythonTextImageDocumentBackend(
        pythonExecutable: 'python',
        scriptPath: textImageScript.path,
        workingDirectory: temporary.path,
        djvuRenderExecutable: 'ddjvu',
        djvuTextExecutable: 'djvutxt',
        djvuScriptExecutable: 'djvused',
        ghostscriptExecutable: 'gs',
        jxrDecoderExecutable: 'jxr',
        xpsRendererExecutable: 'xps',
      ).extract('file.xps', outputDirectory: temporary.path);

      expect(compound.detectedFormat, 'DOCX');
      expect(structured.textBlocks.single.kind, 'vector_data');
      expect(textImage.textBlocks.single.text, 'page');
    },
  );

  test(
    'adapters reject invalid JSON and surface signed service errors',
    () async {
      final invalid = script('invalid.py', 'print("not-json")');
      final failed = script(
        'failed.py',
        '${emit({'error': 'service failed'})}\nraise SystemExit(4)',
      );
      final invalidBackend = PythonAudioBackend(
        pythonExecutable: 'python',
        scriptPath: invalid.path,
        whisperModelPath: 'whisper',
        clapModelPath: 'clap',
      );
      final failedBackend = PythonStaticImageBackend(
        pythonExecutable: 'python',
        scriptPath: failed.path,
        mobileClipModelPath: 'model',
      );

      await expectLater(
        invalidBackend.inspect('file.wav'),
        throwsFormatException,
      );
      await expectLater(
        failedBackend.inspect('file.png'),
        throwsA(
          isA<ProcessException>().having(
            (error) => error.message,
            'message',
            contains('service failed'),
          ),
        ),
      );
    },
  );
}

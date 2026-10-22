import 'dart:convert';
import 'dart:io';

import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/parsing/text_image_document_parser.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 6) {
    throw ArgumentError(
      'Usage: dart run validate_text_image_document_parser.dart '
      '<source-image> <model-path> <working-directory> <temporary-root> '
      '<python-executable> <tesseract-executable>',
    );
  }

  final sourceImage = File(arguments[0]);
  if (!await sourceImage.exists()) {
    throw FileSystemException('Source image not found', sourceImage.path);
  }

  final temporaryRoot = Directory(arguments[3]);
  if (!await temporaryRoot.exists()) {
    await temporaryRoot.create(recursive: true);
  }
  final runDirectory = await temporaryRoot.createTemp(
    'text_image_document_validation_',
  );
  final document = File(
    '${runDirectory.path}${Platform.pathSeparator}validation.fb2',
  );

  try {
    final imageBase64 = base64Encode(await sourceImage.readAsBytes());
    await document.writeAsString(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" '
      'xmlns:l="http://www.w3.org/1999/xlink">'
      '<description><title-info><book-title>直接文本验证</book-title>'
      '</title-info></description>'
      '<body><section><p>compound document direct text</p>'
      '<image l:href="#screen"/></section></body>'
      '<binary id="screen" content-type="image/png">$imageBase64</binary>'
      '</FictionBook>',
      flush: true,
    );

    final parser = TextImageDocumentParser.python(
      mobileClipModelPath: arguments[1],
      pythonExecutable: arguments[4],
      tesseractExecutable: arguments[5],
      workingDirectory: arguments[2],
      temporaryDirectoryPath: runDirectory.path,
    );
    final result = await parser.parse(document.path);
    final content = result.content;

    if (content.status != ExtractionStatus.completed) {
      throw StateError(
        content.issues
            .map((issue) => '${issue.stage}: ${issue.message}')
            .join('\n'),
      );
    }
    if (!content.mergedText.contains('compound document direct text')) {
      throw StateError('Direct FB2 text was not extracted.');
    }
    if (!content.mergedText.contains('2047')) {
      throw StateError('OCR text did not contain the expected 2047 marker.');
    }
    if (content.imageInformation.length != 1) {
      throw StateError('Expected exactly one embedded image.');
    }
    final image = content.imageInformation.single;
    if (image.semanticVector.length != 512) {
      throw StateError(
        'Expected a 512-dimensional image vector, got '
        '${image.semanticVector.length}.',
      );
    }
    if (content.audioInformation.isNotEmpty ||
        content.videoInformation.isNotEmpty) {
      throw StateError('Audio and video lists must remain empty.');
    }

    stdout.writeln(
      jsonEncode({
        'status': content.status.name,
        'text_items': content.textInformation.length,
        'image_items': content.imageInformation.length,
        'audio_items': content.audioInformation.length,
        'video_items': content.videoInformation.length,
        'semantic_dimensions': image.semanticVector.length,
        'ocr_contains_2047': content.mergedText.contains('2047'),
      }),
    );
  } finally {
    if (await runDirectory.exists()) {
      await runDirectory.delete(recursive: true);
    }
  }
}

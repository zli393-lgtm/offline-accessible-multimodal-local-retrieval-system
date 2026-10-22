import 'dart:convert';
import 'dart:io';

import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/parsing/static_image_parser.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length < 2 || arguments.length > 3) {
    stderr.writeln(
      'Usage: dart validate_static_image_parser.dart '
      '<image-path> <mobileclip-model-path> [python-executable]',
    );
    exitCode = 64;
    return;
  }

  final parser = StaticImageParser.python(
    mobileClipModelPath: arguments[1],
    pythonExecutable: arguments.length == 3 ? arguments[2] : 'python',
  );
  final result = await parser.parse(arguments[0]);
  final images = result.content.imageInformation;

  if (images.length != 1) {
    throw StateError('Expected exactly one static image information item.');
  }
  if (images.single.semanticVector.length != 512) {
    throw StateError('Expected a 512-dimension MobileCLIP vector.');
  }
  if (!images.single.hasDecodedPixels) {
    throw StateError('Expected decoded RGBA pixel information.');
  }
  if (result.content.status != ExtractionStatus.completed) {
    throw StateError(
      'Expected completed extraction, got ${result.content.status.name}: '
      '${result.content.issues.map((issue) => issue.message).join('; ')}',
    );
  }

  stdout.writeln(
    jsonEncode({
      'fileType': result.metadata.detectedFileType,
      'textItems': result.content.textInformation.length,
      'ocrText': result.content.mergedText,
      'imageItems': images.length,
      'audioItems': result.content.audioInformation.length,
      'videoItems': result.content.videoInformation.length,
      'semanticModel': images.single.semanticModel,
      'semanticDimensions': images.single.semanticVector.length,
      'pixelFormat': images.single.pixelFormat,
      'pixelBytes': images.single.pixelBytes?.length,
      'status': result.content.status.name,
    }),
  );
}

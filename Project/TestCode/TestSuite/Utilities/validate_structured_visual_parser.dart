import 'dart:convert';
import 'dart:io';

import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/parsing/structured_visual_parser.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length < 3 || arguments.length > 5) {
    stderr.writeln(
      'Usage: dart validate_structured_visual_parser.dart '
      '<source-path> <mobileclip-model-path> <python-executable> '
      '[browser-executable] [tesseract-executable]',
    );
    exitCode = 64;
    return;
  }

  final parser = StructuredVisualParser.python(
    mobileClipModelPath: arguments[1],
    pythonExecutable: arguments[2],
    browserExecutable: arguments.length >= 4 ? arguments[3] : null,
    tesseractExecutable: arguments.length >= 5 ? arguments[4] : null,
  );
  final result = await parser.parse(arguments[0]);

  for (final image in result.content.imageInformation) {
    if (!image.hasDecodedPixels) {
      throw StateError('A rendered visual has no decoded pixel information.');
    }
    if (image.semanticVector.length != 512) {
      throw StateError(
        'A rendered visual has no 512-dimension semantic vector.',
      );
    }
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
      'textKinds': result.content.textInformation
          .map((item) => item.informationKind.name)
          .toList(),
      'imageKinds': result.content.imageInformation
          .map((item) => item.informationKind.name)
          .toList(),
      'pixelBytes': result.content.imageInformation
          .map((item) => item.pixelBytes?.length ?? 0)
          .toList(),
      'semanticDimensions': result.content.imageInformation
          .map((item) => item.semanticVector.length)
          .toList(),
      'audioItems': result.content.audioInformation.length,
      'videoItems': result.content.videoInformation.length,
      'status': result.content.status.name,
    }),
  );
}

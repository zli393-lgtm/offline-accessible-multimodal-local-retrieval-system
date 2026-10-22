import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/parsing/archive_name_parser.dart';

void main() {
  test('ArchiveNameParser reads only the archive object filename', () async {
    final directory = await Directory.systemTemp.createTemp();
    final file = File('${directory.path}/records.zip');
    await file.writeAsBytes([0x50, 0x4b, 3, 4]);

    final result = await const ArchiveNameParser().parse(file.path);

    expect(result.metadata.detectedFileType, 'ZIP');
    expect(result.content.status, ExtractionStatus.completed);
    expect(result.content.textInformation.single.text, 'records.zip');
    expect(
      result.content.textInformation.single.informationKind,
      TextInformationKind.fileName,
    );
    expect(result.content.imageInformation, isEmpty);
    expect(result.content.audioInformation, isEmpty);
    expect(result.content.videoInformation, isEmpty);

    await directory.delete(recursive: true);
  });
}

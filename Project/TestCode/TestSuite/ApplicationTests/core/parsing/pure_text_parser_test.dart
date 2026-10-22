import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/file_io/pure_text_file_types.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/parsing/pure_text_parser.dart';

void main() {
  test('PureTextParser reads TXT content and metadata correctly', () async {
    final tempDir = await Directory.systemTemp.createTemp();
    final file = File('${tempDir.path}/test.txt');

    await file.writeAsString('Hello World');

    const parser = PureTextParser();
    final result = await parser.parse(file.path);

    expect(result.content.textInformation, hasLength(1));
    expect(result.content.textInformation.single.text, 'Hello World');
    expect(
      result.content.textInformation.single.extractionMethod,
      TextExtractionMethod.direct,
    );
    expect(result.content.imageInformation, isEmpty);
    expect(result.content.audioInformation, isEmpty);
    expect(result.content.videoInformation, isEmpty);
    expect(result.content.status, ExtractionStatus.completed);
    expect(result.metadata.filePath, file.path);
    expect(result.metadata.detectedFileType, 'TXT');
    expect(result.metadata.fileSize, greaterThan(0));
    expect(
      result.content.textInformation.single.informationKind,
      TextInformationKind.plainText,
    );

    await tempDir.delete(recursive: true);
  });

  test(
    'PureTextParser throws FileSystemException when file does not exist',
    () async {
      const parser = PureTextParser();

      expect(
        () => parser.parse('file_that_does_not_exist.txt'),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('PureTextParser supports source, config, and text data files', () async {
    final tempDir = await Directory.systemTemp.createTemp();
    final cases = {
      'sample.py': 'print("hello")',
      'sample.json': '{"value": 1}',
      'sample.yaml': 'value: 1',
      'sample.csv': 'name,value\nalpha,1',
      'sample.tsv': 'name\tvalue\nalpha\t1',
      'sample.sql': 'select 1;',
      'Dockerfile': 'FROM scratch',
    };
    const parser = PureTextParser();

    for (final entry in cases.entries) {
      final file = File('${tempDir.path}/${entry.key}');
      await file.writeAsString(entry.value);
      final result = await parser.parse(file.path);

      expect(result.content.mergedText, entry.value);
      expect(result.content.imageInformation, isEmpty);
      expect(result.content.audioInformation, isEmpty);
      expect(result.content.videoInformation, isEmpty);
      expect(result.metadata.detectedFileType, isNot('UNSUPPORTED'));
      expect(
        result.content.textInformation.single.informationKind,
        entry.key.endsWith('.csv') || entry.key.endsWith('.tsv')
            ? TextInformationKind.table
            : TextInformationKind.plainText,
      );
    }

    await tempDir.delete(recursive: true);
  });

  test('PureTextParser decodes UTF-8 BOM and UTF-16 files', () async {
    final tempDir = await Directory.systemTemp.createTemp();
    final utf8Bom = File('${tempDir.path}/utf8.txt');
    final utf16Le = File('${tempDir.path}/utf16.txt');
    await utf8Bom.writeAsBytes([0xef, 0xbb, 0xbf, ...utf8.encode('中文')]);
    await utf16Le.writeAsBytes([0xff, 0xfe, 0x2d, 0x4e, 0x87, 0x65]);

    const parser = PureTextParser();
    expect((await parser.parse(utf8Bom.path)).content.mergedText, '中文');
    expect((await parser.parse(utf16Le.path)).content.mergedText, '中文');

    await tempDir.delete(recursive: true);
  });

  test('PureTextParser rejects composite and binary files', () async {
    expect(PureTextFileTypes.supports('document.md'), isFalse);
    expect(PureTextFileTypes.supports('document.html'), isFalse);
    expect(PureTextFileTypes.supports('document.pdf'), isFalse);

    final tempDir = await Directory.systemTemp.createTemp();
    final fakeText = File('${tempDir.path}/fake.txt');
    final output = await fakeText.open(mode: FileMode.write);
    await output.writeFrom([0, 1, 2, 3]);
    await output.flush();
    await output.close();

    await expectLater(
      const PureTextParser().parse(fakeText.path),
      throwsA(isA<FormatException>()),
    );

    await tempDir.delete(recursive: true);
  });
}

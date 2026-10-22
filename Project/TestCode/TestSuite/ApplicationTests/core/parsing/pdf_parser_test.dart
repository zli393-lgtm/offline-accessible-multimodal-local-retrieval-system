import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/parsing/pdf_parser.dart';

void main() {
  final testSuite =
      Platform.environment['SXSX_TEST_SUITE'] ??
      [
        Directory.current.path,
        '..',
        'TestCode',
        'TestSuite',
      ].join(Platform.pathSeparator);
  final pdfFixtures = [
    testSuite,
    'ApplicationTests',
    'fixtures',
    'pdf',
  ].join(Platform.pathSeparator);
  final pdfiumLibrary = [
    Directory.current.path,
    '..',
    '..',
    'Dependencies',
    'Non-Packageable',
    'Windows',
    'pdfium',
    'pdfium.dll',
  ].join(Platform.pathSeparator);

  test('PdfParser extracts structured PDF content correctly', () async {
    final parser = PdfParser(libraryPath: pdfiumLibrary);
    final result = await parser.parse(
      '$pdfFixtures${Platform.pathSeparator}sample.pdf',
    );

    expect(result.metadata.detectedFileType, 'PDF');
    expect(result.metadata.fileSize, greaterThan(0));
    expect(result.content, isA<ExtractedFileContent>());
    expect(result.content.textInformation, isNotEmpty);
    expect(result.content.audioInformation, isEmpty);
    expect(result.content.videoInformation, isEmpty);
    expect(result.content.status, ExtractionStatus.completed);

    for (final item in result.content.textInformation) {
      expect(item.text.trim(), isNotEmpty);
      expect(item.extractionMethod, TextExtractionMethod.direct);
      expect(item.regions, isNotEmpty);
      final region = item.regions.single;
      expect(region.pageIndex, greaterThanOrEqualTo(0));
      expect(region.right, greaterThanOrEqualTo(region.left!));
      expect(region.top, greaterThanOrEqualTo(region.bottom!));
      expect(region.sourceOrder, greaterThanOrEqualTo(0));
      expect(region.layoutOrder, greaterThanOrEqualTo(0));
    }

    for (final item in result.content.imageInformation) {
      expect(item.pixelWidth, greaterThanOrEqualTo(0));
      expect(item.pixelHeight, greaterThanOrEqualTo(0));
      expect(item.region?.pageIndex, greaterThanOrEqualTo(0));
      expect(item.semanticVector, isEmpty);
    }
  });

  test('PdfParser throws when file does not exist', () async {
    final parser = PdfParser(libraryPath: pdfiumLibrary);

    expect(
      () => parser.parse('$pdfFixtures${Platform.pathSeparator}missing.pdf'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('PdfParser reads representative PDF fixtures', () async {
    final parser = PdfParser(libraryPath: pdfiumLibrary);
    final sampleRoot = '$pdfFixtures${Platform.pathSeparator}samples';
    final samples = <File>[
      File('$sampleRoot${Platform.pathSeparator}q1_chaos_separation.pdf'),
      File('$sampleRoot${Platform.pathSeparator}q2_abm_timeseries.pdf'),
      File('$sampleRoot${Platform.pathSeparator}q3_lv_phase_compare_h.pdf'),
    ];

    expect(samples, isNotEmpty);
    for (final sample in samples) {
      final result = await parser.parse(sample.path);
      expect(result.metadata.detectedFileType, 'PDF', reason: sample.path);
      expect(result.metadata.fileSize, greaterThan(0), reason: sample.path);
      expect(result.content.status, ExtractionStatus.completed, reason: sample.path);
      expect(
        result.content.textInformation,
        isNotEmpty,
        reason: sample.path,
      );
    }
  });
}

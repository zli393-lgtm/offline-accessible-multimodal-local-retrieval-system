import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../file_io/file_type_detector.dart';
import '../file_io/pure_text_file_types.dart';
import '../models/extracted_file_content.dart';
import '../models/file_metadata.dart';
import '../models/parsing_result.dart';
import 'parser.dart';

class PureTextParser implements Parser {
  const PureTextParser();

  static bool supports(String filePath) => PureTextFileTypes.supports(filePath);

  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async {
    await reportFileProcessing(observer, FileProcessingStage.reading);
    final file = File(filePath);

    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }
    if (!supports(filePath)) {
      throw UnsupportedError('Not a supported pure-text file: $filePath');
    }

    final bytes = await file.readAsBytes();
    await reportFileProcessing(
      observer,
      _informationKind(filePath) == TextInformationKind.table
          ? FileProcessingStage.tableExtraction
          : FileProcessingStage.textExtraction,
      completedUnits: 1,
      totalUnits: 1,
    );
    final content = _decode(bytes, filePath);
    final stat = await file.stat();

    return ParsingResult(
      metadata: FileMetadata(
        filePath: filePath,
        detectedFileType: await FileTypeDetector.detect(filePath),
        fileSize: stat.size,
        modifiedTime: stat.modified,
      ),
      content: ExtractedFileContent(
        textInformation: [
          TextInformation(
            text: content,
            extractionMethod: TextExtractionMethod.direct,
            informationKind: _informationKind(filePath),
            sourcePath: filePath,
            regions: const [],
          ),
        ],
        imageInformation: const [],
        audioInformation: const [],
        videoInformation: const [],
        issues: const [],
        status: ExtractionStatus.completed,
      ),
    );
  }

  static TextInformationKind _informationKind(String filePath) {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.csv') || lower.endsWith('.tsv')) {
      return TextInformationKind.table;
    }
    return TextInformationKind.plainText;
  }

  static String _decode(Uint8List bytes, String filePath) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      return utf8.decode(bytes.sublist(3));
    }
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      return _decodeUtf16(bytes.sublist(2), Endian.little, filePath);
    }
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      return _decodeUtf16(bytes.sublist(2), Endian.big, filePath);
    }

    try {
      final content = utf8.decode(bytes);
      if (content.contains('\u0000')) {
        throw const FormatException('NUL byte in text file');
      }
      return content;
    } on FormatException catch (error) {
      throw FormatException('Invalid UTF-8 text in $filePath: $error');
    }
  }

  static String _decodeUtf16(Uint8List bytes, Endian endian, String filePath) {
    if (bytes.length.isOdd) {
      throw FormatException('Invalid UTF-16 byte length in $filePath');
    }
    final data = ByteData.sublistView(bytes);
    final codeUnits = <int>[];
    for (var offset = 0; offset < bytes.length; offset += 2) {
      codeUnits.add(data.getUint16(offset, endian));
    }
    return String.fromCharCodes(codeUnits);
  }
}

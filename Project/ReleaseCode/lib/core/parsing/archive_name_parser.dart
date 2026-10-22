import 'dart:io';

import 'package:path/path.dart' as p;

import '../file_io/archive_file_types.dart';
import '../models/extracted_file_content.dart';
import '../models/file_metadata.dart';
import '../models/parsing_result.dart';
import 'parser.dart';

/// Archives are intentionally treated as opaque file objects.
///
/// Their entries are not listed, extracted, or recursively parsed.  Only the
/// archive object's own filename becomes searchable text.
class ArchiveNameParser implements Parser {
  const ArchiveNameParser();

  static bool supports(String filePath) => ArchiveFileTypes.supports(filePath);

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
      throw UnsupportedError('Not a supported archive file: $filePath');
    }
    final stat = await file.stat();
    await reportFileProcessing(observer, FileProcessingStage.textExtraction);
    final name = p.basename(filePath);
    return ParsingResult(
      metadata: FileMetadata(
        filePath: filePath,
        detectedFileType: ArchiveFileTypes.typeLabel(filePath),
        fileSize: stat.size,
        modifiedTime: stat.modified,
      ),
      content: ExtractedFileContent(
        textInformation: [
          TextInformation(
            text: name,
            extractionMethod: TextExtractionMethod.direct,
            informationKind: TextInformationKind.fileName,
            sourcePath: filePath,
            regions: [ContentRegion(sourceName: name)],
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
}

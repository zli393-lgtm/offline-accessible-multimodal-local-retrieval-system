import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/extracted_file_content.dart';
import '../models/file_metadata.dart';
import '../models/parsing_result.dart';
import 'parser.dart';

/// Creates the minimum valid index representation for an otherwise unknown
/// regular file. Its bytes are intentionally not interpreted; only the outer
/// file object's own name is recorded.
class OpaqueFileParser implements Parser {
  const OpaqueFileParser();

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
    final stat = await file.stat();
    final name = p.basename(filePath);
    final extension = p.extension(name);
    await reportFileProcessing(observer, FileProcessingStage.textExtraction);
    return ParsingResult(
      metadata: FileMetadata(
        filePath: filePath,
        detectedFileType: extension.isEmpty
            ? 'UNKNOWN'
            : extension.substring(1).toUpperCase(),
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

import 'file_metadata.dart';
import 'extracted_file_content.dart';

class ParsingResult {
  final FileMetadata metadata;
  final ExtractedFileContent content;

  const ParsingResult({required this.metadata, required this.content});
}

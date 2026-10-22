import '../core/models/extracted_file_content.dart';

enum SummarySourceKind {
  nativeText,
  extractedText,
  image,
  audio,
  overallSummary,
}

class GeneratedSummary {
  final SummarySourceKind sourceKind;
  final String text;

  const GeneratedSummary({required this.sourceKind, required this.text});
}

class FileSummaryBundle {
  final List<GeneratedSummary> firstLevel;
  final GeneratedSummary? overall;

  const FileSummaryBundle({this.firstLevel = const [], this.overall});

  bool get isEmpty => firstLevel.isEmpty && overall == null;
}

/// Stable replacement boundary for the summary subsystem.
///
/// The rest of the application depends only on this contract.  A backend may
/// be the bundled deterministic implementation or a future local generative
/// model.  Backends must inspect all available evidence, must not substitute a
/// random/extractive sentence for a summary, and must be used symmetrically by
/// indexing and temporary query attachments.
abstract interface class SummaryGenerator {
  Future<FileSummaryBundle> generate(ExtractedFileContent content);
}

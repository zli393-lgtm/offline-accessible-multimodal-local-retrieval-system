import 'dart:math' as math;

import '../../../core/models/extracted_file_content.dart';
import '../../../embedding/audio/clap_audio_embedding_engine.dart';
import '../../../embedding/embedding_engine.dart';
import '../../../embedding/embedding_result.dart';
import '../../../embedding/image/mobile_clip_image_embedding_engine.dart';
import '../../../embedding/source_reference.dart';
import '../../summary_generator.dart';
import 'summary_concepts.dart';

/// Offline summary backend using only models already required by the project.
///
/// It performs full-evidence semantic classification and deterministic language
/// realisation. It is deliberately isolated so a future model-backed generator
/// can replace this directory while preserving [SummaryGenerator].
class ExistingModelsSummaryGenerator implements SummaryGenerator {
  final EmbeddingEngine textEngine;
  final ImageEmbeddingEngine imageEngine;
  final AudioEmbeddingEngine audioEngine;
  final int maximumTopics;
  final int maximumTerms;
  final double minimumConceptSimilarity;

  final Map<String, Future<List<EmbeddingResult>>> _candidateCache = {};

  ExistingModelsSummaryGenerator({
    required this.textEngine,
    required this.imageEngine,
    required this.audioEngine,
    this.maximumTopics = 4,
    this.maximumTerms = 8,
    this.minimumConceptSimilarity = 0.20,
  });

  @override
  Future<FileSummaryBundle> generate(ExtractedFileContent content) async {
    final native = <TextInformation>[];
    final extracted = <TextInformation>[];
    for (final item in content.textInformation) {
      (_isExtracted(item) ? extracted : native).add(item);
    }

    final summaries = <GeneratedSummary>[];
    final nativeSummary = await _summarizeText(native, '原生文字');
    if (nativeSummary != null) {
      summaries.add(
        GeneratedSummary(
          sourceKind: SummarySourceKind.nativeText,
          text: nativeSummary,
        ),
      );
    }
    final extractedSummary = await _summarizeText(extracted, '提取文字');
    if (extractedSummary != null) {
      summaries.add(
        GeneratedSummary(
          sourceKind: SummarySourceKind.extractedText,
          text: extractedSummary,
        ),
      );
    }
    final imageSummary = await _summarizeImages(content.imageInformation);
    if (imageSummary != null) {
      summaries.add(
        GeneratedSummary(
          sourceKind: SummarySourceKind.image,
          text: imageSummary,
        ),
      );
    }
    final audioSummary = await _summarizeAudio(content.audioInformation);
    if (audioSummary != null) {
      summaries.add(
        GeneratedSummary(
          sourceKind: SummarySourceKind.audio,
          text: audioSummary,
        ),
      );
    }

    final overall = summaries.isEmpty
        ? null
        : GeneratedSummary(
            sourceKind: SummarySourceKind.overallSummary,
            text: _overallSummary(summaries),
          );
    return FileSummaryBundle(
      firstLevel: List.unmodifiable(summaries),
      overall: overall,
    );
  }

  bool _isExtracted(TextInformation item) =>
      item.extractionMethod != TextExtractionMethod.direct ||
      item.informationKind == TextInformationKind.ocr ||
      item.informationKind == TextInformationKind.speechTranscript ||
      item.informationKind == TextInformationKind.metadata;

  Future<String?> _summarizeText(
    List<TextInformation> information,
    String label,
  ) async {
    final texts = information
        .map((item) => item.text.trim())
        .where((text) => text.isNotEmpty)
        .toList(growable: false);
    if (texts.isEmpty) return null;
    final sources = List.generate(
      texts.length,
      (index) => SourceReference(sourcePath: '<summary-text-$index>'),
    );
    final evidence = await textEngine.embedLongTextBatch(
      texts: texts,
      sources: sources,
    );
    final topics = await _rankTextConcepts(evidence);
    final terms = _importantTerms(texts.join('\n'));
    return _render(label, texts.length, topics, terms);
  }

  Future<String?> _summarizeImages(List<ImageInformation> images) async {
    if (images.isEmpty) return null;
    final evidence = await imageEngine.embedImagesBatch(images);
    final topics = await _rankCrossModalConcepts(
      key: 'image',
      concepts: SummaryConcepts.image,
      evidence: evidence,
      embed: (concepts, sources) =>
          imageEngine.embedTextQueriesBatch(texts: concepts, sources: sources),
    );
    final details = <String>{
      for (final image in images)
        '${image.format} ${image.pixelWidth}×${image.pixelHeight}',
    }.take(3).toList(growable: false);
    return _render('图像', images.length, topics, details);
  }

  Future<String?> _summarizeAudio(List<AudioInformation> audio) async {
    if (audio.isEmpty) return null;
    final evidence = await audioEngine.embedAudioBatch(audio);
    final topics = await _rankCrossModalConcepts(
      key: 'audio',
      concepts: SummaryConcepts.audio,
      evidence: evidence,
      embed: (concepts, sources) =>
          audioEngine.embedTextQueriesBatch(texts: concepts, sources: sources),
    );
    final details = <String>{};
    for (final item in audio) {
      for (final entry in item.tags.entries) {
        final value = entry.value.trim();
        if (value.isNotEmpty) details.add('${entry.key}: $value');
      }
      if (item.format?.isNotEmpty == true) details.add(item.format!);
    }
    return _render('音频', audio.length, topics, details.take(6).toList());
  }

  Future<List<String>> _rankTextConcepts(List<EmbeddingResult> evidence) async {
    if (evidence.isEmpty) return const [];
    final candidates = await _candidateCache.putIfAbsent('text', () async {
      final sources = List.generate(
        SummaryConcepts.text.length,
        (index) => SourceReference(sourcePath: '<text-concept-$index>'),
      );
      return textEngine.embedTextBatch(
        texts: SummaryConcepts.text.map((item) => item.prompt).toList(),
        sources: sources,
      );
    });
    return _rank(
      SummaryConcepts.text.map((item) => item.label).toList(),
      candidates,
      evidence,
    );
  }

  Future<List<String>> _rankCrossModalConcepts({
    required String key,
    required List<SummaryConcept> concepts,
    required List<EmbeddingResult> evidence,
    required Future<List<EmbeddingResult>> Function(
      List<String>,
      List<SourceReference>,
    )
    embed,
  }) async {
    if (evidence.isEmpty) return const [];
    final candidates = await _candidateCache.putIfAbsent(key, () async {
      final sources = List.generate(
        concepts.length,
        (index) => SourceReference(sourcePath: '<$key-concept-$index>'),
      );
      return embed(concepts.map((item) => item.prompt).toList(), sources);
    });
    return _rank(
      concepts.map((item) => item.label).toList(),
      candidates,
      evidence,
    );
  }

  List<String> _rank(
    List<String> labels,
    List<EmbeddingResult> candidates,
    List<EmbeddingResult> evidence,
  ) {
    final scored = <(String, double)>[];
    for (
      var index = 0;
      index < math.min(labels.length, candidates.length);
      index++
    ) {
      var total = 0.0;
      var count = 0;
      for (final item in evidence) {
        if (item.space != candidates[index].space) continue;
        total += _cosine(candidates[index].vector, item.vector);
        count++;
      }
      if (count > 0) scored.add((labels[index], total / count));
    }
    scored.sort((left, right) => right.$2.compareTo(left.$2));
    final above = scored
        .where((item) => item.$2 >= minimumConceptSimilarity)
        .take(maximumTopics)
        .map((item) => item.$1)
        .toList(growable: false);
    // Never invent a weak concept merely to fill the output.
    return above;
  }

  List<String> _importantTerms(String text) {
    final counts = <String, int>{};
    final expression = RegExp(
      r'[A-Za-z][A-Za-z0-9_+.-]{2,}|[\u3400-\u9fff]{2,8}',
      unicode: true,
    );
    for (final match in expression.allMatches(text)) {
      final term = match.group(0)!.toLowerCase();
      if (SummaryConcepts.stopWords.contains(term)) continue;
      counts[term] = (counts[term] ?? 0) + 1;
    }
    final ranked = counts.entries.toList()
      ..sort((left, right) {
        final frequency = right.value.compareTo(left.value);
        return frequency != 0 ? frequency : left.key.compareTo(right.key);
      });
    return ranked.take(maximumTerms).map((entry) => entry.key).toList();
  }

  String _render(
    String label,
    int units,
    List<String> topics,
    List<String> details,
  ) {
    final buffer = StringBuffer('$label摘要：综合分析了 $units 个信息单元。');
    if (topics.isNotEmpty) buffer.write('主要语义涉及${topics.join('、')}。');
    if (details.isNotEmpty) buffer.write('可核实的信息包括${details.join('、')}。');
    if (topics.isEmpty && details.isEmpty) {
      buffer.write('现有证据不足以可靠命名主题，保留其语义向量用于匹配。');
    }
    return buffer.toString();
  }

  String _overallSummary(List<GeneratedSummary> summaries) {
    final names = summaries
        .map(
          (item) => switch (item.sourceKind) {
            SummarySourceKind.nativeText => '原生文字',
            SummarySourceKind.extractedText => '提取文字',
            SummarySourceKind.image => '图像',
            SummarySourceKind.audio => '音频',
            SummarySourceKind.overallSummary => '总体',
          },
        )
        .join('、');
    final facts = <String>{};
    for (final summary in summaries) {
      for (final sentence in summary.text.split('。')) {
        final value = sentence.trim();
        if (value.isEmpty || value.contains('综合分析了')) continue;
        facts.add(value);
      }
    }
    final body = facts.isEmpty
        ? '各类信息已经统一形成文件级语义描述。'
        : '综合主题与可核实信息包括：${facts.join('；')}。';
    return '文件总体摘要：该对象综合了$names信息，$body';
  }

  double _cosine(List<double> left, List<double> right) {
    if (left.isEmpty || left.length != right.length) return -1;
    var dot = 0.0;
    var leftNorm = 0.0;
    var rightNorm = 0.0;
    for (var index = 0; index < left.length; index++) {
      dot += left[index] * right[index];
      leftNorm += left[index] * left[index];
      rightNorm += right[index] * right[index];
    }
    if (leftNorm == 0 || rightNorm == 0) return -1;
    return dot / (math.sqrt(leftNorm) * math.sqrt(rightNorm));
  }
}

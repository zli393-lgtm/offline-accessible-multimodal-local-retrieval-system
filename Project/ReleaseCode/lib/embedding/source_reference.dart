class SourceReference {
  final String sourcePath;
  final int? pageIndex;
  final int? chunkIndex;
  final int? startOffset;
  final int? endOffset;
  final int? informationIndex;
  final int? frameIndex;
  final int? startTimeMs;
  final int? endTimeMs;
  final String? queryInformationKind;
  final String? summaryKind;
  final String? summaryLevel;
  final String? summaryText;

  const SourceReference({
    required this.sourcePath,
    this.pageIndex,
    this.chunkIndex,
    this.startOffset,
    this.endOffset,
    this.informationIndex,
    this.frameIndex,
    this.startTimeMs,
    this.endTimeMs,
    this.queryInformationKind,
    this.summaryKind,
    this.summaryLevel,
    this.summaryText,
  });

  SourceReference copyWith({
    String? sourcePath,
    int? pageIndex,
    int? chunkIndex,
    int? startOffset,
    int? endOffset,
    int? informationIndex,
    int? frameIndex,
    int? startTimeMs,
    int? endTimeMs,
    String? queryInformationKind,
    String? summaryKind,
    String? summaryLevel,
    String? summaryText,
  }) => SourceReference(
    sourcePath: sourcePath ?? this.sourcePath,
    pageIndex: pageIndex ?? this.pageIndex,
    chunkIndex: chunkIndex ?? this.chunkIndex,
    startOffset: startOffset ?? this.startOffset,
    endOffset: endOffset ?? this.endOffset,
    informationIndex: informationIndex ?? this.informationIndex,
    frameIndex: frameIndex ?? this.frameIndex,
    startTimeMs: startTimeMs ?? this.startTimeMs,
    endTimeMs: endTimeMs ?? this.endTimeMs,
    queryInformationKind: queryInformationKind ?? this.queryInformationKind,
    summaryKind: summaryKind ?? this.summaryKind,
    summaryLevel: summaryLevel ?? this.summaryLevel,
    summaryText: summaryText ?? this.summaryText,
  );
}

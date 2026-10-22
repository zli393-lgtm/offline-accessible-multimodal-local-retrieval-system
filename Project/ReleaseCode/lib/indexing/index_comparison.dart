enum IndexComparisonPreset { none, quick, standard, advanced, complete, custom }

class IndexComparisonOptions {
  final bool path;
  final bool size;
  final bool modifiedTime;
  final bool hash;

  const IndexComparisonOptions({
    required this.path,
    required this.size,
    required this.modifiedTime,
    required this.hash,
  });

  const IndexComparisonOptions.none()
    : path = false,
      size = false,
      modifiedTime = false,
      hash = false;

  const IndexComparisonOptions.quick()
    : path = true,
      size = false,
      modifiedTime = false,
      hash = false;

  const IndexComparisonOptions.standard()
    : path = true,
      size = true,
      modifiedTime = true,
      hash = false;

  const IndexComparisonOptions.advanced()
    : path = true,
      size = false,
      modifiedTime = false,
      hash = true;

  const IndexComparisonOptions.complete()
    : path = true,
      size = true,
      modifiedTime = true,
      hash = true;

  bool get checksExistingFile => size || modifiedTime || hash;

  Map<String, bool> toJson() => {
    'path': path,
    'size': size,
    'modifiedTime': modifiedTime,
    'hash': hash,
  };

  IndexComparisonPreset get preset {
    if (!path && !size && !modifiedTime && !hash) {
      return IndexComparisonPreset.none;
    }
    if (path && !size && !modifiedTime && !hash) {
      return IndexComparisonPreset.quick;
    }
    if (path && size && modifiedTime && !hash) {
      return IndexComparisonPreset.standard;
    }
    if (path && !size && !modifiedTime && hash) {
      return IndexComparisonPreset.advanced;
    }
    if (path && size && modifiedTime && hash) {
      return IndexComparisonPreset.complete;
    }
    return IndexComparisonPreset.custom;
  }

  factory IndexComparisonOptions.forPreset(IndexComparisonPreset preset) {
    return switch (preset) {
      IndexComparisonPreset.none => const IndexComparisonOptions.none(),
      IndexComparisonPreset.quick => const IndexComparisonOptions.quick(),
      IndexComparisonPreset.standard => const IndexComparisonOptions.standard(),
      IndexComparisonPreset.advanced => const IndexComparisonOptions.advanced(),
      IndexComparisonPreset.complete => const IndexComparisonOptions.complete(),
      IndexComparisonPreset.custom => throw ArgumentError(
        'Custom comparison options must be selected individually.',
      ),
    };
  }

  IndexComparisonOptions copyWith({
    bool? path,
    bool? size,
    bool? modifiedTime,
    bool? hash,
  }) => IndexComparisonOptions(
    path: path ?? this.path,
    size: size ?? this.size,
    modifiedTime: modifiedTime ?? this.modifiedTime,
    hash: hash ?? this.hash,
  );
}

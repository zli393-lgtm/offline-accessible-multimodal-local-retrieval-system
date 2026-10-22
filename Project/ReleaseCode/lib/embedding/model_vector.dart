class ModelVector {
  final String model;
  final List<double> vector;

  const ModelVector({required this.model, required this.vector});

  factory ModelVector.fromJson(Map<String, dynamic> json) {
    final vector = (json['vector'] as List<dynamic>)
        .map((value) => (value as num).toDouble())
        .toList(growable: false);
    final dimensions = (json['dimensions'] as num).toInt();
    if (vector.isEmpty || dimensions != vector.length) {
      throw const FormatException('Model returned an invalid vector.');
    }
    return ModelVector(model: json['model'] as String, vector: vector);
  }
}

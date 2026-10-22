import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/query/query_file_type_options.dart';

void main() {
  test('follow-preset suffix sets preserve the required relationships', () {
    expect(
      QueryFileTypeOptions.standard,
      containsAll(QueryFileTypeOptions.pureText),
    );
    expect(
      QueryFileTypeOptions.advanced,
      containsAll(QueryFileTypeOptions.standard),
    );
    expect(
      QueryFileTypeOptions.advanced,
      containsAll(QueryFileTypeOptions.images),
    );
    expect(
      QueryFileTypeOptions.advanced.intersection(QueryFileTypeOptions.audio),
      isEmpty,
    );
    expect(QueryFileTypeOptions.images, containsAll({'PDF', 'PPTX', 'DOCX'}));
    expect(QueryFileTypeOptions.audio, containsAll({'MP3', 'FLAC', 'WAV'}));
  });

  test('known suffixes include archives while Other remains implicit', () {
    expect(
      QueryFileTypeOptions.known,
      containsAll(QueryFileTypeOptions.archives),
    );
    expect(QueryFileTypeOptions.known, isNot(contains('OTHER')));
  });
}

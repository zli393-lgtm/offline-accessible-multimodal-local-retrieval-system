import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/embedding/multimodal_embedding_engine.dart';

import '../support/fakes.dart';

void main() {
  test('multimodal inference is split into bounded modality batches', () async {
    final text = FakeTextEngine();
    final image = FakeImageEngine();
    final audio = FakeAudioEngine();
    final engine = fakeMultimodalEngine(
      textBatchSize: 2,
      imageBatchSize: 2,
      audioBatchSize: 2,
      text: text,
      image: image,
      audio: audio,
    );
    final contents = List.generate(
      5,
      (index) => fakeContent(
        'file-$index.dat',
        text: 'text $index',
        withImage: true,
        withAudio: true,
      ),
    );

    final result = await engine.embedContents(contents);

    expect(result.textEmbeddings, hasLength(5));
    expect(result.imageEmbeddings, hasLength(5));
    expect(result.audioEmbeddings, hasLength(5));
    expect(text.observedBatchSizes, [2, 2, 1]);
    expect(image.observedBatchSizes, [2, 2, 1]);
    expect(audio.observedBatchSizes, [2, 2, 1]);
    expect(result.status, EmbeddingStatus.completed);
  });
}

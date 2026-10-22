import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/core/models/extracted_file_content.dart';
import 'package:retrieval/core/parsing/audio_parser.dart';

class _FakeAudioBackend implements AudioBackend {
  final List<String> calls = [];
  Object? transcriptionError;

  _FakeAudioBackend({this.transcriptionError});

  @override
  Future<AudioMetadata> inspect(String filePath) async {
    calls.add('inspect');
    return const AudioMetadata(
      format: 'WAV',
      codec: 'pcm_s16le',
      duration: Duration(seconds: 2),
      sampleRate: 16000,
      channels: 1,
      bitRate: 256000,
      tags: {'title': 'sample'},
    );
  }

  @override
  Future<AudioTranscription> transcribe(String filePath) async {
    calls.add('transcribe');
    if (transcriptionError != null) throw transcriptionError!;
    return const AudioTranscription(
      text: '语音文本',
      model: 'whisper-medium',
      language: 'zh',
      languageProbability: 0.98,
      segments: [
        SpeechSegment(
          text: '语音文本',
          start: Duration.zero,
          end: Duration(seconds: 2),
          confidence: 0.9,
        ),
      ],
    );
  }

  @override
  Future<AudioSemanticResult> analyze(String filePath) async {
    calls.add('analyze');
    return const AudioSemanticResult(
      model: 'clap-htsat-fused',
      vector: [0.1, 0.2, 0.3],
      regions: [
        ContentRegion(startTime: Duration.zero, endTime: Duration(seconds: 2)),
      ],
    );
  }
}

void main() {
  test('AudioParser separates speech text and audio semantics', () async {
    final directory = await Directory.systemTemp.createTemp();
    final file = File('${directory.path}/sample.wav');
    await file.writeAsBytes([1, 2, 3]);
    final backend = _FakeAudioBackend();

    final result = await AudioParser(backend: backend).parse(file.path);

    expect(backend.calls, ['inspect', 'transcribe', 'analyze']);
    expect(result.content.status, ExtractionStatus.completed);
    expect(result.content.textInformation, hasLength(2));
    final metadataText = result.content.textInformation.first;
    expect(metadataText.text, 'title: sample');
    expect(metadataText.informationKind, TextInformationKind.metadata);
    expect(metadataText.extractionMethod, TextExtractionMethod.other);
    final speechText = result.content.textInformation.last;
    expect(speechText.informationKind, TextInformationKind.speechTranscript);
    expect(speechText.extractionMethod, TextExtractionMethod.speechRecognition);
    expect(result.content.imageInformation, isEmpty);
    expect(result.content.audioInformation, hasLength(1));
    expect(result.content.audioInformation.single.codec, 'pcm_s16le');
    expect(result.content.audioInformation.single.hasSemanticAnalysis, isTrue);
    expect(result.content.videoInformation, isEmpty);

    await directory.delete(recursive: true);
  });

  test(
    'AudioParser still analyzes audio when speech recognition fails',
    () async {
      final directory = await Directory.systemTemp.createTemp();
      final file = File('${directory.path}/sample.mp3');
      await file.writeAsBytes([1, 2, 3]);
      final backend = _FakeAudioBackend(
        transcriptionError: StateError('no speech'),
      );

      final result = await AudioParser(backend: backend).parse(file.path);

      expect(result.content.textInformation, hasLength(1));
      expect(
        result.content.textInformation.single.informationKind,
        TextInformationKind.metadata,
      );
      expect(result.content.textInformation.single.text, 'title: sample');
      expect(
        result.content.audioInformation.single.hasSemanticAnalysis,
        isTrue,
      );
      expect(result.content.status, ExtractionStatus.partial);
      expect(result.content.issues.single.stage, 'speech_recognition');

      await directory.delete(recursive: true);
    },
  );
}

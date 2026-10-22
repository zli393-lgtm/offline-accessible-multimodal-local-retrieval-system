import 'package:path/path.dart' as p;

class AudioFileTypes {
  AudioFileTypes._();

  static const Map<String, String> extensionLabels = {
    '.wav': 'WAV',
    '.wave': 'WAV',
    '.mp3': 'MP3',
    '.flac': 'FLAC',
    '.m4a': 'M4A',
    '.aac': 'AAC',
    '.ogg': 'OGG',
    '.oga': 'OGG',
    '.opus': 'OPUS',
    '.wma': 'WMA',
    '.aiff': 'AIFF',
    '.aif': 'AIFF',
    '.aifc': 'AIFF',
    '.au': 'AU',
    '.snd': 'SND',
    '.amr': 'AMR',
    '.ac3': 'AC3',
    '.eac3': 'EAC3',
    '.ape': 'APE',
    '.wv': 'WV',
  };

  static bool supports(String filePath) =>
      extensionLabels.containsKey(p.extension(filePath).toLowerCase());

  static String typeLabel(String filePath) =>
      extensionLabels[p.extension(filePath).toLowerCase()] ?? 'UNSUPPORTED';
}

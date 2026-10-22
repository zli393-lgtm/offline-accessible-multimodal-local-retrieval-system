import 'package:path/path.dart' as p;

class StaticImageFileTypes {
  StaticImageFileTypes._();

  static const Map<String, String> extensionLabels = {
    '.jpg': 'JPEG',
    '.jpeg': 'JPEG',
    '.jpe': 'JPEG',
    '.jfif': 'JPEG',
    '.png': 'PNG',
    '.bmp': 'BMP',
    '.dib': 'BMP',
    '.tif': 'TIFF',
    '.tiff': 'TIFF',
    '.webp': 'WEBP',
    '.gif': 'GIF',
    '.pbm': 'PBM',
    '.pgm': 'PGM',
    '.ppm': 'PPM',
    '.pnm': 'PNM',
  };

  static const Set<String> detectedFormats = {
    'JPEG',
    'PNG',
    'BMP',
    'DIB',
    'TIFF',
    'WEBP',
    'GIF',
    'PBM',
    'PGM',
    'PPM',
    'PNM',
  };

  static bool supports(String filePath) =>
      extensionLabels.containsKey(p.extension(filePath).toLowerCase());

  static String typeLabel(String filePath) =>
      extensionLabels[p.extension(filePath).toLowerCase()] ?? 'UNSUPPORTED';

  static bool supportsDetectedFormat(String format) =>
      detectedFormats.contains(format.toUpperCase());

  static bool extensionMatchesFormat(String filePath, String format) {
    final expected = typeLabel(filePath);
    final actual = format.toUpperCase();
    if (expected == 'BMP' && actual == 'DIB') return true;
    return expected == actual;
  }
}

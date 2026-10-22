import 'package:path/path.dart' as p;

class StructuredVisualFileTypes {
  StructuredVisualFileTypes._();

  static const Map<String, String> extensionLabels = {
    '.xlsx': 'XLSX',
    '.xlsm': 'XLSM',
    '.xltx': 'XLTX',
    '.xltm': 'XLTM',
    '.svg': 'SVG',
    '.svgz': 'SVGZ',
  };

  static bool supports(String filePath) =>
      extensionLabels.containsKey(p.extension(filePath).toLowerCase());

  static String typeLabel(String filePath) =>
      extensionLabels[p.extension(filePath).toLowerCase()] ?? 'UNSUPPORTED';
}

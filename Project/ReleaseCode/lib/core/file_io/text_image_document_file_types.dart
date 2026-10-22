import 'package:path/path.dart' as p;

class TextImageDocumentFileTypes {
  TextImageDocumentFileTypes._();

  static const Map<String, String> extensionLabels = {
    '.xps': 'XPS',
    '.oxps': 'OXPS',
    '.djvu': 'DJVU',
    '.djv': 'DJVU',
    '.fb2': 'FB2',
    '.ps': 'PS',
    '.eps': 'EPS',
  };

  static bool supports(String filePath) {
    final name = p.basename(filePath).toLowerCase();
    return name.endsWith('.fb2.zip') ||
        extensionLabels.containsKey(p.extension(name));
  }

  static String typeLabel(String filePath) {
    final name = p.basename(filePath).toLowerCase();
    if (name.endsWith('.fb2.zip')) return 'FB2_ZIP';
    return extensionLabels[p.extension(name)] ?? 'UNSUPPORTED';
  }

  static bool requiresDjVuLibre(String filePath) {
    final type = typeLabel(filePath);
    return type == 'DJVU';
  }

  static bool requiresGhostscript(String filePath) {
    final type = typeLabel(filePath);
    return type == 'PS' || type == 'EPS';
  }
}

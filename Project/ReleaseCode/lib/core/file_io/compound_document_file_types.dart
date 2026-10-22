import 'package:path/path.dart' as p;

class CompoundDocumentFileTypes {
  CompoundDocumentFileTypes._();

  static const Map<String, String> extensionLabels = {
    '.pdf': 'PDF',
    '.doc': 'DOC',
    '.docx': 'DOCX',
    '.docm': 'DOCM',
    '.dot': 'DOT',
    '.dotx': 'DOTX',
    '.ppt': 'PPT',
    '.pptx': 'PPTX',
    '.pptm': 'PPTM',
    '.pps': 'PPS',
    '.ppsx': 'PPSX',
    '.xls': 'XLS',
    '.xlsx': 'XLSX',
    '.xlsm': 'XLSM',
    '.xlsb': 'XLSB',
    '.odt': 'ODT',
    '.ods': 'ODS',
    '.odp': 'ODP',
    '.rtf': 'RTF',
    '.md': 'MD',
    '.mdx': 'MDX',
    '.html': 'HTML',
    '.htm': 'HTML',
    '.xhtml': 'XHTML',
    '.mhtml': 'MHTML',
    '.mht': 'MHTML',
    '.epub': 'EPUB',
    '.fb2': 'FB2',
    '.xps': 'XPS',
    '.oxps': 'OXPS',
    '.djvu': 'DJVU',
    '.djv': 'DJVU',
    '.ps': 'PS',
    '.eps': 'EPS',
    '.chm': 'CHM',
    '.eml': 'EML',
    '.msg': 'MSG',
    '.pages': 'PAGES',
    '.key': 'KEY',
    '.numbers': 'NUMBERS',
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
}

import 'package:path/path.dart' as p;

class ArchiveFileTypes {
  ArchiveFileTypes._();

  static const Map<String, String> extensionLabels = {
    '.zip': 'ZIP',
    '.rar': 'RAR',
    '.7z': '7Z',
    '.tar': 'TAR',
    '.gz': 'GZ',
    '.tgz': 'TGZ',
    '.bz2': 'BZ2',
    '.tbz': 'TBZ',
    '.tbz2': 'TBZ2',
    '.xz': 'XZ',
    '.txz': 'TXZ',
    '.cab': 'CAB',
    '.iso': 'ISO',
  };

  static bool supports(String filePath) =>
      extensionLabels.containsKey(p.extension(filePath).toLowerCase());

  static String typeLabel(String filePath) =>
      extensionLabels[p.extension(filePath).toLowerCase()] ?? 'UNSUPPORTED';
}

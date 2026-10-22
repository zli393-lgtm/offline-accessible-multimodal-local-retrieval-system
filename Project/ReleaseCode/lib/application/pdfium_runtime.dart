import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves the native PDFium library consistently on every supported desktop
/// platform. A saved path always wins, followed by the portable dependency
/// folder, environment variables, the legacy packaged path, and system paths.
class PdfiumRuntime {
  const PdfiumRuntime._();

  static String libraryName() => switch (Platform.operatingSystem) {
    'windows' => 'pdfium.dll',
    'linux' => 'libpdfium.so',
    'macos' => 'libpdfium.dylib',
    _ => throw UnsupportedError(
      'PDFium is not configured for ${Platform.operatingSystem}.',
    ),
  };

  static String? resolve({
    required String applicationDirectory,
    String? explicitLibrary,
  }) {
    final candidates = <String?>[
      explicitLibrary,
      p.join(applicationDirectory, 'dependencies', 'pdfium', libraryName()),
      Platform.environment['PDFIUM_LIBRARY'],
      ..._rootCandidates(Platform.environment['PDFIUM_ROOT']),
      _packagedLibrary(applicationDirectory),
      ..._systemCandidates(),
    ];
    for (final candidate in candidates) {
      if (candidate == null || candidate.trim().isEmpty) continue;
      final normalized = p.normalize(candidate.trim().replaceAll('"', ''));
      if (File(normalized).existsSync()) return File(normalized).absolute.path;
    }
    return null;
  }

  static Iterable<String?> _rootCandidates(String? root) sync* {
    if (root == null || root.trim().isEmpty) return;
    final value = root.trim().replaceAll('"', '');
    yield p.join(value, libraryName());
    yield p.join(value, 'lib', libraryName());
    yield p.join(value, 'bin', libraryName());
    yield p.join(value, 'out', 'Release', libraryName());
  }

  static String _packagedLibrary(String root) =>
      switch (Platform.operatingSystem) {
        'windows' => p.join(
          root,
          'windows',
          'third_party',
          'pdfium',
          'x64',
          libraryName(),
        ),
        'linux' => p.join(
          root,
          'linux',
          'third_party',
          'pdfium',
          'x64',
          libraryName(),
        ),
        'macos' => p.join(
          root,
          'macos',
          'third_party',
          'pdfium',
          'lib',
          libraryName(),
        ),
        _ => throw UnsupportedError(
          'PDFium is not configured for ${Platform.operatingSystem}.',
        ),
      };

  static Iterable<String> _systemCandidates() sync* {
    if (Platform.isWindows) return;
    if (Platform.isLinux) {
      yield '/usr/local/lib/libpdfium.so';
      yield '/usr/lib/libpdfium.so';
      yield '/usr/lib64/libpdfium.so';
      yield '/lib/libpdfium.so';
      return;
    }
    if (Platform.isMacOS) {
      yield '/opt/homebrew/lib/libpdfium.dylib';
      yield '/usr/local/lib/libpdfium.dylib';
      yield '/usr/lib/libpdfium.dylib';
    }
  }
}

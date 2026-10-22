import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// Computes the content identity used to decide whether one path changed.
///
/// A fingerprint never identifies a [FileObject]. File-object identity remains
/// path-based, so equal bytes at two different paths still produce two objects.
class FileFingerprint {
  const FileFingerprint._();

  static const algorithm = 'sha256';

  static Future<String> compute(String path) => Isolate.run(
    () => _computeInBackground(path),
    debugName: 'retrieval-file-fingerprint',
  );

  static Future<String> _computeInBackground(String path) async {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('Path is not a file', path);
    }
    final digest = await sha256.bind(file.openRead()).first;
    return '$algorithm:${digest.toString()}';
  }
}

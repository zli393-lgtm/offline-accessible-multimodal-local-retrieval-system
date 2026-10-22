import 'dart:io';

import 'archive_file_types.dart';
import 'audio_file_types.dart';
import 'compound_document_file_types.dart';
import 'pure_text_file_types.dart';
import 'static_image_file_types.dart';
import 'structured_visual_file_types.dart';
import 'text_image_document_file_types.dart';

class FileTypeDetector {
  static Future<String> detect(String filePath) async {
    final file = File(filePath);

    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }

    if (PureTextFileTypes.supports(filePath)) {
      return PureTextFileTypes.typeLabel(filePath);
    }

    if (StaticImageFileTypes.supports(filePath)) {
      return StaticImageFileTypes.typeLabel(filePath);
    }

    if (StructuredVisualFileTypes.supports(filePath)) {
      return StructuredVisualFileTypes.typeLabel(filePath);
    }

    if (AudioFileTypes.supports(filePath)) {
      return AudioFileTypes.typeLabel(filePath);
    }

    if (TextImageDocumentFileTypes.supports(filePath)) {
      return TextImageDocumentFileTypes.typeLabel(filePath);
    }

    if (CompoundDocumentFileTypes.supports(filePath)) {
      return CompoundDocumentFileTypes.typeLabel(filePath);
    }

    if (ArchiveFileTypes.supports(filePath)) {
      return ArchiveFileTypes.typeLabel(filePath);
    }

    final result = await Process.run('tika', [
      '--detect',
      filePath,
    ], runInShell: true);

    if (result.exitCode != 0) {
      throw FileSystemException('Failed to detect file type', filePath);
    }

    final mimeType = result.stdout.toString().trim();

    switch (mimeType) {
      case 'text/plain':
        return 'TXT';
      case 'application/pdf':
        return 'PDF';
      case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
        return 'DOCX';
      case 'image/jpeg':
        return 'JPG';
      case 'image/png':
        return 'PNG';
      default:
        return 'UNSUPPORTED';
    }
  }
}

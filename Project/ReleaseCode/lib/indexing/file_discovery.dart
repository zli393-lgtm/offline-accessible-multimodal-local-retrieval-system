import 'dart:async';
import 'dart:io';

import 'database_storage.dart';
import 'failure_log.dart';
import 'index_scope.dart';

sealed class FileDiscoveryEvent {
  final String path;

  const FileDiscoveryEvent(this.path);
}

class DiscoveredFile extends FileDiscoveryEvent {
  const DiscoveredFile(super.path);
}

class DiscoveryFailure extends FileDiscoveryEvent {
  final String code;
  final String message;

  const DiscoveryFailure(
    super.path, {
    required this.code,
    required this.message,
  });
}

class FileDiscoveryService {
  final VolumeDiscovery volumeDiscovery;

  const FileDiscoveryService({
    this.volumeDiscovery = const PlatformVolumeDiscovery(),
  });

  Stream<FileDiscoveryEvent> discover({
    required IndexScope scope,
    required DatabaseStorageProfile storage,
  }) async* {
    final roots = scope.mode == IndexScopeMode.allDevices
        ? await volumeDiscovery.roots()
        : scope.includedPaths;
    final visited = <String>{};
    final pending = <String>[...roots.reversed];
    while (pending.isNotEmpty) {
      final path = PathRules.canonical(pending.removeLast());
      if (!visited.add(path)) continue;
      if (scope.excludes(path, systemPaths: storage.protectedPaths)) continue;
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        if (!path.endsWith(FailureLogCodec.fileExtension)) {
          yield DiscoveredFile(path);
        }
        continue;
      }
      if (type == FileSystemEntityType.notFound) {
        yield DiscoveryFailure(
          path,
          code: 'PATH_NOT_FOUND',
          message: 'The selected path does not exist.',
        );
        continue;
      }
      if (type != FileSystemEntityType.directory) continue;
      try {
        await for (final entity in Directory(
          path,
        ).list(recursive: false, followLinks: false)) {
          if (entity is Link) continue;
          if (entity is Directory && scope.recursive) {
            pending.add(entity.path);
          } else if (entity is File &&
              !scope.excludes(
                entity.path,
                systemPaths: storage.protectedPaths,
              ) &&
              !entity.path.endsWith(FailureLogCodec.fileExtension)) {
            yield DiscoveredFile(PathRules.canonical(entity.path));
          }
        }
      } on FileSystemException catch (error) {
        yield DiscoveryFailure(
          path,
          code: _errorCode(error),
          message: error.message,
        );
      }
    }
  }

  String _errorCode(FileSystemException error) {
    final code = error.osError?.errorCode;
    if (code == 5 || code == 13) return 'PERMISSION_DENIED';
    return 'DISCOVERY_FAILED';
  }
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('Windows inherits the invoker token and permits manual elevation', () {
    final manifest = File(p.join('windows', 'runner', 'runner.exe.manifest'))
        .readAsStringSync();

    expect(manifest, contains('requestedExecutionLevel'));
    expect(manifest, contains('level="asInvoker"'));
    expect(manifest, isNot(contains('requireAdministrator')));
  });

  test('desktop packages carry local models and service resources', () async {
    final application = Directory.current;
    final windows = await File(
      '${application.path}${Platform.pathSeparator}windows${Platform.pathSeparator}CMakeLists.txt',
    ).readAsString();
    final linux = await File(
      '${application.path}${Platform.pathSeparator}linux${Platform.pathSeparator}CMakeLists.txt',
    ).readAsString();
    final macProject = await File(
      '${application.path}${Platform.pathSeparator}macos${Platform.pathSeparator}Runner.xcodeproj${Platform.pathSeparator}project.pbxproj',
    ).readAsString();

    for (final cmake in [windows, linux]) {
      expect(cmake, contains('local_retrieval'));
      expect(cmake, contains('/../assets/'));
      expect(cmake, contains('/../services/'));
      expect(cmake, contains('PATTERN "__pycache__" EXCLUDE'));
    }
    expect(macProject, contains('Copy Local Retrieval Resources'));
    expect(macProject, contains('local_retrieval'));
    expect(macProject, contains(r'$SOURCE_ROOT/assets/'));
    expect(macProject, contains(r'$SOURCE_ROOT/services/'));
    expect(
      RegExp('A1B2C3D4E5F60123456789AB').allMatches(macProject),
      hasLength(2),
    );
  });

  test('macOS desktop build is not confined to the App Sandbox', () async {
    final root = Directory.current.path;
    for (final name in ['DebugProfile', 'Release']) {
      final entitlement = await File(
        '$root${Platform.pathSeparator}macos${Platform.pathSeparator}Runner${Platform.pathSeparator}$name.entitlements',
      ).readAsString();
      expect(
        entitlement,
        contains('<key>com.apple.security.app-sandbox</key>\n\t<false/>'),
      );
    }
  });
}

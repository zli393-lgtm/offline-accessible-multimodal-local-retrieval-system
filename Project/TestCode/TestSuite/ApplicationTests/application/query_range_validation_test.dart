import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/application/application_controller.dart';
import 'package:retrieval/indexing/database_storage.dart';
import 'package:retrieval/indexing/index_scope.dart';
import 'package:retrieval/indexing/index_coverage.dart';

void main() {
  test(
    'query range validation distinguishes covered and unavailable paths',
    () async {
      final temporary = await Directory.systemTemp.createTemp('query-range-');
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final indexed = Directory(p.join(temporary.path, 'indexed'));
      final child = Directory(p.join(indexed.path, 'child'));
      final missingIndex = Directory(p.join(temporary.path, 'not-indexed'));
      final excluded = Directory(p.join(indexed.path, 'excluded'));
      await child.create(recursive: true);
      await missingIndex.create(recursive: true);
      await excluded.create(recursive: true);

      final controller = ApplicationController();
      addTearDown(controller.dispose);
      controller.scope = IndexScope(
        mode: IndexScopeMode.selectedPaths,
        includedPaths: [indexed.path],
        excludedPaths: [excluded.path],
      );
      controller.indexCoverage = IndexCoverage(roots: [indexed.path]);

      final unavailable = await controller.unindexedQueryPaths([
        child.path,
        missingIndex.path,
        excluded.path,
        p.join(temporary.path, 'does-not-exist'),
      ]);

      expect(unavailable, contains(missingIndex.path));
      expect(unavailable, contains(excluded.path));
      expect(unavailable, contains(p.join(temporary.path, 'does-not-exist')));
      expect(unavailable, isNot(contains(child.path)));
    },
  );

  test(
    'unindexed query paths replace the library selection without scanning',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'query-library-transfer-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final oldPath = p.join(temporary.path, 'old');
      final firstMissing = p.join(temporary.path, 'first-missing');
      final secondMissing = p.join(temporary.path, 'second-missing');
      final excluded = p.join(temporary.path, 'excluded');
      final controller = ApplicationController();
      addTearDown(controller.dispose);
      controller.scope = IndexScope(
        mode: IndexScopeMode.allDevices,
        includedPaths: [oldPath],
        excludedPaths: [excluded],
      );

      await controller.replaceIndexPaths([secondMissing, firstMissing]);

      expect(controller.scope.mode, IndexScopeMode.selectedPaths);
      expect(controller.scope.includedPaths, [
        PathRules.canonical(firstMissing),
        PathRules.canonical(secondMissing),
      ]);
      expect(controller.scope.includedPaths, isNot(contains(oldPath)));
      expect(controller.scope.excludedPaths, [PathRules.canonical(excluded)]);
      expect(controller.indexState, isNull);
    },
  );

  test(
    'unindexed query paths can merge with the existing library selection',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'query-library-merge-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final existing = p.join(temporary.path, 'existing');
      final missing = p.join(temporary.path, 'missing');
      final controller = ApplicationController();
      addTearDown(controller.dispose);
      controller.scope = IndexScope(
        mode: IndexScopeMode.selectedPaths,
        includedPaths: [existing],
      );

      await controller.mergeIndexPaths([missing, existing]);

      expect(controller.scope.mode, IndexScopeMode.selectedPaths);
      expect(controller.scope.includedPaths, [
        PathRules.canonical(existing),
        PathRules.canonical(missing),
      ]);
      expect(controller.indexState, isNull);
    },
  );
}

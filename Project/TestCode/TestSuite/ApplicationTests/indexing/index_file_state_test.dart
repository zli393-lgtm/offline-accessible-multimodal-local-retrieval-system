import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:retrieval/indexing/index_file_state.dart';

void main() {
  test('legacy partial file state is migrated to failed', () {
    final state = IndexFileState.fromJson({
      'jobId': 'legacy-job',
      'fileObjectId': 'legacy-file',
      'path': p.join(Directory.systemTemp.path, 'legacy.txt'),
      'status': 'partial',
      'stage': 'committed',
      'message': 'legacy partial result',
      'time': DateTime.utc(2026, 10, 12).toIso8601String(),
    });

    expect(state.status, IndexFileStatus.failed);
  });

  test('JSONL store replays the latest state for every file', () async {
    final temporary = await Directory.systemTemp.createTemp('file-state-');
    addTearDown(() => temporary.delete(recursive: true));
    final store = IndexFileStateStore(temporary.path);

    await store.append(
      IndexFileState.forPath(
        jobId: 'job-1',
        path: p.join(temporary.path, 'a.txt'),
        status: IndexFileStatus.discovered,
        stage: 'discovery',
      ),
    );
    await store.append(
      IndexFileState.forPath(
        jobId: 'job-1',
        path: p.join(temporary.path, 'a.txt'),
        status: IndexFileStatus.indexed,
        stage: 'committed',
      ),
    );

    final latest = await store.loadLatest('job-1');
    expect(latest, hasLength(1));
    expect(latest.values.single.status, IndexFileStatus.indexed);
    expect(await store.fileFor('job-1').readAsLines(), hasLength(2));
  });

  test(
    'user log contains final successes and failures in one bilingual file',
    () async {
      final temporary = await Directory.systemTemp.createTemp('result-log-');
      addTearDown(() => temporary.delete(recursive: true));
      final log = await const IndexResultLogFile().write(
        directory: temporary.path,
        jobId: 'job-2',
        states: [
          IndexFileState.forPath(
            jobId: 'job-2',
            path: p.join(temporary.path, 'success.txt'),
            status: IndexFileStatus.indexed,
            stage: 'committed',
          ),
          IndexFileState.forPath(
            jobId: 'job-2',
            path: p.join(temporary.path, 'failure.txt'),
            status: IndexFileStatus.failed,
            stage: 'processing',
            message: 'test failure',
          ),
          IndexFileState.forPath(
            jobId: 'job-2',
            path: p.join(temporary.path, 'ignored.txt'),
            status: IndexFileStatus.discovered,
          ),
        ],
      );

      expect(p.extension(log.path), '.log');
      final contents = await log.readAsString();
      expect(contents, contains('[成功 / SUCCESS]'));
      expect(contents, contains('[失败 / FAILED]'));
      expect(contents, contains('success.txt'));
      expect(contents, contains('failure.txt'));
      expect(contents, isNot(contains('ignored.txt')));
    },
  );
}

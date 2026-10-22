import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/indexing/failure_log.dart';

IndexFailureRecord record({bool retryable = true}) => IndexFailureRecord(
  failureId: 'job-000001',
  fileObjectId: 'file-a',
  path: 'missing.txt',
  stage: 'index',
  code: 'PATH_NOT_FOUND',
  message: 'not found',
  retryable: retryable,
  attempts: 1,
  time: DateTime.utc(2026),
);

void main() {
  const codec = FailureLogCodec();

  test('strict marked format round-trips known failures', () {
    final value = record();
    final encoded = codec.encode([value]);
    expect(encoded, startsWith(FailureLogCodec.header));
    expect(encoded, contains(FailureLogCodec.recordStart));
    expect(encoded, endsWith('${FailureLogCodec.footer}\n'));

    final decoded = codec.decode(encoded);
    expect(decoded.rejectedEntries, isEmpty);
    final plan = codec.createRetryPlan(
      log: decoded,
      knownFailures: {value.failureId: value},
    );
    expect(plan.accepted.single.failureId, value.failureId);
    expect(plan.rejected, isEmpty);
  });

  test('arbitrary text and edited records can never become retry paths', () {
    final value = record();
    final json = value.toJson();
    json['path'] = 'arbitrary-added-by-user.txt';
    json['recordHash'] = FailureLogCodec.hashRecord(
      Map<String, Object>.from(json)..remove('recordHash'),
    );
    final input = [
      FailureLogCodec.header,
      'untrusted/should-not-be-scanned.txt',
      FailureLogCodec.recordStart,
      '${FailureLogCodec.pathLabel} ${jsonEncode('arbitrary-added-by-user.txt')}',
      jsonEncode(json),
      FailureLogCodec.recordEnd,
      FailureLogCodec.footer,
    ].join('\n');

    final decoded = codec.decode(input);
    expect(decoded.rejectedEntries, hasLength(1));
    final plan = codec.createRetryPlan(
      log: decoded,
      knownFailures: {value.failureId: value},
    );
    expect(plan.accepted, isEmpty);
    expect(plan.rejected.join(' '), contains('modified'));
    expect(plan.rejected.join(' '), contains('unrecognized content'));
  });

  test('invalid checksum and non-retryable failures are rejected', () {
    final value = record(retryable: false);
    final encoded = codec.encode([value]);
    final decoded = codec.decode(encoded);
    final plan = codec.createRetryPlan(
      log: decoded,
      knownFailures: {value.failureId: value},
    );
    expect(plan.accepted, isEmpty);
    expect(plan.rejected.single, contains('not retryable'));

    final damaged = encoded.replaceFirst('not found', 'changed');
    expect(codec.decode(damaged).records, isEmpty);
    expect(codec.decode(damaged).rejectedEntries.single, contains('checksum'));
  });
}

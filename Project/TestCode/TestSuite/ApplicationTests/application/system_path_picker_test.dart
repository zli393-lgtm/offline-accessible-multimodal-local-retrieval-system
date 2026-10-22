import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/application/system_path_picker.dart';

void main() {
  group('SystemPathPicker', () {
    test(
      'decodes multiple Windows files without changing their paths',
      () async {
        final runner = _FakeRunner([
          ProcessResult(
            1,
            0,
            r'["fixtures\\资料\\一.png","fixtures\\two.pdf"]',
            '',
          ),
        ]);
        final picker = SystemPathPicker(
          platform: PathPickerPlatform.windows,
          commandRunner: runner,
        );

        expect(await picker.pickFiles(), [
          r'fixtures\资料\一.png',
          r'fixtures\two.pdf',
        ]);
        expect(runner.calls.single.arguments, contains('-STA'));
      },
    );

    test('returns null when the user cancels a directory selection', () async {
      final picker = SystemPathPicker(
        platform: PathPickerPlatform.macos,
        commandRunner: _FakeRunner([ProcessResult(1, 1, '', 'cancelled')]),
      );

      expect(await picker.pickDirectory(), isNull);
    });

    test('returns separate macOS files in the selected order', () async {
      final picker = SystemPathPicker(
        platform: PathPickerPlatform.macos,
        commandRunner: _FakeRunner([
          ProcessResult(1, 0, '/tmp/first.txt\n/tmp/second.png\n', ''),
        ]),
      );

      expect(await picker.pickFiles(), ['/tmp/first.txt', '/tmp/second.png']);
    });

    test('macOS application picker returns the chosen app bundle', () async {
      final runner = _FakeRunner([
        ProcessResult(1, 0, '/Applications/Preview.app\n', ''),
      ]);
      final picker = SystemPathPicker(
        platform: PathPickerPlatform.macos,
        commandRunner: runner,
      );

      expect(await picker.pickApplication(), '/Applications/Preview.app');
      expect(runner.calls.single.executable, '/usr/bin/osascript');
      expect(
        runner.calls.single.arguments.join(' '),
        contains('choose application'),
      );
    });

    test('falls back to kdialog when zenity is unavailable', () async {
      final runner = _FakeRunner([
        ProcessException('zenity', const []),
        ProcessResult(1, 0, '/tmp/selected', ''),
      ]);
      final picker = SystemPathPicker(
        platform: PathPickerPlatform.linux,
        commandRunner: runner,
      );

      expect(await picker.pickDirectory(), '/tmp/selected');
      expect(runner.calls.map((call) => call.executable), [
        'zenity',
        'kdialog',
      ]);
    });

    test('reports a non-cancellation system error', () async {
      final picker = SystemPathPicker(
        platform: PathPickerPlatform.windows,
        commandRunner: _FakeRunner([ProcessResult(1, 2, '', 'dialog failed')]),
      );

      expect(() => picker.pickFile(), throwsA(isA<ProcessException>()));
    });

    test('rejects a selected file outside the allowed suffixes', () async {
      final picker = SystemPathPicker(
        platform: PathPickerPlatform.linux,
        commandRunner: _FakeRunner([
          ProcessResult(1, 0, '/tmp/not-a-log.txt\n', ''),
        ]),
      );

      expect(
        () =>
            picker.pickFile(allowedSuffixes: const ['.retrieval-failures.log']),
        throwsA(isA<FormatException>()),
      );
    });

    test('passes initial folder and suffix filter to Linux picker', () async {
      final runner = _FakeRunner([
        ProcessResult(1, 0, '/tmp/logs/task.retrieval-failures.log\n', ''),
      ]);
      final picker = SystemPathPicker(
        platform: PathPickerPlatform.linux,
        commandRunner: runner,
      );

      await picker.pickFile(
        initialDirectory: '/tmp/logs',
        allowedSuffixes: const ['.retrieval-failures.log'],
        filterLabel: 'Failure records',
      );

      expect(runner.calls.single.arguments, contains('--filename=/tmp/logs/'));
      expect(
        runner.calls.single.arguments,
        contains('--file-filter=Failure records | *.retrieval-failures.log'),
      );
    });
  });
}

class _CommandCall {
  final String executable;
  final List<String> arguments;

  const _CommandCall(this.executable, this.arguments);
}

class _FakeRunner implements PathPickerCommandRunner {
  final List<Object> _responses;
  final List<_CommandCall> calls = [];

  _FakeRunner(this._responses);

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) async {
    calls.add(_CommandCall(executable, arguments));
    final response = _responses.removeAt(0);
    if (response is ProcessException) throw response;
    return response as ProcessResult;
  }
}

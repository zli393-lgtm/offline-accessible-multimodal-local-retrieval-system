import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retrieval/application/system_file_launcher.dart';

void main() {
  test('Windows open and reveal pass paths as separate arguments', () async {
    final runner = _RecordingRunner(exitCode: 1);
    final launcher = SystemFileLauncher(
      platform: FileLauncherPlatform.windows,
      commandRunner: runner,
    );
    const path = r'folder with spaces\example.txt';

    await launcher.openFile(path);
    await launcher.openFileWith(path);
    await launcher.revealFile(path);

    expect(runner.commands.map((value) => value.$1), [
      'explorer.exe',
      'rundll32.exe',
      'explorer.exe',
    ]);
    expect(runner.commands[0].$2, [path]);
    expect(runner.commands[1].$2, ['shell32.dll,OpenAs_RunDLL', path]);
    expect(runner.commands[2].$2, ['/select,', path]);
  });

  test('Linux reveal opens the containing directory', () async {
    final runner = _RecordingRunner();
    final launcher = SystemFileLauncher(
      platform: FileLauncherPlatform.linux,
      commandRunner: runner,
    );

    await launcher.revealFile('/tmp/folder/example.txt');

    expect(runner.commands.single.$1, 'xdg-open');
    expect(runner.commands.single.$2, ['/tmp/folder']);
  });

  test('macOS and Linux can open a file with a user-selected app', () async {
    final macRunner = _RecordingRunner();
    final mac = SystemFileLauncher(
      platform: FileLauncherPlatform.macos,
      commandRunner: macRunner,
    );
    await mac.openFileWith(
      '/tmp/report.pdf',
      applicationPath: '/Applications/Preview.app',
    );
    expect(macRunner.commands.single.$1, '/usr/bin/open');
    expect(macRunner.commands.single.$2, [
      '-a',
      '/Applications/Preview.app',
      '/tmp/report.pdf',
    ]);

    final linuxRunner = _RecordingRunner();
    final linux = SystemFileLauncher(
      platform: FileLauncherPlatform.linux,
      commandRunner: linuxRunner,
    );
    await linux.openFileWith(
      '/tmp/report.pdf',
      applicationPath: '/usr/bin/evince',
    );
    expect(linuxRunner.commands.single.$1, '/usr/bin/evince');
    expect(linuxRunner.commands.single.$2, ['/tmp/report.pdf']);
  });

  test('launcher reports genuine command failures', () async {
    final launcher = SystemFileLauncher(
      platform: FileLauncherPlatform.macos,
      commandRunner: _RecordingRunner(exitCode: 4),
    );

    await expectLater(
      launcher.openFile('/tmp/example.txt'),
      throwsA(isA<ProcessException>()),
    );
  });
}

class _RecordingRunner implements FileLauncherCommandRunner {
  final int exitCode;
  final List<(String, List<String>)> commands = [];

  _RecordingRunner({this.exitCode = 0});

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) async {
    commands.add((executable, List.of(arguments)));
    return ProcessResult(1, exitCode, '', exitCode == 0 ? '' : 'failed');
  }
}

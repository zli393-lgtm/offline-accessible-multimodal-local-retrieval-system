import 'dart:io';

import 'package:path/path.dart' as p;

enum FileLauncherPlatform { windows, macos, linux, unsupported }

abstract interface class FileLauncherCommandRunner {
  Future<ProcessResult> run(String executable, List<String> arguments);
}

class IoFileLauncherCommandRunner implements FileLauncherCommandRunner {
  const IoFileLauncherCommandRunner();

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) =>
      Process.run(executable, arguments, runInShell: false);
}

class SystemFileLauncher {
  final FileLauncherPlatform platform;
  final FileLauncherCommandRunner commandRunner;

  const SystemFileLauncher({
    required this.platform,
    this.commandRunner = const IoFileLauncherCommandRunner(),
  });

  factory SystemFileLauncher.platformDefault() => SystemFileLauncher(
    platform: switch (Platform.operatingSystem) {
      'windows' => FileLauncherPlatform.windows,
      'macos' => FileLauncherPlatform.macos,
      'linux' => FileLauncherPlatform.linux,
      _ => FileLauncherPlatform.unsupported,
    },
  );

  Future<void> openFile(String path, {bool english = false}) =>
      _run(switch (platform) {
        FileLauncherPlatform.windows => ('explorer.exe', [path]),
        FileLauncherPlatform.macos => ('/usr/bin/open', [path]),
        FileLauncherPlatform.linux => ('xdg-open', [path]),
        FileLauncherPlatform.unsupported => throw UnsupportedError(
          english
              ? 'This operating system cannot open files from the app.'
              : '当前操作系统不支持从程序打开文件。',
        ),
      }, english: english);

  Future<void> revealFile(String path, {bool english = false}) =>
      _run(switch (platform) {
        FileLauncherPlatform.windows => ('explorer.exe', ['/select,', path]),
        FileLauncherPlatform.macos => ('/usr/bin/open', ['-R', path]),
        FileLauncherPlatform.linux => ('xdg-open', [p.dirname(path)]),
        FileLauncherPlatform.unsupported => throw UnsupportedError(
          english
              ? 'This operating system cannot reveal files.'
              : '当前操作系统不支持定位文件。',
        ),
      }, english: english);

  Future<void> openFileWith(
    String path, {
    String? applicationPath,
    bool english = false,
  }) => _run(switch (platform) {
    FileLauncherPlatform.windows => (
      'rundll32.exe',
      ['shell32.dll,OpenAs_RunDLL', path],
    ),
    FileLauncherPlatform.macos =>
      applicationPath == null
          ? throw ArgumentError(
              english
                  ? 'Choose an application on macOS.'
                  : 'macOS 打开方式需要选择一个应用。',
            )
          : ('/usr/bin/open', ['-a', applicationPath, path]),
    FileLauncherPlatform.linux =>
      applicationPath == null
          ? throw ArgumentError(
              english
                  ? 'Choose an application on Linux.'
                  : 'Linux 打开方式需要选择一个应用程序。',
            )
          : (applicationPath, [path]),
    FileLauncherPlatform.unsupported => throw UnsupportedError(
      english
          ? 'This operating system does not support choosing another application to open a file.'
          : '当前操作系统不支持选择其他应用打开文件。',
    ),
  }, english: english);

  Future<void> _run(
    (String, List<String>) command, {
    required bool english,
  }) async {
    final result = await commandRunner.run(command.$1, command.$2);
    // Windows Explorer commonly returns 1 after successfully handing the
    // request to an existing Explorer process. Other launchers use 0.
    final succeeded = platform == FileLauncherPlatform.windows
        ? result.exitCode == 0 || result.exitCode == 1
        : result.exitCode == 0;
    if (!succeeded) {
      final detail = '${result.stderr}'.trim();
      throw ProcessException(
        command.$1,
        command.$2,
        detail.isEmpty
            ? (english
                  ? 'The system did not complete the operation.'
                  : '系统没有完成该操作。')
            : detail,
        result.exitCode,
      );
    }
  }
}

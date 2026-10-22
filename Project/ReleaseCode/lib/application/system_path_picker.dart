import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

enum PathPickerPlatform { windows, macos, linux, unsupported }

abstract interface class PathPickerCommandRunner {
  Future<ProcessResult> run(String executable, List<String> arguments);
}

class IoPathPickerCommandRunner implements PathPickerCommandRunner {
  const IoPathPickerCommandRunner();

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) =>
      Process.run(
        executable,
        arguments,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
}

/// Opens the operating system's own file and folder chooser without adding a
/// package-level dependency or fixing any user path in application code.
class SystemPathPicker {
  final PathPickerPlatform platform;
  final PathPickerCommandRunner commandRunner;
  final bool useNativeWindowsDialogs;

  const SystemPathPicker({
    required this.platform,
    this.commandRunner = const IoPathPickerCommandRunner(),
    this.useNativeWindowsDialogs = false,
  });

  factory SystemPathPicker.platformDefault() => SystemPathPicker(
    platform: switch (Platform.operatingSystem) {
      'windows' => PathPickerPlatform.windows,
      'macos' => PathPickerPlatform.macos,
      'linux' => PathPickerPlatform.linux,
      _ => PathPickerPlatform.unsupported,
    },
    useNativeWindowsDialogs: Platform.isWindows,
  );

  static const MethodChannel _windowsChannel = MethodChannel(
    'retrieval/system_path_picker',
  );

  Future<String?> pickDirectory({bool english = false}) async {
    if (platform == PathPickerPlatform.windows && useNativeWindowsDialogs) {
      final values = await _pickWindows('pickDirectory');
      return values.isEmpty ? null : values.first;
    }
    final result = switch (platform) {
      PathPickerPlatform.windows => await commandRunner.run('powershell', [
        '-NoProfile',
        '-STA',
        '-Command',
        _windowsDirectoryScript(english),
      ]),
      PathPickerPlatform.macos => await commandRunner.run('/usr/bin/osascript', [
        '-e',
        'POSIX path of (choose folder with prompt "${english ? 'Choose a folder' : '选择文件夹'}")',
      ]),
      PathPickerPlatform.linux => await _runLinuxDirectoryPicker(english),
      PathPickerPlatform.unsupported => throw UnsupportedError(
        english
            ? 'No system path picker is available. Enter the path directly.'
            : '当前操作系统没有可用的系统路径选择器，请直接输入路径。',
      ),
    };
    final values = _readLines(
      result,
      operation: english ? 'Choose folder' : '选择文件夹',
      english: english,
    );
    return values.isEmpty ? null : values.first;
  }

  Future<List<String>> pickFiles({
    bool multiple = true,
    bool english = false,
    String? initialDirectory,
    List<String> allowedSuffixes = const [],
    String? filterLabel,
  }) async {
    if (platform == PathPickerPlatform.windows && useNativeWindowsDialogs) {
      final values = await _pickWindows(
        'pickFiles',
        multiple: multiple,
        initialDirectory: initialDirectory,
        allowedSuffixes: allowedSuffixes,
        filterLabel: filterLabel,
      );
      return _validateSuffixes(values, allowedSuffixes, english);
    }
    final result = switch (platform) {
      PathPickerPlatform.windows => await commandRunner.run('powershell', [
        '-NoProfile',
        '-STA',
        '-Command',
        _windowsFileScript(multiple, english),
      ]),
      PathPickerPlatform.macos => await commandRunner.run(
        '/usr/bin/osascript',
        ['-e', _macFileScript(multiple, english, initialDirectory)],
      ),
      PathPickerPlatform.linux => await _runLinuxFilePicker(
        multiple,
        english,
        initialDirectory: initialDirectory,
        allowedSuffixes: allowedSuffixes,
        filterLabel: filterLabel,
      ),
      PathPickerPlatform.unsupported => throw UnsupportedError(
        english
            ? 'No system file picker is available. Enter the path directly.'
            : '当前操作系统没有可用的系统文件选择器，请直接输入路径。',
      ),
    };
    return _validateSuffixes(
      _readLines(
        result,
        operation: english ? 'Choose file' : '选择文件',
        english: english,
      ),
      allowedSuffixes,
      english,
    );
  }

  Future<List<String>> _pickWindows(
    String method, {
    bool multiple = false,
    String? initialDirectory,
    List<String> allowedSuffixes = const [],
    String? filterLabel,
  }) async {
    final arguments = <String, Object>{'multiple': multiple};
    if (initialDirectory != null) {
      arguments['initialDirectory'] = initialDirectory;
    }
    if (allowedSuffixes.isNotEmpty) {
      arguments['allowedSuffixes'] = allowedSuffixes;
    }
    if (filterLabel != null) arguments['filterLabel'] = filterLabel;
    final values = await _windowsChannel.invokeListMethod<String>(
      method,
      arguments,
    );
    return values ?? const [];
  }

  Future<String?> pickFile({
    bool english = false,
    String? initialDirectory,
    List<String> allowedSuffixes = const [],
    String? filterLabel,
  }) async {
    final files = await pickFiles(
      multiple: false,
      english: english,
      initialDirectory: initialDirectory,
      allowedSuffixes: allowedSuffixes,
      filterLabel: filterLabel,
    );
    return files.isEmpty ? null : files.first;
  }

  List<String> _validateSuffixes(
    List<String> paths,
    List<String> allowedSuffixes,
    bool english,
  ) {
    if (allowedSuffixes.isEmpty) return paths;
    final normalized = allowedSuffixes.map((value) => value.toLowerCase());
    for (final path in paths) {
      if (!normalized.any((suffix) => path.toLowerCase().endsWith(suffix))) {
        throw FormatException(
          english
              ? 'The selected file type is not allowed for this item.'
              : '所选文件类型不符合当前项目的要求。',
        );
      }
    }
    return paths;
  }

  Future<String?> pickApplication({bool english = false}) async {
    final result = switch (platform) {
      PathPickerPlatform.windows => throw UnsupportedError(
        english
            ? 'Windows uses the system Open with dialog; no application file needs to be selected.'
            : 'Windows 使用系统“打开方式”窗口，不需要另选应用程序文件。',
      ),
      PathPickerPlatform.macos => await commandRunner.run('/usr/bin/osascript', [
        '-e',
        'POSIX path of (choose application with prompt "${english ? 'Choose an application to open the file' : '选择用于打开文件的应用'}")',
      ]),
      PathPickerPlatform.linux => await _runLinuxFilePicker(false, english),
      PathPickerPlatform.unsupported => throw UnsupportedError(
        english
            ? 'No system application picker is available.'
            : '当前操作系统没有可用的应用程序选择器。',
      ),
    };
    final values = _readLines(
      result,
      operation: english ? 'Choose application' : '选择应用程序',
      english: english,
    );
    return values.isEmpty ? null : values.first;
  }

  Future<ProcessResult> _runLinuxDirectoryPicker(bool english) async {
    try {
      return await commandRunner.run('zenity', [
        '--file-selection',
        '--directory',
        '--title=${english ? 'Choose a folder' : '选择文件夹'}',
      ]);
    } on ProcessException {
      try {
        return await commandRunner.run('kdialog', [
          '--getexistingdirectory',
          '.',
          '--title',
          english ? 'Choose a folder' : '选择文件夹',
        ]);
      } on ProcessException {
        throw StateError(
          english
              ? 'The system provides neither zenity nor kdialog. Enter the folder path directly.'
              : '系统未提供 zenity 或 kdialog，请直接输入文件夹路径。',
        );
      }
    }
  }

  Future<ProcessResult> _runLinuxFilePicker(
    bool multiple,
    bool english, {
    String? initialDirectory,
    List<String> allowedSuffixes = const [],
    String? filterLabel,
  }) async {
    final pattern = allowedSuffixes.map((value) => '*$value').join(' ');
    try {
      return await commandRunner.run('zenity', [
        '--file-selection',
        if (multiple) '--multiple',
        if (multiple) '--separator=\n',
        if (initialDirectory != null) '--filename=$initialDirectory/',
        if (allowedSuffixes.isNotEmpty)
          '--file-filter=${filterLabel ?? (english ? 'Allowed files' : '允许的文件')} | $pattern',
        '--title=${english ? 'Choose files' : '选择文件'}',
      ]);
    } on ProcessException {
      try {
        return await commandRunner.run('kdialog', [
          '--getopenfilename',
          initialDirectory ?? '.',
          if (allowedSuffixes.isNotEmpty) pattern,
          if (multiple) '--multiple',
          if (multiple) '--separate-output',
          '--title',
          english ? 'Choose files' : '选择文件',
        ]);
      } on ProcessException {
        throw StateError(
          english
              ? 'The system provides neither zenity nor kdialog. Enter the file path directly.'
              : '系统未提供 zenity 或 kdialog，请直接输入文件路径。',
        );
      }
    }
  }

  List<String> _readLines(
    ProcessResult result, {
    required String operation,
    required bool english,
  }) {
    if (result.exitCode == 1) return const [];
    if (result.exitCode != 0) {
      final detail = '${result.stderr}'.trim();
      throw ProcessException(
        'system-path-picker',
        const [],
        detail.isEmpty ? '$operation失败。' : detail,
        result.exitCode,
      );
    }
    final output = '${result.stdout}'.trim();
    if (output.isEmpty) return const [];
    if (platform == PathPickerPlatform.windows) {
      final decoded = jsonDecode(output);
      if (decoded is String) return [decoded];
      if (decoded is List) {
        return decoded
            .whereType<String>()
            .where((item) => item.isNotEmpty)
            .toList();
      }
      throw FormatException(
        english
            ? 'The system file picker returned invalid data.'
            : '系统文件选择器返回了无效数据。',
      );
    }
    return const LineSplitter()
        .convert(output)
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
  }

  static String _windowsDirectoryScript(bool english) =>
      '''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
\$dialog.Description = '${english ? 'Choose a folder' : '选择文件夹'}'
\$dialog.ShowNewFolderButton = \$true
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  ConvertTo-Json -Compress -InputObject \$dialog.SelectedPath
}
''';

  static String _windowsFileScript(bool multiple, bool english) =>
      '''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.OpenFileDialog
\$dialog.Title = '${english ? 'Choose files' : '选择文件'}'
\$dialog.Multiselect = \$$multiple
\$dialog.CheckFileExists = \$true
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  ConvertTo-Json -Compress -InputObject @(\$dialog.FileNames)
}
''';

  static String _macFileScript(
    bool multiple,
    bool english,
    String? initialDirectory,
  ) {
    final location = initialDirectory == null
        ? ''
        : ' default location POSIX file ${jsonEncode(initialDirectory)}';
    return multiple
        ? '''
set chosenFiles to choose file with prompt "${english ? 'Choose files' : '选择文件'}" with multiple selections allowed$location
set output to ""
repeat with chosenFile in chosenFiles
  set output to output & POSIX path of chosenFile & linefeed
end repeat
return output
'''
        : 'POSIX path of (choose file with prompt "${english ? 'Choose a file' : '选择文件'}"$location)';
  }
}

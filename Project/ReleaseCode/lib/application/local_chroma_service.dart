import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../storage/chroma_client.dart';

class LocalChromaService {
  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  final List<String> recentOutput = [];

  bool get isRunning => _process != null;

  Future<ChromaClient> start({
    required String pythonExecutable,
    required String serviceScript,
    required String dataDirectory,
    required String workingDirectory,
  }) async {
    if (_process != null) {
      throw StateError('The local vector service is already running.');
    }
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final process = await Process.start(
      pythonExecutable,
      [serviceScript, '--data-dir', dataDirectory, '--port', '$port'],
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    _process = process;
    _stdout = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_record);
    _stderr = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_record);
    final client = ChromaClient(baseUri: Uri.parse('http://127.0.0.1:$port'));
    Object? lastError;
    for (var attempt = 0; attempt < 60; attempt++) {
      if (_process == null) break;
      try {
        await client.count();
        return client;
      } catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    client.close();
    await stop();
    throw StateError(
      'The local vector service did not become ready. $lastError '
      '${recentOutput.join(' | ')}',
    );
  }

  void _record(String line) {
    if (line.trim().isEmpty) return;
    recentOutput.add(line);
    if (recentOutput.length > 30) recentOutput.removeAt(0);
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
    }
    await _stdout?.cancel();
    await _stderr?.cancel();
    _stdout = null;
    _stderr = null;
  }
}

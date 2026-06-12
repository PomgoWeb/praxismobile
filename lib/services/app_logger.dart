import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class AppLogger {
  AppLogger();

  static const String fileName = 'rsapp.log';

  final List<String> _buffer = <String>[];
  File? _logFile;
  bool _ready = false;
  bool _initInProgress = false;
  bool _flushInProgress = false;
  int _retryCount = 0;
  Timer? _retryTimer;

  Future<void> init() async {
    await _ensureReady();
  }

  void log(
    String message, {
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    _record('INFO', message, details: details);
  }

  void logError(String scope, Object error, [StackTrace? stackTrace]) {
    _record('ERROR', scope, error: error, stackTrace: stackTrace);
  }

  Future<String> getLogFilePath() async {
    await _ensureReady();
    return _logFile?.path ?? '';
  }

  Future<String> writeDiagnosticFile(String fileName, String contents) async {
    await _ensureReady();
    if (_logFile == null) return '';

    try {
      final Directory parentDir = _logFile!.parent;
      final File diagnosticFile = File(
        '${parentDir.path}${Platform.pathSeparator}$fileName',
      );
      await diagnosticFile.writeAsString(
        contents,
        mode: FileMode.write,
        encoding: utf8,
        flush: true,
      );
      return diagnosticFile.path;
    } catch (error, stackTrace) {
      _debugFallback(
        _formatLine(
          'ERROR',
          'logger.write_diagnostic_file_failed',
          details: <String, Object?>{'fileName': fileName},
          error: error,
          stackTrace: stackTrace,
        ),
      );
      return '';
    }
  }

  Future<String> getDiagnosticFilePath(String fileName) async {
    await _ensureReady();
    if (_logFile == null) return '';
    return '${_logFile!.parent.path}${Platform.pathSeparator}$fileName';
  }

  Future<String> readDiagnosticFile(String fileName) async {
    final String path = await getDiagnosticFilePath(fileName);
    if (path.isEmpty) return '';

    try {
      final File diagnosticFile = File(path);
      if (!await diagnosticFile.exists()) return '';
      return await diagnosticFile.readAsString(encoding: utf8);
    } catch (error, stackTrace) {
      _debugFallback(
        _formatLine(
          'ERROR',
          'logger.read_diagnostic_file_failed',
          details: <String, Object?>{'fileName': fileName},
          error: error,
          stackTrace: stackTrace,
        ),
      );
      return '';
    }
  }

  Future<String> readContents() async {
    await _ensureReady();
    if (_logFile == null) return '';

    try {
      return await _logFile!.readAsString(encoding: utf8);
    } catch (error, stackTrace) {
      _debugFallback(
        _formatLine(
          'ERROR',
          'logger.read_contents_failed',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      return '';
    }
  }

  Future<String> readTail({int maxLines = 200}) async {
    final String contents = await readContents();
    if (contents.isEmpty) return '';

    final List<String> lines = const LineSplitter()
        .convert(contents)
        .where((String line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length <= maxLines) {
      return lines.join('\n');
    }
    return lines.sublist(lines.length - maxLines).join('\n');
  }

  void _record(
    String level,
    String message, {
    Map<String, Object?> details = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {
    final String line = _formatLine(
      level,
      message,
      details: details,
      error: error,
      stackTrace: stackTrace,
    );

    _debugFallback(line);

    _buffer.add(line);
    unawaited(_flushBuffer());
    if (!_ready) {
      unawaited(_ensureReady());
    }
  }

  String _formatLine(
    String level,
    String message, {
    Map<String, Object?> details = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {
    final String timestamp = DateTime.now().toIso8601String();
    final StringBuffer buffer = StringBuffer('$timestamp [$level] $message');

    if (details.isNotEmpty) {
      buffer.write(' details=');
      buffer.write(jsonEncode(details));
    }
    if (error != null) {
      buffer.write(' error="');
      buffer.write(error.toString().replaceAll('"', "'"));
      buffer.write('"');
    }
    if (stackTrace != null) {
      buffer.write(' stack="');
      buffer.write(
        stackTrace.toString().replaceAll('"', "'").replaceAll('\n', ' | '),
      );
      buffer.write('"');
    }

    return buffer.toString();
  }

  Future<void> _ensureReady() async {
    if (_ready || _initInProgress) return;
    _initInProgress = true;

    try {
      final Directory documentsDir = await getApplicationDocumentsDirectory();
      final Directory visibleDir = Directory(documentsDir.path);
      if (!await visibleDir.exists()) {
        await visibleDir.create(recursive: true);
      }

      _logFile = File('${visibleDir.path}${Platform.pathSeparator}$fileName');
      if (!await _logFile!.exists()) {
        await _logFile!.create(recursive: true);
      }

      _ready = true;
      _retryCount = 0;
      _retryTimer?.cancel();
      _debugFallback(
        _formatLine(
          'INFO',
          'logger.init_ok',
          details: <String, Object?>{'path': _logFile!.path},
        ),
      );
      await _flushBuffer();
    } catch (error, stackTrace) {
      _debugFallback(
        _formatLine(
          'ERROR',
          'logger.init_failed',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      _scheduleRetry();
    } finally {
      _initInProgress = false;
    }
  }

  void _scheduleRetry() {
    if (_retryTimer?.isActive ?? false) return;
    _retryCount += 1;
    final int delaySeconds = _retryCount < 5 ? 1 : 3;
    _retryTimer = Timer(Duration(seconds: delaySeconds), () {
      unawaited(_ensureReady());
    });
  }

  Future<void> _flushBuffer() async {
    if (!_ready || _logFile == null || _buffer.isEmpty || _flushInProgress) {
      return;
    }

    _flushInProgress = true;
    final List<String> pendingLines = List<String>.from(_buffer);
    final String payload = '${pendingLines.join('\n')}\n';

    try {
      await _logFile!.writeAsString(
        payload,
        mode: FileMode.append,
        encoding: utf8,
        flush: true,
      );
      _buffer.removeRange(0, pendingLines.length);
    } catch (error, stackTrace) {
      _debugFallback(
        _formatLine(
          'ERROR',
          'logger.flush_failed',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      _ready = false;
      _scheduleRetry();
    } finally {
      _flushInProgress = false;
      if (_ready && _buffer.isNotEmpty) {
        unawaited(_flushBuffer());
      }
    }
  }

  void _debugFallback(String line) {
    debugPrint(line);
  }
}

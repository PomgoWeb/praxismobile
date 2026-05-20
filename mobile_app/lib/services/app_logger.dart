import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class AppLogger {
  File? _logFile;
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    final Directory dir = await getApplicationDocumentsDirectory();
    _logFile = File('${dir.path}${Platform.pathSeparator}rsapp.log');
    if (!await _logFile!.exists()) {
      await _logFile!.create(recursive: true);
    }
    _ready = true;
  }

  void log(
    String event, {
    Map<String, Object?> details = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {
    unawaited(
      _write(event, details: details, error: error, stackTrace: stackTrace),
    );
  }

  Future<void> _write(
    String event, {
    required Map<String, Object?> details,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    final Map<String, Object?> payload = <String, Object?>{
      'ts': DateTime.now().toIso8601String(),
      'event': event,
      'details': details,
      if (error != null) 'error': error.toString(),
      if (stackTrace != null) 'stack': stackTrace.toString(),
    };
    final String line = jsonEncode(payload);

    if (kDebugMode) {
      // ignore: avoid_print
      print(line);
    }

    if (!_ready || _logFile == null) return;
    try {
      await _logFile!.writeAsString(
        '$line\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (_) {
      // Never block app execution because of logging issues.
    }
  }
}

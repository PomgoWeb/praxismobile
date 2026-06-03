import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_logger.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String _logs = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() {
      _loading = true;
    });

    final AppLogger logger = context.read<AppLogger>();
    final String logs = await logger.readTail(maxLines: 250);

    if (!mounted) return;
    setState(() {
      _logs = logs;
      _loading = false;
    });
  }

  Future<void> _copyLogs() async {
    await Clipboard.setData(ClipboardData(text: _logs));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Logs copiés dans le presse-papiers')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: <Widget>[
          IconButton(
            onPressed: _loading ? null : _loadLogs,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Rafraîchir',
          ),
          IconButton(
            onPressed: (_loading || _logs.isEmpty) ? null : _copyLogs,
            icon: const Icon(Icons.copy_rounded),
            tooltip: 'Copier',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _logs.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Aucun log disponible pour le moment.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                _logs,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ),
    );
  }
}

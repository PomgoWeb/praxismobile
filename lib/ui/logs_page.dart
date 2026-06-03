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
  String _logFilePath = '';
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
    final String logFilePath = await logger.getLogFilePath();

    if (!mounted) return;
    setState(() {
      _logs = logs;
      _logFilePath = logFilePath;
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
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Aucun log disponible pour le moment.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  _LogLocation(filePath: _logFilePath),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _LogLocation(filePath: _logFilePath),
                const SizedBox(height: 16),
                SelectableText(
                  _logs,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.45,
                  ),
                ),
              ],
            ),
    );
  }
}

class _LogLocation extends StatelessWidget {
  const _LogLocation({required this.filePath});

  final String filePath;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF4F7F9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Fichier accessible sur iPhone',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text('Fichiers > Sur mon iPhone > Praxis > rsapp.log'),
            if (filePath.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              SelectableText(
                filePath,
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

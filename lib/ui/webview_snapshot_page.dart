import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_logger.dart';

class WebViewSnapshotPage extends StatefulWidget {
  const WebViewSnapshotPage({super.key});

  @override
  State<WebViewSnapshotPage> createState() => _WebViewSnapshotPageState();
}

class _WebViewSnapshotPageState extends State<WebViewSnapshotPage> {
  static const String _snapshotFileName = 'rsapp-webview-snapshot.json';

  String _contents = '';
  String _filePath = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSnapshot();
  }

  Future<void> _loadSnapshot() async {
    setState(() {
      _loading = true;
    });

    final AppLogger logger = context.read<AppLogger>();
    final String contents = await logger.readDiagnosticFile(_snapshotFileName);
    final String filePath = await logger.getDiagnosticFilePath(
      _snapshotFileName,
    );

    if (!mounted) return;
    setState(() {
      _contents = contents;
      _filePath = filePath;
      _loading = false;
    });
  }

  Future<void> _copySnapshot() async {
    await Clipboard.setData(ClipboardData(text: _contents));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Snapshot HTML copié dans le presse-papiers'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Snapshot HTML'),
        actions: <Widget>[
          IconButton(
            onPressed: _loading ? null : _loadSnapshot,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Rafraîchir',
          ),
          IconButton(
            onPressed: (_loading || _contents.isEmpty) ? null : _copySnapshot,
            icon: const Icon(Icons.copy_rounded),
            tooltip: 'Copier',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _contents.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Aucun snapshot HTML disponible pour le moment.'),
                  const SizedBox(height: 8),
                  const Text(
                    'Ouvre une page dans la WebView, puis reviens ici et appuie sur rafraîchir.',
                  ),
                  const SizedBox(height: 16),
                  _SnapshotLocation(filePath: _filePath),
                ],
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _SnapshotLocation(filePath: _filePath),
                const SizedBox(height: 12),
                Text(
                  '${_contents.length} caractères',
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  _contents,
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

class _SnapshotLocation extends StatelessWidget {
  const _SnapshotLocation({required this.filePath});

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
              'Fichier diagnostic',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text('rsapp-webview-snapshot.json'),
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

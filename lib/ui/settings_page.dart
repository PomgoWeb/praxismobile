import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../models/app_state.dart';
import '../services/app_logger.dart';
import 'logs_page.dart';
import 'webview_snapshot_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _versionLabel = 'N/A';

  @override
  void initState() {
    super.initState();
    _loadVersionLabel();
  }

  Future<void> _loadVersionLabel() async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _versionLabel = '${packageInfo.version} (${packageInfo.buildNumber})';
      });
    } on Exception catch (error, stackTrace) {
      if (!mounted) return;
      context.read<AppLogger>().logError(
        'settings_package_info_error',
        error,
        stackTrace,
      );
      setState(() {
        _versionLabel = 'Indisponible';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppState appState = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Paramètres')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          ListTile(title: const Text('Application'), subtitle: Text(kAppName)),
          ListTile(title: const Text('Version'), subtitle: Text(_versionLabel)),
          ListTile(title: const Text('URL de base'), subtitle: Text(kBaseUrl)),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: const Text('Logs'),
            subtitle: const Text(
              'Afficher les logs techniques et les copier pour le support.',
            ),
            onTap: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => const LogsPage()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.code_rounded),
            title: const Text('Snapshot HTML WebView'),
            subtitle: const Text(
              'Afficher le JSON contenant le HTML de la page et le copier.',
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const WebViewSnapshotPage(),
                ),
              );
            },
          ),
          SwitchListTile(
            value: appState.notificationsEnabled,
            onChanged: null,
            title: const Text('Notifications activées'),
            subtitle: const Text(
              'État détecté lors de la dernière demande de permission.',
            ),
          ),
        ],
      ),
    );
  }
}

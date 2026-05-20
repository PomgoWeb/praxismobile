import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config/app_config.dart';
import 'models/app_state.dart';
import 'services/app_logger.dart';
import 'services/push_service.dart';
import 'ui/settings_page.dart';
import 'webview/app_webview.dart';

const Color _kBrandNavy = Color(0xFF06263F);
const Color _kBrandOrange = Color(0xFFFF4A00);
const Color _kBrandLight = Color(0xFFE8EEF3);
const Color _kBrandWhite = Color(0xFFFFFFFF);

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final Connectivity _connectivity;
  final GlobalKey _webViewKey = GlobalKey();
  PushService? _pushService;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _pushStarted = false;

  @override
  void initState() {
    super.initState();
    _connectivity = Connectivity();
    _startConnectivityListener();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pushStarted) return;
    _pushStarted = true;
    _pushService = context.read<PushService>();
    unawaited(_startPush());
  }

  @override
  void dispose() {
    unawaited(_connectivitySub?.cancel());
    unawaited(_pushService?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppState appState = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text(kAppName),
        actions: <Widget>[
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_rounded),
            tooltip: 'Paramètres',
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          AppWebView(key: _webViewKey),
          if (appState.isOffline)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: _OfflineView(onRetry: _retryConnectivityCheck),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: const BoxDecoration(
            color: _kBrandLight,
            border: Border(top: BorderSide(color: Color(0xFFD0D8DE))),
          ),
          child: Row(
            children: kMenuDestinations.map((MenuDestination destination) {
              final bool selected = appState.currentPath == destination.path;
              return Expanded(
                child: _ActionItem(
                  destination: destination,
                  selected: selected,
                  onTap: () =>
                      context.read<AppState>().navigateToPath(destination.path),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Future<void> _startPush() async {
    final AppLogger logger = context.read<AppLogger>();
    final PushService pushService = _pushService!;
    final AppState appState = context.read<AppState>();
    try {
      await pushService.initialize(appState);
      logger.log('push_ready');
    } on Exception catch (error, stackTrace) {
      logger.log('push_init_error', error: error, stackTrace: stackTrace);
    }
  }

  void _startConnectivityListener() {
    _connectivitySub = _connectivity.onConnectivityChanged.listen((
      List<ConnectivityResult> status,
    ) {
      if (!mounted) return;
      context.read<AppState>().updateConnectivity(status);
    });
  }

  Future<void> _retryConnectivityCheck() async {
    final List<ConnectivityResult> current = await _connectivity
        .checkConnectivity();
    if (!mounted) return;
    context.read<AppState>().updateConnectivity(current);
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
  }
}

class _ActionItem extends StatelessWidget {
  const _ActionItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final MenuDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = selected ? _kBrandOrange : _kBrandNavy;
    final FontWeight weight = selected ? FontWeight.w700 : FontWeight.w600;

    return Material(
      color: _kBrandWhite,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(destination.icon, color: color),
              const SizedBox(height: 4),
              Text(
                destination.label,
                style: TextStyle(
                  color: color,
                  fontWeight: weight,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineView extends StatelessWidget {
  const _OfflineView({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.wifi_off_rounded, size: 64),
            const SizedBox(height: 12),
            const Text(
              'Connexion indisponible',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Vérifie le réseau puis relance le chargement.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Réessayer')),
          ],
        ),
      ),
    );
  }
}

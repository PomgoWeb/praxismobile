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
    final int matchedIndex = kMenuDestinations.indexWhere(
      (MenuDestination e) => e.path == appState.currentPath,
    );
    final int currentIndex = matchedIndex < 0 ? 0 : matchedIndex;

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
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: _kBrandNavy,
          indicatorColor: _kBrandLight,
          labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>((
            Set<WidgetState> states,
          ) {
            final Color color = states.contains(WidgetState.selected)
                ? _kBrandOrange
                : _kBrandLight;
            return TextStyle(color: color, fontWeight: FontWeight.w600);
          }),
          iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>((
            Set<WidgetState> states,
          ) {
            final Color color = states.contains(WidgetState.selected)
                ? _kBrandOrange
                : _kBrandLight;
            return IconThemeData(color: color);
          }),
        ),
        child: NavigationBar(
          selectedIndex: currentIndex,
          onDestinationSelected: (int index) {
            final MenuDestination destination = kMenuDestinations[index];
            context.read<AppState>().navigateToPath(destination.path);
          },
          destinations: kMenuDestinations
              .map(
                (MenuDestination d) =>
                    NavigationDestination(icon: Icon(d.icon), label: d.label),
              )
              .toList(),
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

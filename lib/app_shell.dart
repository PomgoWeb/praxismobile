import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config/app_config.dart';
import 'models/app_state.dart';
import 'services/app_logger.dart';
import 'services/push_service.dart';
import 'services/wp_api.dart';
import 'ui/settings_page.dart';
import 'webview/app_webview.dart';

const Color _kBrandNavy = Color(0xFF06263F);
const Color _kBrandOrange = Color(0xFFC10F00);
const Color _kActionBarBg = Color(0xFFFFFFFF);

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
  bool _loggedFirstBuild = false;
  Timer? _pushStartTimer;

  @override
  void initState() {
    super.initState();
    _connectivity = Connectivity();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppLogger>().log('app_shell_init_state');
    });
    _startConnectivityListener();
  }

  @override
  void dispose() {
    unawaited(_connectivitySub?.cancel());
    _pushStartTimer?.cancel();
    unawaited(_pushService?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppState appState = context.watch<AppState>();
    if (!_loggedFirstBuild) {
      _loggedFirstBuild = true;
      context.read<AppLogger>().log('app_shell_first_build');
    }
    _ensurePushStarted(appState);
    final double bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 34,
        titleSpacing: 8,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Image.asset('assets/icon/app_logo.png', height: 16),
            const SizedBox(width: 6),
            const Text(kAppName, style: TextStyle(fontSize: 14, height: 1)),
          ],
        ),
        actions: <Widget>[
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_rounded, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            visualDensity: VisualDensity.compact,
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
      bottomNavigationBar: Container(
        padding: EdgeInsets.fromLTRB(8, 6, 8, 6 + bottomInset),
        decoration: const BoxDecoration(
          color: _kActionBarBg,
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
    );
  }

  Future<void> _startPush() async {
    final AppLogger logger = context.read<AppLogger>();
    final WpApi wpApi = context.read<WpApi>();
    final AppState appState = context.read<AppState>();
    try {
      if (_pushService == null) {
        logger.log('push_service_create_start');
        _pushService = PushService(logger: logger, wpApi: wpApi);
        logger.log('push_service_created');
      }
      final PushService pushService = _pushService!;
      logger.log('push_init_start');
      await pushService.initialize(appState);
      logger.log('push_ready');
    } catch (error, stackTrace) {
      logger.logError('push_init_error', error, stackTrace);
    }
  }

  void _ensurePushStarted(AppState appState) {
    if (_pushStarted || !appState.bootstrapComplete) return;
    _pushStarted = true;
    context.read<AppLogger>().log('push_init_scheduled');
    _pushStartTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      unawaited(_startPush());
    });
  }

  void _startConnectivityListener() {
    context.read<AppLogger>().log('connectivity_listener_start');
    _connectivitySub = _connectivity.onConnectivityChanged.listen((
      List<ConnectivityResult> status,
    ) {
      if (!mounted) return;
      context.read<AppLogger>().log(
        'connectivity_listener_event',
        details: <String, Object?>{
          'status': status.map((ConnectivityResult e) => e.name).join(','),
        },
      );
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
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        splashColor: _kBrandNavy.withValues(alpha: 0.08),
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(destination.icon, color: color, size: 20),
              const SizedBox(height: 3),
              Text(
                destination.label,
                style: TextStyle(
                  color: color,
                  fontWeight: weight,
                  fontSize: 11,
                  height: 1,
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

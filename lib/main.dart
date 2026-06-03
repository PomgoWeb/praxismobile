import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_shell.dart';
import 'config/app_config.dart';
import 'models/app_state.dart';
import 'services/app_logger.dart';
import 'services/push_service.dart';
import 'services/wp_api.dart';

const Color _kBrandNavy = Color(0xFF06263F);
const Color _kBrandLight = Color(0xFFE8EEF3);

Future<void> main() async {
  final AppLogger logger = AppLogger();
  logger.log('main_enter');

  WidgetsFlutterBinding.ensureInitialized();
  logger.log('widgets_flutter_binding_ready');

  unawaited(logger.init());
  logger.log('logger_init_requested');

  final AppState appState = AppState(
    prefs: null,
    initialConnectivity: const <ConnectivityResult>[],
  );
  logger.log('app_state_created');
  final WpApi wpApi = WpApi(logger: logger);
  logger.log('wp_api_created');
  final PushService pushService = PushService(logger: logger, wpApi: wpApi);
  logger.log('push_service_created');

  logger.log('run_app_before');
  runApp(
    MultiProvider(
      providers: [
        Provider<AppLogger>.value(value: logger),
        Provider<WpApi>.value(value: wpApi),
        Provider<PushService>.value(value: pushService),
        ChangeNotifierProvider<AppState>.value(value: appState),
      ],
      child: const PraxisMediaApp(),
    ),
  );
  logger.log('run_app_after');

  unawaited(_bootstrapApplication(logger: logger, appState: appState));
}

Future<void> _bootstrapApplication({
  required AppLogger logger,
  required AppState appState,
}) async {
  SharedPreferences? prefs;
  List<ConnectivityResult> initialConnectivity = const <ConnectivityResult>[];

  try {
    logger.log('logger_init_wait_start');
    await logger.init().timeout(const Duration(seconds: 2));
    logger.log('logger_init_wait_done');
  } catch (error, stackTrace) {
    logger.logError('logger_init_wait_failed', error, stackTrace);
  }

  logger.log('bootstrap_start');

  try {
    logger.log('firebase_init_start');
    await Firebase.initializeApp().timeout(const Duration(seconds: 5));
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    logger.log('firebase_init_ok');
  } catch (error, stackTrace) {
    logger.logError('firebase_init_error', error, stackTrace);
  }

  try {
    logger.log('prefs_init_start');
    prefs = await SharedPreferences.getInstance().timeout(
      const Duration(seconds: 3),
    );
    logger.log('prefs_init_ok');
  } catch (error, stackTrace) {
    logger.logError('prefs_init_error', error, stackTrace);
  }

  try {
    logger.log('connectivity_init_start');
    initialConnectivity = await Connectivity().checkConnectivity().timeout(
      const Duration(seconds: 3),
    );
    logger.log(
      'connectivity_init_ok',
      details: <String, Object?>{
        'status': initialConnectivity
            .map((ConnectivityResult e) => e.name)
            .join(','),
      },
    );
  } catch (error, stackTrace) {
    logger.logError('connectivity_init_error', error, stackTrace);
  }

  try {
    logger.log('app_state_hydrate_start');
    await appState
        .hydrateFromPrefs(prefs: prefs)
        .timeout(const Duration(seconds: 2));
    appState.updateConnectivity(initialConnectivity);
    logger.log('app_state_hydrate_ok');
  } catch (error, stackTrace) {
    logger.logError('app_state_hydrate_error', error, stackTrace);
  } finally {
    appState.markBootstrapComplete();
    logger.log('bootstrap_ready');
  }
}

class PraxisMediaApp extends StatelessWidget {
  const PraxisMediaApp({super.key});

  static bool _loggedFirstBuild = false;

  @override
  Widget build(BuildContext context) {
    if (!_loggedFirstBuild) {
      _loggedFirstBuild = true;
      context.read<AppLogger>().log('app_widget_first_build');
    }
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: _kBrandNavy),
        scaffoldBackgroundColor: _kBrandLight,
        appBarTheme: const AppBarTheme(
          backgroundColor: _kBrandLight,
          foregroundColor: _kBrandNavy,
        ),
        useMaterial3: true,
      ),
      home: const AppShell(),
    );
  }
}

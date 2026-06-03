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
  WidgetsFlutterBinding.ensureInitialized();

  final AppLogger logger = AppLogger();
  final AppState appState = AppState(
    prefs: null,
    initialConnectivity: const <ConnectivityResult>[],
  );
  final WpApi wpApi = WpApi(logger: logger);
  final PushService pushService = PushService(logger: logger, wpApi: wpApi);

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

  unawaited(_bootstrapApplication(logger: logger, appState: appState));
}

Future<void> _bootstrapApplication({
  required AppLogger logger,
  required AppState appState,
}) async {
  SharedPreferences? prefs;
  List<ConnectivityResult> initialConnectivity = const <ConnectivityResult>[];

  try {
    await logger.init();
  } catch (_) {
    // Logger init is non-critical for app startup.
  }

  logger.log('bootstrap_start');

  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } on Exception catch (error, stackTrace) {
    logger.log('firebase_init_error', error: error, stackTrace: stackTrace);
  }

  try {
    prefs = await SharedPreferences.getInstance();
  } on Exception catch (error, stackTrace) {
    logger.log('prefs_init_error', error: error, stackTrace: stackTrace);
  }

  try {
    initialConnectivity = await Connectivity().checkConnectivity();
  } on Exception catch (error, stackTrace) {
    logger.log('connectivity_init_error', error: error, stackTrace: stackTrace);
  }

  await appState.hydrateFromPrefs(prefs: prefs);
  appState.updateConnectivity(initialConnectivity);
  appState.markBootstrapComplete();

  logger.log('bootstrap_ready');
}

class PraxisMediaApp extends StatelessWidget {
  const PraxisMediaApp({super.key});

  @override
  Widget build(BuildContext context) {
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

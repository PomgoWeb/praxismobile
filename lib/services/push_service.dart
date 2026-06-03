import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_state.dart';
import 'app_logger.dart';
import 'wp_api.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {
    // Background isolate must never crash on Firebase re-init.
  }
}

class PushService {
  PushService({required AppLogger logger, required WpApi wpApi})
    : _logger = logger,
      _wpApi = wpApi;

  final AppLogger _logger;
  final WpApi _wpApi;
  FirebaseMessaging? _messaging;
  FlutterLocalNotificationsPlugin? _localNotifications;

  StreamSubscription<String>? _tokenRefreshSub;
  bool _initialized = false;

  FirebaseMessaging get _messagingInstance {
    if (_messaging != null) return _messaging!;
    _logger.log('push_messaging_instance_start');
    _messaging = FirebaseMessaging.instance;
    _logger.log('push_messaging_instance_ready');
    return _messaging!;
  }

  FlutterLocalNotificationsPlugin get _localNotificationsInstance {
    if (_localNotifications != null) return _localNotifications!;
    _logger.log('push_local_notifications_instance_start');
    _localNotifications = FlutterLocalNotificationsPlugin();
    _logger.log('push_local_notifications_instance_ready');
    return _localNotifications!;
  }

  Future<void> initialize(AppState appState) async {
    if (_initialized) return;
    _initialized = true;

    try {
      _logger.log('push_initialize_enter');
      await _initLocalNotifications(appState);
      await _requestNotificationPermissions(appState);
      await _registerCurrentToken(appState);

      _tokenRefreshSub = _messagingInstance.onTokenRefresh.listen(
        (String token) =>
            _registerTokenToWordPress(token: token, appState: appState),
        onError: (Object error, StackTrace stackTrace) {
          _logger.logError('push_register_error', error, stackTrace);
        },
      );

      FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
        _logger.log('push_on_message');
        await _showForegroundNotification(message);
      });

      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        _logger.log('push_on_message_opened');
        _handleMessageNavigation(message, appState);
      });

      final RemoteMessage? initialMessage = await _messagingInstance
          .getInitialMessage();
      if (initialMessage != null) {
        _logger.log('push_get_initial_message');
        _handleMessageNavigation(initialMessage, appState);
      }
    } on Exception catch (error, stackTrace) {
      _logger.logError('push_init_error', error, stackTrace);
    }
  }

  Future<void> dispose() async {
    await _tokenRefreshSub?.cancel();
  }

  Future<void> _initLocalNotifications(AppState appState) async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings();

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _localNotificationsInstance.initialize(
      settings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final String? payload = response.payload;
        if (payload == null || payload.isEmpty) return;
        appState.navigateFromPushPayload(payload);
      },
    );
  }

  Future<void> _requestNotificationPermissions(AppState appState) async {
    await appState.setNotificationPrompted(true);

    bool permissionGranted = false;
    if (Platform.isIOS) {
      final NotificationSettings settings = await _messagingInstance
          .requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      permissionGranted =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;

      final IOSFlutterLocalNotificationsPlugin? iosPlatform =
          _localNotificationsInstance
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >();
      await iosPlatform?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
    } else if (Platform.isAndroid) {
      final AndroidFlutterLocalNotificationsPlugin? androidPlatform =
          _localNotificationsInstance
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >();
      final bool? granted = await androidPlatform
          ?.requestNotificationsPermission();
      permissionGranted = granted ?? false;
    }

    await appState.setNotificationEnabled(permissionGranted);
  }

  Future<void> _registerCurrentToken(AppState appState) async {
    try {
      final String? token = await _messagingInstance.getToken();
      if (token == null || token.trim().isEmpty) return;
      await _registerTokenToWordPress(token: token, appState: appState);
    } on Exception catch (error, stackTrace) {
      _logger.logError('push_register_error', error, stackTrace);
    }
  }

  Future<void> _registerTokenToWordPress({
    required String token,
    required AppState appState,
  }) async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      await _wpApi.registerToken(
        token: token,
        platform: Platform.isIOS ? 'ios' : 'android',
        locale: Platform.localeName,
        appVersion: '${packageInfo.version}+${packageInfo.buildNumber}',
      );
      _logger.log('push_register_token_ok');
    } on Exception catch (error, stackTrace) {
      _logger.logError('push_register_error', error, stackTrace);
    }
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    final String title = message.notification?.title ?? 'PraxisMedia';
    final String body = message.notification?.body ?? '';
    final String payload = message.data['url']?.toString() ?? '';

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'rsapp_default_channel',
          'PraxisMedia Notifications',
          channelDescription: 'Foreground notifications',
          importance: Importance.high,
          priority: Priority.high,
        );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails();

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _localNotificationsInstance.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: payload,
    );
  }

  void _handleMessageNavigation(RemoteMessage message, AppState appState) {
    final String? url = message.data['url']?.toString();
    if (url == null || url.trim().isEmpty) return;
    appState.navigateFromPushPayload(url);
  }
}

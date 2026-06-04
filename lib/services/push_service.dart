import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../firebase_options.dart';
import '../models/app_state.dart';
import 'app_logger.dart';
import 'wp_api.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
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
  Timer? _tokenRetryTimer;
  bool _initialized = false;

  FirebaseMessaging? _ensureMessaging() {
    if (_messaging != null) return _messaging;
    _logger.log('push_messaging_instance_start');
    try {
      _messaging = FirebaseMessaging.instance;
      _logger.log('push_messaging_instance_ready');
      return _messaging;
    } catch (error, stackTrace) {
      _logger.logError('push_messaging_instance_error', error, stackTrace);
      return null;
    }
  }

  FlutterLocalNotificationsPlugin? _ensureLocalNotifications() {
    if (_localNotifications != null) return _localNotifications;
    _logger.log('push_local_notifications_instance_start');
    try {
      _localNotifications = FlutterLocalNotificationsPlugin();
      _logger.log('push_local_notifications_instance_ready');
      return _localNotifications;
    } catch (error, stackTrace) {
      _logger.logError(
        'push_local_notifications_instance_error',
        error,
        stackTrace,
      );
      return null;
    }
  }

  Future<void> initialize(AppState appState) async {
    if (_initialized) return;
    _initialized = true;

    try {
      _logger.log('push_initialize_enter');
      final FirebaseMessaging? messaging = _ensureMessaging();
      if (messaging == null) {
        _logger.log('push_initialize_aborted_no_messaging');
        return;
      }
      await _initLocalNotifications(appState);
      await _requestNotificationPermissions(appState);
      await _registerCurrentToken(appState);

      _tokenRefreshSub = messaging.onTokenRefresh.listen(
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

      final RemoteMessage? initialMessage = await messaging.getInitialMessage();
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
    _tokenRetryTimer?.cancel();
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

    final FlutterLocalNotificationsPlugin? localNotifications =
        _ensureLocalNotifications();
    if (localNotifications == null) {
      _logger.log('push_local_notifications_unavailable');
      return;
    }

    await localNotifications.initialize(
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
    final FirebaseMessaging? messaging = _ensureMessaging();
    if (messaging == null) {
      _logger.log('push_permissions_skipped_no_messaging');
      await appState.setNotificationEnabled(false);
      return;
    }

    if (Platform.isIOS) {
      final NotificationSettings settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      _logger.log(
        'push_permission_status',
        details: <String, Object?>{
          'platform': 'ios',
          'status': settings.authorizationStatus.name,
        },
      );
      permissionGranted =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;

      final FlutterLocalNotificationsPlugin? localNotifications =
          _ensureLocalNotifications();
      final IOSFlutterLocalNotificationsPlugin? iosPlatform =
          localNotifications?.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      await iosPlatform?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
    } else if (Platform.isAndroid) {
      final FlutterLocalNotificationsPlugin? localNotifications =
          _ensureLocalNotifications();
      final AndroidFlutterLocalNotificationsPlugin? androidPlatform =
          localNotifications?.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      final bool? granted = await androidPlatform
          ?.requestNotificationsPermission();
      permissionGranted = granted ?? false;
      _logger.log(
        'push_permission_status',
        details: <String, Object?>{
          'platform': 'android',
          'granted': permissionGranted,
        },
      );
    }

    await appState.setNotificationEnabled(permissionGranted);
  }

  Future<void> _registerCurrentToken(AppState appState) async {
    try {
      final FirebaseMessaging? messaging = _ensureMessaging();
      if (messaging == null) {
        _logger.log('push_register_skipped_no_messaging');
        return;
      }
      if (Platform.isIOS) {
        final String? apnsToken = await messaging.getAPNSToken();
        _logger.log(
          'push_apns_token_state',
          details: <String, Object?>{
            'available': apnsToken != null && apnsToken.trim().isNotEmpty,
          },
        );
      }

      final String? token = await messaging.getToken();
      if (token == null || token.trim().isEmpty) {
        _logger.log('push_token_empty');
        _scheduleTokenRetry(appState);
        return;
      }
      await _registerTokenToWordPress(token: token, appState: appState);
    } on Exception catch (error, stackTrace) {
      _logger.logError('push_register_error', error, stackTrace);
      _scheduleTokenRetry(appState);
    }
  }

  Future<void> _registerTokenToWordPress({
    required String token,
    required AppState appState,
  }) async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final bool registered = await _wpApi.registerToken(
        token: token,
        platform: Platform.isIOS ? 'ios' : 'android',
        locale: Platform.localeName,
        appVersion: '${packageInfo.version}+${packageInfo.buildNumber}',
      );
      if (!registered) {
        _logger.log(
          'push_register_token_failed',
          details: <String, Object?>{'length': token.length},
        );
        _scheduleTokenRetry(appState);
        return;
      }
      _tokenRetryTimer?.cancel();
      _logger.log(
        'push_register_token_ok',
        details: <String, Object?>{'length': token.length},
      );
    } on Exception catch (error, stackTrace) {
      _logger.logError('push_register_error', error, stackTrace);
      _scheduleTokenRetry(appState);
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

    final FlutterLocalNotificationsPlugin? localNotifications =
        _ensureLocalNotifications();
    if (localNotifications == null) {
      _logger.log('push_foreground_notification_skipped_no_plugin');
      return;
    }

    await localNotifications.show(
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

  void _scheduleTokenRetry(AppState appState) {
    if (_tokenRetryTimer?.isActive ?? false) return;
    _logger.log('push_token_retry_scheduled');
    _tokenRetryTimer = Timer(const Duration(seconds: 5), () {
      unawaited(_registerCurrentToken(appState));
    });
  }
}

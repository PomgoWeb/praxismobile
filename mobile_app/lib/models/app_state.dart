import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../utils/url_utils.dart';

class AppState extends ChangeNotifier {
  AppState({
    required SharedPreferences? prefs,
    required List<ConnectivityResult> initialConnectivity,
  }) : _prefs = prefs,
       _isOffline = initialConnectivity.contains(ConnectivityResult.none);

  final SharedPreferences? _prefs;

  bool _isOffline;
  bool _webViewReady = false;
  String _currentPath = '/';
  String _lastLoadedUrl = buildUrl(kBaseUrl, '/').toString();
  int _navRequestId = 0;
  String? _requestedUrl;
  bool _notificationsPrompted = false;
  bool _notificationsEnabled = false;

  bool get isOffline => _isOffline;
  bool get webViewReady => _webViewReady;
  String get currentPath => _currentPath;
  String get lastLoadedUrl => _lastLoadedUrl;
  int get navRequestId => _navRequestId;
  String? get requestedUrl => _requestedUrl;
  bool get notificationsPrompted => _notificationsPrompted;
  bool get notificationsEnabled => _notificationsEnabled;

  Future<void> hydrateFromPrefs() async {
    _notificationsPrompted = _prefs?.getBool('notificationsPrompted') ?? false;
    _notificationsEnabled = _prefs?.getBool('notificationsEnabled') ?? false;
    notifyListeners();
  }

  void updateConnectivity(List<ConnectivityResult> status) {
    final bool offline = status.contains(ConnectivityResult.none);
    if (_isOffline == offline) return;
    _isOffline = offline;
    notifyListeners();
  }

  void markWebViewReady() {
    if (_webViewReady) return;
    _webViewReady = true;
    notifyListeners();
  }

  void markWebViewNotReady() {
    if (!_webViewReady) return;
    _webViewReady = false;
    notifyListeners();
  }

  void markLoadedUrl(String? absoluteUrl) {
    if (absoluteUrl == null || absoluteUrl.isEmpty) return;
    _lastLoadedUrl = absoluteUrl;
    notifyListeners();
  }

  Uri buildPathUrl(String path) => buildUrl(kBaseUrl, path);

  void navigateToPath(String path) {
    final String normalizedPath = normalizePath(path);
    _currentPath = normalizedPath;
    _queueNavigation(buildPathUrl(normalizedPath).toString());
  }

  void navigateFromPushPayload(String urlValue) {
    final String raw = urlValue.trim();
    if (raw.isEmpty) return;
    if (isAbsoluteUrl(raw)) {
      _queueNavigation(raw);
      return;
    }
    _queueNavigation(buildPathUrl(raw).toString());
  }

  void consumeNavigation(int requestId) {
    if (_navRequestId != requestId) return;
    _requestedUrl = null;
  }

  Future<void> setNotificationPrompted(bool value) async {
    _notificationsPrompted = value;
    await _prefs?.setBool('notificationsPrompted', value);
    notifyListeners();
  }

  Future<void> setNotificationEnabled(bool value) async {
    _notificationsEnabled = value;
    await _prefs?.setBool('notificationsEnabled', value);
    notifyListeners();
  }

  void _queueNavigation(String absoluteUrl) {
    _navRequestId += 1;
    _requestedUrl = absoluteUrl;
    notifyListeners();
  }
}

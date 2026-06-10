import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'app_logger.dart';

class WebViewCookieStore {
  WebViewCookieStore({required this.logger});

  static const String _prefsKey = 'webview.persistedCookies.v1';
  static const Duration _fallbackSessionCookieLifetime = Duration(days: 30);

  final AppLogger logger;

  Future<void> restore() async {
    try {
      logger.log('webview_cookie_restore_start');
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? rawCookies = prefs.getString(_prefsKey);
      if (rawCookies == null || rawCookies.isEmpty) {
        logger.log('webview_cookie_restore_empty');
        return;
      }

      final Object? decoded = jsonDecode(rawCookies);
      if (decoded is! List) {
        logger.log('webview_cookie_restore_invalid_payload');
        return;
      }

      int restoredCount = 0;
      final CookieManager cookieManager = CookieManager.instance();
      for (final Object item in decoded) {
        if (item is! Map) continue;
        final _StoredCookie? cookie = _StoredCookie.fromJson(item);
        if (cookie == null || cookie.isExpired) continue;

        final bool restored = await cookieManager.setCookie(
          url: WebUri(kBaseUrl),
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path,
          expiresDate: cookie.effectiveExpiresDate,
          isSecure: cookie.isSecure,
          isHttpOnly: cookie.isHttpOnly,
          sameSite: cookie.sameSite,
        );
        if (restored) restoredCount += 1;
      }

      logger.log(
        'webview_cookie_restore_done',
        details: <String, Object?>{'count': restoredCount},
      );
    } catch (error, stackTrace) {
      logger.logError('webview_cookie_restore_error', error, stackTrace);
    }
  }

  Future<void> persist() async {
    try {
      final List<Cookie> cookies = await CookieManager.instance().getCookies(
        url: WebUri(kBaseUrl),
      );
      final List<_StoredCookie> storedCookies = cookies
          .where(_isPraxisCookie)
          .map(_StoredCookie.fromCookie)
          .where((cookie) => !cookie.isExpired)
          .toList(growable: false);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(
          storedCookies
              .map((cookie) => cookie.toJson())
              .toList(growable: false),
        ),
      );

      logger.log(
        'webview_cookie_persist_done',
        details: <String, Object?>{
          'count': storedCookies.length,
          'sessionOnlyCount': storedCookies
              .where((cookie) => cookie.wasSessionOnly)
              .length,
        },
      );
    } catch (error, stackTrace) {
      logger.logError('webview_cookie_persist_error', error, stackTrace);
    }
  }

  bool _isPraxisCookie(Cookie cookie) {
    final String domain = (cookie.domain ?? Uri.parse(kBaseUrl).host)
        .toLowerCase()
        .replaceFirst(RegExp(r'^\.'), '');
    final String baseHost = Uri.parse(kBaseUrl).host.toLowerCase();
    return domain == baseHost || domain.endsWith('.$baseHost');
  }
}

class _StoredCookie {
  const _StoredCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.expiresDate,
    required this.wasSessionOnly,
    required this.isSecure,
    required this.isHttpOnly,
    required this.sameSite,
  });

  final String name;
  final String value;
  final String? domain;
  final String path;
  final int expiresDate;
  final bool wasSessionOnly;
  final bool? isSecure;
  final bool? isHttpOnly;
  final HTTPCookieSameSitePolicy? sameSite;

  bool get isExpired => expiresDate <= DateTime.now().millisecondsSinceEpoch;

  int get effectiveExpiresDate => expiresDate;

  factory _StoredCookie.fromCookie(Cookie cookie) {
    final bool isSessionOnly = cookie.isSessionOnly == true;
    final int fallbackExpiresDate = DateTime.now()
        .add(WebViewCookieStore._fallbackSessionCookieLifetime)
        .millisecondsSinceEpoch;

    return _StoredCookie(
      name: cookie.name,
      value: '${cookie.value ?? ''}',
      domain: cookie.domain,
      path: cookie.path?.isNotEmpty == true ? cookie.path! : '/',
      expiresDate: cookie.expiresDate ?? fallbackExpiresDate,
      wasSessionOnly: isSessionOnly,
      isSecure: cookie.isSecure,
      isHttpOnly: cookie.isHttpOnly,
      sameSite: cookie.sameSite,
    );
  }

  static _StoredCookie? fromJson(Map<dynamic, dynamic> json) {
    final Object? name = json['name'];
    final Object? value = json['value'];
    final Object? expiresDate = json['expiresDate'];
    if (name is! String || value is! String || expiresDate is! int) {
      return null;
    }

    return _StoredCookie(
      name: name,
      value: value,
      domain: json['domain'] is String ? json['domain'] as String : null,
      path: json['path'] is String ? json['path'] as String : '/',
      expiresDate: expiresDate,
      wasSessionOnly: json['wasSessionOnly'] == true,
      isSecure: json['isSecure'] is bool ? json['isSecure'] as bool : null,
      isHttpOnly: json['isHttpOnly'] is bool
          ? json['isHttpOnly'] as bool
          : null,
      sameSite: HTTPCookieSameSitePolicy.fromNativeValue(
        json['sameSite'] is String ? json['sameSite'] as String : null,
      ),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'name': name,
      'value': value,
      'domain': domain,
      'path': path,
      'expiresDate': expiresDate,
      'wasSessionOnly': wasSessionOnly,
      'isSecure': isSecure,
      'isHttpOnly': isHttpOnly,
      'sameSite': sameSite?.toNativeValue(),
    };
  }
}

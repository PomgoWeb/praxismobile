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

  Future<WebViewCookieHeaderResult> buildInitialCookieHeader() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<_StoredCookie> cookies = _loadStoredCookies(prefs);
      if (cookies.isEmpty) return const WebViewCookieHeaderResult();

      final String header = cookies
          .where((cookie) => cookie.name.isNotEmpty)
          .map((cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');

      return WebViewCookieHeaderResult(
        header: header.isEmpty ? null : header,
        cookieCount: cookies.length,
        authCookieCount: cookies.where(_isStoredAuthCookie).length,
      );
    } catch (error, stackTrace) {
      logger.logError('webview_cookie_initial_header_error', error, stackTrace);
      return const WebViewCookieHeaderResult();
    }
  }

  Future<WebViewCookiePersistResult> persist({
    bool allowAuthCookieRemoval = false,
  }) async {
    try {
      final List<Cookie> cookies = await CookieManager.instance().getCookies(
        url: WebUri(kBaseUrl),
      );
      final List<_StoredCookie> currentCookies = cookies
          .where(_isPraxisCookie)
          .map(_StoredCookie.fromCookie)
          .where((cookie) => !cookie.isExpired)
          .toList(growable: false);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<_StoredCookie> existingCookies = _loadStoredCookies(prefs);
      final List<_StoredCookie> currentWordPressCookies = currentCookies
          .where(_isStoredWordPressCookie)
          .toList(growable: false);
      final List<_StoredCookie> currentSwpmCookies = currentCookies
          .where(_isStoredSwpmCookie)
          .toList(growable: false);
      final List<_StoredCookie> currentWordPressLoggedInCookies = currentCookies
          .where(_isStoredWordPressLoggedInCookie)
          .toList(growable: false);
      final List<_StoredCookie> currentWordPressSecCookies = currentCookies
          .where(_isStoredWordPressSecCookie)
          .toList(growable: false);
      final List<_StoredCookie> currentSwpmMembershipCookies = currentCookies
          .where(_isStoredSwpmMembershipCookie)
          .toList(growable: false);
      final List<_StoredCookie> currentSwpmFlagCookies = currentCookies
          .where(_isStoredSwpmFlagCookie)
          .toList(growable: false);
      final int currentAuthCookieCount =
          currentWordPressCookies.length + currentSwpmCookies.length;
      final List<_StoredCookie> existingWordPressCookies = existingCookies
          .where(_isStoredWordPressCookie)
          .where((cookie) => !cookie.isExpired)
          .toList(growable: false);
      final List<_StoredCookie> existingSwpmCookies = existingCookies
          .where(_isStoredSwpmCookie)
          .where((cookie) => !cookie.isExpired)
          .toList(growable: false);

      List<_StoredCookie> cookiesToPersist = currentCookies;
      int preservedAuthCookieCount = 0;
      int preservedWordPressCookieCount = 0;
      int preservedSwpmCookieCount = 0;

      if (!allowAuthCookieRemoval) {
        final Map<String, _StoredCookie> mergedCookies =
            <String, _StoredCookie>{
              for (final _StoredCookie cookie in currentCookies)
                cookie.storageKey: cookie,
            };

        if (currentWordPressCookies.isEmpty &&
            existingWordPressCookies.isNotEmpty) {
          for (final _StoredCookie cookie in existingWordPressCookies) {
            mergedCookies[cookie.storageKey] = cookie;
          }
          preservedWordPressCookieCount = existingWordPressCookies.length;
        }

        if (currentSwpmCookies.isEmpty && existingSwpmCookies.isNotEmpty) {
          for (final _StoredCookie cookie in existingSwpmCookies) {
            mergedCookies[cookie.storageKey] = cookie;
          }
          preservedSwpmCookieCount = existingSwpmCookies.length;
        }

        cookiesToPersist = mergedCookies.values.toList(growable: false);
        preservedAuthCookieCount =
            preservedWordPressCookieCount + preservedSwpmCookieCount;
      }

      await prefs.setString(
        _prefsKey,
        jsonEncode(
          cookiesToPersist
              .map((cookie) => cookie.toJson())
              .toList(growable: false),
        ),
      );

      logger.log(
        'webview_cookie_persist_done',
        details: <String, Object?>{
          'count': cookiesToPersist.length,
          'currentCount': currentCookies.length,
          'authCookieCount': currentAuthCookieCount,
          'wordpressCookieCount': currentCookies
              .where(_isStoredWordPressCookie)
              .length,
          'wordpressLoggedInCount': currentWordPressLoggedInCookies.length,
          'wordpressSecCount': currentWordPressSecCookies.length,
          'swpmCookieCount': currentCookies.where(_isStoredSwpmCookie).length,
          'swpmMembershipCount': currentSwpmMembershipCookies.length,
          'swpmFlagCount': currentSwpmFlagCookies.length,
          'preservedAuthCookieCount': preservedAuthCookieCount,
          'preservedWordPressCookieCount': preservedWordPressCookieCount,
          'preservedSwpmCookieCount': preservedSwpmCookieCount,
          'sessionOnlyCount': cookiesToPersist
              .where((cookie) => cookie.wasSessionOnly)
              .length,
        },
      );
      return WebViewCookiePersistResult(
        currentCookieCount: currentCookies.length,
        currentAuthCookieCount: currentAuthCookieCount,
        persistedCookieCount: cookiesToPersist.length,
        preservedAuthCookieCount: preservedAuthCookieCount,
      );
    } catch (error, stackTrace) {
      logger.logError('webview_cookie_persist_error', error, stackTrace);
      return const WebViewCookiePersistResult(
        currentCookieCount: 0,
        currentAuthCookieCount: 0,
        persistedCookieCount: 0,
        preservedAuthCookieCount: 0,
      );
    }
  }

  List<_StoredCookie> _loadStoredCookies(SharedPreferences prefs) {
    final String? rawCookies = prefs.getString(_prefsKey);
    if (rawCookies == null || rawCookies.isEmpty) {
      return const <_StoredCookie>[];
    }

    final Object? decoded = jsonDecode(rawCookies);
    if (decoded is! List) {
      return const <_StoredCookie>[];
    }

    return decoded
        .whereType<Map<dynamic, dynamic>>()
        .map(_StoredCookie.fromJson)
        .whereType<_StoredCookie>()
        .where((cookie) => !cookie.isExpired)
        .toList(growable: false);
  }

  bool _isPraxisCookie(Cookie cookie) {
    final String domain = (cookie.domain ?? Uri.parse(kBaseUrl).host)
        .toLowerCase()
        .replaceFirst(RegExp(r'^\.'), '');
    final String baseHost = Uri.parse(kBaseUrl).host.toLowerCase();
    return domain == baseHost || domain.endsWith('.$baseHost');
  }

  bool _isStoredWordPressCookie(_StoredCookie cookie) {
    final String name = cookie.name.toLowerCase();
    return name.startsWith('wordpress_') || name.startsWith('wp-');
  }

  bool _isStoredWordPressLoggedInCookie(_StoredCookie cookie) {
    return cookie.name.toLowerCase().startsWith('wordpress_logged_in_');
  }

  bool _isStoredWordPressSecCookie(_StoredCookie cookie) {
    return cookie.name.toLowerCase().startsWith('wordpress_sec_');
  }

  bool _isStoredSwpmCookie(_StoredCookie cookie) {
    return _isStoredSwpmMembershipCookie(cookie) ||
        _isStoredSwpmFlagCookie(cookie);
  }

  bool _isStoredSwpmMembershipCookie(_StoredCookie cookie) {
    return cookie.name.toLowerCase().startsWith('simple_wp_membership_');
  }

  bool _isStoredSwpmFlagCookie(_StoredCookie cookie) {
    final String name = cookie.name.toLowerCase();
    return name == 'swpm_in_use' ||
        name == 'wp_swpm_in_use' ||
        name == 'swpm_session';
  }

  bool _isStoredAuthCookie(_StoredCookie cookie) {
    return _isStoredWordPressCookie(cookie) || _isStoredSwpmCookie(cookie);
  }
}

class WebViewCookieHeaderResult {
  const WebViewCookieHeaderResult({
    this.header,
    this.cookieCount = 0,
    this.authCookieCount = 0,
  });

  final String? header;
  final int cookieCount;
  final int authCookieCount;

  bool get hasHeader => header?.isNotEmpty == true;
}

class WebViewCookiePersistResult {
  const WebViewCookiePersistResult({
    required this.currentCookieCount,
    required this.currentAuthCookieCount,
    required this.persistedCookieCount,
    required this.preservedAuthCookieCount,
  });

  final int currentCookieCount;
  final int currentAuthCookieCount;
  final int persistedCookieCount;
  final int preservedAuthCookieCount;

  bool get preservedAuthCookies => preservedAuthCookieCount > 0;
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

  String get storageKey => '${domain ?? ''}|$path|$name';

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

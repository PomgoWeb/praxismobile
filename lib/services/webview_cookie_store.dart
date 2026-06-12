import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'app_logger.dart';

class WebViewCookieStore {
  WebViewCookieStore({required this.logger});

  static const String _prefsKey = 'webview.persistedCookies.v1';
  static const Duration _fallbackNonWordPressSessionCookieLifetime = Duration(
    days: 30,
  );

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

      int restoredCount = 0;
      int deletedVariantCount = 0;
      final CookieManager cookieManager = CookieManager.instance();
      final List<_StoredCookie> cookies = _loadStoredCookies(
        prefs,
        source: 'restore',
      );
      final List<_StoredCookie> authCookies = cookies
          .where(_isStoredAuthCookie)
          .toList(growable: false);
      if (authCookies.isNotEmpty) {
        _logStoredAuthCookieDetails(
          'webview_cookie_restore_auth_details',
          authCookies,
        );
      }

      for (final _StoredCookie cookie in cookies) {
        if (_isStoredAuthCookie(cookie)) {
          deletedVariantCount += await _deleteCookieVariants(
            cookieManager,
            cookie,
          );
        }
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
        details: <String, Object?>{
          'count': restoredCount,
          'authCookieCount': authCookies.length,
          'deletedVariantCount': deletedVariantCount,
        },
      );
    } catch (error, stackTrace) {
      logger.logError('webview_cookie_restore_error', error, stackTrace);
    }
  }

  Future<WebViewCookieHeaderResult> buildInitialCookieHeader() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<_StoredCookie> cookies = _loadStoredCookies(
        prefs,
        source: 'initial_header',
      );
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
      final List<_StoredCookie> rawCurrentCookies = cookies
          .where(_isPraxisCookie)
          .map(_StoredCookie.fromCookie)
          .where((cookie) => !cookie.isExpired)
          .toList(growable: false);
      final List<_StoredCookie> currentCookies = rawCurrentCookies
          .where((cookie) => !_isStoredSessionOnlyWordPressAuthCookie(cookie))
          .toList(growable: false);
      final int skippedSessionOnlyWordPressCookieCount =
          rawCurrentCookies.length - currentCookies.length;

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<_StoredCookie> existingCookies = _loadStoredCookies(
        prefs,
        source: 'persist_existing',
      );
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
      _logStoredAuthCookieDetails(
        'webview_cookie_persist_auth_details',
        cookiesToPersist.where(_isStoredAuthCookie).toList(growable: false),
        extraDetails: <String, Object?>{
          'currentAuthCookieCount': currentAuthCookieCount,
          'skippedSessionOnlyWordPressCookieCount':
              skippedSessionOnlyWordPressCookieCount,
          'allowAuthCookieRemoval': allowAuthCookieRemoval,
        },
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
          'skippedSessionOnlyWordPressCookieCount':
              skippedSessionOnlyWordPressCookieCount,
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

  Future<void> dropStoredAuthCookies({required String reason}) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<_StoredCookie> existingCookies = _loadStoredCookies(
        prefs,
        source: 'drop_auth',
      );
      final List<_StoredCookie> authCookies = existingCookies
          .where(_isStoredAuthCookie)
          .toList(growable: false);
      final List<_StoredCookie> remainingCookies = existingCookies
          .where((cookie) => !_isStoredAuthCookie(cookie))
          .toList(growable: false);

      await prefs.setString(
        _prefsKey,
        jsonEncode(
          remainingCookies
              .map((cookie) => cookie.toJson())
              .toList(growable: false),
        ),
      );

      int deletedVariantCount = 0;
      final CookieManager cookieManager = CookieManager.instance();
      for (final _StoredCookie cookie in authCookies) {
        deletedVariantCount += await _deleteCookieVariants(
          cookieManager,
          cookie,
        );
      }

      _logStoredAuthCookieDetails(
        'webview_cookie_drop_auth_details',
        authCookies,
        extraDetails: <String, Object?>{
          'reason': reason,
          'remainingCount': remainingCookies.length,
          'deletedVariantCount': deletedVariantCount,
        },
      );
      logger.log(
        'webview_cookie_drop_auth_done',
        details: <String, Object?>{
          'reason': reason,
          'removedCount': authCookies.length,
          'remainingCount': remainingCookies.length,
          'deletedVariantCount': deletedVariantCount,
        },
      );
    } catch (error, stackTrace) {
      logger.logError('webview_cookie_drop_auth_error', error, stackTrace);
    }
  }

  List<_StoredCookie> _loadStoredCookies(
    SharedPreferences prefs, {
    required String source,
  }) {
    final String? rawCookies = prefs.getString(_prefsKey);
    if (rawCookies == null || rawCookies.isEmpty) {
      return const <_StoredCookie>[];
    }

    final Object? decoded = jsonDecode(rawCookies);
    if (decoded is! List) {
      logger.log(
        'webview_cookie_stored_payload_invalid',
        details: <String, Object?>{'source': source},
      );
      return const <_StoredCookie>[];
    }

    final List<_StoredCookie> parsedCookies = decoded
        .whereType<Map<dynamic, dynamic>>()
        .map(_StoredCookie.fromJson)
        .whereType<_StoredCookie>()
        .toList(growable: false);
    final List<_StoredCookie> validCookies = parsedCookies
        .where((cookie) => !cookie.isExpired)
        .where((cookie) => !_isStoredSessionOnlyWordPressAuthCookie(cookie))
        .toList(growable: false);
    final int expiredCount = parsedCookies
        .where((cookie) => cookie.isExpired)
        .length;
    final int skippedSessionOnlyWordPressCookieCount = parsedCookies
        .where((cookie) => !cookie.isExpired)
        .where(_isStoredSessionOnlyWordPressAuthCookie)
        .length;
    if (expiredCount > 0 || skippedSessionOnlyWordPressCookieCount > 0) {
      logger.log(
        'webview_cookie_stored_cleanup',
        details: <String, Object?>{
          'source': source,
          'inputCount': parsedCookies.length,
          'outputCount': validCookies.length,
          'expiredCount': expiredCount,
          'skippedSessionOnlyWordPressCookieCount':
              skippedSessionOnlyWordPressCookieCount,
        },
      );
    }
    return validCookies;
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

  bool _isStoredSessionOnlyWordPressAuthCookie(_StoredCookie cookie) {
    return _isStoredWordPressCookie(cookie) && cookie.wasSessionOnly;
  }

  Future<int> _deleteCookieVariants(
    CookieManager cookieManager,
    _StoredCookie cookie,
  ) async {
    final Set<String?> domains = <String?>{
      null,
      Uri.parse(kBaseUrl).host.toLowerCase(),
      '.${Uri.parse(kBaseUrl).host.toLowerCase()}',
      cookie.domain,
      if (cookie.domain != null)
        cookie.domain!.replaceFirst(RegExp(r'^\.'), ''),
      if (cookie.domain != null &&
          !cookie.domain!.startsWith('.') &&
          cookie.domain!.isNotEmpty)
        '.${cookie.domain}',
    };
    final Set<String> paths = <String>{'/', cookie.path};
    int deletedCount = 0;

    for (final String? domain in domains) {
      for (final String path in paths) {
        try {
          final bool deleted = await cookieManager.deleteCookie(
            url: WebUri(kBaseUrl),
            name: cookie.name,
            domain: domain,
            path: path,
          );
          if (deleted) deletedCount += 1;
        } catch (error, stackTrace) {
          logger.logError(
            'webview_cookie_delete_variant_error',
            error,
            stackTrace,
          );
        }
      }
    }

    return deletedCount;
  }

  void _logStoredAuthCookieDetails(
    String eventName,
    List<_StoredCookie> cookies, {
    Map<String, Object?> extraDetails = const <String, Object?>{},
  }) {
    if (cookies.isEmpty && extraDetails.isEmpty) return;
    logger.log(
      eventName,
      details: <String, Object?>{
        ...extraDetails,
        'count': cookies.length,
        'wordpressCookieCount': cookies.where(_isStoredWordPressCookie).length,
        'wordpressLoggedInCount': cookies
            .where(_isStoredWordPressLoggedInCookie)
            .length,
        'wordpressSecCount': cookies.where(_isStoredWordPressSecCookie).length,
        'swpmCookieCount': cookies.where(_isStoredSwpmCookie).length,
        'swpmMembershipCount': cookies
            .where(_isStoredSwpmMembershipCookie)
            .length,
        'duplicates': _duplicateAuthCookieKeys(cookies),
        'cookies': cookies.map(_storedCookieSummary).toList(growable: false),
      },
    );
  }

  List<Map<String, Object?>> _duplicateAuthCookieKeys(
    List<_StoredCookie> cookies,
  ) {
    final Map<String, int> counts = <String, int>{};
    for (final _StoredCookie cookie in cookies) {
      counts[cookie.name] = (counts[cookie.name] ?? 0) + 1;
    }
    final Set<String> duplicateNames = counts.entries
        .where((MapEntry<String, int> entry) => entry.value > 1)
        .map((MapEntry<String, int> entry) => entry.key)
        .toSet();
    return cookies
        .where((cookie) => duplicateNames.contains(cookie.name))
        .map((cookie) {
          return <String, Object?>{
            'name': cookie.name,
            'domain': cookie.domain,
            'path': cookie.path,
            'valueHash': _shortStableHash(cookie.value),
          };
        })
        .toList(growable: false);
  }

  Map<String, Object?> _storedCookieSummary(_StoredCookie cookie) {
    return <String, Object?>{
      'name': cookie.name,
      'domain': cookie.domain,
      'path': cookie.path,
      'isSecure': cookie.isSecure,
      'isHttpOnly': cookie.isHttpOnly,
      'isSessionOnly': cookie.wasSessionOnly,
      'expiresDate': cookie.expiresDate,
      'sameSite': cookie.sameSite?.toNativeValue(),
      'valueHash': _shortStableHash(cookie.value),
      'valueLength': cookie.value.length,
    };
  }

  String _shortStableHash(String value) {
    const int fnvPrime = 16777619;
    int hash = 2166136261;
    for (final int unit in utf8.encode(value)) {
      hash ^= unit;
      hash = (hash * fnvPrime) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
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
        .add(WebViewCookieStore._fallbackNonWordPressSessionCookieLifetime)
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

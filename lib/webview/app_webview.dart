import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../models/app_state.dart';
import '../services/app_logger.dart';
import '../services/webview_cookie_store.dart';
import '../ui/startup_splash.dart';
import '../utils/url_utils.dart';
import '../utils/webview_auth_navigation_guard.dart';

class AppWebView extends StatefulWidget {
  const AppWebView({super.key});

  @override
  State<AppWebView> createState() => _AppWebViewState();
}

class _AppWebViewState extends State<AppWebView>
    with AutomaticKeepAliveClientMixin<AppWebView>, WidgetsBindingObserver {
  InAppWebViewController? _controller;
  late final WebViewCookieStore _cookieStore;
  int _lastConsumedRequestId = -1;
  bool _isLoading = true;
  bool _showStartupSplash = true;
  String? _lastError;
  Timer? _startupSplashTimer;
  bool _loggedFirstBuild = false;
  bool _preloadedActionPages = false;
  bool _paymentFlowNavigationAllowed = false;
  bool _logoutNavigationAllowed = false;
  bool _cookiesRestored = false;
  bool _authCookieRecoveryAttempted = false;
  bool _isRecoveringAuthCookies = false;
  bool _isProtectingAuthNavigation = false;
  bool _suppressNextCancelledNavigationError = false;
  String? _lastAuthenticatedUrl;
  String? _pendingAppNavigationUrl;
  DateTime? _lastAuthenticatedAt;

  @override
  bool get wantKeepAlive => true;

  bool get _usesCookiePersistenceWorkaround {
    return defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  void initState() {
    super.initState();
    _cookieStore = WebViewCookieStore(logger: context.read<AppLogger>());
    if (_usesCookiePersistenceWorkaround) {
      WidgetsBinding.instance.addObserver(this);
      unawaited(_restoreCookiesBeforeFirstLoad());
    } else {
      _cookiesRestored = true;
    }
    _startupSplashTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      context.read<AppLogger>().log('startup_splash_timeout');
      setState(() {
        _showStartupSplash = false;
      });
    });
  }

  @override
  void dispose() {
    if (_usesCookiePersistenceWorkaround) {
      WidgetsBinding.instance.removeObserver(this);
      unawaited(_cookieStore.persist());
    }
    _startupSplashTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_usesCookiePersistenceWorkaround) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_cookieStore.persist());
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final AppState appState = context.watch<AppState>();
    if (!_loggedFirstBuild) {
      _loggedFirstBuild = true;
      context.read<AppLogger>().log('webview_widget_first_build');
    }

    _consumePendingNavigation(appState);

    if (!_cookiesRestored) {
      return const StartupSplash();
    }

    return Stack(
      children: <Widget>[
        InAppWebView(
          initialUrlRequest: _buildInitialUrlRequest(
            appState.buildPathUrl(appState.currentPath),
          ),
          initialSettings: InAppWebViewSettings(
            userAgent: defaultTargetPlatform == TargetPlatform.iOS
                ? null
                : 'Mozilla/5.0 $kAppUserAgentTag',
            applicationNameForUserAgent:
                defaultTargetPlatform == TargetPlatform.iOS
                ? kAppUserAgentTag
                : null,
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
            incognito: false,
            cacheEnabled: true,
            sharedCookiesEnabled: true,
            mediaPlaybackRequiresUserGesture: false,
            supportZoom: false,
            builtInZoomControls: false,
            displayZoomControls: false,
            ignoresViewportScaleLimits: false,
          ),
          onWebViewCreated: (InAppWebViewController controller) {
            _controller = controller;
            appState.markWebViewReady();
            context.read<AppLogger>().log('webview_created');
          },
          onLoadStart: (InAppWebViewController controller, WebUri? uri) {
            _clearPendingAppNavigation(uri?.uriValue);
            setState(() {
              _showStartupSplash = false;
              _isLoading = true;
              _lastError = null;
            });
            _startupSplashTimer?.cancel();
            context.read<AppLogger>().log(
              'webview_load_start',
              details: <String, Object?>{'url': uri?.toString() ?? ''},
            );
            unawaited(_injectAppCssClasses(controller));
          },
          onLoadStop: (InAppWebViewController controller, WebUri? uri) async {
            final AppLogger logger = context.read<AppLogger>();
            setState(() {
              _showStartupSplash = false;
              _isLoading = true;
              _lastError = null;
            });
            _startupSplashTimer?.cancel();
            appState.markLoadedUrl(uri?.toString());
            unawaited(_injectAppCssClasses(controller));
            final bool recoveryReloaded = _usesCookiePersistenceWorkaround
                ? await _persistCookiesAfterLoad(controller, uri)
                : false;
            if (recoveryReloaded) return;

            if (!mounted) return;
            setState(() {
              _isLoading = false;
              _isRecoveringAuthCookies = false;
              _isProtectingAuthNavigation = false;
            });
            unawaited(_preloadActionPages(controller, appState));
            unawaited(_logCookieState(uri: uri?.uriValue, source: 'load_stop'));
            logger.log(
              'webview_load_stop',
              details: <String, Object?>{'url': uri?.toString() ?? ''},
            );
          },
          onReceivedError:
              (
                InAppWebViewController controller,
                WebResourceRequest request,
                WebResourceError error,
              ) {
                if (_shouldSuppressCancelledNavigationError(error)) {
                  _suppressNextCancelledNavigationError = false;
                  context.read<AppLogger>().log(
                    'webview_cancelled_navigation_error_suppressed',
                    details: <String, Object?>{
                      'url': request.url.toString(),
                      'code': error.type.toString(),
                      'description': error.description,
                    },
                  );
                  return;
                }
                _suppressNextCancelledNavigationError = false;
                setState(() {
                  _showStartupSplash = false;
                  _isLoading = false;
                  _isProtectingAuthNavigation = false;
                  _lastError = error.description;
                });
                _startupSplashTimer?.cancel();
                context.read<AppLogger>().log(
                  'webview_load_error',
                  details: <String, Object?>{
                    'code': error.type.toString(),
                    'description': error.description,
                  },
                );
              },
          shouldOverrideUrlLoading:
              (
                InAppWebViewController controller,
                NavigationAction navigationAction,
              ) async {
                final Uri? rawUri = navigationAction.request.url?.uriValue;
                if (rawUri == null) return NavigationActionPolicy.ALLOW;

                final Uri baseUri = Uri.parse(kBaseUrl);
                final bool external = !isSameDomainOrSubdomain(baseUri, rawUri);
                if (external) {
                  if (!navigationAction.isForMainFrame) {
                    context.read<AppLogger>().log(
                      'webview_external_subframe_allowed',
                      details: <String, Object?>{'url': rawUri.toString()},
                    );
                    return NavigationActionPolicy.ALLOW;
                  }

                  final bool isUserNavigation =
                      navigationAction.hasGesture == true ||
                      navigationAction.navigationType ==
                          NavigationType.LINK_ACTIVATED;
                  final bool isPaymentRedirect =
                      _isStripeCheckoutNavigation(rawUri) ||
                      _paymentFlowNavigationAllowed;
                  context.read<AppLogger>().log(
                    'webview_external_navigation',
                    details: <String, Object?>{
                      'url': rawUri.toString(),
                      'mainFrame': navigationAction.isForMainFrame,
                      'hasGesture': navigationAction.hasGesture,
                      'navigationType':
                          navigationAction.navigationType?.toString() ?? '',
                      'paymentRedirect': isPaymentRedirect,
                      'allowed': isUserNavigation || isPaymentRedirect,
                    },
                  );
                  if (isPaymentRedirect) {
                    _paymentFlowNavigationAllowed = true;
                    return NavigationActionPolicy.ALLOW;
                  }
                  if (!isUserNavigation) {
                    return NavigationActionPolicy.CANCEL;
                  }
                  await launchUrl(rawUri, mode: LaunchMode.externalApplication);
                  return NavigationActionPolicy.CANCEL;
                }
                if (_paymentFlowNavigationAllowed) {
                  _paymentFlowNavigationAllowed = false;
                  context.read<AppLogger>().log(
                    'webview_payment_flow_returned_to_app_domain',
                    details: <String, Object?>{'url': rawUri.toString()},
                  );
                }
                if (_isAuthDiagnosticUrl(rawUri)) {
                  _logAuthNavigationDiagnostic(rawUri, navigationAction);
                }
                if (_shouldCancelAutomaticLogoutNavigation(
                  rawUri,
                  navigationAction,
                )) {
                  context.read<AppLogger>().log(
                    'webview_automatic_logout_navigation_cancelled',
                    details: <String, Object?>{
                      'url': rawUri.toString(),
                      'navigationType':
                          navigationAction.navigationType?.toString() ?? '',
                      'hasGesture': navigationAction.hasGesture,
                    },
                  );
                  _suppressNextCancelledNavigationError = true;
                  unawaited(
                    _cookieStore.dropStoredAuthCookies(
                      reason: 'automatic_logout_redirect',
                    ),
                  );
                  return NavigationActionPolicy.CANCEL;
                }
                if (_isLogoutUrl(rawUri)) {
                  _logoutNavigationAllowed = true;
                  context.read<AppLogger>().log(
                    'webview_logout_navigation_allowed',
                    details: <String, Object?>{
                      'url': rawUri.toString(),
                      'navigationType':
                          navigationAction.navigationType?.toString() ?? '',
                      'hasGesture': navigationAction.hasGesture,
                      'isUserInitiated': _isUserInitiatedNavigation(
                        navigationAction,
                      ),
                    },
                  );
                  return NavigationActionPolicy.ALLOW;
                }
                if (_isLoginResolverUrl(rawUri)) {
                  context.read<AppLogger>().log(
                    'webview_login_resolver_navigation_allowed',
                    details: <String, Object?>{
                      'url': rawUri.toString(),
                      'navigationType':
                          navigationAction.navigationType?.toString() ?? '',
                      'hasGesture': navigationAction.hasGesture,
                      'hasKnownAuthSession': _lastAuthenticatedAt != null,
                    },
                  );
                }
                if (_shouldBlockAutomaticDuplicateNavigation(
                  rawUri,
                  navigationAction,
                )) {
                  context.read<AppLogger>().log(
                    'webview_duplicate_authenticated_navigation_cancelled',
                    details: <String, Object?>{
                      'url': rawUri.toString(),
                      'navigationType':
                          navigationAction.navigationType?.toString() ?? '',
                      'hasGesture': navigationAction.hasGesture,
                    },
                  );
                  return NavigationActionPolicy.CANCEL;
                }
                if (_shouldRestoreAuthCookiesBeforeNavigation(
                  rawUri,
                  navigationAction,
                )) {
                  await _restoreAuthCookiesBeforeNavigation(
                    rawUri,
                    'same_domain',
                  );
                }
                if (_shouldProtectAuthNavigation(rawUri, navigationAction)) {
                  _startAuthNavigationProtection(rawUri, 'same_domain');
                }
                return NavigationActionPolicy.ALLOW;
              },
        ),
        if (_showStartupSplash)
          const Positioned.fill(child: StartupSplash())
        else if (_isRecoveringAuthCookies || _isProtectingAuthNavigation)
          const Positioned.fill(child: StartupSplash())
        else if (_isLoading)
          const Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (_lastError != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Material(
              color: Colors.red.shade700,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Erreur de chargement: $_lastError',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _consumePendingNavigation(AppState appState) {
    if (_controller == null) return;
    if (appState.requestedUrl == null) return;
    if (_lastConsumedRequestId == appState.navRequestId) return;

    _lastConsumedRequestId = appState.navRequestId;
    final String targetUrl = appState.requestedUrl!;
    _pendingAppNavigationUrl = _normalizeUrlForDuplicateGuard(
      Uri.parse(targetUrl),
    );
    _startAuthNavigationProtection(Uri.parse(targetUrl), 'app_request');
    context.read<AppLogger>().log(
      'webview_load_url_requested',
      details: <String, Object?>{'url': targetUrl},
    );
    unawaited(
      _restoreAuthCookiesBeforeNavigation(
        Uri.parse(targetUrl),
        'app_request',
      ).then((_) async {
        await _controller!.loadUrl(
          urlRequest: URLRequest(url: WebUri(targetUrl)),
        );
      }),
    );
    appState.consumeNavigation(appState.navRequestId);
  }

  void _clearPendingAppNavigation(Uri? uri) {
    if (uri == null || _pendingAppNavigationUrl == null) return;
    if (_normalizeUrlForDuplicateGuard(uri) == _pendingAppNavigationUrl) {
      _pendingAppNavigationUrl = null;
    }
  }

  bool _shouldBlockAutomaticDuplicateNavigation(
    Uri uri,
    NavigationAction navigationAction,
  ) {
    if (!_usesCookiePersistenceWorkaround) return false;
    if (!navigationAction.isForMainFrame) return false;
    if (navigationAction.hasGesture == true) return false;
    if (navigationAction.navigationType == NavigationType.LINK_ACTIVATED) {
      return false;
    }

    final String normalizedUrl = _normalizeUrlForDuplicateGuard(uri);
    if (_pendingAppNavigationUrl == normalizedUrl) return false;
    if (_lastAuthenticatedUrl != normalizedUrl) return false;

    final DateTime? lastAuthenticatedAt = _lastAuthenticatedAt;
    if (lastAuthenticatedAt == null) return false;
    return DateTime.now().difference(lastAuthenticatedAt) <
        const Duration(seconds: 8);
  }

  bool _shouldCancelAutomaticLogoutNavigation(
    Uri uri,
    NavigationAction navigationAction,
  ) {
    if (!_usesCookiePersistenceWorkaround) return false;
    return WebViewAuthNavigationGuard.shouldCancelAutomaticLogoutNavigation(
      uri: uri,
      usesCookiePersistenceWorkaround: _usesCookiePersistenceWorkaround,
      logoutNavigationAllowed: _logoutNavigationAllowed,
      isUserInitiated: _isUserInitiatedNavigation(navigationAction),
    );
  }

  bool _shouldSuppressCancelledNavigationError(WebResourceError error) {
    if (!_suppressNextCancelledNavigationError) return false;
    final String description = error.description.toLowerCase();
    return description.contains('webkiterrordomain') &&
        (description.contains('code=102') ||
            description.contains('frame load interrupted') ||
            description.contains('chargement du cadre interrompu'));
  }

  bool _shouldProtectAuthNavigation(
    Uri uri,
    NavigationAction navigationAction,
  ) {
    if (!_usesCookiePersistenceWorkaround) return false;
    if (!navigationAction.isForMainFrame) return false;
    if (_lastAuthenticatedAt == null) return false;
    if (_isLogoutUrl(uri)) return false;
    return true;
  }

  bool _isUserInitiatedNavigation(NavigationAction navigationAction) {
    return navigationAction.hasGesture == true ||
        navigationAction.navigationType == NavigationType.LINK_ACTIVATED;
  }

  void _logAuthNavigationDiagnostic(
    Uri uri,
    NavigationAction navigationAction,
  ) {
    context.read<AppLogger>().log(
      'webview_auth_navigation_diagnostic',
      details: <String, Object?>{
        'url': uri.toString(),
        'isLoginResolver': _isLoginResolverUrl(uri),
        'isLogoutUrl': _isLogoutUrl(uri),
        'hasKnownAuthSession': _lastAuthenticatedAt != null,
        'logoutNavigationAllowed': _logoutNavigationAllowed,
        'isUserInitiated': _isUserInitiatedNavigation(navigationAction),
        'navigationType': navigationAction.navigationType?.toString() ?? '',
        'hasGesture': navigationAction.hasGesture,
        'mainFrame': navigationAction.isForMainFrame,
      },
    );
    unawaited(
      _logCookieState(
        eventName: 'webview_auth_navigation_cookie_state',
        uri: uri,
        source: 'navigation_diagnostic',
      ),
    );
  }

  bool _isAuthDiagnosticUrl(Uri uri) {
    return _isLoginResolverUrl(uri) || _isLogoutUrl(uri);
  }

  bool _shouldRestoreAuthCookiesBeforeNavigation(
    Uri uri,
    NavigationAction navigationAction,
  ) {
    if (!_usesCookiePersistenceWorkaround) return false;
    if (!navigationAction.isForMainFrame) return false;
    if (_lastAuthenticatedAt == null) return false;
    if (_isLogoutUrl(uri)) return false;

    final String method =
        navigationAction.request.method?.toUpperCase() ?? 'GET';
    if (method != 'GET') return false;

    return true;
  }

  Future<void> _restoreAuthCookiesBeforeNavigation(
    Uri uri,
    String source,
  ) async {
    if (!_usesCookiePersistenceWorkaround) return;
    if (_isLogoutUrl(uri)) return;

    await _cookieStore.restore().timeout(
      const Duration(seconds: 1),
      onTimeout: () {
        if (mounted) {
          context.read<AppLogger>().log(
            'webview_auth_cookie_pre_navigation_restore_timeout',
            details: <String, Object?>{'url': uri.toString()},
          );
        }
      },
    );

    final WebViewCookieHeaderResult headerResult = await _cookieStore
        .buildInitialCookieHeader()
        .timeout(
          const Duration(seconds: 1),
          onTimeout: () {
            if (mounted) {
              context.read<AppLogger>().log(
                'webview_auth_cookie_pre_navigation_state_timeout',
                details: <String, Object?>{'url': uri.toString()},
              );
            }
            return const WebViewCookieHeaderResult();
          },
        );
    if (mounted) {
      context.read<AppLogger>().log(
        'webview_auth_cookie_pre_navigation_restore_done',
        details: <String, Object?>{
          'url': uri.toString(),
          'source': source,
          'cookieCount': headerResult.cookieCount,
          'authCookieCount': headerResult.authCookieCount,
        },
      );
      unawaited(
        _logCookieState(
          eventName: 'webview_auth_cookie_pre_navigation_state',
          uri: uri,
          source: source,
        ),
      );
    }
  }

  void _startAuthNavigationProtection(Uri uri, String source) {
    if (!_usesCookiePersistenceWorkaround) return;
    if (_lastAuthenticatedAt == null) return;
    if (_isLogoutUrl(uri)) return;
    if (!mounted) return;

    if (!_isProtectingAuthNavigation) {
      context.read<AppLogger>().log(
        'webview_auth_navigation_protection_start',
        details: <String, Object?>{'url': uri.toString(), 'source': source},
      );
    }
    setState(() {
      _isProtectingAuthNavigation = true;
      _isLoading = true;
    });
  }

  String _normalizeUrlForDuplicateGuard(Uri uri) {
    return uri.replace(fragment: '').toString();
  }

  URLRequest _buildInitialUrlRequest(Uri uri) {
    return URLRequest(url: WebUri.uri(uri), httpShouldHandleCookies: true);
  }

  Future<void> _restoreCookiesBeforeFirstLoad() async {
    final AppLogger logger = context.read<AppLogger>();
    await _cookieStore.restore().timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        logger.log('webview_cookie_restore_timeout');
      },
    );
    final WebViewCookieHeaderResult headerResult = await _cookieStore
        .buildInitialCookieHeader()
        .timeout(
          const Duration(seconds: 1),
          onTimeout: () {
            logger.log('webview_cookie_initial_header_timeout');
            return const WebViewCookieHeaderResult();
          },
        );
    logger.log(
      'webview_cookie_initial_state_ready',
      details: <String, Object?>{
        'cookieCount': headerResult.cookieCount,
        'authCookieCount': headerResult.authCookieCount,
      },
    );
    if (!mounted) return;
    setState(() {
      _cookiesRestored = true;
    });
  }

  Future<bool> _persistCookiesAfterLoad(
    InAppWebViewController controller,
    WebUri? uri,
  ) async {
    final AppLogger logger = context.read<AppLogger>();
    final Uri? loadedUri = uri?.uriValue;
    final bool allowsAuthCookieRemoval = _isLogoutUrl(loadedUri);
    final bool signupRedirectWithKnownAuth =
        _usesCookiePersistenceWorkaround &&
        _isSignupUrl(loadedUri) &&
        _lastAuthenticatedAt != null;
    if (allowsAuthCookieRemoval) {
      logger.log(
        'webview_logout_url_loaded',
        details: <String, Object?>{
          'url': uri?.toString() ?? '',
          'logoutNavigationAllowed': _logoutNavigationAllowed,
        },
      );
    }
    final WebViewCookiePersistResult result = await _cookieStore.persist(
      allowAuthCookieRemoval: allowsAuthCookieRemoval,
    );

    if (!mounted) return false;
    if (signupRedirectWithKnownAuth) {
      logger.log(
        'webview_signup_redirect_with_known_auth',
        details: <String, Object?>{
          'url': uri?.toString() ?? '',
          'currentAuthCookieCount': result.currentAuthCookieCount,
          'persistedCookieCount': result.persistedCookieCount,
        },
      );
      _lastAuthenticatedAt = null;
      _lastAuthenticatedUrl = null;
      _authCookieRecoveryAttempted = false;
      unawaited(
        _cookieStore.dropStoredAuthCookies(
          reason: 'signup_redirect_with_known_auth',
        ),
      );
    }
    if (allowsAuthCookieRemoval) {
      _logoutNavigationAllowed = false;
      _isRecoveringAuthCookies = false;
      _isProtectingAuthNavigation = false;
      return false;
    }
    if (!result.preservedAuthCookies) {
      if (result.currentAuthCookieCount > 0) {
        _authCookieRecoveryAttempted = false;
        if (uri?.uriValue != null) {
          _lastAuthenticatedUrl = _normalizeUrlForDuplicateGuard(uri!.uriValue);
          _lastAuthenticatedAt = DateTime.now();
        }
      }
      _isRecoveringAuthCookies = false;
      _isProtectingAuthNavigation = false;
      return false;
    }
    if (_authCookieRecoveryAttempted) {
      _isRecoveringAuthCookies = false;
      _isProtectingAuthNavigation = false;
      return false;
    }

    _authCookieRecoveryAttempted = true;
    setState(() {
      _isRecoveringAuthCookies = true;
      _isProtectingAuthNavigation = true;
      _isLoading = true;
    });
    logger.log(
      'webview_cookie_auth_recovery_reload',
      details: <String, Object?>{
        'url': uri?.toString() ?? '',
        'preservedAuthCookieCount': result.preservedAuthCookieCount,
      },
    );

    await _cookieStore.restore();
    await controller.reload();
    return true;
  }

  Future<void> _preloadActionPages(
    InAppWebViewController controller,
    AppState appState,
  ) async {
    if (_preloadedActionPages || appState.isOffline) return;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _preloadedActionPages = true;
      context.read<AppLogger>().log('webview_preload_action_pages_skipped_ios');
      return;
    }
    _preloadedActionPages = true;

    final List<String> urls = kMenuDestinations
        .map((MenuDestination destination) {
          return appState.buildPathUrl(destination.path).toString();
        })
        .toSet()
        .toList(growable: false);

    context.read<AppLogger>().log(
      'webview_preload_action_pages_start',
      details: <String, Object?>{'count': urls.length},
    );

    try {
      await controller.evaluateJavascript(
        source:
            '''
          (function(urls) {
            if (!Array.isArray(urls) || !urls.length) return;
            window.rsappPreloadedActionPages = window.rsappPreloadedActionPages || {};

            urls.forEach(function(url) {
              if (!url || window.rsappPreloadedActionPages[url]) return;
              window.rsappPreloadedActionPages[url] = true;

              try {
                var link = document.createElement('link');
                link.rel = 'prefetch';
                link.href = url;
                link.as = 'document';
                (document.head || document.documentElement).appendChild(link);
              } catch (_) {}
            });
          })(${jsonEncode(urls)});
        ''',
      );
      if (!mounted) return;
      context.read<AppLogger>().log(
        'webview_preload_action_pages_done',
        details: <String, Object?>{'count': urls.length},
      );
    } catch (error, stackTrace) {
      if (!mounted) return;
      context.read<AppLogger>().logError(
        'webview_preload_action_pages_error',
        error,
        stackTrace,
      );
    }
  }

  bool _isStripeCheckoutNavigation(Uri uri) {
    final String host = uri.host.toLowerCase();
    return uri.scheme == 'https' && host == 'checkout.stripe.com';
  }

  bool _isLogoutUrl(Uri? uri) {
    return WebViewAuthNavigationGuard.isLogoutUrl(uri);
  }

  bool _isSignupUrl(Uri? uri) {
    if (uri == null) return false;
    return uri.path.replaceAll(RegExp(r'/+$'), '') == '/inscription';
  }

  bool _isLoginResolverUrl(Uri uri) {
    return WebViewAuthNavigationGuard.isLoginResolverUrl(uri);
  }

  Future<void> _logCookieState({
    String eventName = 'webview_cookie_state',
    Uri? uri,
    String? source,
  }) async {
    final AppLogger logger = context.read<AppLogger>();
    try {
      final List<Cookie> cookies = await CookieManager.instance().getCookies(
        url: WebUri(kBaseUrl),
      );
      if (!mounted) return;

      final int wordpressCookieCount = cookies.where((Cookie cookie) {
        return cookie.name.toLowerCase().startsWith('wordpress_') ||
            cookie.name.toLowerCase().startsWith('wp-');
      }).length;
      final int wordpressLoggedInCookieCount = cookies.where((Cookie cookie) {
        return cookie.name.toLowerCase().startsWith('wordpress_logged_in_');
      }).length;
      final int wordpressSecCookieCount = cookies.where((Cookie cookie) {
        return cookie.name.toLowerCase().startsWith('wordpress_sec_');
      }).length;
      final int swpmCookieCount = cookies.where((Cookie cookie) {
        return _isSwpmCookieName(cookie.name);
      }).length;
      final int swpmMembershipCookieCount = cookies.where((Cookie cookie) {
        return cookie.name.toLowerCase().startsWith('simple_wp_membership_');
      }).length;
      final int swpmPrimaryMembershipCookieCount = cookies.where((
        Cookie cookie,
      ) {
        final String name = cookie.name.toLowerCase();
        return name.startsWith('simple_wp_membership_') &&
            !name.startsWith('simple_wp_membership_sec_');
      }).length;
      final int swpmSecMembershipCookieCount = cookies.where((Cookie cookie) {
        return cookie.name.toLowerCase().startsWith(
          'simple_wp_membership_sec_',
        );
      }).length;
      final int swpmFlagCookieCount = cookies.where((Cookie cookie) {
        final String name = cookie.name.toLowerCase();
        return name == 'swpm_in_use' ||
            name == 'wp_swpm_in_use' ||
            name == 'swpm_session';
      }).length;
      final int sessionOnlyCount = cookies.where((Cookie cookie) {
        return cookie.isSessionOnly == true;
      }).length;
      final int secureCookieCount = cookies.where((Cookie cookie) {
        return cookie.isSecure == true;
      }).length;
      final int httpOnlyCookieCount = cookies.where((Cookie cookie) {
        return cookie.isHttpOnly == true;
      }).length;
      final int sameSiteLaxCookieCount = cookies.where((Cookie cookie) {
        return cookie.sameSite == HTTPCookieSameSitePolicy.LAX;
      }).length;
      final int sameSiteStrictCookieCount = cookies.where((Cookie cookie) {
        return cookie.sameSite == HTTPCookieSameSitePolicy.STRICT;
      }).length;
      final int sameSiteNoneCookieCount = cookies.where((Cookie cookie) {
        return cookie.sameSite == HTTPCookieSameSitePolicy.NONE;
      }).length;

      logger.log(
        eventName,
        details: <String, Object?>{
          'url': ?uri?.toString(),
          'source': ?source,
          'count': cookies.length,
          'wordpressCount': wordpressCookieCount,
          'wordpressLoggedInCount': wordpressLoggedInCookieCount,
          'wordpressSecCount': wordpressSecCookieCount,
          'swpmCount': swpmCookieCount,
          'swpmMembershipCount': swpmMembershipCookieCount,
          'swpmPrimaryMembershipCount': swpmPrimaryMembershipCookieCount,
          'swpmSecMembershipCount': swpmSecMembershipCookieCount,
          'swpmFlagCount': swpmFlagCookieCount,
          'authCount': wordpressCookieCount + swpmCookieCount,
          'sessionOnlyCount': sessionOnlyCount,
          'persistentCount': cookies.length - sessionOnlyCount,
          'secureCount': secureCookieCount,
          'httpOnlyCount': httpOnlyCookieCount,
          'sameSiteLaxCount': sameSiteLaxCookieCount,
          'sameSiteStrictCount': sameSiteStrictCookieCount,
          'sameSiteNoneCount': sameSiteNoneCookieCount,
        },
      );
    } catch (error, stackTrace) {
      if (!mounted) return;
      logger.logError('webview_cookie_state_error', error, stackTrace);
    }
  }

  bool _isSwpmCookieName(String name) {
    final String lowerName = name.toLowerCase();
    return lowerName.startsWith('simple_wp_membership_') ||
        lowerName == 'swpm_in_use' ||
        lowerName == 'wp_swpm_in_use' ||
        lowerName == 'swpm_session';
  }

  Future<void> _injectAppCssClasses(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: '''
          (function() {
            var html = document.documentElement;
            var body = document.body;
            if (!html && !body) return;

            var classes = ['rsapp', 'rsapp-webview'];
            var ua = (navigator.userAgent || '').toLowerCase();
            if (ua.indexOf('android') >= 0) {
              classes.push('rsapp-android');
            } else if (ua.indexOf('iphone') >= 0 || ua.indexOf('ipad') >= 0 || ua.indexOf('ipod') >= 0) {
              classes.push('rsapp-ios');
            }

            if (html) {
              html.classList.remove('rsapp-hide');
              for (var i = 0; i < classes.length; i++) {
                html.classList.add(classes[i]);
              }
            }
            if (body) {
              body.classList.remove('rsapp-hide');
              for (var j = 0; j < classes.length; j++) {
                body.classList.add(classes[j]);
              }
            }

            if (!document.getElementById('rsapp-mobile-css')) {
              var style = document.createElement('style');
              style.id = 'rsapp-mobile-css';
              style.type = 'text/css';
              style.appendChild(document.createTextNode(
                [
                  'html.rsapp,html.rsapp body{touch-action:pan-x pan-y!important;}',
                  'html.rsapp .rsapp-hide,html.rsapp .pab-vx-filters-label.rsapp-hide,html.rsapp .mobile-toggle-wrap,html.rsapp .elementor-widget-foxiz-collapse-toggle{display:none!important;}',
                  'html.rsapp .pab-vx-filters-row{display:block!important;overflow:hidden!important;}',
                  'html.rsapp .pab-vx-filters-label:not(.rsapp-hide){display:block!important;margin:0 0 8px!important;}',
                  'html.rsapp .pab-vx-filters{display:flex!important;flex-wrap:nowrap!important;gap:9px!important;overflow-x:auto!important;overflow-y:hidden!important;-webkit-overflow-scrolling:touch!important;scroll-snap-type:x proximity!important;padding:0 18px 12px 22px!important;margin:0!important;}',
                  'html.rsapp .pab-vx-filter-btn{flex:0 0 auto!important;white-space:nowrap!important;scroll-snap-align:start!important;border:1.5px solid #06263F!important;border-radius:999px!important;background:#FFFFFF!important;color:#06263F!important;padding:9px 14px!important;font-weight:700!important;line-height:1!important;box-shadow:0 2px 8px rgba(6,38,63,.08)!important;}',
                  'html.rsapp .pab-vx-filter-btn.is-active{background:#06263F!important;border-color:#06263F!important;color:#FFFFFF!important;box-shadow:0 3px 10px rgba(6,38,63,.22)!important;}',
                  'html.rsapp .pab-vx-filters::-webkit-scrollbar{display:none!important;}',
                  'html.rsapp .pab-vx-filters{scrollbar-width:none!important;}',
                ].join('')
              ));
              (document.head || html || body).appendChild(style);
            }

            var viewportContent = 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
            var viewport = document.querySelector('meta[name="viewport"]');
            if (!viewport) {
              viewport = document.createElement('meta');
              viewport.setAttribute('name', 'viewport');
              (document.head || html || body).appendChild(viewport);
            }
            viewport.setAttribute('content', viewportContent);

            if (!window.rsappDisableZoomReady) {
              window.rsappDisableZoomReady = true;
              ['gesturestart', 'gesturechange', 'gestureend'].forEach(function(eventName) {
                document.addEventListener(eventName, function(event) {
                  event.preventDefault();
                }, { passive: false });
              });
              document.addEventListener('touchmove', function(event) {
                if (event.touches && event.touches.length > 1) {
                  event.preventDefault();
                }
              }, { passive: false });
              document.addEventListener('wheel', function(event) {
                if (event.ctrlKey) {
                  event.preventDefault();
                }
              }, { passive: false });
            }

            window.rsappCenterActiveFilter = function(button) {
              var active = button || document.querySelector('.pab-vx-filter-btn.is-active');
              if (!active) return;
              var rail = active.closest('.pab-vx-filters');
              if (!rail) return;
              var target = active.offsetLeft - (rail.clientWidth - active.offsetWidth) / 2;
              rail.scrollTo({
                left: Math.max(0, target),
                behavior: 'smooth'
              });
            };

            if (!window.rsappFilterCenteringReady) {
              window.rsappFilterCenteringReady = true;
              document.addEventListener('click', function(event) {
                var button = event.target && event.target.closest
                  ? event.target.closest('.pab-vx-filter-btn')
                  : null;
                if (!button) return;
                window.setTimeout(function() {
                  window.rsappCenterActiveFilter(button);
                }, 80);
              }, true);

              var observer = new MutationObserver(function(mutations) {
                for (var i = 0; i < mutations.length; i++) {
                  var target = mutations[i].target;
                  if (target && target.classList && target.classList.contains('is-active')) {
                    window.rsappCenterActiveFilter(target);
                    break;
                  }
                }
              });
              observer.observe(document.documentElement, {
                attributes: true,
                attributeFilter: ['class'],
                subtree: true
              });
            }

            window.setTimeout(function() {
              window.rsappCenterActiveFilter();
            }, 120);
          })();
        ''',
      );
    } catch (_) {
      // CSS hook injection is non-critical.
    }
  }
}
